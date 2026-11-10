//
//  DMPRemoteUpdateManager.swift
//  dimina
//
//  Created by doslin on 2026/5/19.
//

import CommonCrypto
import Foundation

private actor DMPAsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class DMPRemoteUpdateManager {
    static let shared = DMPRemoteUpdateManager()

    private let stateLock = NSLock()
    private var appLocks: [String: DMPAsyncLock] = [:]
    private var operationGenerations: [String: Int] = [:]
    private var uninstallingApps: Set<String> = []

    private init() {}

    /// Ensures a runnable package exists before the service and render runtimes
    /// are initialized. Returns true when this call performed the first install.
    func installInitialPackageIfNeeded(appId: String, manifestUrl: String?) async throws -> Bool {
        try validateAppId(appId)
        let token = operationToken(for: appId)
        return try await appLock(for: appId).withLock {
            try self.ensureOperationActive(appId: appId, token: token)
            if self.isPackageReady(appId: appId) {
                return false
            }

            let trimmedUrl = manifestUrl?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedUrl.isEmpty else {
                throw RemoteUpdateError.install(
                    "mini program \(appId) has no local package or updateManifestUrl"
                )
            }

            let manifest = try await self.fetchManifest(manifestUrl: trimmedUrl)
            try self.ensureOperationActive(appId: appId, token: token)
            try self.validateManifestAppId(manifest, expectedAppId: appId)

            let zipPath = try await self.downloadPackage(manifest: manifest)
            do {
                try self.ensureOperationActive(appId: appId, token: token)
                try self.installActivePackage(manifest: manifest, zipPath: zipPath)
            } catch {
                DMPFileUtil.removeItem(at: zipPath)
                throw error
            }
            return true
        }
    }

    func checkForUpdate(app: DMPApp, manifestUrl: String, operationToken token: Int) async {
        let appId = app.getAppId()
        let trimmedUrl = manifestUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUrl.isEmpty else {
            await app.notifyUpdateStatus(event: "noupdate")
            return
        }

        var updateAnnounced = false
        do {
            try validateAppId(appId)
            try await appLock(for: appId).withLock {
                try self.ensureOperationActive(appId: appId, token: token)
                let manifest = try await self.fetchManifest(manifestUrl: trimmedUrl)
                try self.ensureOperationActive(appId: appId, token: token)
                try self.validateManifestAppId(manifest, expectedAppId: appId)

                let currentVersion = self.currentVersionCode(appId: appId)
                guard manifest.versionCode > currentVersion else {
                    self.deletePendingPackage(appId: appId)
                    await app.notifyUpdateStatus(event: "noupdate")
                    return
                }

                updateAnnounced = true
                await app.notifyUpdateStatus(event: "updating")

                if let pendingVersion = try self.pendingVersionCode(appId: appId),
                   pendingVersion >= manifest.versionCode {
                    await app.notifyUpdateStatus(event: "updateready")
                    return
                }

                let zipPath = try await self.downloadPackage(manifest: manifest)
                do {
                    try self.ensureOperationActive(appId: appId, token: token)
                    try self.installPendingPackage(manifest: manifest, zipPath: zipPath)
                } catch {
                    DMPFileUtil.removeItem(at: zipPath)
                    throw error
                }
                await app.notifyUpdateStatus(event: "updateready")
            }
        } catch RemoteUpdateError.cancelled {
            return
        } catch {
            DMPLogger.debug("Remote update failed: \(error)")
            await app.notifyUpdateStatus(event: updateAnnounced ? "updatefail" : "noupdate")
        }
    }

    func activatePendingUpdate(appId: String) async throws -> Bool {
        try validateAppId(appId)
        let token = operationToken(for: appId)
        return try await appLock(for: appId).withLock {
            try self.ensureOperationActive(appId: appId, token: token)
            guard let pendingVersion = try self.pendingVersionCode(appId: appId) else {
                return false
            }
            guard pendingVersion > self.currentVersionCode(appId: appId) else {
                self.deletePendingPackage(appId: appId)
                return false
            }
            try self.replaceActivePackage(
                sourcePath: self.pendingPath(appId: appId),
                appId: appId
            )
            return true
        }
    }

    func operationToken(for appId: String) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operationGenerations[appId, default: 0]
    }

    func isPackageOperationInProgress(appId: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return uninstallingApps.contains(appId)
    }

    func beginUninstall(appId: String) throws {
        try validateAppId(appId)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !uninstallingApps.contains(appId) else {
            throw RemoteUpdateError.install("mini program \(appId) is already being uninstalled")
        }
        uninstallingApps.insert(appId)
        operationGenerations[appId, default: 0] += 1
    }

    func endUninstall(appId: String) {
        stateLock.lock()
        uninstallingApps.remove(appId)
        stateLock.unlock()
    }

    func uninstallPackage(appId: String, clearUserData: Bool) async throws {
        try await appLock(for: appId).withLock {
            try self.validateAppId(appId)
            try self.removeInstalledPackage(appId: appId, clearUserData: clearUserData)
            self.deletePendingPackage(appId: appId)
            try self.removeArtifactDirectory(rootName: ".remote", appId: appId)
            try self.removeArtifactDirectory(rootName: ".backup", appId: appId)
            let downloadPath = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("dimina-updates/\(appId)")
            DMPFileUtil.removeItem(at: downloadPath)
        }
    }

    func getAppVersionInfo(appId: String) throws -> [String: Any]? {
        try validateAppId(appId)
        let path = DMPSandboxManager.appBundlePath(appId)
        guard (try? validatePackage(at: path)) != nil,
              let config = DMPFileUtil.loadJSONFromFile(filePath: DMPSandboxManager.appBundleConfigPath(appId: appId)),
              config["appId"] as? String == appId,
              let version = config["versionCode"] as? Int, version >= 0 else { return nil }
        return config
    }

    func installLocalPackage(appId: String, packagePath: String) async throws -> [String: Any] {
        try validateAppId(appId)
        return try await appLock(for: appId).withLock {
            let staging = (DMPSandboxManager.sandboxPath() as NSString)
                .appendingPathComponent(".local/\(appId)-\(UUID().uuidString)")
            defer { DMPFileUtil.removeItem(at: staging) }
            guard DMPFileUtil.unzipFile(at: packagePath, to: staging) else {
                throw RemoteUpdateError.install("failed to unzip local package")
            }
            try self.validatePackage(at: staging)
            guard var config = DMPFileUtil.loadJSONFromFile(filePath: (staging as NSString).appendingPathComponent("config.json")),
                  config["appId"] as? String == appId,
                  let version = config["versionCode"] as? Int, version >= 0 else {
                throw RemoteUpdateError.install("invalid local package config")
            }
            config["hostManaged"] = true
            try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: staging).appendingPathComponent("config.json"))
            try self.replaceActivePackage(sourcePath: staging, appId: appId)
            self.deletePendingPackage(appId: appId)
            return config
        }
    }

    private func isPackageReady(appId: String) -> Bool {
        let requiredFiles = [
            DMPSandboxManager.appConfigPath(appId: appId),
            DMPSandboxManager.appServicePath(appId: appId),
        ]
        return requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    private func validateManifestAppId(
        _ manifest: RemoteUpdateManifest,
        expectedAppId: String
    ) throws {
        guard manifest.appId == expectedAppId else {
            throw RemoteUpdateError.invalidManifest(
                "manifest appId \(manifest.appId) does not match \(expectedAppId)"
            )
        }
    }

    private func fetchManifest(manifestUrl: String) async throws -> RemoteUpdateManifest {
        guard let url = URL(string: manifestUrl) else {
            throw RemoteUpdateError.invalidManifest("invalid manifest url")
        }

        let (data, response) = try await requestData(url: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw RemoteUpdateError.network("manifest request failed: HTTP \(httpResponse.statusCode)")
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw RemoteUpdateError.invalidManifest("manifest is not an object")
        }

        let payload = root["data"] as? [String: Any] ?? root
        return try RemoteUpdateManifest(json: payload)
    }

    private func downloadPackage(manifest: RemoteUpdateManifest) async throws -> String {
        guard let url = URL(string: manifest.packageUrl) else {
            throw RemoteUpdateError.invalidManifest("invalid package url")
        }

        let (downloadedURL, response) = try await downloadFile(url: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw RemoteUpdateError.network("package download failed: HTTP \(httpResponse.statusCode)")
        }

        let targetPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("dimina-updates/\(manifest.appId)/\(manifest.versionCode).zip")
        try FileManager.default.createDirectory(
            atPath: (targetPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: nil
        )
        if FileManager.default.fileExists(atPath: targetPath) {
            try FileManager.default.removeItem(atPath: targetPath)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: URL(fileURLWithPath: targetPath))
        return targetPath
    }

    private func installActivePackage(manifest: RemoteUpdateManifest, zipPath: String) throws {
        let stagingPath = try preparePackage(manifest: manifest, zipPath: zipPath)
        defer { DMPFileUtil.removeItem(at: stagingPath) }
        try replaceActivePackage(sourcePath: stagingPath, appId: manifest.appId)
    }

    private func installPendingPackage(manifest: RemoteUpdateManifest, zipPath: String) throws {
        let stagingPath = try preparePackage(manifest: manifest, zipPath: zipPath)
        let pendingPath = pendingPath(appId: manifest.appId)
        defer { DMPFileUtil.removeItem(at: stagingPath) }
        DMPFileUtil.removeItem(at: pendingPath)
        try FileManager.default.createDirectory(
            atPath: (pendingPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try FileManager.default.moveItem(atPath: stagingPath, toPath: pendingPath)
    }

    private func preparePackage(manifest: RemoteUpdateManifest, zipPath: String) throws -> String {
        let sandboxPath = DMPSandboxManager.sandboxPath()
        let stagingPath = (sandboxPath as NSString)
            .appendingPathComponent(".remote/\(manifest.appId)/\(manifest.versionCode)-\(UUID().uuidString)")

        defer {
            DMPFileUtil.removeItem(at: zipPath)
        }

        if let sha256 = manifest.sha256, !sha256.isEmpty {
            try verifySha256(filePath: zipPath, expectedSha256: sha256)
        }
        DMPFileUtil.removeItem(at: stagingPath)
        guard DMPFileUtil.unzipFile(at: zipPath, to: stagingPath) else {
            throw RemoteUpdateError.install("failed to unzip package")
        }

        try writeConfig(manifest: manifest, to: (stagingPath as NSString).appendingPathComponent("config.json"))
        try validatePackage(at: stagingPath)
        return stagingPath
    }

    private func replaceActivePackage(sourcePath: String, appId: String) throws {
        let sandboxPath = DMPSandboxManager.sandboxPath()
        let targetPath = DMPSandboxManager.appBundlePath(appId)
        let backupPath = (sandboxPath as NSString)
            .appendingPathComponent(".backup/\(appId)/\(Int(Date().timeIntervalSince1970 * 1000))")
        try DMPFileUtil.replaceDirectory(
            from: sourcePath,
            to: targetPath,
            backupPath: backupPath,
            preserving: ["store", "resources/store"]
        )
        DMPSandboxManager.initBundleDirectoryForApp(appId: appId)
    }

    private func writeConfig(manifest: RemoteUpdateManifest, to path: String) throws {
        let config: [String: Any] = [
            "appId": manifest.appId,
            "name": manifest.name,
            "path": manifest.path,
            "versionCode": manifest.versionCode,
            "versionName": manifest.versionName,
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    private func requestData(url: URL) async throws -> (Data, URLResponse) {
        // 更新清单决定「有没有新版本」，同样不能读 URLCache 里的旧副本
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: RemoteUpdateError.network("empty response"))
                    return
                }
                continuation.resume(returning: (data, response))
            }.resume()
        }
    }

    private func downloadFile(url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.downloadTask(with: url) { url, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url, let response else {
                    continuation.resume(throwing: RemoteUpdateError.network("empty download response"))
                    return
                }
                continuation.resume(returning: (url, response))
            }.resume()
        }
    }

    private func validatePackage(at packagePath: String) throws {
        let requiredFiles = [
            "config.json",
            "main/app-config.json",
            "main/logic.js",
        ]

        for file in requiredFiles {
            let path = (packagePath as NSString).appendingPathComponent(file)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular else {
                throw RemoteUpdateError.install("package missing required file: \(file)")
            }
        }
    }

    private func pendingPath(appId: String) -> String {
        return (DMPSandboxManager.sandboxPath() as NSString)
            .appendingPathComponent(".pending/\(appId)")
    }

    private func pendingVersionCode(appId: String) throws -> Int? {
        let path = pendingPath(appId: appId)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            try validatePackage(at: path)
            let configPath = (path as NSString).appendingPathComponent("config.json")
            let config = DMPFileUtil.loadJSONFromFile(filePath: configPath)
            guard config?["appId"] as? String == appId,
                  let versionCode = config?["versionCode"] as? Int else {
                throw RemoteUpdateError.install("invalid pending package config")
            }
            return versionCode
        } catch {
            DMPFileUtil.removeItem(at: path)
            throw error
        }
    }

    private func deletePendingPackage(appId: String) {
        DMPFileUtil.removeItem(at: pendingPath(appId: appId))
    }

    private func removeInstalledPackage(appId: String, clearUserData: Bool) throws {
        let appPath = DMPSandboxManager.appBundlePath(appId)
        guard FileManager.default.fileExists(atPath: appPath) else { return }
        if clearUserData {
            try FileManager.default.removeItem(atPath: appPath)
            return
        }

        let persistentPaths: Set<String> = ["store", "resources"]
        for item in try FileManager.default.contentsOfDirectory(atPath: appPath) {
            let path = (appPath as NSString).appendingPathComponent(item)
            if !persistentPaths.contains(item) {
                try FileManager.default.removeItem(atPath: path)
            }
        }

        let resourcesPath = (appPath as NSString).appendingPathComponent("resources")
        if FileManager.default.fileExists(atPath: resourcesPath) {
            for item in try FileManager.default.contentsOfDirectory(atPath: resourcesPath) where item != "store" {
                try FileManager.default.removeItem(
                    atPath: (resourcesPath as NSString).appendingPathComponent(item)
                )
            }
        }
    }

    private func removeArtifactDirectory(rootName: String, appId: String) throws {
        let root = (DMPSandboxManager.sandboxPath() as NSString).appendingPathComponent(rootName)
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let appURL = rootURL.appendingPathComponent(appId, isDirectory: true).standardizedFileURL
        guard appURL.deletingLastPathComponent() == rootURL else {
            throw RemoteUpdateError.install("invalid appId")
        }
        DMPFileUtil.removeItem(at: appURL.path)
    }

    private func currentVersionCode(appId: String) -> Int {
        let config = DMPFileUtil.loadJSONFromFile(filePath: DMPSandboxManager.appBundleConfigPath(appId: appId))
        return config?["versionCode"] as? Int ?? 0
    }

    private func appLock(for appId: String) -> DMPAsyncLock {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let lock = appLocks[appId] {
            return lock
        }
        let lock = DMPAsyncLock()
        appLocks[appId] = lock
        return lock
    }

    private func ensureOperationActive(appId: String, token: Int) throws {
        stateLock.lock()
        let active = !uninstallingApps.contains(appId)
            && operationGenerations[appId, default: 0] == token
        stateLock.unlock()
        if !active {
            throw RemoteUpdateError.cancelled
        }
    }

    private func validateAppId(_ appId: String) throws {
        let reservedAppIds: Set<String> = ["sdk", ".remote", ".backup", ".pending", ".local"]
        guard !appId.isEmpty,
              appId != ".",
              appId != "..",
              !appId.contains("/"),
              !appId.contains("\\"),
              !appId.contains("\0"),
              !reservedAppIds.contains(appId) else {
            throw RemoteUpdateError.install("invalid appId")
        }
    }

    private func verifySha256(filePath: String, expectedSha256: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        let actualSha256 = digest.map { String(format: "%02x", $0) }.joined()
        guard actualSha256.lowercased() == expectedSha256.lowercased() else {
            throw RemoteUpdateError.install("package sha256 mismatch")
        }
    }

    private struct RemoteUpdateManifest {
        let appId: String
        let name: String
        let path: String
        let versionCode: Int
        let versionName: String
        let packageUrl: String
        let sha256: String?

        init(json: [String: Any]) throws {
            guard let appId = json["appId"] as? String, !appId.isEmpty else {
                throw RemoteUpdateError.invalidManifest("manifest missing appId")
            }
            guard let path = json["path"] as? String, !path.isEmpty else {
                throw RemoteUpdateError.invalidManifest("manifest missing path")
            }
            guard let versionCode = json["versionCode"] as? Int else {
                throw RemoteUpdateError.invalidManifest("manifest missing versionCode")
            }

            let packageUrl = (json["packageUrl"] as? String)
                ?? (json["downloadUrl"] as? String)
                ?? (json["url"] as? String)
                ?? ""
            guard !packageUrl.isEmpty else {
                throw RemoteUpdateError.invalidManifest("manifest missing packageUrl")
            }

            self.appId = appId
            self.name = json["name"] as? String ?? ""
            self.path = path
            self.versionCode = versionCode
            self.versionName = json["versionName"] as? String ?? ""
            self.packageUrl = packageUrl
            self.sha256 = json["sha256"] as? String
        }
    }

    private enum RemoteUpdateError: Error {
        case invalidManifest(String)
        case network(String)
        case install(String)
        case cancelled
    }
}
