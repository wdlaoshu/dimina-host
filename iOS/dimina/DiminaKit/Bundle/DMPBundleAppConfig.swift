//
//  DMPBundleAppConfig.swift
//  dimina
//
//  Created by Lehem on 2025/4/21.
//

import Foundation

public class DMPBundleAppConfig {
    var data: [String: Any]
    var app: [String: Any]
    var modules: [String: Any]
    var pages: [String]?
    var tabBar: DMPTabBarConfig?
    var style: String
    var sitemapLocation: String
    var subPackages: [SubPackageConfig]
    var _entryPagePath: String
    let runtimeType: String
    var moduleMaps: [String: ModuleConfig]
    
    init(data: [String: Any]) {
        self.data = data
        self.app = data["app"] as? [String: Any] ?? [:]
        self.modules = data["modules"] as? [String: Any] ?? [:]
        
        self.pages = self.app["pages"] as? [String]
        self.tabBar = DMPTabBarConfig.from(self.app["tabBar"] as? [String: Any])
        self.style = self.app["style"] as? String ?? ""
        self.sitemapLocation = self.app["sitemapLocation"] as? String ?? ""
        self.subPackages = (self.app["subPackages"] as? [[String: Any]] ?? []).compactMap { package in
            guard let root = package["root"] as? String, !root.isEmpty,
                  let pages = package["pages"] as? [String] else { return nil }
            return SubPackageConfig(root: root, pages: pages)
        }
        self._entryPagePath = self.app["entryPagePath"] as? String ?? ""
        self.runtimeType = self.app["runtimeType"] as? String == "game" ? "game" : "miniProgram"
        
        // app.pages / subPackages 声明页面；modules 只是可选的页面配置。
        // 远程包可能完全省略页面私有配置，不能因此拒绝已声明的入口。
        var maps = [String: ModuleConfig]()
        // 小游戏入口不是普通页面，不从 pages / subPackages 合成页面模块。
        if self.runtimeType == "miniProgram" {
            for pagePath in self.pages ?? [] where !pagePath.isEmpty {
                maps[pagePath] = ModuleConfig(root: "main", pages: [pagePath])
            }
            for package in self.subPackages {
                let root = package.root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !root.isEmpty else { continue }
                for page in package.pages where !page.isEmpty {
                    let pagePath = root + "/" + page
                    maps[pagePath] = ModuleConfig(root: root, pages: [pagePath])
                }
            }
        }
        
        for (pagePath, moduleData) in self.modules {
            guard let moduleDict = moduleData as? [String: Any] else { continue }
            let root = moduleDict["root"] as? String ?? maps[pagePath]?.root ?? "main"
            let moduleConfig = ModuleConfig(root: root, pages: [pagePath])
            maps[pagePath] = moduleConfig
        }
        
        self.moduleMaps = maps
    }
    
    /// app.json 的 `networkTimeout.connectSocket`，毫秒。未配置或配了非正数时是 nil，
    /// 由调用方回落到自己的默认值。
    var networkTimeoutConnectSocketMs: Int? {
        guard let networkTimeout = app["networkTimeout"] as? [String: Any],
              let boxed = networkTimeout["connectSocket"] as? NSNumber,
              CFGetTypeID(boxed) != CFBooleanGetTypeID(),
              boxed.doubleValue.isFinite,
              boxed.doubleValue > 0,
              boxed.doubleValue <= Double(0x7fffffff)
        else {
            return nil
        }
        return Int(boxed.doubleValue.rounded(.down))
    }

    func getRootPackage(pagePath: String) -> String {
        return moduleMaps[pagePath]?.root ?? "main"
    }
    
    func isContainsPage(pagePath: String) -> Bool {
        return moduleMaps[pagePath] != nil
    }
    
    func getModuleConfig(pagePath: String) -> ModuleConfig? {
        return moduleMaps[pagePath]
    }
    
    static func fromJsonString(json: String) -> DMPBundleAppConfig? {
        guard let data = json.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return DMPBundleAppConfig(data: dictionary)
    }
    
    var entryPagePath: String {
        get {
            if _entryPagePath.isEmpty {
                guard let firstPage = pages?.first else {
                    return ""
                }
                _entryPagePath = firstPage
            }
            // 统一输出无前导斜杠的 module-key 形态——首页判定（resolveLeftNavAction）、
            // navigateHome、openPage 等所有读者都按 app-config key 消费同一权威值
            return _entryPagePath.hasPrefix("/")
                ? String(_entryPagePath.drop(while: { $0 == "/" }))
                : _entryPagePath
        }
        set {
            _entryPagePath = newValue
        }
    }
    
    func getPageConfig(pagePath: String) -> [String: Any] {
        let pagePrivateConfig = modules[pagePath] as? [String: Any] ?? [:]
        let appWindowConfig = app["window"] as? [String: Any] ?? [:]
        
        var mergedConfig = [String: Any]()
        mergedConfig["navigationBarTitleText"] = (pagePrivateConfig["navigationBarTitleText"] as? String) ?? 
                       (appWindowConfig["navigationBarTitleText"] as? String) ?? ""
        mergedConfig["navigationBarBackgroundColor"] = (pagePrivateConfig["navigationBarBackgroundColor"] as? String) ?? 
                       (appWindowConfig["navigationBarBackgroundColor"] as? String) ?? "#FFFFFF"
        mergedConfig["navigationBarTextStyle"] = (pagePrivateConfig["navigationBarTextStyle"] as? String) ?? 
                       (appWindowConfig["navigationBarTextStyle"] as? String) ?? "black"
        mergedConfig["backgroundColor"] = (pagePrivateConfig["backgroundColor"] as? String) ?? 
                       (appWindowConfig["backgroundColor"] as? String) ?? "#FFFFFF"
        mergedConfig["navigationStyle"] = (pagePrivateConfig["navigationStyle"] as? String) ??
                       (appWindowConfig["navigationStyle"] as? String) ?? "default"
        mergedConfig["homeButton"] = (pagePrivateConfig["homeButton"] as? Bool) ??
                       (appWindowConfig["homeButton"] as? Bool) ?? false
        mergedConfig["usingComponents"] = pagePrivateConfig["usingComponents"] ?? [:]
        
        return mergedConfig
    }

    func getTabBarIndex(pagePath: String) -> Int {
        return tabBar?.list.firstIndex(where: { $0.pagePath == pagePath }) ?? -1
    }

    func isTabBarPage(pagePath: String) -> Bool {
        return getTabBarIndex(pagePath: pagePath) >= 0
    }
}

struct DMPTabBarConfig {
    var color: String
    var selectedColor: String
    var borderStyle: String
    var backgroundColor: String
    var list: [DMPTabBarItem]
    /// 微信自定义 tabBar：为 true 时由小程序自己的 custom-tab-bar 组件渲染底部栏，
    /// 原生 tabBar 需要隐藏，否则会出现双 tabBar。
    var custom: Bool = false

    static func from(_ data: [String: Any]?) -> DMPTabBarConfig? {
        guard let data = data else { return nil }
        let rawList = data["list"] as? [[String: Any]] ?? []
        let items = rawList.compactMap { DMPTabBarItem.from($0) }

        guard !items.isEmpty else {
            return nil
        }

        return DMPTabBarConfig(
            color: data["color"] as? String ?? "#999999",
            selectedColor: data["selectedColor"] as? String ?? "#1890ff",
            borderStyle: data["borderStyle"] as? String ?? "black",
            backgroundColor: data["backgroundColor"] as? String ?? "#FFFFFF",
            list: items,
            custom: (data["custom"] as? Bool) ?? false
        )
    }
}

struct DMPTabBarItem {
    var pagePath: String
    var iconPath: String
    var selectedIconPath: String
    var text: String

    static func from(_ data: [String: Any]) -> DMPTabBarItem? {
        guard let pagePath = data["pagePath"] as? String, !pagePath.isEmpty else {
            return nil
        }

        return DMPTabBarItem(
            pagePath: pagePath,
            iconPath: data["iconPath"] as? String ?? "",
            selectedIconPath: data["selectedIconPath"] as? String ?? "",
            text: data["text"] as? String ?? ""
        )
    }
}

struct ModuleConfig {
    var root: String
    var pages: [String]
}

struct SubPackageConfig {
    var root: String
    var pages: [String]
}
