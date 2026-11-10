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

    // 小程序页面在栈顶时，整窗外观要跟着小程序自身深浅走（微信同款）：
    // 宿主是深色、小程序是浅色时，状态栏区域和图标才是小程序自己的浅色。
    // 回到宿主后框架会广播 .unspecified，这里自动回落到宿主的主题设置。
    @State private var miniProgramStyle: UIUserInterfaceStyle = .unspecified

    var body: some Scene {
        WindowGroup {
            // 根容器铺满整屏，避免状态栏与 Home Indicator 区域露出白色背景
            HostRootView(themeMode: themeMode)
                .ignoresSafeArea()
                .preferredColorScheme(preferredScheme)
                .onReceive(
                    NotificationCenter.default.publisher(for: .dmpMiniProgramInterfaceStyleDidChange)
                ) { note in
                    if let raw = note.userInfo?["style"] as? Int,
                        let style = UIUserInterfaceStyle(rawValue: raw)
                    {
                        miniProgramStyle = style
                    } else {
                        miniProgramStyle = .unspecified
                    }
                }
        }
    }

    /// 小程序在栈顶时用小程序自己的深浅；否则用宿主设置的三档主题
    private var preferredScheme: ColorScheme? {
        switch miniProgramStyle {
        case .light:
            return .light
        case .dark:
            return .dark
        default:
            return HostThemeMode(rawValue: themeMode)?.colorScheme
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
