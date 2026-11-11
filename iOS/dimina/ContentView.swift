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
    @State private var showNewGroupAlert = false
    @State private var newGroupName = ""
    @State private var renamingGroup: HostGroup?
    @State private var renameText = ""
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
    @State private var toast: HostToast?
    @State private var didStartupCheck = false
    /// 长按拖动排序后的顺序（appId），持久化在本地。
    @State private var manualOrder: [String] = []
    @State private var draggingId: String?
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var dragFrames: [String: CGRect] = [:]
    @State private var suppressTapUntil = Date.distantPast
    /// 拖动起点与当前手指位置（内容坐标系），用于让浮动卡片跟手。
    @State private var dragStart: CGPoint?
    @State private var dragLocation: CGPoint?
    /// 按下瞬间各格子的矩形（顺序与展示列表一致），拖动全程不变。
    @State private var dragSlots: [CGRect] = []
    /// 卡片长按/拖动手势是否在进行中；手势被系统取消时 SwiftUI 会自动复位为 false。
    @GestureState private var cardGestureActive = false
    /// 当前仍在运行的小程序（前台排第一），由框架的实例快照刷新。
    @State private var runningIds: [String] = []
    @State private var showSwitcher = false
    @State private var showCloseAllConfirm = false
    /// 下拉刷新状态，驱动顶部提示条的"同步中"文案。
    @State private var isRefreshing = false

    /// 存储UINavigationController的引用
    static var navigationController: UINavigationController?

    /// 自动化测试钩子的一次性标记（见 autoOpenAppForTestIfRequested）
    static var didAutoOpenForTest = false

    private static let appOrderKey = "dimina.host.appOrder"

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
                    .transition(.opacity)
            }

            if let toast {
                HostToastView(toast: toast)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            manualOrder = UserDefaults.standard.stringArray(forKey: Self.appOrderKey) ?? []
            // 按设置应用后台保活数量：常驻不超时，只受数量上限约束。
            DMPAppManager.sharedInstance().configureRetention(
                DMPRetentionPolicy(maxBackgroundApps: catalog.config.maxBackgroundApps, backgroundTimeoutMs: 0)
            )
            permissions.refresh()
            refreshRunning()
            autoOpenAppForTestIfRequested()
            await startupCheck()
        }
        // 从小程序退回来时根视图重新可见，刷新运行中实例。
        .background(
            HostAppearanceObserver {
                refreshRunning()
            }
            .frame(width: 0, height: 0)
        )
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshRunning()
        }
        // 手势被系统取消（滚动竞争 / 视图重建）时 GestureState 会复位，
        // 在这里兜底清掉拖动状态，避免跟手浮层永久卡在屏幕上。
        // 延迟一点执行，确保正常结束的 onEnded（打开详情 / 落位）先跑完。
        .onChange(of: cardGestureActive) { _, active in
            guard !active, draggingId != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if draggingId != nil {
                    resetDragState()
                }
            }
        }
        .sheet(isPresented: $showSwitcher) {
            switcherSheet
        }
        .confirmationDialog("关闭全部小程序？", isPresented: $showCloseAllConfirm, titleVisibility: .visible) {
            Button("全部关闭", role: .destructive) {
                Task { await closeAllRunning() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将结束所有后台实例，页面栈会被清空；小程序包和用户数据保留。")
        }
        .sheet(item: $selectedItem) { item in
            HostAppDetailSheet(
                item: item,
                catalog: catalog,
                groups: store.groups,
                currentGroupId: store.groupId(for: item.appId),
                onAssignGroup: { groupId in
                    store.assign(item.appId, to: groupId)
                },
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
        .alert("新建分组", isPresented: $showNewGroupAlert) {
            TextField("分组名称", text: $newGroupName)
            Button("创建") {
                let group = store.addGroup(named: newGroupName)
                withAnimation(.easeOut(duration: 0.18)) { filter = .group(group.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("分组只保存在本机，可随时重命名或删除。")
        }
        .alert("重命名分组", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("分组名称", text: $renameText)
            Button("保存") {
                if let group = renamingGroup {
                    store.renameGroup(group.id, to: renameText)
                }
                renamingGroup = nil
            }
            Button("取消", role: .cancel) { renamingGroup = nil }
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
                    showToast("读取失败：\(error.localizedDescription)", kind: .error)
                }
            case .failure(let error):
                showToast("选择文件失败：\(error.localizedDescription)", kind: .error)
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HostFilter.builtins) { item in
                        filterChip(item, title: item.title, count: count(for: item))
                    }

                    ForEach(store.groups) { group in
                        filterChip(
                            .group(group.id),
                            title: group.name,
                            count: count(for: .group(group.id))
                        )
                        .contextMenu {
                            Button {
                                renameText = group.name
                                renamingGroup = group
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                if filter == .group(group.id) { filter = .all }
                                store.deleteGroup(group.id)
                            } label: {
                                Label("删除分组", systemImage: "trash")
                            }
                        }
                    }

                    // 新建分组
                    Button {
                        newGroupName = ""
                        showNewGroupAlert = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(HostTheme.muted)
                            .frame(width: 32, height: 32)
                            .background(HostTheme.surface)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新建分组")
                }
            }

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

    private func filterChip(_ item: HostFilter, title: String, count: Int) -> some View {
        let selected = filter == item
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { filter = item }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(selected ? HostTheme.surface : HostTheme.muted)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(selected ? HostTheme.text : HostTheme.surface)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
        // 单一滚动容器：外层一个 ScrollView，内部不用嵌套 LazyVGrid / LazyColumn。
        // SwiftUI 嵌套滚动视图会出现手势竞争，导致下拉刷新偶发被内层吃掉。
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 独立刷新提示条：在 runningStrip 上方，无任何 Drag/LongPress 手势
                // 专门给外层 ScrollView .refreshable 留的"安全区"
                RefreshHintBar(isRefreshing: isRefreshing) {
                    isRefreshing = true
                    await sync(force: true)
                    isRefreshing = false
                }

                // 运行中横条：常驻显示。无运行时展示空状态。
                runningStrip

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
                    // 非懒加载网格：首页小程序数量一般是几十个以内，用 Grid 排足够流畅。
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.appId) { idx, item in
                            if idx % 3 == 0 {
                                GridRow {
                                    appCard(item)
                                    // 同一行缺的补占位，否则 Grid 会把卡片拉宽。
                                    if idx + 1 < visibleItems.count {
                                        appCard(visibleItems[idx + 1])
                                    } else {
                                        Color.clear.frame(height: 116)
                                    }
                                    if idx + 2 < visibleItems.count {
                                        appCard(visibleItems[idx + 2])
                                    } else {
                                        Color.clear.frame(height: 116)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 32)
            // 排序拖拽用到的坐标系与卡片位置缓存
            .coordinateSpace(name: "host-content")
            .overlay(alignment: .topLeading) {
                dragPreviewLayer
            }
            .onPreferenceChange(HostCardFrameKey.self) { frames in
                cardFrames = frames
            }
        }
        .scrollIndicators(.hidden)
        // 搜索框弹出键盘后，点列表空白处或拖动列表都要能收起键盘，
        // 否则键盘会一直压在首页上。
        .scrollDismissesKeyboard(.immediately)
        // 下拉刷新挂在 ScrollView 上；提示条区域无手势，外层 refreshable 直接触达。
        .refreshable {
            isRefreshing = true
            await sync(force: true)
            isRefreshing = false
        }
        // 点内容空白处收起键盘，不再用 simultaneousGesture——它会干扰 refreshable 的手势识别。
        .onTapGesture { searchFocused = false }
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

    // MARK: - Running

    private var runningItems: [HostHubItem] {
        runningIds.compactMap { id in hubItems.first { $0.appId == id } }
    }

    /// 最近用过但已被回收的实例，最多列 6 个，点击按普通启动重新打开。
    private var recycledItems: [HostHubItem] {
        store.recentIds
            .filter { !runningIds.contains($0) }
            .prefix(6)
            .compactMap { id in hubItems.first { $0.appId == id } }
    }

    private func refreshRunning() {
        // 拖动排序进行中不重建运行中列表：布局变化会打断手势，导致跟手浮层卡住。
        guard draggingId == nil, !cardGestureActive else { return }
        runningIds = DMPAppManager.sharedInstance().runningMiniPrograms().map(\.appId)
    }

    /// 清空拖动相关状态（手势正常结束或被系统取消时调用）。
    private func resetDragState() {
        draggingId = nil
        dragStart = nil
        dragLocation = nil
        dragFrames = [:]
        dragSlots = []
    }

    private var runningStrip: some View {
        let isEmpty = runningItems.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            // Header：状态 + "全部 >"
            HStack(spacing: 7) {
                if isEmpty {
                    Circle()
                        .fill(HostTheme.muted.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text("当前无程序运行")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(HostTheme.muted)
                } else {
                    Circle()
                        .fill(HostTheme.green)
                        .frame(width: 6, height: 6)
                    Text("运行中 \(runningItems.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(HostTheme.text)
                }
                Spacer(minLength: 4)
                if !isEmpty {
                    Button {
                        refreshRunning()
                        showSwitcher = true
                    } label: {
                        HStack(spacing: 2) {
                            Text("全部")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(HostTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 卡片区域：有运行时横向滚动卡片
            if !isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(runningItems) { item in
                            Button {
                                activateRunning(item)
                            } label: {
                                runningCard(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(12)
        .background(HostTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(HostTheme.line, lineWidth: 1)
        )
    }

    private func runningCard(_ item: HostHubItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                appIcon(item, size: 34, corner: 11, fontSize: 15)
                Spacer(minLength: 2)
                Circle()
                    .fill(HostTheme.green)
                    .frame(width: 6, height: 6)
                    .padding(.top, 3)
            }
            Text(item.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(HostTheme.text)
                .lineLimit(1)
            Text(hostRelativeTimeText(store.lastUsed(item.appId)))
                .font(.system(size: 10))
                .foregroundColor(HostTheme.muted)
                .lineLimit(1)
        }
        .padding(10)
        .frame(width: 132, height: 96, alignment: .topLeading)
        .background(HostTheme.bg.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var switcherSheet: some View {
        HostSwitcherSheet(
            running: runningItems,
            recycled: recycledItems,
            icons: catalog.icons,
            times: store.recentTimes,
            onOpen: { item in
                showSwitcher = false
                // 等面板收起再做导航，避免转场叠在一起。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if runningIds.contains(item.appId) {
                        activateRunning(item)
                    } else {
                        open(item)
                    }
                }
            },
            onCloseOne: { item in
                closeOneRunning(item)
            },
            onCloseAll: {
                showSwitcher = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    showCloseAllConfirm = true
                }
            }
        )
    }

    /// 切回已保留的实例，页面栈原样恢复；实例已被回收时退回普通启动。
    private func activateRunning(_ item: HostHubItem) {
        guard let app = item.local else { return }
        store.recordUsed(app.appId)
        Task { @MainActor in
            do {
                try await DMPAppManager.sharedInstance().switchToMiniProgram(appId: app.appId)
                refreshRunning()
            } catch {
                refreshRunning()
                open(app)
            }
        }
    }

    /// 单卡关闭：只销毁该实例，页面栈与用户数据策略同 destroyAll。
    private func closeOneRunning(_ item: HostHubItem) {
        Task { @MainActor in
            do {
                try await DMPAppManager.sharedInstance().closeMiniProgram(appId: item.appId)
                refreshRunning()
                showToast("已关闭 \(item.name)")
            } catch {
                showToast("关闭失败：\(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func closeAllRunning() async {
        do {
            try await DMPAppManager.sharedInstance().destroyAllMiniPrograms()
            refreshRunning()
            showToast("已关闭全部小程序")
        } catch {
            showToast("关闭失败：\(error.localizedDescription)", kind: .error)
        }
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

    /// 卡片视觉本体：首页网格与拖动浮层共用同一套样式，浮层才不会走样。
    private func cardBase(_ item: HostHubItem, transfer: HostTransferState?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
                HostProgressBar(value: transfer?.progress)
                    .padding(.top, 10)
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
    }

    private func appCard(_ item: HostHubItem) -> some View {
        let transfer = catalog.transfers[item.appId]
        return cardBase(item, transfer: transfer)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HostCardFrameKey.self,
                        value: draggingId == item.appId
                            ? [String: CGRect]()
                            : [item.appId: proxy.frame(in: .named("host-content"))]
                    )
                }
            )
            // 被拖起来的那张先藏起来，跟手的是最上层的浮层，原位不留残影。
            .opacity(draggingId == item.appId ? 0 : 1)
            .zIndex(draggingId == item.appId ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard Date() >= suppressTapUntil else { return }
            activate(item)
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 6, coordinateSpace: .named("host-content")))
                // 手势被系统取消（滚动竞争 / 视图重建）时 GestureState 会自动复位，
                // 用它兜底清理拖动状态，避免跟手浮层永久卡在屏幕上。
                .updating($cardGestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    guard case let .second(true, drag?) = value else { return }
                    // 最近使用是按使用时间自动排的，不参与手动排序。
                    guard filter != .recent else { return }
                    if draggingId == nil {
                        dragFrames = cardFrames
                        dragSlots = visibleItems.compactMap { cardFrames[$0.appId] }
                        draggingId = item.appId
                        dragStart = drag.location
                        dragLocation = drag.location
                        // 长按已经算「排序 / 详情」，压掉随后可能补发的点击
                        suppressTapUntil = Date().addingTimeInterval(5)
                    }
                    guard draggingId == item.appId else { return }
                    dragLocation = drag.location
                    // 用按下瞬间的格子矩形判断落在哪一格，再用「当前」第几格取目标，
                    // 布局动画途中也不会两张卡片来回抢位。
                    if let slot = dragSlots.firstIndex(where: { $0.contains(drag.location) }),
                       slot < visibleItems.count {
                        let target = visibleItems[slot].appId
                        if target != item.appId {
                            moveCard(item.appId, over: target)
                        }
                    }
                }
                .onEnded { value in
                    guard draggingId == item.appId else {
                        // 长按成功但没进入拖动（DragGesture 未达 6pt 阈值）→ 打开详情。
                        // 注意 v1.0.41 把 minimumDistance 调成 6 之后，纯长按不再产生
                        // .second(true, drag)，只有 .first(true)，必须单独处理。
                        switch value {
                        case .first(true):
                            suppressTapUntil = Date().addingTimeInterval(0.35)
                            selectedItem = item
                        case let .second(true, drag?):
                            if abs(drag.translation.width) <= 6,
                               abs(drag.translation.height) <= 6 {
                                suppressTapUntil = Date().addingTimeInterval(0.35)
                                selectedItem = item
                            }
                        default:
                            break
                        }
                        return
                    }
                    var moved = false
                    if case let .second(true, drag?) = value {
                        moved = abs(drag.translation.width) > 6 || abs(drag.translation.height) > 6
                    }
                    draggingId = nil
                    dragStart = nil
                    dragLocation = nil
                    suppressTapUntil = Date().addingTimeInterval(0.35)
                    // 长按但没挪动 → 打开详情；拖动过则已经完成排序。
                    if !moved {
                        selectedItem = item
                    }
                }
        )
    }

    /// 单列模式的视觉本体：图标 + 名称/版本 + 右侧状态，同样被拖动浮层复用。
    private func rowBase(_ item: HostHubItem, transfer: HostTransferState?) -> some View {
        HStack(spacing: 12) {
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
    }

    private func appRow(_ item: HostHubItem) -> some View {
        let transfer = catalog.transfers[item.appId]
        return rowBase(item, transfer: transfer)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HostCardFrameKey.self,
                        value: draggingId == item.appId
                            ? [String: CGRect]()
                            : [item.appId: proxy.frame(in: .named("host-content"))]
                    )
                }
            )
            // 被拖起来的那张先藏起来，跟手的是最上层的浮层，原位不留残影。
            .opacity(draggingId == item.appId ? 0 : 1)
            .zIndex(draggingId == item.appId ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard Date() >= suppressTapUntil else { return }
            activate(item)
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 6, coordinateSpace: .named("host-content")))
                // 手势被系统取消（滚动竞争 / 视图重建）时 GestureState 会自动复位，
                // 用它兜底清理拖动状态，避免跟手浮层永久卡在屏幕上。
                .updating($cardGestureActive) { _, active, _ in active = true }
                .onChanged { value in
                    guard case let .second(true, drag?) = value else { return }
                    // 最近使用是按使用时间自动排的，不参与手动排序。
                    guard filter != .recent else { return }
                    if draggingId == nil {
                        dragFrames = cardFrames
                        dragSlots = visibleItems.compactMap { cardFrames[$0.appId] }
                        draggingId = item.appId
                        dragStart = drag.location
                        dragLocation = drag.location
                        // 长按已经算「排序 / 详情」，压掉随后可能补发的点击
                        suppressTapUntil = Date().addingTimeInterval(5)
                    }
                    guard draggingId == item.appId else { return }
                    dragLocation = drag.location
                    // 用按下瞬间的格子矩形判断落在哪一格，再用「当前」第几格取目标，
                    // 布局动画途中也不会两张卡片来回抢位。
                    if let slot = dragSlots.firstIndex(where: { $0.contains(drag.location) }),
                       slot < visibleItems.count {
                        let target = visibleItems[slot].appId
                        if target != item.appId {
                            moveCard(item.appId, over: target)
                        }
                    }
                }
                .onEnded { value in
                    guard draggingId == item.appId else {
                        // 长按成功但没进入拖动（DragGesture 未达 6pt 阈值）→ 打开详情。
                        // 注意 v1.0.41 把 minimumDistance 调成 6 之后，纯长按不再产生
                        // .second(true, drag)，只有 .first(true)，必须单独处理。
                        switch value {
                        case .first(true):
                            suppressTapUntil = Date().addingTimeInterval(0.35)
                            selectedItem = item
                        case let .second(true, drag?):
                            if abs(drag.translation.width) <= 6,
                               abs(drag.translation.height) <= 6 {
                                suppressTapUntil = Date().addingTimeInterval(0.35)
                                selectedItem = item
                            }
                        default:
                            break
                        }
                        return
                    }
                    var moved = false
                    if case let .second(true, drag?) = value {
                        moved = abs(drag.translation.width) > 6 || abs(drag.translation.height) > 6
                    }
                    draggingId = nil
                    dragStart = nil
                    dragLocation = nil
                    suppressTapUntil = Date().addingTimeInterval(0.35)
                    // 长按但没挪动 → 打开详情；拖动过则已经完成排序。
                    if !moved {
                        selectedItem = item
                    }
                }
        )
    }

    private func activate(_ item: HostHubItem) {
        if item.canOpen && !item.hasUpdate {
            open(item)
        } else {
            selectedItem = item
        }
    }

    /// 长按拖到另一张卡片上时，把拖拽项移动到目标位置并持久化。
    private func moveCard(_ dragging: String, over targetId: String) {
        // 首次排序或遇到新装的应用，先用当前展示顺序播种。
        if manualOrder.isEmpty
            || !manualOrder.contains(dragging)
            || !manualOrder.contains(targetId) {
            manualOrder = hubItems.map(\.appId)
        }

        guard let from = manualOrder.firstIndex(of: dragging),
              let to = manualOrder.firstIndex(of: targetId),
              from != to
        else { return }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            let moved = manualOrder.remove(at: from)
            manualOrder.insert(moved, at: to)
        }
        // 换位时给一点触感，拖动不至于「无声无息」。
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UserDefaults.standard.set(manualOrder, forKey: Self.appOrderKey)
    }

    /// 拖动时盖在最上层的「跟手」卡片：位置只由手指位移决定，
    /// 与网格里的换位动画互不干扰，看起来才不会一跳一跳。
    @ViewBuilder
    private var dragPreviewLayer: some View {
        if let id = draggingId,
           let frame = dragFrames[id],
           let start = dragStart,
           let location = dragLocation,
           let item = hubItems.first(where: { $0.appId == id }) {
            let transfer = catalog.transfers[id]
            Group {
                if listLayout {
                    rowBase(item, transfer: transfer)
                } else {
                    cardBase(item, transfer: transfer)
                }
            }
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(1.05)
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
            .offset(
                x: frame.minX + location.x - start.x,
                y: frame.minY + location.y - start.y
            )
            .allowsHitTesting(false)
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
        } else if item.local?.importedLocally == true {
            // 只有用户自己从本地 ZIP 导入的包才标「导入」，云端下载的不标。
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
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .transition(.opacity)
            HostLoadingCard(title: "正在安装小程序", subtitle: "请稍候，马上就好")
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
        return orderedByUser(items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        })
    }

    /// 用户长按拖动排好的顺序优先；没排过的（新装 / 新上架）按名称排在后面。
    private func orderedByUser(_ items: [HostHubItem]) -> [HostHubItem] {
        guard !manualOrder.isEmpty else { return items }
        let index = Dictionary(
            manualOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.sorted { a, b in
            switch (index[a.appId], index[b.appId]) {
            case let (x?, y?):
                return x < y
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
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
            // 最近使用永远按使用时间排，不套用用户拖动出来的顺序。
            items = store.recentIds.compactMap { id in
                hubItems.first { $0.appId == id }
            }
        case .all:
            items = hubItems
        case .updates:
            items = updatableItems
        case .group(let groupId):
            items = hubItems.filter { store.groupId(for: $0.appId) == groupId }
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
        case .group(let groupId):
            return hubItems.filter { store.groupId(for: $0.appId) == groupId }.count
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
            showToast(message, kind: .error)
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
                showToast("\(item.name)：\(HostCatalogCenter.describe(error))", kind: .error)
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
            showToast("\(remote.name)：\(HostCatalogCenter.describe(error))", kind: .error)
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

        // 已在后台保留的实例直接切回，页面栈原样恢复；失败再退回普通启动。
        if runningIds.contains(app.appId) {
            Task { @MainActor in
                do {
                    try await DMPAppManager.sharedInstance().switchToMiniProgram(appId: app.appId)
                    refreshRunning()
                } catch {
                    refreshRunning()
                    guard let navController = ContentView.navigationController else {
                        showToast("导航控制器尚未就绪", kind: .error)
                        return
                    }
                    launch(app, navigationController: navController)
                }
            }
            return
        }

        guard let navController = ContentView.navigationController else {
            showToast("导航控制器尚未就绪", kind: .error)
            return
        }
        launch(app, navigationController: navController)
    }

    private func launch(_ app: HostApp, navigationController navController: UINavigationController) {
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
        withAnimation(.easeInOut(duration: 0.2)) { isInstalling = true }
        do {
            try await store.install(package)
            showToast("已导入 \(package.name)")
        } catch {
            showToast("导入失败：\(error.localizedDescription)", kind: .error)
        }
        withAnimation(.easeInOut(duration: 0.2)) { isInstalling = false }
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
            showToast("卸载失败：\(error.localizedDescription)", kind: .error)
        }
    }

    private func showToast(_ message: String, kind: HostToastKind = .success) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            toast = HostToast(message: message, kind: kind)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            if toast?.message == message {
                withAnimation(.easeOut(duration: 0.22)) {
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

enum HostFilter: Hashable, Identifiable {
    case recent
    case all
    case updates
    case group(String)

    var id: String {
        switch self {
        case .recent: return "recent"
        case .all: return "all"
        case .updates: return "updates"
        case .group(let id): return "group-\(id)"
        }
    }

    var title: String {
        switch self {
        case .recent: return "最近使用"
        case .all: return "全部程序"
        case .updates: return "更新程序"
        case .group: return ""
        }
    }

    /// 三个内置筛选，自建分组追加在后面。
    static let builtins: [HostFilter] = [.recent, .all, .updates]
}

// MARK: - Detail sheet

private struct HostAppDetailSheet: View {
    let item: HostHubItem
    @ObservedObject var catalog: HostCatalogCenter
    let groups: [HostGroup]
    let currentGroupId: String?
    let onAssignGroup: (String?) -> Void
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

    /// 分组归属：未分组 / 已有分组单选，点击即移动。
    private var groupPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("分组")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(HostTheme.text)
                Spacer()
                if groups.isEmpty {
                    Text("可在首页 + 新建分组")
                        .font(.system(size: 11))
                        .foregroundColor(HostTheme.muted)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    groupOption(title: "未分组", selected: currentGroupId == nil) {
                        onAssignGroup(nil)
                    }
                    ForEach(groups) { group in
                        groupOption(title: group.name, selected: currentGroupId == group.id) {
                            onAssignGroup(group.id)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HostTheme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func groupOption(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(selected ? HostTheme.surface : HostTheme.muted)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(selected ? HostTheme.text : HostTheme.surface)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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

                groupPicker

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
                                HostSpinner(size: 13)
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
        HStack(spacing: 12) {
            switch state {
            case .downloading:
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(HostTheme.primary)
            case .verifying, .installing:
                HostSpinner(size: 16)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(HostTheme.red)
            }

            VStack(alignment: .leading, spacing: 7) {
                switch state {
                case let .downloading(progress):
                    Text(progress >= 0 ? "正在下载 \(Int(progress * 100))%" : "正在连接下载…")
                    HostProgressBar(value: progress >= 0 ? progress : nil)
                case .verifying:
                    Text("校验安装包…")
                case .installing:
                    Text("安装中…")
                case let .failed(message):
                    Text(message)
                        .foregroundColor(HostTheme.red)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(HostTheme.text)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(HostTheme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                if transfer?.isBusy == true {
                    HostProgressBar(value: transfer?.progress)
                        .padding(.top, 4)
                }
            }

            Spacer()

            if transfer?.isBusy == true {
                HostSpinner(size: 18)
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

                retentionSection

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

    /// 后台保活数量：实例常驻不超时，只受数量上限约束（内存压力时系统仍会兜底回收）。
    private var retentionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("后台保活")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(HostTheme.text)
            HStack(spacing: 8) {
                ForEach([1, 2, 3, 5, 8], id: \.self) { count in
                    let selected = catalog.config.maxBackgroundApps == count
                    Text("\(count) 个")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selected ? HostTheme.surface : HostTheme.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(selected ? HostTheme.text : HostTheme.surface)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                        .onTapGesture {
                            catalog.updateConfig { $0.maxBackgroundApps = count }
                            applyRetention(count)
                        }
                }
                Spacer(minLength: 0)
            }
            Text("小程序退到后台后常驻，超出数量时回收最久未用的；调小后在下一次切换时生效")
                .font(.system(size: 11))
                .foregroundColor(HostTheme.muted)
        }
    }

    /// 应用保活数量：常驻不超时，超出上限时框架按最久未用回收。
    private func applyRetention(_ count: Int) {
        DMPAppManager.sharedInstance().configureRetention(
            DMPRetentionPolicy(maxBackgroundApps: count, backgroundTimeoutMs: 0)
        )
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
                    TextField("用户名（仅 Basic 鉴权需要，可留空）", text: $authUserDraft)
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
                    SecureField("访问密钥 / 密码", text: $authPasswordDraft)
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

            Text("地址支持直接填写 apps.json，或填写站点根路径自动补全 /apps.json。安装包与图标必须与应用源同域。只填「访问密钥」时走 X-Api-Key 请求头（Nginx 密钥鉴权）；同时填用户名和密钥时走 HTTP Basic（宝塔「密码访问」）。")
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

// MARK: - App switcher

private func hostRelativeTimeText(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "刚刚" }
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "刚刚" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) 分钟前" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours) 小时前" }
    return "\(hours / 24) 天前"
}

/// 运行中 / 最近使用的切换面板：运行中的实例点击直接切回，已回收的按需重启。
private struct HostSwitcherSheet: View {
    let running: [HostHubItem]
    let recycled: [HostHubItem]
    let icons: [String: UIImage]
    let times: [String: TimeInterval]
    let onOpen: (HostHubItem) -> Void
    let onCloseOne: (HostHubItem) -> Void
    let onCloseAll: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if running.isEmpty {
                        Text("当前没有运行中的小程序")
                            .font(.system(size: 13))
                            .foregroundColor(HostTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(running) { item in
                                Button {
                                    onOpen(item)
                                } label: {
                                    card(
                                        item,
                                        time: usedAt(item.appId),
                                        now: context.date,
                                        running: true
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !recycled.isEmpty {
                        Text("最近使用")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(HostTheme.muted)
                            .padding(.top, 2)

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(recycled) { item in
                                Button {
                                    onOpen(item)
                                } label: {
                                    card(
                                        item,
                                        time: usedAt(item.appId),
                                        now: context.date,
                                        running: false
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !running.isEmpty {
                        Button {
                            onCloseAll()
                        } label: {
                            Text("全部关闭")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(HostTheme.red)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(HostTheme.red.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .background(HostTheme.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(HostTheme.green)
                .frame(width: 7, height: 7)
            Text("运行中 \(running.count)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(HostTheme.text)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(HostTheme.muted)
                    .frame(width: 30, height: 30)
                    .background(HostTheme.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func usedAt(_ appId: String) -> Date? {
        times[appId].map { Date(timeIntervalSince1970: $0) }
    }

    private func card(_ item: HostHubItem, time: Date?, now: Date, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                icon(item, size: 42)
                Spacer(minLength: 4)
                if running {
                    // 单卡关闭按钮：嵌在卡片点击区里，得用独立小按钮避免触发整卡点击。
                    Button {
                        onCloseOne(item)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(HostTheme.muted)
                            .frame(width: 26, height: 26)
                            .background(HostTheme.bg)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("已回收")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(HostTheme.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(HostTheme.bg)
                        .clipShape(Capsule())
                }
            }
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(HostTheme.text)
                .lineLimit(1)
            Text(running ? hostRelativeTimeText(time, now: now) : "按需重启")
                .font(.system(size: 10))
                .foregroundColor(HostTheme.muted)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(HostTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(HostTheme.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func icon(_ item: HostHubItem, size: CGFloat) -> some View {
        Group {
            if let image = icons[item.appId] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [item.tint.opacity(0.7), item.tint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(item.iconText)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// 根视图重新可见（从小程序返回）时通知宿主刷新运行中实例。
private struct HostAppearanceObserver: UIViewControllerRepresentable {
    let onAppear: () -> Void

    func makeUIViewController(context: Context) -> ObserverController {
        let controller = ObserverController()
        controller.onAppear = onAppear
        return controller
    }

    func updateUIViewController(_ controller: ObserverController, context: Context) {
        controller.onAppear = onAppear
    }

    final class ObserverController: UIViewController {
        var onAppear: (() -> Void)?

        override func loadView() {
            view = UIView(frame: .zero)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onAppear?()
        }
    }
}

// MARK: - Refresh Hint Bar

/// runningStrip 上方的独立刷新提示条。
/// 极简：一行 HStack，左边"↓ 下拉刷新"灰色文字，右边刷新按钮。
/// 整个区域**不加任何 Drag/LongPress 手势**——专门给外层 .refreshable 留的"安全区"。
/// 刷新按钮是 Button tap，和 ScrollView 的 drag 手势天然正交不冲突。
struct RefreshHintBar: View {
    let isRefreshing: Bool
    let onRefresh: () async -> Void

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：胶囊包裹的灰色小字提示 —— 无任何手势，外层 .refreshable 直接触达
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .medium))
                Text(isRefreshing ? "正在同步…" : "下拉刷新")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(HostTheme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(HostTheme.surface, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(HostTheme.muted.opacity(0.15), lineWidth: 0.5)
            )

            Spacer(minLength: 0)

            // 右侧：圆形刷新按钮 —— Button tap，天然不抢 drag
            Button {
                Task { await onRefresh() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HostTheme.muted)
                    .frame(width: 28, height: 28)
                    .background(HostTheme.surface, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(HostTheme.muted.opacity(0.15), lineWidth: 0.5)
                    )
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default,
                        value: isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
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

// MARK: - Host feedback components

enum HostToastKind {
    case success
    case info
    case error

    var tint: Color {
        switch self {
        case .success: return HostTheme.green
        case .info: return HostTheme.primary
        case .error: return HostTheme.red
        }
    }

    var symbol: String {
        switch self {
        case .success: return "checkmark"
        case .info: return "info"
        case .error: return "exclamationmark"
        }
    }
}

struct HostToast {
    let message: String
    let kind: HostToastKind
}

/// 悬浮提示：毛玻璃卡片 + 语义色图标，替代原先的纯黑胶囊。
struct HostToastView: View {
    let toast: HostToast

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(toast.kind.tint.opacity(0.16))
                    .frame(width: 24, height: 24)
                Image(systemName: toast.kind.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(toast.kind.tint)
            }

            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(HostTheme.text)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(HostTheme.surface.opacity(0.55))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(HostTheme.line.opacity(0.8), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
    }
}

/// 宿主统一的活动指示器：渐变弧线旋转，比系统菊花更贴合卡片风格。
struct HostSpinner: View {
    var size: CGFloat = 20
    @State private var rotating = false

    private var lineWidth: CGFloat { max(2, size * 0.12) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(HostTheme.line, lineWidth: lineWidth)
            Circle()
                .trim(from: 0.06, to: 0.34)
                .stroke(
                    AngularGradient(
                        colors: [HostTheme.primary.opacity(0.2), HostTheme.primary],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(rotating ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                rotating = true
            }
        }
    }
}

/// 居中加载卡片：用于安装等会挡住整页的操作。
struct HostLoadingCard: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            HostSpinner(size: 36)
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(HostTheme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(HostTheme.muted)
                }
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 26)
        .frame(minWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(HostTheme.surface.opacity(0.6))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(HostTheme.line.opacity(0.8), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 28, y: 14)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}

/// 细进度条：确定进度时按比例填充，进度未知时做来回扫光。
struct HostProgressBar: View {
    var value: Double?
    @State private var sweeping = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(HostTheme.line)
                if let value {
                    Capsule()
                        .fill(barGradient)
                        .frame(width: max(geo.size.width * min(max(value, 0), 1), 5))
                        .animation(.easeOut(duration: 0.25), value: value)
                } else {
                    Capsule()
                        .fill(barGradient)
                        .frame(width: max(geo.size.width * 0.3, 20))
                        .offset(x: sweeping ? geo.size.width * 0.7 : 0)
                        .animation(
                            .easeInOut(duration: 1.15).repeatForever(autoreverses: true),
                            value: sweeping
                        )
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
        .onAppear { sweeping = true }
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [HostTheme.primary.opacity(0.65), HostTheme.primary],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// 收集每张卡片在滚动内容坐标系里的位置，供长按拖动排序做命中判断。
private struct HostCardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

#Preview("ContentView") {
    ContentView()
}
