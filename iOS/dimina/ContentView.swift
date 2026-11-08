//
//  ContentView.swift
//  dimina
//
//  Created by Lehem on 2025/4/15.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = HostStore()
    @StateObject private var network = HostNetworkMonitor()
    @StateObject private var permissions = HostPermissionCenter()

    @State private var searchText = ""
    @State private var selectedApp: HostApp?
    @State private var showSettings = false
    @State private var showFileImporter = false
    @State private var pendingImport: HostImportPackage?
    @State private var uninstallTarget: HostApp?
    @State private var showUninstallConfirm = false
    @State private var isInstalling = false
    @State private var toast: String?

    // 存储UINavigationController的引用
    static var navigationController: UINavigationController?

    // 自动化测试钩子的一次性标记（见 autoOpenAppForTestIfRequested）
    static var didAutoOpenForTest = false

    var body: some View {
        let items = store.filteredApps(query: searchText)
        let recent = store.recentApps

        NavigationView {
            ZStack(alignment: .bottom) {
                HostTheme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    searchBar
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if !recent.isEmpty {
                                sectionHeader("最近使用", trailing: "\(recent.count)")
                                recentRow(recent)
                            }

                            sectionHeader("全部应用", trailing: "共 \(items.count) 个")

                            if items.isEmpty {
                                emptyState
                            } else {
                                LazyVGrid(
                                    columns: Array(
                                        repeating: GridItem(.flexible(), spacing: 12),
                                        count: 3
                                    ),
                                    spacing: 12
                                ) {
                                    ForEach(items) { app in
                                        appCard(app)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 32)
                    }
                    .scrollIndicators(.hidden)
                }

                if isInstalling {
                    installingOverlay
                }

                if let toast {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.82))
                        .clipShape(Capsule())
                        .padding(.bottom, 26)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarHidden(true)
            .preferredColorScheme(.light)
            .onAppear {
                setupNavigationController()
                autoOpenAppForTestIfRequested()
                permissions.refresh()
            }
            .sheet(item: $selectedApp) { app in
                HostAppDetailSheet(
                    app: app,
                    onOpen: {
                        selectedApp = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            open(app)
                        }
                    },
                    onCheckUpdate: {
                        await store.checkForUpdate(app)
                    },
                    onUninstall: {
                        selectedApp = nil
                        uninstallTarget = app
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            showUninstallConfirm = true
                        }
                    }
                )
            }
            .sheet(isPresented: $showSettings) {
                HostSettingsSheet(
                    network: network,
                    permissions: permissions,
                    onOpenSettings: { permissions.openSettings() }
                )
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.zip],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        pendingImport = try HostStore.prepareImport(from: url)
                    } catch {
                        showToast("读取失败：\(error.localizedDescription)")
                    }
                case .failure(let error):
                    showToast("选择文件失败：\(error.localizedDescription)")
                }
            }
            .alert(item: $pendingImport) { pkg in
                Alert(
                    title: Text("导入小程序"),
                    message: Text(
                        "\(pkg.name)\n版本 \(pkg.versionName)\n\(pkg.appId)\n\n" +
                            "导入后会覆盖同 appId 的本地包，用户数据默认保留。"
                    ),
                    primaryButton: .default(Text("导入")) {
                        Task { await install(pkg) }
                    },
                    secondaryButton: .cancel(Text("取消")) {
                        try? FileManager.default.removeItem(at: pkg.fileURL)
                    }
                )
            }
            .confirmationDialog(
                "卸载 \(uninstallTarget?.name ?? "小程序")？",
                isPresented: $showUninstallConfirm,
                titleVisibility: .visible
            ) {
                Button("卸载", role: .destructive) {
                    guard let app = uninstallTarget else { return }
                    Task { await uninstall(app) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(
                    uninstallTarget?.bundled == true
                        ? "将移除本地安装包并停止运行。内置版本会在下次启动时恢复，用户数据默认保留。"
                        : "将移除已导入的小程序包，用户数据默认保留。"
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.36, green: 0.48, blue: 1),
                                     Color(red: 0.48, green: 0.36, blue: 1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("D")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Dream Tapir")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(HostTheme.text)
                Text("本地运行 · \(store.apps.count) 个应用")
                    .font(.system(size: 12))
                    .foregroundColor(HostTheme.muted)
            }

            Spacer()

            headerButton(systemName: "plus", label: "导入小程序") {
                showFileImporter = true
            }
            headerButton(systemName: "slider.horizontal.3", label: "网络与权限") {
                showSettings = true
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func headerButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(HostTheme.text)
                .frame(width: 38, height: 38)
                .background(HostTheme.surface)
                .clipShape(Circle())
        }
        .accessibilityLabel(label)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(HostTheme.muted)

            TextField("搜索名称或 appId", text: $searchText)
                .font(.system(size: 15))
                .foregroundColor(HostTheme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(HostTheme.muted)
                }
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(HostTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(HostTheme.text)
            Spacer()
            Text(trailing)
                .font(.system(size: 12))
                .foregroundColor(HostTheme.muted)
        }
        .padding(.top, 8)
    }

    // MARK: - Cards

    private func recentRow(_ apps: [HostApp]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(apps) { app in
                    HStack(spacing: 10) {
                        appIcon(app, size: 38, corner: 12, fontSize: 17)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(HostTheme.text)
                                .lineLimit(1)
                            Text("v\(app.versionName)")
                                .font(.system(size: 11))
                                .foregroundColor(HostTheme.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 136, alignment: .leading)
                    .padding(12)
                    .background(HostTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { open(app) }
                    .onLongPressGesture(minimumDuration: 0.35) {
                        selectedApp = app
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func appCard(_ app: HostApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                appIcon(app, size: 48, corner: 15, fontSize: 21)
                Spacer(minLength: 4)
                if app.installed && !app.bundled {
                    Text("导入")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(HostTheme.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(HostTheme.primarySoft)
                        .clipShape(Capsule())
                }
            }

            Spacer(minLength: 8)

            Text(app.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(HostTheme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(height: 36, alignment: .topLeading)

            Text("v\(app.versionName) · \(app.sourceLabel)")
                .font(.system(size: 10))
                .foregroundColor(HostTheme.muted)
                .lineLimit(1)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 142)
        .background(HostTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.035), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { open(app) }
        .onLongPressGesture(minimumDuration: 0.35) {
            selectedApp = app
        }
    }

    private func appIcon(
        _ app: HostApp,
        size: CGFloat,
        corner: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [app.tint.opacity(0.7), app.tint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(app.iconText)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "square.grid.2x2" : "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(HostTheme.muted.opacity(0.5))
            Text(searchText.isEmpty ? "还没有小程序" : "没有匹配的小程序")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(HostTheme.text)
                .padding(.top, 4)
            Text(searchText.isEmpty ? "导入一个 ZIP 包开始使用" : "换个关键词试试")
                .font(.system(size: 13))
                .foregroundColor(HostTheme.muted)
            if searchText.isEmpty {
                Button {
                    showFileImporter = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("导入小程序")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(HostTheme.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(HostTheme.primary.opacity(0.45), lineWidth: 1)
                    )
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var installingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            HStack(spacing: 14) {
                ProgressView()
                    .tint(HostTheme.primary)
                Text("正在安装小程序…")
                    .font(.system(size: 14))
                    .foregroundColor(HostTheme.text)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(HostTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - Actions

    private func open(_ app: HostApp) {
        store.recordRecent(app.appId)

        guard let navController = ContentView.navigationController else {
            showToast("导航控制器尚未就绪")
            return
        }

        var appConfig = DMPAppConfig(appName: app.name, appId: app.appId)
        appConfig.isDebugMode = true
        appConfig.path = app.path
        appConfig.versionCode = app.versionCode
        appConfig.versionName = app.versionName
        appConfig.updateManifestUrl = app.updateManifestUrl

        let manager = DMPAppManager.sharedInstance()
        let dmpApp = manager.appWithConfig(appConfig: appConfig)
        dmpApp.getNavigator()!.setup(navigationController: navController)

        Task { @MainActor in
            var launchConfig = DMPLaunchConfig(
                appEntryPath: ProcessInfo.processInfo.environment["DMP_TEST_ENTRY_PATH"]
            )
            if let rawQuery = ProcessInfo.processInfo.environment["DMP_TEST_ENTRY_QUERY"],
               !rawQuery.isEmpty {
                var query: [String: Any] = [:]
                for pair in rawQuery.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard let key = kv.first else { continue }
                    query[String(key)] = kv.count > 1 ? String(kv[1]) : ""
                }
                launchConfig.query = query
            }
            await dmpApp.launch(launchConfig: launchConfig)
        }
    }

    private func install(_ package: HostImportPackage) async {
        isInstalling = true
        do {
            try await store.install(package)
            showToast("已导入 \(package.name)")
        } catch {
            showToast("导入失败：\(error.localizedDescription)")
        }
        isInstalling = false
    }

    private func uninstall(_ app: HostApp) async {
        do {
            try await store.uninstall(app)
            showToast("已卸载 \(app.name)")
        } catch {
            showToast("卸载失败：\(error.localizedDescription)")
        }
    }

    private func showToast(_ message: String) {
        withAnimation {
            toast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if toast == message {
                withAnimation {
                    toast = nil
                }
            }
        }
    }

    /// 自动化测试钩子：环境变量 DMP_TEST_AUTO_OPEN_APPID 指定 appId 时，启动后自动打开
    /// 该小程序，配合 DMP_TEST_ENTRY_PATH 覆盖启动页。
    /// 只触发一次：小程序 relaunch 的 popToRootViewController 会瞬时露出本列表页并
    /// 重跑 onAppear，无防重会用测试入口页重启小程序、覆盖正在进行的 relaunch
    private func autoOpenAppForTestIfRequested() {
        guard !ContentView.didAutoOpenForTest,
              let autoId = ProcessInfo.processInfo.environment["DMP_TEST_AUTO_OPEN_APPID"],
              let item = store.apps.first(where: { $0.appId == autoId }) else {
            return
        }
        ContentView.didAutoOpenForTest = true
        // setupNavigationController 在 onAppear 中先向 main 队列入队；这里再入队
        // 即按 FIFO 排在其后，执行时导航控制器已就绪，无需定时等待
        DispatchQueue.main.async {
            open(item)
        }
    }

    private func setupNavigationController() {
        // 在视图出现时获取并保存导航控制器
        DispatchQueue.main.async {
            if ContentView.navigationController == nil,
               let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let rootVC = window.rootViewController {

                // 尝试获取根导航控制器
                if let navController = rootVC as? UINavigationController {
                    ContentView.navigationController = navController
                } else {
                    // 如果没有导航控制器，替换根视图控制器为导航控制器
                    let navController = UINavigationController()

                    // 使用UIHostingController包装当前视图，避免重复创建ContentView
                    let hostingController = UIHostingController(rootView: self)
                    hostingController.navigationItem.title = "Dream Tapir"

                    // 设置为根视图
                    navController.viewControllers = [hostingController]
                    window.rootViewController = navController

                    ContentView.navigationController = navController
                }
            }
        }
    }
}

// MARK: - Detail sheet

private struct HostAppDetailSheet: View {
    let app: HostApp
    let onOpen: () -> Void
    let onCheckUpdate: () async -> String
    let onUninstall: () -> Void

    @State private var updateMessage = ""
    @State private var isUpdating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    appIcon(size: 62, corner: 19, fontSize: 27)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(HostTheme.text)
                        Text("\(app.sourceLabel) · v\(app.versionName)")
                            .font(.system(size: 13))
                            .foregroundColor(HostTheme.muted)
                    }
                    Spacer()
                }

                VStack(spacing: 0) {
                    detailRow("appId", app.appId)
                    detailRow("版本号", "\(app.versionCode)")
                    detailRow("启动页", app.path ?? "默认")
                    detailRow("更新源", app.canUpdate ? "已配置" : "未配置")
                }
                .padding(14)
                .background(HostTheme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if !updateMessage.isEmpty {
                    HStack(spacing: 8) {
                        if isUpdating {
                            ProgressView().tint(HostTheme.primary)
                        } else {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(HostTheme.primary)
                        }
                        Text(updateMessage)
                            .font(.system(size: 12))
                            .foregroundColor(HostTheme.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(HostTheme.primarySoft)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button(action: onOpen) {
                    Text("打开小程序")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(HostTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            isUpdating = true
                            updateMessage = await onCheckUpdate()
                            isUpdating = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(app.canUpdate ? "检查更新" : "无更新源")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(app.canUpdate ? HostTheme.text : HostTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(HostTheme.line, lineWidth: 1)
                        )
                    }
                    .disabled(!app.canUpdate || isUpdating)

                    Button(action: onUninstall) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("卸载")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(app.canUninstall ? HostTheme.red : HostTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(HostTheme.line, lineWidth: 1)
                        )
                    }
                    .disabled(!app.canUninstall)
                }

                Text("长按应用卡片也可以打开此面板。内置应用卸载后会在下次启动时恢复。")
                    .font(.system(size: 11))
                    .foregroundColor(HostTheme.muted)
                    .lineSpacing(3)
            }
            .padding(20)
        }
        .background(HostTheme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func appIcon(size: CGFloat, corner: CGFloat, fontSize: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [app.tint.opacity(0.7), app.tint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(app.iconText)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(HostTheme.muted)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(HostTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings sheet

private struct HostSettingsSheet: View {
    @ObservedObject var network: HostNetworkMonitor
    @ObservedObject var permissions: HostPermissionCenter
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("网络与权限")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(HostTheme.text)
                    Text("宿主统一管理小程序运行所需的系统能力")
                        .font(.system(size: 12))
                        .foregroundColor(HostTheme.muted)
                }

                networkCard

                VStack(alignment: .leading, spacing: 8) {
                    Text("权限中心")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(HostTheme.text)

                    VStack(spacing: 0) {
                        ForEach(Array(HostPermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                            permissionRow(kind)
                            if index < HostPermissionKind.allCases.count - 1 {
                                Divider()
                                    .padding(.horizontal, 14)
                            }
                        }
                    }
                    .background(HostTheme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                Text("小程序内首次调用相机、定位等能力时，系统也会弹出授权。若已拒绝，请前往系统设置手动开启。")
                    .font(.system(size: 11))
                    .foregroundColor(HostTheme.muted)
                    .lineSpacing(3)

                Button(action: onOpenSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                        Text("打开应用设置")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(HostTheme.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(HostTheme.line, lineWidth: 1)
                    )
                }
            }
            .padding(20)
        }
        .background(HostTheme.surface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            permissions.refresh()
        }
    }

    private var networkCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(network.snapshot.connected ? HostTheme.green : HostTheme.red)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(network.snapshot.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(HostTheme.text)
                Text(network.snapshot.detail)
                    .font(.system(size: 12))
                    .foregroundColor(HostTheme.muted)
            }
            Spacer()
        }
        .padding(16)
        .background(
            network.snapshot.connected
                ? Color(red: 0.92, green: 0.97, blue: 0.945)
                : Color(red: 1, green: 0.94, blue: 0.94)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func permissionRow(_ kind: HostPermissionKind) -> some View {
        let state = permissions.states[kind] ?? .notDetermined
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(HostTheme.text)
                Text(kind.detail)
                    .font(.system(size: 11))
                    .foregroundColor(HostTheme.muted)
            }
            Spacer()
            if state.isAuthorized {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("已授权")
                }
                .font(.system(size: 12))
                .foregroundColor(HostTheme.green)
            } else {
                Button {
                    if state == .notDetermined {
                        permissions.request(kind)
                    } else {
                        permissions.openSettings()
                    }
                } label: {
                    Text(state == .notDetermined ? "授权" : "去设置")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(HostTheme.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Theme

private enum HostTheme {
    static let bg = Color(red: 0.953, green: 0.961, blue: 0.984)
    static let surface = Color.white
    static let primary = Color(red: 0.231, green: 0.357, blue: 1)
    static let primarySoft = Color(red: 0.914, green: 0.929, blue: 1)
    static let text = Color(red: 0.09, green: 0.102, blue: 0.133)
    static let muted = Color(red: 0.478, green: 0.506, blue: 0.58)
    static let line = Color(red: 0.91, green: 0.922, blue: 0.953)
    static let green = Color(red: 0.094, green: 0.659, blue: 0.42)
    static let red = Color(red: 0.898, green: 0.282, blue: 0.302)
}

#Preview("ContentView") {
    ContentView()
}
