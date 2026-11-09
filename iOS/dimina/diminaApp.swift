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
    var body: some Scene {
        WindowGroup {
            // 根容器铺满整屏，避免状态栏与 Home Indicator 区域露出白色背景
            HostRootView()
                .ignoresSafeArea()
        }
    }
}

/// 应用根容器。
/// 小程序容器需要向应用级 UINavigationController push 页面，返回时再 pop 回宿主首页。
/// 这里在启动时就创建好导航控制器，避免运行时替换 window.rootViewController 造成的
/// 首屏闪烁、导航栏遮挡首页按钮以及返回后布局变化的问题。
struct HostRootView: UIViewControllerRepresentable {
    // 设置页改动后触发 updateUIViewController，把外观覆盖同步到整个导航栈
    @AppStorage(HostThemeMode.storageKey) private var themeMode = HostThemeMode.system.rawValue

    func makeUIViewController(context: Context) -> UINavigationController {
        let hostingController = UIHostingController(rootView: ContentView())
        hostingController.view.backgroundColor = UIColor(HostTheme.bg)

        let navigationController = UINavigationController(rootViewController: hostingController)
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
