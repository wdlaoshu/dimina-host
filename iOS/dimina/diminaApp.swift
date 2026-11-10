//
//  diminaApp.swift
//  dimina
//
//  Created by Lehem on 2025/4/15.
//

import SwiftUI
import UIKit

@main
struct diminaApp: App {
    // 主题观察放在 App 层：@AppStorage 在 representable（非 View）中不会可靠触发
    // updateUIViewController；在这里持有时，改动会重建 HostRootView 并同步 preferredColorScheme。
    @AppStorage(HostThemeMode.storageKey) private var themeMode = HostThemeMode.system.rawValue

    var body: some Scene {
        WindowGroup {
            // 根容器铺满整屏，避免状态栏与 Home Indicator 区域露出白色背景
            HostRootView(themeMode: themeMode)
                .ignoresSafeArea()
                .preferredColorScheme(HostThemeMode(rawValue: themeMode)?.colorScheme)
        }
    }
}

/// 应用根容器。
/// 小程序容器需要向应用级 UINavigationController push 页面，返回时再 pop 回宿主首页。
/// 这里在启动时就创建好导航控制器，避免运行时替换 window.rootViewController 造成的
/// 首屏闪烁、导航栏遮挡首页按钮以及返回后布局变化的问题。
struct HostRootView: UIViewControllerRepresentable {
    /// 来自 App 层的主题设置（system/light/dark），变化时触发 updateUIViewController 刷新导航栈外观覆盖
    let themeMode: String

    func makeUIViewController(context: Context) -> UINavigationController {
        let hostingController = UIHostingController(rootView: ContentView())
        hostingController.view.backgroundColor = UIColor(HostTheme.bg)

        let navigationController = DMPNavigationController(rootViewController: hostingController)
        navigationController.setNavigationBarHidden(true, animated: false)
        navigationController.view.backgroundColor = UIColor(HostTheme.bg)
        navigationController.overrideUserInterfaceStyle = HostThemeMode(rawValue: themeMode)?.uiStyle ?? .unspecified

        ContentView.navigationController = navigationController
        return navigationController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        uiViewController.overrideUserInterfaceStyle = HostThemeMode(rawValue: themeMode)?.uiStyle ?? .unspecified
    }
}
