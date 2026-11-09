//
//  DMPAppConfig.swift
//  dimina
//
//  Created by Lehem on 2025/4/17.
//

import SwiftUI
import UIKit

public struct DMPAppConfig : Identifiable {
    var appName: String
    var appId: String

    var path: String?
    var versionCode: Int?
    var versionName: String?
    public var updateManifestUrl: String?
    public var isDebugMode: Bool = false

    /// Keep service collection and pageFrame activation on the same policy.
    var isVConsoleEnabled: Bool {
        isDebugMode
    }

    var color: Color?
    var icon: String?
    /// 宿主下发的真实小程序图标（来自宿主 catalog 缓存），胶囊菜单里展示用
    var iconImage: UIImage?

    // 符合Identifiable协议的id属性
    public var id: String { appId }

    public init(appName: String, appId: String) {
        self.appName = appName
        self.appId = appId
    }
}
