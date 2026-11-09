import fs from 'node:fs'
import { relative, resolve, sep } from 'node:path'
import { isMainThread, parentPort } from 'node:worker_threads'
import { parseSync } from 'oxc-parser'
import { walk } from 'oxc-walker'
import MagicString from 'magic-string'
import { transform } from 'esbuild'
import { getWxMemberName, takeCompatibilityWarnings, warnUnsupportedWxApi } from '../common/compatibility.js'
import { collectAssets, hasCompileInfo, isCollectableImageAsset, resolveAssetSourcePath } from '../common/utils.js'
import { getAppConfigInfo, getAppId, getComponent, getContentByPath, getDependencyGraph, getNpmResolver, getTargetPath, getWorkPath, isMiniGame, resetStoreInfo, resolveAppAlias } from '../env.js'
import { mergeSourcemap, remapSourcemap } from './sourcemap.js'

// 用于缓存已处理的模块
const processedModules = new Set()

// 全局图片路径映射（原始路径 → static 产物路径），供运行时 resolve helper 注入
const localImageMap = new Map()

// 是否生成 sourcemap
let enableSourcemap = false
let sourcemapTargetPath = null

if (!isMainThread) {
	parentPort.on('message', async ({ pages, storeInfo, sourcemap, sourcemapTargetPath: targetPath }) => {
		try {
			resetStoreInfo(storeInfo)
			enableSourcemap = !!sourcemap
			sourcemapTargetPath = targetPath || getTargetPath()

			const progress = {
				_completedTasks: 0,
				get completedTasks() {
					return this._completedTasks
				},
				set completedTasks(value) {
					this._completedTasks = value
					parentPort.postMessage({ completedTasks: this.completedTasks })
				},
			}

			const mainCompileRes = await compileJS(pages.mainPages, null, null, progress)
			for (const [root, subPages] of Object.entries(pages.subPages)) {
				try {
					// 独立分包: https://developers.weixin.qq.com/miniprogram/dev/framework/subpackages/independent.html
					const subCompileRes = await compileJS(
						subPages.info,
						root,
						subPages.independent ? [] : mainCompileRes,
						progress,
					)
					await writeCompileRes(subCompileRes, root)
				}
				catch (error) {
					throw new Error(`Error processing subpackage ${root}: ${error.message}\n${error.stack}`)
				}
			}
			await writeCompileRes(mainCompileRes, null)

			// Worker 任务完成后清理缓存，释放内存
			processedModules.clear()

			parentPort.postMessage({
				success: true,
				compatibilityWarnings: takeCompatibilityWarnings(),
				dependencyGraph: getDependencyGraph().toJSON(),
			})
		}
		catch (error) {
			// 错误时也清理缓存
			processedModules.clear()

			parentPort.postMessage({
				success: false,
				error: {
					message: error.message,
					stack: error.stack,
					name: error.name
				}
			})
		}
	})
}

async function writeCompileRes(compileRes, root) {
	const outputDir = root
		? `${getTargetPath()}/${root}`
		: `${getTargetPath()}/main`

	if (!fs.existsSync(outputDir)) {
		fs.mkdirSync(outputDir, { recursive: true })
	}

	// 注入运行时图片路径 resolve helper：把 localImageMap 里的原始路径→static 路径映射打包
	let runtimeAssetHelper = ''
	if (localImageMap.size > 0) {
		const mapJson = JSON.stringify(Object.fromEntries(localImageMap.entries()))
		runtimeAssetHelper = `(function(){var m=${mapJson};globalThis.__dmTL=function(s){return m[s]||s;};})();`
	}

	/*
	 * sourcemap 模式跳过 minify：
	 * 当前 mergeSourcemap 只做单层行偏移拼接，
	 * 若再对 bundle 整体 minify 则需用 remapping 串联两份 map，暂未实现
	 */
	if (enableSourcemap) {
		const finalOutputDir = root
			? resolve(sourcemapTargetPath, root)
			: resolve(sourcemapTargetPath, 'main')
		const rebasedCompileRes = compileRes.map((module) => {
			if (!module.map) return module
			const moduleMap = JSON.parse(module.map)
			moduleMap.sources = moduleMap.sources.map((source) => {
				const sourcePath = source.replace(/^[/\\]+/, '')
				return relative(finalOutputDir, resolve(getWorkPath(), sourcePath)).split(sep).join('/')
			})
			return { ...module, map: JSON.stringify(moduleMap) }
		})
		const { bundleCode, sourcemap } = mergeSourcemap(rebasedCompileRes)
		const sourcemapFileName = 'logic.js.map'
		fs.writeFileSync(`${outputDir}/logic.js`, `${runtimeAssetHelper}${bundleCode}//# sourceMappingURL=${sourcemapFileName}\n`)
		fs.writeFileSync(`${outputDir}/${sourcemapFileName}`, sourcemap)
	}
	else {
		let mergeCode = runtimeAssetHelper
		for (const module of compileRes) {
			const amdFormat = `modDefine('${module.path}', function(require, module, exports) {
${module.code}
});`
			//TODO: 替换成 https://oxc.rs/docs/guide/usage/minifier.html
			const { code: minifiedCode } = await transform(amdFormat, {
				minify: true,
				target: ['es2023'], // quickjs 支持版本
				platform: 'neutral',
			})
			mergeCode += minifiedCode
		}
		fs.writeFileSync(`${outputDir}/logic.js`, mergeCode)
	}
}

/**
 * 编译 js 文件
 */
async function compileJS(pages, root, mainCompileRes, progress) {
	const compileRes = []
	if (!root && !isMiniGame()) {
		await buildJSByPath(root, { path: 'app' }, compileRes, mainCompileRes, false)
	}

	for (const page of pages) {
		await buildJSByPath(root, page, compileRes, mainCompileRes, true)
		progress.completedTasks++
	}

	return compileRes
}

async function buildJSByPath(packageName, module, compileRes, mainCompileRes, addExtra, activePaths = new Set(), putMain = false) {
	const currentPath = module.path

	if (!currentPath) {
		// 业务逻辑不存在
		return
	}
	// Module cycles are valid dependency graphs. Stop only a back edge on the
	// current traversal path, without truncating a finite deep dependency chain.
	if (activePaths.has(currentPath)) {
		return
	}
	// 防止添加相同的 js
	if (hasCompileInfo(module.path, compileRes, mainCompileRes)) {
		return
	}
	const compileInfo = {
		path: module.path,
		code: '',
		sourceFile: null,
	}

	const src = module.path.startsWith('/') ? module.path : `/${module.path}`
	const modulePath = getJSAbsolutePath(src)
	if (!modulePath) {
		console.warn('[logic]', `找不到模块文件: ${src}`)
		return
	}
	getDependencyGraph().addFile(currentPath, modulePath, 'logic')
	const diagnosticSource = modulePath.startsWith(getWorkPath())
		? modulePath.slice(getWorkPath().length)
		: src
	
	const sourceCode = getContentByPath(modulePath)
	if (!sourceCode) {
		console.warn('[logic]', `无法读取模块文件: ${modulePath}`)
		return
	}
	const isTypeScript = modulePath.endsWith('.ts')

	// 记录源文件路径，用于 sourcemap
	if (enableSourcemap) {
		const workPath = getWorkPath()
		compileInfo.sourceFile = modulePath.startsWith(workPath)
			? modulePath.slice(workPath.length)
			: src
	}

	// 使用 oxc-parser 解析代码
	const parseResult = parseSync(modulePath, sourceCode, {
		sourceType: 'module',
		lang: isTypeScript ? 'ts' : 'js'
	})
	const ast = parseResult.program
	
	// 使用 MagicString 进行代码修改
	const s = new MagicString(sourceCode)

	// 构建 extraInfo 对象（使用 JSON 而不是 AST）
	const extraInfo = {
		path: module.path
	}
	activePaths.add(currentPath)

	// https://developers.weixin.qq.com/miniprogram/dev/framework/custom-component/
	// 将 component 字段设为 true 可将这一组文件设为自定义组件
	if (module.component) {
		extraInfo.component = true
	}

	if (module.usingComponents) {
		const componentsObj = {}
		const allSubPackages = getAppConfigInfo().subPackages
		const graphDependencies = getDependencyGraph().getDirectDependencies(module.path, 'component')
		const componentDependencies = graphDependencies.length > 0
			? new Set(graphDependencies)
			: null

		for (const [name, path] of Object.entries(module.usingComponents)) {
			if (componentDependencies && !componentDependencies.has(path)) {
				continue
			}
			let toMainSubPackage = true
			if (packageName) {
				// 如果依赖的组件不在当前的分包，则跳过该组件的编译逻辑，保证分包代码的独立性
				// 考虑到路径可能是 'test/src' 这样的格式，使用前缀匹配而不是分割比较
				const normalizedPath = path.startsWith('/') ? path.substring(1) : path

				// 如果不属于任意分包则将逻辑移动到主包
				for (const subPackage of allSubPackages) {
					if (normalizedPath.startsWith(`${subPackage.root}/`)) {
						toMainSubPackage = false
						break
					}
				}
			}
			else {
				toMainSubPackage = false
			}

			const componentModule = getComponent(path)
			if (!componentModule) {
				continue
			}

			await buildJSByPath(packageName, componentModule, compileRes, mainCompileRes, true, activePaths, putMain || toMainSubPackage)

			componentsObj[name] = path
		}
		extraInfo.usingComponents = componentsObj
	}

	// 如果需要添加 extraInfo，在代码开头注入
	if (addExtra) {
		const extraInfoCode = `globalThis.__extraInfo = ${JSON.stringify(extraInfo)};\n`
		if (enableSourcemap) {
			// 存到 compileInfo，在 modDefine header 中注入，避免影响 sourcemap 行号
			compileInfo.extraInfoCode = extraInfoCode
		} else {
			s.prepend(extraInfoCode)
		}
	}

	if (putMain) {
		mainCompileRes.push(compileInfo)
	}
	else {
		compileRes.push(compileInfo)
	}

	// 收集需要修改的路径信息和依赖模块
	const pathReplacements = []
	const templateWrapReplacements = []
	const dependenciesToProcess = []

	walk(ast, {
		enter(node, parent) {
			const wxMemberName = getWxMemberName(node)
			if (wxMemberName) {
				warnUnsupportedWxApi(
					wxMemberName,
					compileInfo.sourceFile || diagnosticSource,
					node.loc?.start?.line || getLineByIndex(sourceCode, node.start),
				)
			}

			if ((node.type === 'StringLiteral' || node.type === 'Literal') && isLocalAssetString(node.value)) {
				getDependencyGraph().addFile(
					currentPath,
					resolveAssetSourcePath(getWorkPath(), modulePath, node.value),
					'logic',
				)
				const replacement = collectAssets(getWorkPath(), modulePath, node.value, getTargetPath(), getAppId())
				pathReplacements.push({
					start: node.start,
					end: node.end,
					newValue: replacement,
				})
				localImageMap.set(node.value, replacement.replace(/^'|'$/g, ''))
			}

			// 处理模板字符串里的本地图片路径
			if (node.type === 'TemplateLiteral') {
				const quasis = node.quasis || []

				// 无表达式的模板字符串，整体当作 StringLiteral 处理
				if (node.expressions.length === 0 && quasis.length === 1) {
					const value = quasis[0]?.value?.cooked ?? quasis[0]?.value?.raw ?? ''
					if (isLocalAssetString(value)) {
						getDependencyGraph().addFile(
							currentPath,
							resolveAssetSourcePath(getWorkPath(), modulePath, value),
							'logic',
						)
						const replacement = collectAssets(getWorkPath(), modulePath, value, getTargetPath(), getAppId())
						pathReplacements.push({
							start: node.start,
							end: node.end,
							newValue: replacement,
						})
						localImageMap.set(value, replacement.replace(/^'|'$/g, ''))
					}
				}
				else {
					// 有表达式的模板字符串：逐个 TemplateElement 检查完整路径片段
					let looksLikeImageTemplate = false
					for (const quasi of quasis) {
						const cooked = quasi.value?.cooked ?? quasi.value?.raw ?? ''
						if (!cooked) continue

						// TemplateElement 本身就是一张完整图片（比如被两个 expression 夹在中间）
						if (isLocalAssetString(cooked) && quasi.start != null && quasi.end != null) {
							getDependencyGraph().addFile(
								currentPath,
								resolveAssetSourcePath(getWorkPath(), modulePath, cooked),
								'logic',
							)
							const replacement = collectAssets(getWorkPath(), modulePath, cooked, getTargetPath(), getAppId())
							pathReplacements.push({
								start: quasi.start,
								end: quasi.end,
								newValue: replacement,
							})
							localImageMap.set(cooked, replacement.replace(/^'|'$/g, ''))
						}

						// 静态片段以 `/` 开头且看起来像路径（前缀或后缀都算）→ 整个模板字符串需要运行时 resolve
						if (cooked.startsWith('/images/') || cooked.startsWith('./images/') || cooked.startsWith('../images/')) {
							looksLikeImageTemplate = true
						}
						else if ((cooked.startsWith('/') || cooked.startsWith('./') || cooked.startsWith('../')) && /\.[a-z0-9]+$/i.test(cooked)) {
							// 以路径前缀开头且以文件后缀结尾
							looksLikeImageTemplate = true
						}
					}

					// 整段用 __dmTL 包裹，运行时拼完字符串再过 resolve helper
					if (looksLikeImageTemplate && node.start != null && node.end != null) {
						templateWrapReplacements.push({
							start: node.start,
							end: node.end,
						})

						// 扫描目录把所有可能被拼出来的变体都 collect + 放进 localImageMap
						// 比如 `/images/icon-user${suffix}.svg` 需要同时收集 icon-user.svg 和 icon-user-dark.svg
						const { dir, ext } = extractImageScanParams(quasis)
						if (dir && ext) {
							const workPath = getWorkPath()
							const dirAbs = resolveAssetSourcePath(workPath, modulePath, dir)
							try {
								if (fs.existsSync(dirAbs)) {
									const files = fs.readdirSync(dirAbs).filter(f =>
										f.toLowerCase().endsWith(ext)
									)
									for (const file of files) {
										const fullSrc = dir.replace(/\/$/, '') + '/' + file
										if (!localImageMap.has(fullSrc)) {
											getDependencyGraph().addFile(
												currentPath,
												resolveAssetSourcePath(workPath, modulePath, fullSrc),
												'logic',
											)
											const replacement = collectAssets(
												workPath, modulePath, fullSrc, getTargetPath(), getAppId()
											)
											localImageMap.set(fullSrc, replacement.replace(/^'|'$/g, ''))
										}
									}
								}
							}
							catch (_) {
								// 目录不存在或读取失败，忽略 —— __dmTL 兜底返回原值
							}
						}
					}
				}
			}

			// 处理 require() 调用
			if (node.type === 'CallExpression') {
				// 检查是否是 require() 调用
				const isRequire = node.callee.type === 'Identifier' && node.callee.name === 'require'
				const isRequireProperty = node.callee.type === 'MemberExpression'
					&& node.callee.object?.type === 'Identifier'
					&& node.callee.object?.name === 'require'

				if (
					(isRequire || isRequireProperty)
					&& node.arguments.length > 0
					&& (node.arguments[0].type === 'StringLiteral' || node.arguments[0].type === 'Literal')
				) {
					const arg = node.arguments[0]
					const requirePath = arg.value

					if (requirePath) {
						const { id, shouldProcess } = resolveDependencyId(requirePath, modulePath, false)

						if (shouldProcess) {
							getDependencyGraph().addDependency(currentPath, id, 'logic')
							pathReplacements.push({
								start: arg.start,
								end: arg.end,
								newValue: id,
							})

							if (!processedModules.has(packageName + id)) {
								dependenciesToProcess.push(id)
							}
						}
					}
				}
			}

			// 处理 ES6 import 语句
			if (node.type === 'ImportDeclaration') {
				const importPath = node.source.value
				if (importPath) {
					const { id, shouldProcess } = resolveDependencyId(importPath, modulePath, true)

					if (shouldProcess) {
						getDependencyGraph().addDependency(currentPath, id, 'logic')
						pathReplacements.push({
							start: node.source.start,
							end: node.source.end,
							newValue: id,
						})

						if (!processedModules.has(packageName + id)) {
							dependenciesToProcess.push(id)
						}
					}
				}
			}

			// 处理 TypeScript import equals，如 import helper = require('./helper')
			if (
				node.type === 'TSImportEqualsDeclaration'
				&& node.moduleReference?.type === 'TSExternalModuleReference'
			) {
				const importPathNode = node.moduleReference.expression
				const importPath = importPathNode?.value
				if (importPath) {
					const { id, shouldProcess } = resolveDependencyId(importPath, modulePath, false)

					if (shouldProcess) {
						getDependencyGraph().addDependency(currentPath, id, 'logic')
						pathReplacements.push({
							start: importPathNode.start,
							end: importPathNode.end,
							newValue: id,
						})

						if (!processedModules.has(packageName + id)) {
							dependenciesToProcess.push(id)
						}
					}
				}
			}

			// 处理 re-export 语句，如 export * from './foo'
			// 这类语句不会出现在运行时 require 中，必须在这里提前收集依赖。
			if (
				(node.type === 'ExportAllDeclaration' || node.type === 'ExportNamedDeclaration')
				&& node.source
			) {
				const exportPath = node.source.value
				if (exportPath) {
					const { id, shouldProcess } = resolveDependencyId(exportPath, modulePath, true)

					if (shouldProcess) {
						getDependencyGraph().addDependency(currentPath, id, 'logic')
						pathReplacements.push({
							start: node.source.start,
							end: node.source.end,
							newValue: id,
						})

						if (!processedModules.has(packageName + id)) {
							dependenciesToProcess.push(id)
						}
					}
				}
			}
		}
	})

	// 处理所有依赖模块（异步）
	for (const depId of dependenciesToProcess) {
		await buildJSByPath(packageName, { path: depId }, compileRes, mainCompileRes, false, activePaths, putMain)
	}

	// 反向遍历修改，避免位置偏移
	for (const replacement of pathReplacements.reverse()) {
		s.overwrite(replacement.start, replacement.end, `'${replacement.newValue}'`)
	}

	// 给被表达式断开的图片路径模板字符串加 runtime resolve 包裹
	for (const wrap of templateWrapReplacements.reverse()) {
		s.appendRight(wrap.end, ')')
		s.appendLeft(wrap.start, '__dmTL(')
	}

	const modifiedCode = s.toString()
	let preEsbuildMap = null
	if (enableSourcemap && compileInfo.sourceFile) {
		const generatedMap = JSON.parse(s.generateMap({
			file: compileInfo.sourceFile,
			source: compileInfo.sourceFile,
			includeContent: true,
			hires: true,
		}).toString())
		generatedMap.file = compileInfo.sourceFile
		generatedMap.sources = [compileInfo.sourceFile]
		generatedMap.sourcesContent = [sourceCode]
		preEsbuildMap = JSON.stringify(generatedMap)
	}

	// 使用 esbuild 进行最终的 CommonJS 转换和压缩
	try {
		const esbuildOpts = {
			format: 'cjs',
			target: 'es2020',
			platform: 'neutral',
			loader: isTypeScript ? 'ts' : 'js',
		}
		/*
		 * 当前 sourcemap 会串联 MagicString 和 esbuild 两步 map：
		 * - JS / TS 都先经过 MagicString 路径重写，再交给 esbuild 生成 map
		 * - 这样可避免 TS 先被 transpile 成 JS 后再伪装为 .ts 输出 sourcemap
		 * - bundle 阶段只做 modDefine 包裹和模块拼接，因此 sourcemap 模式会跳过最终 minify
		 */
		if (enableSourcemap && compileInfo.sourceFile) {
			esbuildOpts.sourcemap = true
			esbuildOpts.sourcefile = compileInfo.sourceFile
			esbuildOpts.sourcesContent = true
		}
		const esbuildResult = await transform(modifiedCode, esbuildOpts)

		if (enableSourcemap && esbuildResult.map) {
			compileInfo.map = preEsbuildMap
				? remapSourcemap(esbuildResult.map, preEsbuildMap)
				: esbuildResult.map
		}
		compileInfo.code = esbuildResult.code
	} catch (error) {
		console.error(`[logic] esbuild 转换失败 ${modulePath}:`, error.message)
		// 如果 esbuild 转换失败，使用路径改写后的源码
		compileInfo.code = modifiedCode
	}
	
	// 将当前模块标记为已处理
	processedModules.add(packageName + currentPath)
	activePaths.delete(currentPath)
}

function isLocalAssetString(value) {
	return typeof value === 'string'
		&& !value.startsWith('http')
		&& !value.startsWith('//')
		&& (value.startsWith('/') || value.startsWith('./') || value.startsWith('../'))
		&& isCollectableImageAsset(value)
}

/**
 * 从 TemplateLiteral 的 quasis 里提取图片扫描参数：{ dir, ext }
 * - dir: 能确定的目录前缀（如 '/images/'），用于扫描所有可能被模板字符串拼出来的变体
 * - ext: 能确定的文件扩展名（如 '.svg'）
 * 返回 null 表示无法提取足够信息（放弃收集，仅靠 __dmTL 兜底）
 */
function extractImageScanParams(quasis) {
	const extPattern = /\.(svg|png|jpe?g|gif|webp|heic|heif)/i
	let dir = null
	let ext = null

	for (const quasi of quasis) {
		const cooked = quasi?.value?.cooked ?? quasi?.value?.raw ?? ''
		if (!cooked) continue

		// 提取扩展名
		const m = cooked.match(extPattern)
		if (m && !ext) {
			ext = m[0].toLowerCase()
		}

		// 提取目录（第一个以路径前缀开头的片段）
		if (!dir) {
			const pathStart = cooked.match(/^(\/images\/|\.\/images\/|\.\.\/images\/|\/|\.\/|\.\.)/)
			if (pathStart) {
				const prefix = pathStart[1]
				const afterPrefix = cooked.slice(prefix.length)
				const slashIdx = afterPrefix.lastIndexOf('/')
				if (slashIdx >= 0) {
					dir = prefix + afterPrefix.slice(0, slashIdx + 1)
				}
				else {
					dir = prefix
				}
			}
		}
	}

	return { dir, ext }
}

function getLineByIndex(content, index) {
	if (typeof index !== 'number' || index < 0) {
		return null
	}

	let line = 1
	for (let i = 0; i < index; i++) {
		if (content.charCodeAt(i) === 10) {
			line++
		}
	}
	return line
}

/**
 * 获取 JavaScript 或 TypeScript 文件的绝对路径
 * @param {string} modulePath - 模块路径
 * @returns {string|null} - 文件的绝对路径，如果找不到则返回 null
 */
function getJSAbsolutePath(modulePath) {
	const workPath = getWorkPath()
	const resolvedModuleId = resolveModuleIdToExistingPath(modulePath)
	if (!resolvedModuleId) {
		return null
	}

	const fileTypes = ['.js', '.ts']
	for (const ext of fileTypes) {
		const fullPath = `${workPath}${resolvedModuleId}${ext}`
		if (fs.existsSync(fullPath)) {
			return fullPath
		}
	}

	return null
}

function resolveDependencyId(specifier, modulePath, allowAbsolute) {
	if (!specifier) {
		return { id: specifier, shouldProcess: false }
	}

	if (specifier.startsWith('miniprogram_npm/')) {
		const npmModuleId = normalizeModuleId(`/${specifier}`)
		return {
			id: resolveModuleIdToExistingPath(npmModuleId) || npmModuleId,
			shouldProcess: true,
		}
	}

	if (specifier.startsWith('./') || specifier.startsWith('../')) {
		const resolved = resolveRelativeModuleId(specifier, modulePath)
		return {
			id: resolved || specifier,
			shouldProcess: !!resolved,
		}
	}

	if (specifier.startsWith('/')) {
		const absResolved = allowAbsolute ? normalizeModuleId(specifier) : resolveRelativeModuleId(specifier, modulePath)
		return {
			id: absResolved || specifier,
			shouldProcess: !!absResolved,
		}
	}

	const aliasResolved = resolveAppAlias(specifier)
	if (aliasResolved) {
		return {
			id: normalizeModuleId(aliasResolved),
			shouldProcess: true,
		}
	}

	if (specifier.startsWith('@') || isBareModuleSpecifier(specifier)) {
		const npmModuleId = resolveNpmModuleId(specifier, modulePath)
		if (npmModuleId) {
			return {
				id: npmModuleId,
				shouldProcess: true,
			}
		}

		const siblingModuleId = resolveBareSiblingModuleId(specifier, modulePath)
		return {
			id: siblingModuleId || specifier,
			shouldProcess: Boolean(siblingModuleId),
		}
	}

	return { id: specifier, shouldProcess: false }
}

function isBareModuleSpecifier(specifier) {
	return !specifier.startsWith('.') && !specifier.startsWith('/')
}

function resolveRelativeModuleId(specifier, modulePath) {
	const requireFullPath = resolve(modulePath, `../${specifier}`)
	const relativeId = requireFullPath.split(`${getWorkPath()}${sep}`)[1]
	if (!relativeId) {
		// 路径不在项目根目录下，直接返回原始 specifier 让调用方决定是否跳过
		return null
	}
	return normalizeModuleId(relativeId)
}

function resolveBareSiblingModuleId(specifier, modulePath) {
	const siblingModuleId = resolveRelativeModuleId(`./${specifier}`, modulePath)
	return resolveModuleIdToExistingPath(siblingModuleId)
}

function normalizeModuleId(moduleId) {
	let normalized = moduleId.replace(/\.(js|ts)$/, '').replace(/\\/g, '/')
	if (!normalized.startsWith('/')) {
		normalized = `/${normalized}`
	}
	return normalized
}

function resolveNpmModuleId(specifier, modulePath) {
	const npmResolver = getNpmResolver()
	if (!npmResolver) {
		return null
	}
	return npmResolver.resolveScriptModule(specifier, modulePath, resolveModuleIdToExistingPath)
}

function resolveModuleIdToExistingPath(moduleId) {
	const normalizedModuleId = normalizeModuleId(moduleId)
	const workPath = getWorkPath()

	for (const ext of ['.js', '.ts']) {
		if (fs.existsSync(`${workPath}${normalizedModuleId}${ext}`)) {
			return normalizedModuleId
		}
	}

	for (const ext of ['.js', '.ts']) {
		if (fs.existsSync(`${workPath}${normalizedModuleId}/index${ext}`)) {
			return `${normalizedModuleId}/index`
		}
	}

	const packageJsonPath = `${workPath}${normalizedModuleId}/package.json`
	if (fs.existsSync(packageJsonPath)) {
		try {
			const packageInfo = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8'))
			for (const entryField of ['miniprogram', 'main']) {
				if (typeof packageInfo[entryField] === 'string' && packageInfo[entryField]) {
					const entryModuleId = normalizeModuleId(resolve(normalizedModuleId, packageInfo[entryField]))
					const resolvedEntry = resolveModuleIdToExistingPath(entryModuleId)
					if (resolvedEntry) {
						return resolvedEntry
					}
				}
			}
		}
		catch (error) {
			console.warn('[logic]', `解析 package.json 失败: ${packageJsonPath}`, error.message)
		}
	}

	return null
}

export { compileJS, buildJSByPath }
