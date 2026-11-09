import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import build from '../src/index.js'

describe('logic-compiler template literal assets', () => {
	let tempDir
	let outputDir
	const pagePath = 'pages/index/index'
	const appId = 'tmpl-assets-app'

	beforeEach(() => {
		tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tmpl-assets-'))
		outputDir = path.join(tempDir, 'out')
		writeFile('app.json', JSON.stringify({ pages: [pagePath] }))
		writeFile('app.js', 'App({})\n')
		writeFile('app.wxss', '')
		writeFile('project.config.json', JSON.stringify({ appid: appId }))
		writeFile(`${pagePath}.json`, '{}')
		writeFile(`${pagePath}.wxss`, '')
		writeFile('images/cover.png', 'png')
		writeFile('images/cover-dark.png', 'png')
		writeFile('images/avatar.svg', '<svg></svg>')
	})

	afterEach(() => { fs.rmSync(tempDir, { recursive: true, force: true }) })

	function writeFile(relativePath, content) {
		const filePath = path.join(tempDir, relativePath)
		fs.mkdirSync(path.dirname(filePath), { recursive: true })
		fs.writeFileSync(filePath, content)
	}

	function readOutput(relativePath) {
		return fs.readFileSync(path.join(outputDir, relativePath), 'utf8')
	}

	it('处理无表达式模板字符串里的本地图片路径', async () => {
		writeFile(
			`${pagePath}.js`,
			'Page({ data: { url: `/images/cover.png`, avatar: `/images/avatar.svg` } })\n',
		)

		await build(outputDir, tempDir, false)

		const logic = readOutput('main/logic.js')
		const staticDir = fs.readdirSync(path.join(outputDir, 'main', 'static'))

		expect(logic).toContain(`${appId}/main/static/`)
		expect(logic).not.toContain('`/images/')
		expect(staticDir.some(f => f.includes('cover.png'))).toBe(true)
		expect(staticDir.some(f => f.includes('avatar.svg'))).toBe(true)
	})

	it('处理普通 StringLiteral 里的本地图片路径（回归）', async () => {
		writeFile(
			`${pagePath}.js`,
			"Page({ data: { url: '/images/cover.png' } })\n",
		)

		await build(outputDir, tempDir, false)

		const logic = readOutput('main/logic.js')
		expect(logic).toContain(`${appId}/main/static/`)
		expect(logic).not.toContain("'/images/cover.png'")
	})

	it('运行时 resolve helper 包裹被表达式断开的图片模板字符串', async () => {
		// 用一个 esbuild 无法静态求值的表达式，避免被提前求值
		writeFile(
			`${pagePath}.js`,
			'let suffix = globalThis.suffix;\nPage({ data: { url: `/images/cover${suffix}.png` } })\n',
		)
		writeFile('images/cover-dark.png', 'png-dark')

		await build(outputDir, tempDir, false)

		const logic = readOutput('main/logic.js')
		const staticDir = fs.readdirSync(path.join(outputDir, 'main', 'static'))

		// 1. 运行时 resolve helper 已注入
		expect(logic).toContain('__dmTL')

		// 2. 模板字符串被 __dmTL 包裹（运行时拼完图片路径再过 resolve）
		//    注意：esbuild minify 会把变量名改成短名，不能硬编码 'suffix'
		expect(logic).toMatch(/__dmTL\([^)]*cover[^)]*\.png/)

		// 3. static 目录里有 cover.png（被模板字符串扫描逻辑收集）
		expect(staticDir.some(f => f.includes('cover.png'))).toBe(true)

		// 4. cover-dark.png 也被扫描逻辑发现并收集进 static + localImageMap
		expect(staticDir.some(f => f.includes('cover-dark.png'))).toBe(true)
		expect(logic).toContain('/images/cover-dark.png')
	})
})
