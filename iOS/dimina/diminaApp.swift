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
            HostRootView()
        }
    }
}

/// 应用根容器。
/// 小程序容器需要向应用级 UINavigationController push 页面，返回时再 pop 回宿主首页。
/// 这里在启动时就创建好导航控制器，避免运行时替换 window.rootViewController 造成的
/// 首屏闪烁、导航栏遮挡首页按钮以及返回后布局变化的问题。
struct HostRootView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let hostingController = UIHostingController(rootView: ContentView())
        hostingController.view.backgroundColor = UIColor(HostTheme.bg)

        let navigationController = UINavigationController(rootViewController: hostingController)
        navigationController.setNavigationBarHidden(true, animated: false)

        ContentView.navigationController = navigationController
        return navigationController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}
