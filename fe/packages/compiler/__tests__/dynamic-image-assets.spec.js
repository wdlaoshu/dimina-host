import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import build from '../src/index.js'

describe('dynamic image src assets', () => {
	let tempDir
	let outputDir
	const pagePath = 'pages/index/index'
	const appId = 'dynamic-image-app'

	beforeEach(() => {
		tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dynamic-image-assets-'))
		outputDir = path.join(tempDir, 'out')
		writeFile('app.json', JSON.stringify({ pages: [pagePath] }))
		writeFile('app.js', 'App({})\n')
		writeFile('app.wxss', '')
		writeFile('project.config.json', JSON.stringify({ appid: appId }))
		writeFile(`${pagePath}.json`, '{}')
		writeFile(`${pagePath}.js`, 'Page({ data: { isDark: false } })\n')
		writeFile(`${pagePath}.wxss`, '')
		writeFile('images/hero.png', 'png')
		writeFile('images/hero-dark.svg', '<svg></svg>')
		writeFile('images/static.png', 'png')
	})

	afterEach(() => {
		fs.rmSync(tempDir, { recursive: true, force: true })
	})

	function writeFile(relativePath, content) {
		const filePath = path.join(tempDir, relativePath)
		fs.mkdirSync(path.dirname(filePath), { recursive: true })
		fs.writeFileSync(filePath, content)
	}

	function readOutput(relativePath) {
		return fs.readFileSync(path.join(outputDir, relativePath), 'utf8')
	}

	it('发布并改写动态 src 表达式里的本地图片路径', async () => {
		writeFile(
			`${pagePath}.wxml`,
			'<view>'
			+ '<image src="{{isDark ? \'/images/hero-dark.svg\' : \'/images/hero.png\'}}" />'
			+ '<image src="/images/static.png" />'
			+ '<custom-panel icon-path="/images/hero.png" />'
			+ '</view>\n',
		)

		await build(outputDir, tempDir, false)

		const viewOutput = readOutput('main/pages_index_index.js')
		const staticFiles = fs.readdirSync(path.join(outputDir, 'main', 'static'))

		expect(viewOutput).toContain(`${appId}/main/static/`)
		expect(viewOutput).not.toContain('/images/hero')
		expect(viewOutput).not.toContain('/images/static')
		expect(staticFiles.some(file => file.endsWith('_hero.png'))).toBe(true)
		expect(staticFiles.some(file => file.endsWith('_hero-dark.svg'))).toBe(true)
		expect(staticFiles.some(file => file.endsWith('_static.png'))).toBe(true)
	})

	it('不改写动态表达式里的网络图片和普通字符串', async () => {
		writeFile(
			`${pagePath}.wxml`,
			'<view>'
			+ '<image src="{{isDark ? \'https://cdn.example.com/a.png\' : \'/images/hero.png\'}}" />'
			+ '<image src="{{isDark ? \'flex\' : \'none\'}}" />'
			+ '<custom-panel icon-path="/images/missing.svg" />'
			+ '</view>\n',
		)

		await build(outputDir, tempDir, false)

		const viewOutput = readOutput('main/pages_index_index.js')

		expect(viewOutput).toContain('https://cdn.example.com/a.png')
		expect(viewOutput).toContain('flex')
		expect(viewOutput).toContain('none')
		expect(viewOutput).toContain('/images/missing.svg')
		expect(viewOutput).toContain(`${appId}/main/static/`)
	})
})
