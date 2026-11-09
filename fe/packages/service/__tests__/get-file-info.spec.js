import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('@/api/common', () => ({
	invokeAPI: vi.fn(() => 'bridge-result'),
}))

import { invokeAPI } from '@/api/common'
import { getFileInfo } from '@/api/core/file/index.js'

describe('wx.getFileInfo', () => {
	beforeEach(() => {
		vi.mocked(invokeAPI).mockClear()
	})

	// 微信把 getFileInfo 收敛到 FileSystemManager，但顶层入口仍然保留，
	// 小程序（压缩后读取文件大小）会直接用 wx.getFileInfo。
	// 该入口缺失时是 undefined，在 success 回调里调用会抛 TypeError，
	// 把调用方的 Promise 永久挂住（表现为一直“处理中”）。
	it('forwards to FileSystemManager.getFileInfo', () => {
		const options = {
			filePath: 'difile://tmp/a.jpg',
			success: vi.fn(),
			fail: vi.fn(),
		}

		expect(getFileInfo(options)).toBe('bridge-result')
		expect(invokeAPI).toHaveBeenCalledOnce()
		expect(invokeAPI).toHaveBeenCalledWith(
			'FileSystemManager.getFileInfo',
			expect.objectContaining({ filePath: 'difile://tmp/a.jpg' }),
		)
	})
})
