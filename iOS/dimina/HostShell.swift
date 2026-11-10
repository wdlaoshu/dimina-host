//
//  HostShell.swift
//  dimina
//
//  Host shell model: app discovery, local import, update and system capability status.
//

import AVFoundation
import Combine
import CoreLocation
import Foundation
import Network
import Photos
import SwiftUI
import UserNotifications
import ZIPFoundation

struct HostApp: Identifiable, Hashable {
    let appId: String
    let name: String
    let path: String?
    let versionCode: Int
    let versionName: String
    let updateManifestUrl: String
    let bundled: Bool
    let installed: Bool
    /// 是否是用户从本地 ZIP 导入的；从远程目录下载的为 false。
    let importedLocally: Bool

    var id: String { appId }

    var sourceLabel: String {
        if bundled { return installed ? "内置 · 已安装" : "内置" }
        return importedLocally ? "本地导入" : "远程下载"
    }

    var canUpdate: Bool { !updateManifestUrl.isEmpty }
    var canUninstall: Bool { installed }

    var tint: Color { DMPUtil.generateColorFromName(name: name) }
    var iconText: String { name.isEmpty ? "?" : String(name.prefix(1)) }

    init(
        appId: String,
        name: String,
        path: String?,
        versionCode: Int,
        versionName: String,
        updateManifestUrl: String,
        bundled: Bool,
        installed: Bool,
        importedLocally: Bool = false
    ) {
        self.appId = appId
        self.name = name
        self.path = path
        self.versionCode = versionCode
        self.versionName = versionName
        self.updateManifestUrl = updateManifestUrl
        self.bundled = bundled
        self.installed = installed
        self.importedLocally = importedLocally
    }

    init(config: DMPAppConfig, bundled: Bool, installed: Bool) {
        self.init(
            appId: config.appId,
            name: config.appName,
            path: config.path,
            versionCode: config.versionCode ?? 0,
            versionName: config.versionName ?? "1.0.0",
            updateManifestUrl: config.updateManifestUrl ?? "",
            bundled: bundled,
            installed: installed
        )
    }

    func withBundled(_ value: Bool) -> HostApp {
        HostApp(
            appId: appId,
            name: name,
            path: path,
            versionCode: versionCode,
            versionName: versionName,
            updateManifestUrl: updateManifestUrl,
            bundled: value,
            installed: installed,
            importedLocally: importedLocally
        )
    }
}

/// 记录小程序的安装来源：本地 ZIP 导入 / 远程目录下载。
/// 首页角标只给本地导入的包打「导入」，云端下载的不再误标。
enum HostInstallOrigin {
    private static let key = "dimina.host.appOrigins"

    static func isLocal(_ appId: String) -> Bool {
        origins()[appId] == "local"
    }

    static func record(_ appId: String, local: Bool) {
        var map = origins()
        map[appId] = local ? "local" : "remote"
        UserDefaults.standard.set(map, forKey: key)
    }

    static func remove(_ appId: String) {
        var map = origins()
        guard map.removeValue(forKey: appId) != nil else { return }
        UserDefaults.standard.set(map, forKey: key)
    }

    private static func origins() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

struct HostImportPackage: Identifiable {
    let id = UUID()
    let appId: String
    let name: String
    let versionCode: Int
    let versionName: String
    let fileURL: URL
}

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var apps: [HostApp] = []
    @Published private(set) var recentIds: [String] = []
    /// 每个小程序最近一次使用时间，切换器与「最近使用」用它显示「刚刚 / N 分钟前」。
    @Published private(set) var recentTimes: [String: TimeInterval] = [:]

    private let recentKey = "dimina.host.recentAppIds"
    private let recentTimeKey = "dimina.host.recentTimes"
    private let maxRecent = 8

    init() {
        reload()
    }

    var recentApps: [HostApp] {
        recentIds.compactMap { id in apps.first(where: { $0.appId == id }) }
    }

    func filteredApps(query: String) -> [HostApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
                $0.appId.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func reload() {
        let bundled = DMPResourceManager.getDMPAppConfigs()
        var merged: [String: HostApp] = [:]

        for config in bundled {
            let installed = FileManager.default.fileExists(
                atPath: DMPSandboxManager.appBundleConfigPath(appId: config.appId)
            )
            merged[config.appId] = HostApp(config: config, bundled: true, installed: installed)
        }

        for app in readInstalledApps() {
            merged[app.appId] = app.withBundled(merged[app.appId] != nil)
        }

        apps = merged.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let validIds = Set(apps.map(\.appId))
        let stored = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        recentIds = stored.filter { validIds.contains($0) }

        let storedTimes = UserDefaults.standard.dictionary(forKey: recentTimeKey) as? [String: TimeInterval] ?? [:]
        recentTimes = storedTimes.filter { validIds.contains($0.key) }
    }

    func recordRecent(_ appId: String) {
        var updated = recentIds.filter { $0 != appId }
        updated.insert(appId, at: 0)
        recentIds = Array(updated.prefix(maxRecent))
        UserDefaults.standard.set(recentIds, forKey: recentKey)
        recordUsed(appId)
    }

    /// 切回后台实例时也要刷新使用时间，切换器的相对时间才准。
    func recordUsed(_ appId: String) {
        var times = recentTimes
        times[appId] = Date().timeIntervalSince1970
        recentTimes = times
        UserDefaults.standard.set(times, forKey: recentTimeKey)
    }

    func lastUsed(_ appId: String) -> Date? {
        recentTimes[appId].map { Date(timeIntervalSince1970: $0) }
    }

    func install(_ package: HostImportPackage) async throws {
        _ = try await DMPAppManager.sharedInstance().installMiniProgram(
            appId: package.appId,
            packagePath: package.fileURL.path
        )
        HostInstallOrigin.record(package.appId, local: true)
        try? FileManager.default.removeItem(at: package.fileURL)
        reload()
    }

    func uninstall(_ app: HostApp) async throws {
        try await DMPAppManager.sharedInstance().uninstallMiniProgram(appId: app.appId)
        HostInstallOrigin.remove(app.appId)
        reload()
    }

    func checkForUpdate(_ app: HostApp) async -> String {
        guard app.canUpdate else { return "未配置更新地址" }

        var config = DMPAppConfig(appName: app.name, appId: app.appId)
        config.path = app.path
        config.versionCode = app.versionCode
        config.versionName = app.versionName
        config.updateManifestUrl = app.updateManifestUrl

        let dmpApp = DMPAppManager.sharedInstance().appWithConfig(appConfig: config)
        let token = DMPRemoteUpdateManager.shared.operationToken(for: app.appId)
        await DMPRemoteUpdateManager.shared.checkForUpdate(
            app: dmpApp,
            manifestUrl: app.updateManifestUrl,
            operationToken: token
        )

        let pendingPath = (DMPSandboxManager.sandboxPath() as NSString)
            .appendingPathComponent(".pending/\(app.appId)/config.json")
        let pendingVersion = (DMPFileUtil.loadJSONFromFile(filePath: pendingPath)?["versionCode"] as? Int) ?? 0
        reload()

        if pendingVersion > app.versionCode {
            return "发现新版本 v\(pendingVersion)，已下载，下次启动生效"
        }
        return "已是最新版本"
    }

    /// Reads a local ZIP selected by the document picker without installing it yet.
    nonisolated static func prepareImport(from url: URL) throws -> HostImportPackage {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimina-host-import", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let copyURL = tempDir
            .appendingPathComponent("import-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        try FileManager.default.copyItem(at: url, to: copyURL)

        guard let archive = Archive(url: copyURL, accessMode: .read) else {
            throw HostImportError.invalidArchive
        }

        var configEntry: Entry?
        for entry in archive {
            guard entry.path == "config.json" || entry.path.hasSuffix("/config.json") else {
                continue
            }
            if let current = configEntry {
                let depth = entry.path.filter { $0 == "/" }.count
                let currentDepth = current.path.filter { $0 == "/" }.count
                if depth < currentDepth { configEntry = entry }
            } else {
                configEntry = entry
            }
        }

        guard let entry = configEntry else {
            throw HostImportError.missingConfig
        }

        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostImportError.invalidConfig
        }

        let appId = (json["appId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appId.isEmpty, !appId.contains("/"), !appId.contains("\\") else {
            throw HostImportError.invalidAppId
        }

        return HostImportPackage(
            appId: appId,
            name: json["name"] as? String ?? appId,
            versionCode: json["versionCode"] as? Int ?? 0,
            versionName: json["versionName"] as? String ?? "1.0.0",
            fileURL: copyURL
        )
    }

    private func readInstalledApps() -> [HostApp] {
        let root = DMPSandboxManager.sandboxPath()
        guard !root.isEmpty,
              let folders = try? FileManager.default.contentsOfDirectory(atPath: root)
        else {
            return []
        }

        return folders.compactMap { folder -> HostApp? in
            guard !folder.hasPrefix("."), folder != "sdk" else { return nil }
            let appRoot = (root as NSString).appendingPathComponent(folder)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: appRoot, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return nil
            }
            let configPath = (appRoot as NSString).appendingPathComponent("config.json")
            guard FileManager.default.fileExists(atPath: configPath),
                  let json = DMPFileUtil.loadJSONFromFile(filePath: configPath),
                  json["appId"] as? String == folder,
                  FileManager.default.fileExists(
                      atPath: (appRoot as NSString).appendingPathComponent("main/app-config.json")
                  ),
                  FileManager.default.fileExists(
                      atPath: (appRoot as NSString).appendingPathComponent("main/logic.js")
                  )
            else {
                return nil
            }
            return HostApp(
                appId: folder,
                name: json["name"] as? String ?? folder,
                path: json["path"] as? String,
                versionCode: json["versionCode"] as? Int ?? 0,
                versionName: json["versionName"] as? String ?? "1.0.0",
                updateManifestUrl: json["updateManifestUrl"] as? String ?? "",
                bundled: false,
                installed: true,
                importedLocally: HostInstallOrigin.isLocal(folder)
            )
        }
    }
}

enum HostImportError: LocalizedError {
    case invalidArchive
    case missingConfig
    case invalidConfig
    case invalidAppId

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "无法读取 ZIP 文件"
        case .missingConfig: return "ZIP 内未找到 config.json"
        case .invalidConfig: return "config.json 格式不正确"
        case .invalidAppId: return "config.json 缺少合法的 appId"
        }
    }
}

struct HostNetworkSnapshot {
    let connected: Bool
    let type: String
    let validated: Bool
    let expensive: Bool

    var title: String {
        if !connected { return "未连接" }
        return type.isEmpty ? "未知网络" : type
    }

    var detail: String {
        if !connected { return "小程序网络请求不可用" }
        if validated {
            return expensive ? "已连接 · 计费网络" : "已连接 · 网络正常"
        }
        return "已连接 · 暂未验证互联网"
    }
}

final class HostNetworkMonitor: ObservableObject {
    @Published private(set) var snapshot = HostNetworkSnapshot(
        connected: false,
        type: "",
        validated: false,
        expensive: false
    )

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dimina.host.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let type: String
            if path.usesInterfaceType(.wifi) {
                type = "Wi-Fi"
            } else if path.usesInterfaceType(.cellular) {
                type = "蜂窝网络"
            } else if path.usesInterfaceType(.wiredEthernet) {
                type = "有线网络"
            } else if path.usesInterfaceType(.other) {
                type = "其他网络"
            } else {
                type = ""
            }
            let snapshot = HostNetworkSnapshot(
                connected: path.status == .satisfied,
                type: type,
                validated: path.status == .satisfied,
                expensive: path.isExpensive || path.isConstrained
            )
            DispatchQueue.main.async {
                self?.snapshot = snapshot
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

enum HostPermissionKind: String, CaseIterable, Identifiable, Hashable {
    case camera
    case photos
    case microphone
    case location
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: return "相机"
        case .photos: return "照片"
        case .microphone: return "麦克风"
        case .location: return "定位"
        case .notifications: return "通知"
        }
    }

    var detail: String {
        switch self {
        case .camera: return "扫码、拍照与视频通话"
        case .photos: return "选择图片、保存到相册"
        case .microphone: return "录音、语音消息与通话"
        case .location: return "附近服务、地图与打卡"
        case .notifications: return "更新提醒与消息通知"
        }
    }
}

enum HostPermissionState: Equatable {
    case authorized
    case denied
    case notDetermined
    case restricted
    case unavailable

    var label: String {
        switch self {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未授权"
        case .restricted: return "受限"
        case .unavailable: return "不可用"
        }
    }

    var isAuthorized: Bool { self == .authorized }
}

@MainActor
final class HostPermissionCenter: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var states: [HostPermissionKind: HostPermissionState] = [:]

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        refresh()
    }

    func refresh() {
        states[.camera] = map(DMPPermissionManager.shared.checkPermissionStatusValue(.camera))
        states[.photos] = map(DMPPermissionManager.shared.checkPermissionStatusValue(.photoLibrary))
        states[.microphone] = map(DMPPermissionManager.shared.checkPermissionStatusValue(.microphone))
        refreshLocation()
        refreshNotification()
    }

    func request(_ kind: HostPermissionKind) {
        switch kind {
        case .camera, .photos, .microphone:
            let type: DMPPermissionType = kind == .camera
                ? .camera
                : (kind == .photos ? .photoLibrary : .microphone)
            DMPPermissionManager.shared.requestPermission(type) { [weak self] status in
                DispatchQueue.main.async {
                    self?.states[kind] = self?.map(status) ?? .notDetermined
                }
            }
        case .location:
            locationManager.requestWhenInUseAuthorization()
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            ) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshNotification() }
            }
        }
    }

    func openSettings() {
        DMPPermissionManager.shared.openSettings()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshLocation()
        }
    }

    private func refreshLocation() {
        guard CLLocationManager.locationServicesEnabled() else {
            states[.location] = .unavailable
            return
        }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            states[.location] = .authorized
        case .denied:
            states[.location] = .denied
        case .restricted:
            states[.location] = .restricted
        case .notDetermined:
            states[.location] = .notDetermined
        @unknown default:
            states[.location] = .notDetermined
        }
    }

    private func refreshNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let state: HostPermissionState
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                state = .authorized
            case .denied:
                state = .denied
            case .notDetermined:
                state = .notDetermined
            @unknown default:
                state = .notDetermined
            }
            DispatchQueue.main.async { self?.states[.notifications] = state }
        }
    }

    private func map(_ status: DMPPermissionStatus) -> HostPermissionState {
        switch status {
        case .authorized, .limited:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .restricted, .notAvailable:
            return .restricted
        }
    }
}

private extension DMPPermissionManager {
    /// Synchronous convenience for the host shell; falls back to `.notDetermined`
    /// because the SDK API reports asynchronously.
    func checkPermissionStatusValue(_ type: DMPPermissionType) -> DMPPermissionStatus {
        switch type {
        case .photoLibrary:
            switch PHPhotoLibrary.authorizationStatus() {
            case .authorized, .limited: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .location:
            return .notDetermined
        }
    }
}
