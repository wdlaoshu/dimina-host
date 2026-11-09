import Testing
import UIKit
@testable import dimina

extension DMPUIIntegrationTests {
    @Suite
    @MainActor
    struct LoadingSequenceTests {
        private let api = InteractionAPI()
        private let env = DMPBridgeEnv(appIndex: -1, appId: "loading-sequence", webViewId: 1)

        private func call(_ name: String, title: String = "SequenceLoading") {
            let handler = name == "showLoading" ? api.showLoading : api.hideLoading
            _ = handler(DMPBridgeParam(value: ["title": title, "mask": true]), env, nil)
        }
        private func drainMainQueue() async {
            // Both the bridge and presenter enqueue UI work in the existing implementation.
            for _ in 0..<3 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
        private func rootViews() -> [UIView] {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .compactMap { $0.rootViewController?.view }
        }
        private func containsLabel(_ view: UIView, title: String) -> Bool {
            (view as? UILabel)?.text == title || view.subviews.contains { containsLabel($0, title: title) }
        }
        /// Toast 现在直接挂在当前窗口的根视图上，覆盖层是根视图的直接子视图。
        private func toastOverlays(title: String) -> [UIView] {
            rootViews().flatMap { root in
                root.subviews.filter { containsLabel($0, title: title) }
            }
        }
        private func setAnimationSpeed(_ speed: Float, for layer: CALayer) {
            // Keep local time continuous: changing speed alone rewinds an active
            // animation by a fraction of system uptime on long-running devices.
            let now = CACurrentMediaTime()
            let localTime = layer.convertTime(now, from: nil)
            let parentTime = layer.superlayer?.convertTime(now, from: nil) ?? now
            layer.speed = speed
            layer.beginTime = parentTime - (localTime - layer.timeOffset) / Double(speed)
        }
        /// 轮询等待某个 toast 状态稳定（出现或消失），同时推进主队列。
        private func poll(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(timeout))
            while !condition() {
                try #require(clock.now < deadline, "Toast did not reach the expected state in time")
                try await clock.sleep(for: .milliseconds(10))
                await drainMainQueue()
            }
        }

        @Test(arguments: [Float(1), Float(0.25)])
        func secondLoadingSurvivesFirstHideAnimationAndCanBeHidden(animationSpeed: Float) async throws {
            call("showLoading", title: "First")
            await drainMainQueue()
            let firstOverlay = try #require(toastOverlays(title: "First").first)
            // Exercise slower animation completion without blocking the main thread.
            setAnimationSpeed(animationSpeed, for: firstOverlay.layer)
            defer { setAnimationSpeed(1, for: firstOverlay.layer) }

            call("hideLoading")
            await drainMainQueue() // Start fade-out, then replace it before completion.
            call("showLoading", title: "Second")
            await drainMainQueue()

            // 淡出 0.25s（0.25 倍速下更久）结束后的 completion 不能把新的 loading 收掉。
            try await ContinuousClock().sleep(for: .milliseconds(500))
            await drainMainQueue()
            let secondOverlays = toastOverlays(title: "Second")
            #expect(secondOverlays.count == 1)
            #expect(secondOverlays.first?.alpha == 1)
            #expect(toastOverlays(title: "First").isEmpty)

            call("hideLoading")
            await drainMainQueue()
            try await poll { toastOverlays(title: "Second").isEmpty }
        }

        @Test func rapidDoubleCycleEndsHiddenAndNextShowWorks() async throws {
            call("showLoading"); call("hideLoading")
            call("showLoading"); call("hideLoading")
            await drainMainQueue()
            try await poll { toastOverlays(title: "SequenceLoading").isEmpty }

            call("showLoading", title: "Fresh")
            await drainMainQueue()
            #expect(toastOverlays(title: "Fresh").count == 1)

            call("hideLoading")
            await drainMainQueue()
            try await poll { toastOverlays(title: "Fresh").isEmpty }
        }

        @Test func oldToastTimeoutCannotHideReplacementLoading() async throws {
            _ = api.showToast(DMPBridgeParam(value: ["title": "Toast", "duration": 50]), env, nil)
            await drainMainQueue()
            call("showLoading", title: "Persistent")
            await drainMainQueue()

            // 50ms 的 toast 超时到期时，不能把后面替换上来的 loading 收掉。
            try await ContinuousClock().sleep(for: .milliseconds(300))
            await drainMainQueue()
            let overlays = toastOverlays(title: "Persistent")
            #expect(overlays.count == 1)
            #expect(overlays.first?.alpha == 1)

            call("hideLoading")
            await drainMainQueue()
            try await poll { toastOverlays(title: "Persistent").isEmpty }
        }

        @Test func repeatedShowReplacesThePreviousToast() async throws {
            call("showLoading", title: "Old")
            await drainMainQueue()
            call("showLoading", title: "New")
            await drainMainQueue()
            #expect(toastOverlays(title: "Old").isEmpty)
            #expect(toastOverlays(title: "New").count == 1)

            call("hideLoading"); call("hideLoading")
            await drainMainQueue()
            try await poll { toastOverlays(title: "New").isEmpty }
        }
    }
}
