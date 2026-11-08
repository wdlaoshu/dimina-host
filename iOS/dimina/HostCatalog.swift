//
//  HostCatalog.swift
//  dimina
//
//  Remote catalog: apps.json sync, package download, verification and install.
//

import Combine
import CryptoKit
import Foundation
import SwiftUI
import UIKit

// MARK: - Models

struct HostRemoteApp: Identifiable, Decodable, Hashable {
    let appId: String
    let name: String
    let versionCode: Int
    let versionName: String
    let zip: String
    let sha256: String?
    let size: Int64?
    let icon: String?
    let notes: String?
    let force: Bool?
    let minHostVersion: String?
    let path: String?
    let publishedAt: String?

    var id: String { appId }

    init(
        appId: String,
        name: String,
        versionCode: Int,
        versionName: String,
        zip: String,
        sha256: String? = nil,
        size: Int64? = nil,
        icon: String? = nil,
        notes: String? = nil,
        force: Bool? = nil,
        minHostVersion: String? = nil,
        path: String? = nil,
        publishedAt: String? = nil
    ) {
        self.appId = appId
        self.name = name
        self.versionCode = versionCode
        self.versionName = versionName
        self.zip = zip
        self.sha256 = sha256
        self.size = size
        self.icon = icon
        self.notes = notes
        self.force = force
        self.minHostVersion = minHostVersion
        self.path = path
        self.publishedAt = publishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case appId, name, versionCode, versionName, zip, packageUrl, url
        case sha256, size, icon, notes, force, minHostVersion, path, publishedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appId = try container.decode(String.self, forKey: .appId)
        name = (try? container.decode(String.self, forKey: .name)) ?? appId
        versionCode = (try? container.decode(Int.self, forKey: .versionCode)) ?? 0
        versionName = (try? container.decode(String.self, forKey: .versionName)) ?? "1.0.0"
        let rawZip = try? container.decode(String.self, forKey: .zip)
        let rawPackage = try? container.decode(String.self, forKey: .packageUrl)
        let rawURL = try? container.decode(String.self, forKey: .url)
        zip = rawZip ?? rawPackage ?? rawURL ?? ""
        sha256 = try? container.decode(String.self, forKey: .sha256)
        size = try? container.decode(Int64.self, forKey: .size)
        icon = try? container.decode(String.self, forKey: .icon)
        notes = try? container.decode(String.self, forKey: .notes)
        force = try? container.decode(Bool.self, forKey: .force)
        minHostVersion = try? container.decode(String.self, forKey: .minHostVersion)
        path = try? container.decode(String.self, forKey: .path)
        publishedAt = try? container.decode(String.self, forKey: .publishedAt)
    }
}

struct HostCatalogDoc: Decodable {
    let schema: Int?
    let channel: String?
    let generatedAt: String?
    let apps: [HostRemoteApp]
}

// MARK: - Config

struct HostCatalogConfig: Codable, Equatable {
    var source: String
    var channel: String
    var autoCheck: Bool
    var wifiOnlyAutoDownload: Bool
    var autoInstall: Bool

    static let `default` = HostCatalogConfig(
        source: HostCatalogConfig.defaultSource,
        channel: "prod",
        autoCheck: true,
        wifiOnlyAutoDownload: true,
        autoInstall: false
    )

    /// Overridable at build time by adding `DTHostCatalogURL` to Info.plist.
    static var defaultSource: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "DTHostCatalogURL") as? String
        return (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HostSyncState: Equatable {
    case idle
    case syncing
    case ok(Date)
    case failed(String)
}

enum HostTransferState: Equatable {
    case downloading(Double)
    case verifying
    case installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing: return true
        case .failed: return false
        }
    }

    var progress: Double? {
        if case let .downloading(value) = self, value >= 0 { return value }
        return nil
    }
}

struct HostHubItem: Identifiable {
    let appId: String
    let local: HostApp?
    let remote: HostRemoteApp?

    var id: String { appId }
    var name: String { local?.name ?? remote?.name ?? appId }
    var versionCode: Int { local?.versionCode ?? 0 }
    var versionName: String { local?.versionName ?? remote?.versionName ?? "1.0.0" }
    var installed: Bool { local?.installed == true }
    var bundled: Bool { local?.bundled == true }
    var hasLocalPackage: Bool { local != nil }
    var canOpen: Bool { local != nil }

    var tint: Color { DMPUtil.generateColorFromName(name: name) }
    var iconText: String { name.isEmpty ? "?" : String(name.prefix(1)) }

    var hasUpdate: Bool {
        guard let remote, let local, local.installed else { return false }
        return remote.versionCode > local.versionCode
    }

    var needsInstall: Bool {
        guard let remote else { return false }
        return !remote.zip.isEmpty && !installed && !hasUpdate && (local == nil || remote.versionCode > local!.versionCode)
    }

    var isRemoteOnly: Bool { local == nil && remote != nil }

    var subtitle: String {
        if let remote, hasUpdate {
            return "v\(versionName) → v\(remote.versionName)"
        }
        if installed {
            return "v\(versionName) · 已安装"
        }
        if bundled {
            return "v\(versionName) · 内置"
        }
        if remote != nil {
            return "未安装 · v\(versionName)"
        }
        return "v\(versionName)"
    }
}

// MARK: - Errors

enum HostCatalogError: LocalizedError {
    case notConfigured
    case invalidResponse
    case http(Int)
    case invalidPackageURL
    case checksumMismatch
    case hostTooLow(String)
    case emptyCatalog

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置应用源地址"
        case .invalidResponse: return "服务器返回了无法识别的响应"
        case let .http(code): return "服务器返回 HTTP \(code)"
        case .invalidPackageURL: return "安装包地址不合法"
        case .checksumMismatch: return "安装包校验失败，文件可能损坏"
        case let .hostTooLow(version): return "需要宿主版本 ≥ \(version)"
        case .emptyCatalog: return "应用目录为空"
        }
    }
}

// MARK: - Downloader

/// Delegate-backed downloader so the UI can show byte progress without
/// buffering the whole package in memory.
private final class HostFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var finishedWriting = false
    private var session: URLSession?

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func start(url: URL) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: url)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: location, to: destination)
            finishedWriting = true
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure
        lock.unlock()

        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else if let failure {
            continuation.resume(throwing: failure)
        } else {
            continuation.resume()
        }
    }
}

// MARK: - Center

@MainActor
final class HostCatalogCenter: ObservableObject {
    @Published private(set) var config: HostCatalogConfig
    @Published private(set) var remoteApps: [HostRemoteApp] = []
    @Published private(set) var syncState: HostSyncState = .idle
    @Published private(set) var lastSync: Date?
    @Published private(set) var transfers: [String: HostTransferState] = [:]
    @Published private(set) var icons: [String: UIImage] = [:]
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var isDiagnosing = false
    @Published private(set) var catalogError: String?

    private let defaults = UserDefaults.standard
    private let configKey = "dimina.host.catalog.config"
    private let catalogCacheKey = "dimina.host.catalog.cache"
    private let lastSyncKey = "dimina.host.catalog.lastSync"
    private let etagKey = "dimina.host.catalog.etag"
    private var etag: String?
    private var iconTasks: Set<String> = []

    private let cachesRoot: URL
    private let downloadDir: URL
    private let iconDir: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cachesRoot = caches
        downloadDir = caches.appendingPathComponent("host-downloads", isDirectory: true)
        iconDir = caches.appendingPathComponent("host-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)

        if let data = defaults.data(forKey: configKey),
           let stored = try? JSONDecoder().decode(HostCatalogConfig.self, from: data) {
            config = stored
        } else {
            config = .default
        }

        etag = defaults.string(forKey: etagKey)
        if let timestamp = defaults.object(forKey: lastSyncKey) as? Date {
            lastSync = timestamp
        }
        restoreCachedCatalog()
        loadCachedIcons()
    }

    // MARK: Configuration

    var catalogURL: URL? {
        Self.makeCatalogURL(source: config.source, channel: config.channel)
    }

    var hostVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }

    func updateConfig(_ mutate: (inout HostCatalogConfig) -> Void) {
        var next = config
        mutate(&next)
        guard next != config else { return }
        config = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: configKey)
        }
    }

    func resetSource() {
        updateConfig { $0.source = HostCatalogConfig.defaultSource }
    }

    static func makeCatalogURL(source: String, channel: String) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var text = trimmed
        if !text.lowercased().hasSuffix(".json") {
            if !text.hasSuffix("/") { text += "/" }
            text += "apps.json"
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else {
            return nil
        }
        let channel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !channel.isEmpty && channel != "prod" {
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "channel" }
            items.append(URLQueryItem(name: "channel", value: channel))
            components.queryItems = items
        }
        return components.url
    }

    // MARK: Sync

    func sync(force: Bool = false) async {
        guard let url = catalogURL else {
            syncState = .failed(HostCatalogError.notConfigured.localizedDescription)
            catalogError = HostCatalogError.notConfigured.localizedDescription
            return
        }
        if case .syncing = syncState { return }

        syncState = .syncing
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !force, let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HostCatalogError.invalidResponse
            }
            if http.statusCode == 304 {
                let now = Date()
                lastSync = now
                defaults.set(now, forKey: lastSyncKey)
                syncState = .ok(now)
                catalogError = nil
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                throw HostCatalogError.http(http.statusCode)
            }
            let document = try JSONDecoder().decode(HostCatalogDoc.self, from: data)
            remoteApps = document.apps.filter { !$0.appId.isEmpty }
            etag = http.value(forHTTPHeaderField: "ETag")
            defaults.set(etag, forKey: etagKey)
            let now = Date()
            lastSync = now
            defaults.set(now, forKey: lastSyncKey)
            defaults.set(data, forKey: catalogCacheKey)
            syncState = .ok(now)
            catalogError = nil
            loadCachedIcons()
            downloadMissingIcons()
        } catch {
            let message = Self.describe(error)
            catalogError = message
            syncState = .failed(message)
        }
    }

    private func restoreCachedCatalog() {
        guard let data = defaults.data(forKey: catalogCacheKey),
              let document = try? JSONDecoder().decode(HostCatalogDoc.self, from: data)
        else {
            return
        }
        remoteApps = document.apps.filter { !$0.appId.isEmpty }
    }

    // MARK: URL helpers

    func resolve(_ raw: String, base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.lowercased() == base.host?.lowercased()
        else {
            return nil
        }
        return url
    }

    func packageURL(for remote: HostRemoteApp) -> URL? {
        guard let base = catalogURL else { return nil }
        return resolve(remote.zip, base: base)
    }

    func iconURL(for remote: HostRemoteApp) -> URL? {
        guard let raw = remote.icon, !raw.isEmpty, let base = catalogURL else { return nil }
        return resolve(raw, base: base)
    }

    // MARK: Icons

    private func iconCacheName(_ appId: String) -> String {
        let safe = appId.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(safe) + ".png"
    }

    private func loadCachedIcons() {
        for app in remoteApps where icons[app.appId] == nil {
            let file = iconDir.appendingPathComponent(iconCacheName(app.appId))
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                icons[app.appId] = image
            }
        }
    }

    private func downloadMissingIcons() {
        for app in remoteApps {
            guard icons[app.appId] == nil,
                  !iconTasks.contains(app.appId),
                  iconURL(for: app) != nil
            else {
                continue
            }
            iconTasks.insert(app.appId)
            Task { [weak self] in
                await self?.loadIcon(for: app)
            }
        }
    }

    private func loadIcon(for app: HostRemoteApp) async {
        defer { iconTasks.remove(app.appId) }
        let file = iconDir.appendingPathComponent(iconCacheName(app.appId))
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            icons[app.appId] = image
            return
        }
        guard let url = iconURL(for: app) else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            try? data.write(to: file, options: .atomic)
            if let image = UIImage(data: data) {
                icons[app.appId] = image
            }
        } catch {
            // Icons are best effort; the letter avatar remains as fallback.
        }
    }

    // MARK: Install

    func install(_ remote: HostRemoteApp) async throws {
        guard let zipURL = packageURL(for: remote) else {
            throw HostCatalogError.invalidPackageURL
        }
        if let minimum = remote.minHostVersion,
           !minimum.isEmpty,
           Self.compareVersion(hostVersion, minimum) < 0 {
            throw HostCatalogError.hostTooLow(minimum)
        }

        let destination = downloadDir.appendingPathComponent(
            "\(remote.appId)-\(remote.versionCode).zip"
        )
        transfers[remote.appId] = .downloading(-1)

        do {
            try await HostFileDownloader(destination: destination) { received, expected in
                Task { @MainActor [weak self] in
                    let progress = expected > 0 ? Double(received) / Double(expected) : -1
                    self?.transfers[remote.appId] = .downloading(progress)
                }
            }.start(url: zipURL)

            if let expected = remote.sha256?.trimmingCharacters(in: .whitespacesAndNewlines),
               !expected.isEmpty {
                transfers[remote.appId] = .verifying
                let actual = try Self.sha256Hex(of: destination)
                guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    throw HostCatalogError.checksumMismatch
                }
            }

            transfers[remote.appId] = .installing
            _ = try await DMPAppManager.sharedInstance().installMiniProgram(
                appId: remote.appId,
                packagePath: destination.path
            )
            try? FileManager.default.removeItem(at: destination)
            transfers[remote.appId] = nil
        } catch {
            try? FileManager.default.removeItem(at: destination)
            transfers[remote.appId] = .failed(Self.describe(error))
            throw error
        }
    }

    func clearTransferState(for appId: String) {
        transfers[appId] = nil
    }

    // MARK: Storage

    func downloadCacheBytes() -> Int64 {
        Self.directorySize(downloadDir)
    }

    func iconCacheBytes() -> Int64 {
        Self.directorySize(iconDir)
    }

    func installedBytes() -> Int64 {
        let root = DMPSandboxManager.sandboxPath()
        guard !root.isEmpty else { return 0 }
        return Self.directorySize(URL(fileURLWithPath: root))
    }

    func clearDownloadCache() {
        try? FileManager.default.removeItem(at: downloadDir)
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
    }

    func clearIconCache() {
        try? FileManager.default.removeItem(at: iconDir)
        try? FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)
        icons = [:]
        loadCachedIcons()
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: Diagnostics

    func runDiagnostics() async {
        isDiagnosing = true
        defer { isDiagnosing = false }

        var lines: [String] = []
        guard let url = catalogURL else {
            lines.append("应用源：未配置")
            lines.append("请回到设置填写 apps.json 地址")
            diagnostics = lines
            return
        }
        lines.append("应用源：\(url.absoluteString)")

        let start = Date()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse {
                lines.append("HTTP：\(http.statusCode) · \(elapsed) ms")
                if http.statusCode == 401 || http.statusCode == 403 {
                    lines.append("鉴权：需要凭据（当前未提供）")
                } else if (200..<300).contains(http.statusCode) {
                    lines.append("鉴权：无需凭据或已通过")
                }
                if let type = http.value(forHTTPHeaderField: "Content-Type") {
                    lines.append("Content-Type：\(type)")
                }
                if let etag = http.value(forHTTPHeaderField: "ETag") {
                    lines.append("ETag：\(etag)")
                }
            }
            lines.append("TLS：\(url.scheme == "https" ? "HTTPS 已启用" : "未使用 HTTPS")")
            if let document = try? JSONDecoder().decode(HostCatalogDoc.self, from: data) {
                lines.append("目录：\(document.apps.count) 个应用 · schema \(document.schema ?? 0)")
            } else {
                lines.append("目录：响应不是合法的 apps.json")
            }
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            lines.append("请求失败（\(elapsed) ms）：\(Self.describe(error))")
        }

        let capacity = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = capacity?.volumeAvailableCapacityForImportantUsage {
            lines.append("磁盘可用：\(Self.formatBytes(available))")
        }
        lines.append("宿主版本：\(hostVersion)")
        lines.append("下载缓存：\(Self.formatBytes(downloadCacheBytes()))")
        lines.append("图标缓存：\(Self.formatBytes(iconCacheBytes()))")
        diagnostics = lines
    }

    // MARK: Helpers

    static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func describe(_ error: Error) -> String {
        if let catalogError = error as? HostCatalogError {
            return catalogError.localizedDescription
        }
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet:
            return "网络不可用，请检查连接"
        case NSURLErrorTimedOut:
            return "请求超时，请稍后重试"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
            return "无法连接服务器，请检查域名解析"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "TLS 证书校验失败"
        default:
            return error.localizedDescription
        }
    }

}
