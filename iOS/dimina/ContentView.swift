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
    @StateObject private var catalog = HostCatalogCenter()

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var filter: HostFilter = .all
    // 首页展示方式：三列图标网格 / 单列信息列表，记住上次选择。
    @AppStorage("host.home.listLayout") private var listLayout = false
    @State private var selectedItem: HostHubItem?
    @State private var showSettings = false
    @State private var showUpdateCenter = false
    @State private var showFileImporter = false
    @State private var pendingImport: HostImportPackage?
    @State private var uninstallTarget: HostApp?
    @State private var showUninstallConfirm = false
    @State private var isInstalling = false
    @State private var toast: String?
    @State private var didStartupCheck = false

    // 存储UINavigationController的引用
    static var navigationController: UINavigationController?

    // 自动化测试钩子的一次性标记（见 autoOpenAppForTestIfRequested）
    static var didAutoOpenForTest = false

    var body: some View {
        ZStack(alignment: .bottom) {
            HostTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                searchBar
                filterRow
                if !network.snapshot.connected {
                    offlineBanner
                }
                content
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
        .task {
            permissions.refresh()
            autoOpenAppForTestIfRequested()
            await startupCheck()
        }
        .sheet(item: $selectedItem) { item in
            HostAppDetailSheet(
                item: item,
                catalog: catalog,
                onOpen: {
                    selectedItem = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        open(item)
                    }
                },
                onInstall: { remote in
                    await install(remote)
                },
                onUninstall: { local, clearData in
                    await uninstall(local, clearData: clearData)
                },
                onCheckUpdate: {
                    await sync(force: true)
                },
                onToast: { showToast($0) }
            )
        }
        .sheet(isPresented: $showSettings) {
            HostSettingsSheet(
                catalog: catalog,
                network: network,
                permissions: permissions,
                onOpenSettings: { permissions.openSettings() },
                onRefreshNow: { Task { await sync(force: true) } }
            )
        }
        .sheet(isPresented: $showUpdateCenter) {
            HostUpdateCenterSheet(
                items: updatableItems,
                catalog: catalog,
                onUpdateAll: {
                    await installAll(items: updatableItems)
                },
                onInstallOne: { item in
                    if let remote = item.remote {
                        await install(remote)
                    }
                }
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
                Task { await uninstall(app, clearData: false) }
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

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            syncIndicator

            Spacer(minLength: 4)

            headerButton(systemName: "arrow.clockwise", label: "刷新应用目录") {
                Task { await sync(force: true) }
            }
            headerButton(systemName: "plus", label: "导入小程序") {
                showFileImporter = true
            }
            headerButton(systemName: "slider.horizontal.3", label: "设置") {
                showSettings = true
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var syncIndicator: some View {
        Button {
            if updatableItems.isEmpty {
                showSettings = true
            } else {
                showUpdateCenter = true
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(syncColor)
                    .frame(width: 8, height: 8)
                Text(syncLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(HostTheme.muted)
                if !updatableItems.isEmpty {
                    Text("\(updatableItems.count) 个可更新")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(HostTheme.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(HostTheme.primarySoft)
                        .clipShape(Capsule())
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var syncLabel: String {
        switch catalog.syncState {
        case .syncing:
            return "正在同步…"
        case let .failed(message):
            return message
        case let .ok(date):
            return "已同步 · \(Self.timeText(date))"
        case .idle:
            if catalog.remoteApps.isEmpty { return "未同步 · 点此配置应用源" }
            return "离线目录 · \(catalog.remoteApps.count) 个应用"
        }
    }

    private var syncColor: Color {
        switch catalog.syncState {
        case .syncing: return HostTheme.primary
        case .failed: return HostTheme.red
        case .ok: return HostTheme.green
        case .idle: return HostTheme.muted.opacity(0.6)
        }
    }

    private func headerButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(HostTheme.text)
                .frame(width: 36, height: 36)
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

            TextField("", text: $searchText)
                .font(.system(size: 15))
                .foregroundColor(HostTheme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .accessibilityLabel("搜索名称或 appId")

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
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            ForEach(HostFilter.allCases) { item in
                let count = count(for: item)
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { filter = item }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(filter == item ? HostTheme.surface : HostTheme.muted)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(filter == item ? HostTheme.text : HostTheme.surface)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)

            // 切换网格/单列：图标展示的是「点完会变成的布局」。
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    listLayout.toggle()
                }
            } label: {
                Image(systemName: listLayout ? "square.grid.2x2" : "list.bullet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HostTheme.text)
                    .frame(width: 32, height: 32)
                    .background(HostTheme.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(listLayout ? "切换为网格布局" : "切换为单列布局")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
            Text("当前无网络，显示本地与缓存的目录")
                .font(.system(size: 12))
            Spacer()
        }
        .foregroundColor(HostTheme.red)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(HostTheme.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !updatableItems.isEmpty && filter != .updates {
                    updateBar
                }

                if case let .failed(message) = catalog.syncState, catalog.remoteApps.isEmpty {
                    errorBanner(message)
                }

                if visibleItems.isEmpty {
                    emptyState
                } else if listLayout {
                    VStack(spacing: 10) {
                        ForEach(visibleItems) { item in
                            appRow(item)
                        }
                    }
                } else {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 12),
                            count: 3
                        ),
                        spacing: 12
                    ) {
                        ForEach(visibleItems) { item in
                            appCard(item)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        // 搜索框弹出键盘后，点列表空白处或拖动列表都要能收起键盘，
        // 否则键盘会一直压在首页上。
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(
            TapGesture().onEnded { searchFocused = false }
        )
        .refreshable {
            await sync(force: true)
        }
    }

    private var updateBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 17))
                .foregroundColor(HostTheme.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(updatableItems.count) 个应用可更新")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HostTheme.text)
                Text("下载完成后下次打开生效")
                    .font(.system(size: 11))
                    .foregroundColor(HostTheme.muted)
            }
            Spacer()
            Button {
                showUpdateCenter = true
            } label: {
                Text("全部更新")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(HostTheme.primary)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(HostTheme.primarySoft)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(HostTheme.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("目录同步失败")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(HostTheme.text)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(HostTheme.muted)
                    .lineLimit(2)
            }
            Spacer()
            Button("重试") {
                Task { await sync(force: true) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(HostTheme.primary)
        }
        .padding(12)
        .background(HostTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Cards

    private func appCard(_ item: HostHubItem) -> some View {
        let transfer = catalog.transfers[item.appId]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                appIcon(item, size: 48, corner: 15, fontSize: 21)
                Spacer(minLength: 4)
                statusBadge(item, transfer: transfer)
            }

            Spacer(minLength: 8)

            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(HostTheme.text)
                .lineLimit(1)
                .multilineTextAlignment(.leading)

            // 下载/安装中把版本行换成进度，卡片高度保持不变。
            if transfer?.isBusy == true {
                Group {
                    if let progress = transfer?.progress {
                        ProgressView(value: progress)
                            .tint(HostTheme.primary)
                    } else {
                        ProgressView()
                            .tint(HostTheme.primary)
                            .scaleEffect(0.6, anchor: .leading)
                    }
                }
                .padding(.top, 8)
            } else {
                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(item.hasUpdate ? HostTheme.primary : HostTheme.muted)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 116)
        .background(HostTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    item.hasUpdate
                        ? HostTheme.primary.opacity(0.35)
                        : HostTheme.line,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            activate(item)
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            selectedItem = item
        }
    }

    /// 单列模式：图标 + 名称/版本 + 右侧状态，名称可以完整占一行。
    private func appRow(_ item: HostHubItem) -> some View {
        let transfer = catalog.transfers[item.appId]
        return HStack(spacing: 12) {
            appIcon(item, size: 48, corner: 15, fontSize: 21)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HostTheme.text)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(item.hasUpdate ? HostTheme.primary : HostTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            statusBadge(item, transfer: transfer)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 72)
        .background(HostTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    item.hasUpdate
                        ? HostTheme.primary.opacity(0.35)
                        : HostTheme.line,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            activate(item)
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            selectedItem = item
        }
    }

    private func activate(_ item: HostHubItem) {
        if item.canOpen && !item.hasUpdate {
            open(item)
        } else {
            selectedItem = item
        }
    }

    @ViewBuilder
    private func statusBadge(_ item: HostHubItem, transfer: HostTransferState?) -> some View {
        if case let .failed(message)? = transfer {
            Text("失败")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(HostTheme.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(HostTheme.red.opacity(0.12))
                .clipShape(Capsule())
                .accessibilityLabel(message)
        } else if transfer?.isBusy == true {
            Text(transferLabel(transfer))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(HostTheme.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(HostTheme.primarySoft)
                .clipShape(Capsule())
        } else if item.hasUpdate {
            Text("可更新")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(HostTheme.primary)
                .clipShape(Capsule())
        } else if item.isRemoteOnly {
            Text("未安装")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(HostTheme.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(HostTheme.bg)
                .clipShape(Capsule())
        } else if item.installed && !item.bundled {
            Text("导入")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(HostTheme.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(HostTheme.primarySoft)
                .clipShape(Capsule())
        }
    }

    private func transferLabel(_ state: HostTransferState?) -> String {
        switch state {
        case .installing: return "安装中"
        case .verifying: return "校验中"
        case .downloading: return "下载中"
        default: return "处理中"
        }
    }

    private func appIcon(
        _ item: HostHubItem,
        size: CGFloat,
        corner: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        ZStack {
            if let image = catalog.icons[item.appId] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [item.tint.opacity(0.7), item.tint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(item.iconText)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptySymbol)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(HostTheme.muted.opacity(0.5))
            Text(emptyTitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(HostTheme.text)
                .padding(.top, 4)
            Text(emptyDetail)
                .font(.system(size: 13))
                .foregroundColor(HostTheme.muted)
                .multilineTextAlignment(.center)

            if store.apps.isEmpty && !catalog.remoteApps.isEmpty && searchText.isEmpty {
                Button {
                    Task { await installAll(items: installableItems) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text("全部安装（\(installableItems.count)）")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 42)
                    .background(HostTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.top, 10)
            }

            if searchText.isEmpty {
                HStack(spacing: 10) {
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
                    if catalog.config.source.isEmpty {
                        Button {
                            showSettings = true
                        } label: {
                            Text("配置应用源")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(HostTheme.text)
                                .padding(.horizontal, 16)
                                .frame(height: 42)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(HostTheme.line, lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var emptySymbol: String {
        if !searchText.isEmpty { return "magnifyingglass" }
        if filter == .updates { return "checkmark.circle" }
        if !catalog.remoteApps.isEmpty { return "cloud" }
        return "square.grid.2x2"
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "没有匹配的小程序" }
        if filter == .updates { return "全部应用已是最新" }
        if !catalog.remoteApps.isEmpty && store.apps.isEmpty { return "远程目录有 \(catalog.remoteApps.count) 个应用" }
        return "还没有小程序"
    }

    private var emptyDetail: String {
        if !searchText.isEmpty { return "换个关键词试试" }
        if filter == .updates { return "有新版本时会在这里出现" }
        if !catalog.remoteApps.isEmpty && store.apps.isEmpty {
            return "点击全部安装，或进入设置检查应用源"
        }
        if catalog.config.source.isEmpty { return "先配置 apps.json 地址，再拉取应用目录" }
        return "从远程目录安装，或导入一个 ZIP 包"
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

    // MARK: - Derived data

    private var hubItems: [HostHubItem] {
        var remoteMap: [String: HostRemoteApp] = [:]
        for app in catalog.remoteApps { remoteMap[app.appId] = app }

        var items: [HostHubItem] = []
        var seen = Set<String>()
        for app in store.apps {
            items.append(HostHubItem(appId: app.appId, local: app, remote: remoteMap[app.appId]))
            seen.insert(app.appId)
        }
        for remote in catalog.remoteApps where !seen.contains(remote.appId) {
            items.append(HostHubItem(appId: remote.appId, local: nil, remote: remote))
        }
        return items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var updatableItems: [HostHubItem] {
        hubItems.filter { $0.hasUpdate }
    }

    private var installableItems: [HostHubItem] {
        hubItems.filter { $0.needsInstall }
    }

    private var visibleItems: [HostHubItem] {
        var items: [HostHubItem]
        switch filter {
        case .recent:
            items = store.recentIds.compactMap { id in hubItems.first { $0.appId == id } }
        case .all:
            items = hubItems
        case .updates:
            items = updatableItems
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
                $0.appId.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func count(for item: HostFilter) -> Int {
        switch item {
        case .recent: return store.recentIds.count
        case .all: return hubItems.count
        case .updates: return updatableItems.count
        }
    }

    // MARK: - Actions

    private func startupCheck() async {
        guard !didStartupCheck else { return }
        didStartupCheck = true
        guard catalog.config.autoCheck, !catalog.config.source.isEmpty else { return }
        await sync(force: false)
    }

    private func sync(force: Bool) async {
        await catalog.sync(force: force)
        if case let .failed(message) = catalog.syncState {
            showToast(message)
            return
        }
        if case .ok = catalog.syncState {
            await autoInstallIfNeeded()
        }
    }

    private func autoInstallIfNeeded() async {
        guard catalog.config.autoInstall else { return }
        if catalog.config.wifiOnlyAutoDownload {
            let type = network.snapshot.type
            guard type == "Wi-Fi" || type == "有线网络" else { return }
        }
        let targets = updatableItems
        guard !targets.isEmpty else { return }
        await installAll(items: targets, announce: true)
    }

    private func installAll(items: [HostHubItem], announce: Bool = false) async {
        var completed = 0
        for item in items {
            guard let remote = item.remote else { continue }
            if catalog.transfers[item.appId]?.isBusy == true { continue }
            do {
                try await catalog.install(remote)
                completed += 1
                store.reload()
            } catch {
                showToast("\(item.name)：\(HostCatalogCenter.describe(error))")
            }
        }
        if completed > 0 {
            store.reload()
            showToast(announce ? "已自动更新 \(completed) 个应用，下次打开生效" : "已更新 \(completed) 个应用，下次打开生效")
        }
    }

    private func install(_ remote: HostRemoteApp) async {
        do {
            try await catalog.install(remote)
            store.reload()
            showToast("已更新 \(remote.name)，下次打开生效")
        } catch {
            showToast("\(remote.name)：\(HostCatalogCenter.describe(error))")
        }
    }

    private func open(_ item: HostHubItem) {
        guard let app = item.local else {
            selectedItem = item
            return
        }
        open(app)
    }

    private func open(_ app: HostApp) {
        store.recordRecent(app.appId)

        guard let navController = ContentView.navigationController else {
            showToast("导航控制器尚未就绪")
            return
        }

        var appConfig = DMPAppConfig(appName: app.name, appId: app.appId)
        appConfig.isDebugMode = catalog.config.debugEnabled
        appConfig.path = app.path
        appConfig.versionCode = app.versionCode
        appConfig.versionName = app.versionName
        appConfig.updateManifestUrl = app.updateManifestUrl
        // 胶囊菜单里展示小程序自己的头像，复用首页已经缓存好的图标
        appConfig.iconImage = catalog.icons[app.appId]

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

    private func uninstall(_ app: HostApp, clearData: Bool) async {
        do {
            try await DMPAppManager.sharedInstance().uninstallMiniProgram(
                appId: app.appId,
                clearUserData: clearData
            )
            store.reload()
            showToast(clearData ? "已卸载并清除数据 \(app.name)" : "已卸载 \(app.name)")
        } catch {
            showToast("卸载失败：\(error.localizedDescription)")
        }
    }

    private func showToast(_ message: String) {
        withAnimation {
            toast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            if toast == message {
                withAnimation {
                    toast = nil
                }
            }
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 自动化测试钩子：环境变量 DMP_TEST_AUTO_OPEN_APPID 指定 appId 时，启动后自动打开
    /// 该小程序，配合 DMP_TEST_ENTRY_PATH 覆盖启动页。
    private func autoOpenAppForTestIfRequested() {
        guard !ContentView.didAutoOpenForTest,
              let autoId = ProcessInfo.processInfo.environment["DMP_TEST_AUTO_OPEN_APPID"],
              let item = store.apps.first(where: { $0.appId == autoId }) else {
            return
        }
        ContentView.didAutoOpenForTest = true
        DispatchQueue.main.async {
            open(item)
        }
    }
}

// MARK: - Filters

enum HostFilter: String, CaseIterable, Identifiable {
    case recent
    case all
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "最近使用"
        case .all: return "全部"
        case .updates: return "可更新"
        }
    }
}

// MARK: - Detail sheet

private struct HostAppDetailSheet: View {
    let item: HostHubItem
    @ObservedObject var catalog: HostCatalogCenter
    let onOpen: () -> Void
    let onInstall: (HostRemoteApp) async -> Void
    let onUninstall: (HostApp, Bool) async -> Void
    let onCheckUpdate: () async -> Void
    let onToast: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showUninstallOptions = false
    @State private var isChecking = false

    private var transfer: HostTransferState? { catalog.transfers[item.appId] }

    private var minimumHost: String? {
        guard let raw = item.remote?.minHostVersion, !raw.isEmpty else { return nil }
        return raw
    }

    private var hostTooLow: Bool {
        guard let minimumHost else { return false }
        return HostCatalogCenter.compareVersion(catalog.hostVersion, minimumHost) < 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(spacing: 0) {
                    detailRow("appId", item.appId)
                    detailRow("本地版本", item.local == nil ? "未安装" : item.versionName)
                    if let remote = item.remote {
                        detailRow("远程版本", "\(remote.versionName) (\(remote.versionCode))")
                        if let size = remote.size, size > 0 {
                            detailRow("安装包", HostCatalogCenter.formatBytes(size))
                        }
                        if let publishedAt = remote.publishedAt, !publishedAt.isEmpty {
                            detailRow("发布时间", publishedAt)
                        }
                        if let minVersion = remote.minHostVersion, !minVersion.isEmpty {
                            detailRow("最低宿主", minVersion)
                        }
                    }
                    detailRow("来源", item.local?.sourceLabel ?? "远程目录")
                }
                .padding(14)
                .background(HostTheme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let notes = item.remote?.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("更新说明")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(HostTheme.text)
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundColor(HostTheme.muted)
                            .lineSpacing(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(HostTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(HostTheme.line, lineWidth: 1)
                    )
                }

                if let transfer {
                    transferCard(transfer)
                }

                if hostTooLow, let minimumHost {
                    noticeCard("需要宿主版本 ≥ \(minimumHost)，请先升级 Dream Tapir")
                }

                primaryAction

                HStack(spacing: 10) {
                    Button {
                        Task {
                            isChecking = true
                            await onCheckUpdate()
                            isChecking = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isChecking {
                                ProgressView().tint(HostTheme.text)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("检查更新")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(HostTheme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(HostTheme.line, lineWidth: 1)
                        )
                    }
                    .disabled(isChecking)

                    Button {
                        showUninstallOptions = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("卸载")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(item.canOpen ? HostTheme.red : HostTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(HostTheme.line, lineWidth: 1)
                        )
                    }
                    .disabled(!item.canOpen)
                }

                Text("安装或更新完成后，下次打开小程序生效。内置应用卸载后会在下次启动时恢复。")
                    .font(.system(size: 11))
                    .foregroundColor(HostTheme.muted)
                    .lineSpacing(3)
            }
            .padding(20)
        }
        .background(HostTheme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            "卸载 \(item.name)？",
            isPresented: $showUninstallOptions,
            titleVisibility: .visible
        ) {
            Button("卸载（保留数据）", role: .destructive) {
                guard let local = item.local else { return }
                Task {
                    await onUninstall(local, false)
                    dismiss()
                }
            }
            Button("卸载并清除数据", role: .destructive) {
                guard let local = item.local else { return }
                Task {
                    await onUninstall(local, true)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除数据会移除该小程序的本地存储，操作不可恢复。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let image = catalog.icons[item.appId] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [item.tint.opacity(0.7), item.tint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay(
                        Text(item.iconText)
                            .font(.system(size: 27, weight: .bold))
                            .foregroundColor(.white)
                    )
                }
            }
            .frame(width: 62, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(HostTheme.text)
                Text(item.subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(HostTheme.muted)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let remote = item.remote, item.hasUpdate || item.needsInstall {
            Button {
                Task {
                    await onInstall(remote)
                    if catalog.transfers[item.appId] == nil {
                        dismiss()
                    }
                }
            } label: {
                Text(item.hasUpdate ? "更新到 v\(remote.versionName)" : "安装 v\(remote.versionName)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(hostTooLow ? HostTheme.muted : HostTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .disabled(transfer?.isBusy == true || hostTooLow)
        } else if item.canOpen {
            Button(action: onOpen) {
                Text("打开小程序")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(HostTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        } else {
            Button {
                Task {
                    await onCheckUpdate()
                    onToast("目录已刷新")
                }
            } label: {
                Text("从目录重新获取")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(HostTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
    }

    private func transferCard(_ state: HostTransferState) -> some View {
        HStack(spacing: 10) {
            switch state {
            case let .downloading(progress):
                ProgressView(value: progress >= 0 ? progress : 0.05)
                    .frame(width: 90)
                Text(progress >= 0 ? "下载中 \(Int(progress * 100))%" : "正在连接下载…")
            case .verifying:
                ProgressView().tint(HostTheme.primary)
                Text("校验安装包…")
            case .installing:
                ProgressView().tint(HostTheme.primary)
                Text("安装中…")
            case let .failed(message):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(HostTheme.red)
                Text(message)
            }
        }
        .font(.system(size: 12))
        .foregroundColor(HostTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HostTheme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func noticeCard(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(HostTheme.red)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(HostTheme.red)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(HostTheme.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Update center

private struct HostUpdateCenterSheet: View {
    let items: [HostHubItem]
    @ObservedObject var catalog: HostCatalogCenter
    let onUpdateAll: () async -> Void
    let onInstallOne: (HostHubItem) async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("更新中心")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(HostTheme.text)
                    Text("\(items.count) 个应用有新版本")
                        .font(.system(size: 12))
                        .foregroundColor(HostTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(HostTheme.muted)
                        .frame(width: 30, height: 30)
                        .background(HostTheme.bg)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if items.isEmpty {
                Text("全部应用已是最新")
                    .font(.system(size: 13))
                    .foregroundColor(HostTheme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }

            Button {
                Task {
                    await onUpdateAll()
                    dismiss()
                }
            } label: {
                Text("全部更新（\(items.count)）")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(items.isEmpty ? HostTheme.muted : HostTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .disabled(items.isEmpty)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(HostTheme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ item: HostHubItem) -> some View {
        let transfer = catalog.transfers[item.appId]
        return HStack(spacing: 12) {
            Group {
                if let image = catalog.icons[item.appId] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(
                        colors: [item.tint.opacity(0.7), item.tint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay(
                        Text(item.iconText)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                    )
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(HostTheme.text)
                    .lineLimit(1)
                if let remote = item.remote {
                    Text("v\(item.versionName) → v\(remote.versionName)")
                        .font(.system(size: 11))
                        .foregroundColor(HostTheme.muted)
                }
                if let progress = transfer?.progress {
                    ProgressView(value: progress)
                        .tint(HostTheme.primary)
                }
            }

            Spacer()

            if transfer?.isBusy == true {
                ProgressView().tint(HostTheme.primary)
            } else {
                Button {
                    Task { await onInstallOne(item) }
                } label: {
                    Text("更新")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(HostTheme.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(HostTheme.primarySoft)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(HostTheme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Settings sheet

private struct HostStorageSummary {
    var installed: Int64 = 0
    var downloads: Int64 = 0
    var icons: Int64 = 0
}

private struct HostSettingsSheet: View {
    @ObservedObject var catalog: HostCatalogCenter
    @ObservedObject var network: HostNetworkMonitor
    @ObservedObject var permissions: HostPermissionCenter
    let onOpenSettings: () -> Void
    let onRefreshNow: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sourceDraft = ""
    @State private var channelDraft = ""
    @State private var authUserDraft = ""
    @State private var authPasswordDraft = ""
    @State private var storage = HostStorageSummary()
    @State private var showDiagnostics = false
    @AppStorage(HostThemeMode.storageKey) private var themeMode = HostThemeMode.system.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("设置")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(HostTheme.text)
                        Text("应用源、更新策略与系统权限")
                            .font(.system(size: 12))
                            .foregroundColor(HostTheme.muted)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(HostTheme.muted)
                            .frame(width: 30, height: 30)
                            .background(HostTheme.bg)
                            .clipShape(Circle())
                    }
                }

                sourceSection

                ToggleRow(
                    title: "自动检查更新",
                    detail: "启动时同步应用目录",
                    isOn: Binding(
                        get: { catalog.config.autoCheck },
                        set: { value in catalog.updateConfig { $0.autoCheck = value } }
                    )
                )
                ToggleRow(
                    title: "仅 Wi-Fi 自动下载",
                    detail: "蜂窝网络下不自动下载安装包",
                    isOn: Binding(
                        get: { catalog.config.wifiOnlyAutoDownload },
                        set: { value in catalog.updateConfig { $0.wifiOnlyAutoDownload = value } }
                    )
                )
                ToggleRow(
                    title: "自动安装更新",
                    detail: "同步后自动下载并安装，下次打开生效",
                    isOn: Binding(
                        get: { catalog.config.autoInstall },
                        set: { value in catalog.updateConfig { $0.autoInstall = value } }
                    )
                )

                ToggleRow(
                    title: "调试模式",
                    detail: "打开后小程序内显示 vConsole 调试面板，下次打开小程序生效",
                    isOn: Binding(
                        get: { catalog.config.debugEnabled },
                        set: { value in catalog.updateConfig { $0.debugEnabled = value } }
                    )
                )

                themeSection

                storageSection
                diagnosticsRow
                networkCard
                permissionSection

                Button(action: onOpenSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                        Text("打开系统应用设置")
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
            sourceDraft = catalog.config.source
            channelDraft = catalog.config.channel
            authUserDraft = catalog.config.authUser
            authPasswordDraft = catalog.config.authPassword
            refreshStorage()
        }
        .sheet(isPresented: $showDiagnostics) {
            HostDiagnosticsSheet(catalog: catalog)
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("外观")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(HostTheme.text)
            HStack(spacing: 8) {
                ForEach(HostThemeMode.allCases, id: \.rawValue) { mode in
                    let selected = themeMode == mode.rawValue
                    Text(mode.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selected ? HostTheme.surface : HostTheme.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selected ? HostTheme.text : HostTheme.surface)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(HostTheme.line, lineWidth: selected ? 0 : 1)
                        )
                        .onTapGesture { themeMode = mode.rawValue }
                }
                Spacer(minLength: 0)
            }
            Text("默认跟随系统深色模式切换，手动选择后立即生效")
                .font(.system(size: 11))
                .foregroundColor(HostTheme.muted)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("应用源")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(HostTheme.text)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 13))
                        .foregroundColor(HostTheme.muted)
                    TextField("https://example.com/apps.json", text: $sourceDraft)
                        .font(.system(size: 13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(HostTheme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.system(size: 13))
                        .foregroundColor(HostTheme.muted)
                    TextField("渠道（prod / beta）", text: $channelDraft)
                        .font(.system(size: 13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(HostTheme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 8) {
                    Image(systemName: "person")
                        .font(.system(size: 13))
                        .foregroundColor(HostTheme.muted)
                    TextField("访问用户名（未启用可留空）", text: $authUserDraft)
                        .font(.system(size: 13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(HostTheme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 8) {
                    Image(systemName: "lock")
                        .font(.system(size: 13))
                        .foregroundColor(HostTheme.muted)
                    SecureField("访问密码", text: $authPasswordDraft)
                        .font(.system(size: 13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(HostTheme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        catalog.updateConfig {
                            $0.source = sourceDraft
                            $0.channel = channelDraft
                            $0.authUser = authUserDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            $0.authPassword = authPasswordDraft
                        }
                        onRefreshNow()
                    } label: {
                        Text("保存并刷新")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(HostTheme.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Button {
                        catalog.resetSource()
                        sourceDraft = catalog.config.source
                        channelDraft = "prod"
                        catalog.updateConfig {
                            $0.channel = "prod"
                            $0.authUser = ""
                            $0.authPassword = ""
                        }
                        authUserDraft = ""
                        authPasswordDraft = ""
                    } label: {
                        Text("恢复默认")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(HostTheme.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(HostTheme.line, lineWidth: 1)
                            )
                    }
                }
            }
            .padding(12)
            .background(HostTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(HostTheme.line, lineWidth: 1)
            )

            Text("地址支持直接填写 apps.json，或填写站点根路径自动补全 /apps.json。安装包与图标必须与应用源同域。若站点在宝塔开启了「密码访问」，填写对应的用户名和密码，目录、安装包、图标请求都会自动携带。")
                .font(.system(size: 11))
                .foregroundColor(HostTheme.muted)
                .lineSpacing(3)
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("存储")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(HostTheme.text)

            VStack(spacing: 0) {
                storageRow("已安装应用", HostCatalogCenter.formatBytes(storage.installed))
                Divider().padding(.horizontal, 14)
                storageRow("下载缓存", HostCatalogCenter.formatBytes(storage.downloads))
                Divider().padding(.horizontal, 14)
                storageRow("图标缓存", HostCatalogCenter.formatBytes(storage.icons))
            }
            .background(HostTheme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    catalog.clearDownloadCache()
                    refreshStorage()
                } label: {
                    Text("清理下载缓存")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(HostTheme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 39)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(HostTheme.line, lineWidth: 1)
                        )
                }
                Button {
                    catalog.clearIconCache()
                    refreshStorage()
                } label: {
                    Text("清理图标缓存")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(HostTheme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 39)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(HostTheme.line, lineWidth: 1)
                        )
                }
            }
        }
    }

    private var diagnosticsRow: some View {
        Button {
            showDiagnostics = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 14))
                    .foregroundColor(HostTheme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("源诊断")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(HostTheme.text)
                    Text("检查连通性、TLS、鉴权与磁盘")
                        .font(.system(size: 11))
                        .foregroundColor(HostTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(HostTheme.muted)
            }
            .padding(14)
            .background(HostTheme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
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
            (network.snapshot.connected ? HostTheme.green : HostTheme.red).opacity(0.12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var permissionSection: some View {
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

            Text("小程序内首次调用相机、定位等能力时，系统也会弹出授权。若已拒绝，请前往系统设置手动开启。")
                .font(.system(size: 11))
                .foregroundColor(HostTheme.muted)
                .lineSpacing(3)
        }
    }

    private func storageRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(HostTheme.text)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(HostTheme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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

    private func refreshStorage() {
        storage = HostStorageSummary(
            installed: catalog.installedBytes(),
            downloads: catalog.downloadCacheBytes(),
            icons: catalog.iconCacheBytes()
        )
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(HostTheme.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(HostTheme.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(HostTheme.primary)
        }
        .padding(14)
        .background(HostTheme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Diagnostics

private struct HostDiagnosticsSheet: View {
    @ObservedObject var catalog: HostCatalogCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("源诊断")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(HostTheme.text)
                    Text("连通性、TLS、鉴权与存储")
                        .font(.system(size: 12))
                        .foregroundColor(HostTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(HostTheme.muted)
                        .frame(width: 30, height: 30)
                        .background(HostTheme.bg)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(catalog.diagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(HostTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(HostTheme.bg)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Button {
                Task { await catalog.runDiagnostics() }
            } label: {
                HStack(spacing: 8) {
                    if catalog.isDiagnosing {
                        ProgressView().tint(.white)
                    }
                    Text(catalog.isDiagnosing ? "诊断中…" : "重新诊断")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(HostTheme.primary)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .disabled(catalog.isDiagnosing)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(HostTheme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            if catalog.diagnostics.isEmpty {
                await catalog.runDiagnostics()
            }
        }
    }
}

// MARK: - Theme

/// 宿主明暗两套配色。通过动态 UIColor 桥接，跟随 traitCollection（含 overrideUserInterfaceStyle）自动切换。
enum HostTheme {
    private static func dynamic(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    static let bg = dynamic(light: (0.953, 0.961, 0.984), dark: (0.055, 0.067, 0.094))
    static let surface = dynamic(light: (1, 1, 1), dark: (0.094, 0.110, 0.149))
    static let primary = dynamic(light: (0.231, 0.357, 1), dark: (0.361, 0.455, 1))
    static let primarySoft = dynamic(light: (0.914, 0.929, 1), dark: (0.137, 0.169, 0.290))
    static let text = dynamic(light: (0.09, 0.102, 0.133), dark: (0.945, 0.953, 0.976))
    static let muted = dynamic(light: (0.478, 0.506, 0.58), dark: (0.541, 0.565, 0.639))
    static let line = dynamic(light: (0.91, 0.922, 0.953), dark: (0.149, 0.169, 0.220))
    static let green = dynamic(light: (0.094, 0.659, 0.42), dark: (0.184, 0.741, 0.498))
    static let red = dynamic(light: (0.898, 0.282, 0.302), dark: (1, 0.392, 0.412))
}

/// 宿主外观设置：system（跟随系统）/ light / dark，持久化在 AppStorage。
enum HostThemeMode: String, CaseIterable {
    case system
    case light
    case dark

    static let storageKey = "host.theme.mode"

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var uiStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return .unspecified
        }
    }

    /// SwiftUI 场景下的外观覆盖；system 返回 nil 表示跟随系统。
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

#Preview("ContentView") {
    ContentView()
}
