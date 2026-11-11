@file:OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.material3.ExperimentalMaterial3Api::class,
)

package com.dreamtapir.host

import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items as rowItems
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import kotlin.math.roundToInt
import androidx.compose.ui.zIndex
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.didi.dimina.Dimina
import com.didi.dimina.RunningMiniProgram
import com.didi.dimina.common.Utils
import com.didi.dimina.ui.theme.DiminaAndroidTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 宿主明暗两套调色板，经 [LocalHostPalette] 下发；下方同名只读属性保持各引用点不变。 */
private class HostPalette(
    val bg: Color,
    val surface: Color,
    val primary: Color,
    val primarySoft: Color,
    val text: Color,
    val muted: Color,
    val line: Color,
    val green: Color,
    val red: Color,
)

private val HostLightPalette = HostPalette(
    bg = Color(0xFFF3F5FB),
    surface = Color(0xFFFFFFFF),
    primary = Color(0xFF3B5BFF),
    primarySoft = Color(0xFFE9EDFF),
    text = Color(0xFF171A22),
    muted = Color(0xFF7A8194),
    line = Color(0xFFE8EBF3),
    green = Color(0xFF18A86B),
    red = Color(0xFFE5484D),
)

private val HostDarkPalette = HostPalette(
    bg = Color(0xFF0E1118),
    surface = Color(0xFF181C26),
    primary = Color(0xFF5C74FF),
    primarySoft = Color(0xFF232B4A),
    text = Color(0xFFF1F3F9),
    muted = Color(0xFF8A90A3),
    line = Color(0xFF262B38),
    green = Color(0xFF2FBD7F),
    red = Color(0xFFFF6469),
)

// 主题色运行时会切换，必须用会跟踪读取的 compositionLocalOf；
// staticCompositionLocalOf 不跟踪读取，palette 变化时读取处不重组，界面不换色。
private val LocalHostPalette = compositionLocalOf { HostLightPalette }

private val HostBg: Color @Composable get() = LocalHostPalette.current.bg
private val HostSurface: Color @Composable get() = LocalHostPalette.current.surface
private val HostPrimary: Color @Composable get() = LocalHostPalette.current.primary
private val HostPrimarySoft: Color @Composable get() = LocalHostPalette.current.primarySoft
private val HostText: Color @Composable get() = LocalHostPalette.current.text
private val HostMuted: Color @Composable get() = LocalHostPalette.current.muted
private val HostLine: Color @Composable get() = LocalHostPalette.current.line
private val HostGreen: Color @Composable get() = LocalHostPalette.current.green
private val HostRed: Color @Composable get() = LocalHostPalette.current.red

private fun hostDarkTheme(themeMode: String, systemDark: Boolean): Boolean = when (themeMode) {
    HostCatalogConfig.THEME_LIGHT -> false
    HostCatalogConfig.THEME_DARK -> true
    else -> systemDark
}

private fun hostPaletteFor(themeMode: String, systemDark: Boolean): HostPalette =
    if (hostDarkTheme(themeMode, systemDark)) HostDarkPalette else HostLightPalette

private val IMPORT_MIME_TYPES = arrayOf("application/zip", "application/octet-stream")

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 首帧先按持久化的主题设置着色，避免启动时闪过错误主题
        val systemDark =
            (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        val palette = hostPaletteFor(HostCatalogStore.loadConfig(this).themeMode, systemDark)
        val systemBarColor = palette.bg.toArgb()
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(systemBarColor, systemBarColor),
            navigationBarStyle = SystemBarStyle.auto(systemBarColor, systemBarColor),
        )
        @Suppress("DEPRECATION")
        window.statusBarColor = systemBarColor
        @Suppress("DEPRECATION")
        window.navigationBarColor = systemBarColor
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = !hostDarkTheme(HostCatalogStore.loadConfig(this@MainActivity).themeMode, systemDark)
            isAppearanceLightNavigationBars = !hostDarkTheme(HostCatalogStore.loadConfig(this@MainActivity).themeMode, systemDark)
        }

        setContent {
            HostShellScreen(modifier = Modifier.fillMaxSize())
        }
    }
}

@Composable
fun HostShellScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val activity = context as? Activity
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    val focusManager = LocalFocusManager.current

    val catalog = remember { HostCatalogController(context, scope) }

    var apps by remember { mutableStateOf<List<HostApp>>(emptyList()) }
    var recentIds by remember { mutableStateOf<List<String>>(emptyList()) }
    var query by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf(HostFilter.All) }
    var selectedItem by remember { mutableStateOf<HostHubItem?>(null) }
    var showSettings by remember { mutableStateOf(false) }
    var showUpdates by remember { mutableStateOf(false) }
    var pendingImport by remember { mutableStateOf<HostImportPackage?>(null) }
    var importing by remember { mutableStateOf(false) }
    var permissionTick by remember { mutableIntStateOf(0) }
    var network by remember { mutableStateOf(context.currentNetworkSnapshot()) }
    var started by remember { mutableStateOf(false) }
    // 运行中的实例快照 / 切换面板状态。
    var runningApps by remember { mutableStateOf<List<RunningMiniProgram>>(emptyList()) }
    var showSwitcher by remember { mutableStateOf(false) }
    var showCloseAllConfirm by remember { mutableStateOf(false) }
    var switcherTick by remember { mutableIntStateOf(0) }
    // 长按拖动排序：本地持久化的顺序 + 当前拖拽中的卡片状态。
    var appOrder by remember { mutableStateOf(HostAppOrder.load(context)) }
    var draggingId by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableStateOf(Offset.Zero) }
    var suppressTapUntil by remember { mutableStateOf(0L) }
    // 拖拽中跟随手指的浮动卡片：起点（网格视口坐标）与尺寸。
    var dragPreviewOrigin by remember { mutableStateOf(Offset.Zero) }
    var dragPreviewSize by remember { mutableStateOf(IntSize.Zero) }
    // 按下瞬间的每个格子矩形（顺序与当前展示列表一致），拖动全程不再变化。
    var dragSlots by remember { mutableStateOf<List<Rect>>(emptyList()) }
    // 网格视口 / 外层容器在窗口中的位置，用于把浮动卡片摆到手指下。
    var gridWindowPos by remember { mutableStateOf(Offset.Zero) }
    var boxWindowPos by remember { mutableStateOf(Offset.Zero) }
    val gridState = rememberLazyGridState()
    val hostView = LocalView.current

    fun refreshRunning() {
        runningApps = runCatching { Dimina.getInstance().runningMiniPrograms() }
            .getOrDefault(emptyList())
    }

    fun refresh() {
        apps = HostAppRepository.load(context)
        recentIds = RecentApps.load(context).filter { id -> apps.any { it.appId == id } }
        refreshRunning()
    }

    fun showMessage(message: String) {
        scope.launch { snackbar.showSnackbar(message) }
    }

    fun openApp(app: HostApp) {
        recentIds = RecentApps.record(context, app.appId)
        RecentTimes.record(context, app.appId)
        if (activity != null) {
            // 已在后台保留的实例直接切回，页面栈原样恢复。
            if (runningApps.any { it.appId == app.appId } &&
                Dimina.getInstance().showMiniProgram(app.appId)
            ) {
                return
            }
            Dimina.getInstance().startMiniProgram(
                activity,
                app.toMiniProgram(catalog.iconFileFor(app.appId)?.absolutePath),
            )
        }
    }

    suspend fun autoInstallIfEnabled() {
        val config = catalog.config
        if (!config.autoInstall) return
        if (config.wifiOnlyAutoDownload) {
            val snapshot = context.currentNetworkSnapshot()
            if (snapshot.type != "Wi-Fi" && snapshot.type != "以太网") return
        }
        val targets = buildHub(HostAppRepository.load(context), catalog.remoteApps)
            .filter { it.hasUpdate }
        var completed = 0
        targets.forEach { item ->
            val remote = item.remote ?: return@forEach
            if (catalog.install(remote).isSuccess) completed++
            refresh()
        }
        if (completed > 0) showMessage("已自动更新 $completed 个应用，下次打开生效")
    }

    suspend fun syncNow(force: Boolean) {
        catalog.sync(force)
        when (val state = catalog.syncState) {
            is HostSyncState.Failed -> showMessage(state.message)
            is HostSyncState.Ok -> autoInstallIfEnabled()
            else -> Unit
        }
    }

    LaunchedEffect(Unit) {
        if (!started) {
            started = true
            refresh()
            if (catalog.config.autoCheck && catalog.config.source.isNotBlank()) {
                syncNow(false)
            }
        }
    }

    DisposableEffect(Unit) {
        val manager = context.getSystemService(android.net.ConnectivityManager::class.java)
        val mainHandler = Handler(Looper.getMainLooper())
        val callback = object : android.net.ConnectivityManager.NetworkCallback() {
            private fun publish() {
                mainHandler.post { network = context.currentNetworkSnapshot() }
            }

            override fun onAvailable(network: android.net.Network) = publish()
            override fun onLost(network: android.net.Network) = publish()
            override fun onCapabilitiesChanged(
                network: android.net.Network,
                networkCapabilities: android.net.NetworkCapabilities,
            ) = publish()
        }
        runCatching { manager.registerDefaultNetworkCallback(callback) }
        onDispose { runCatching { manager.unregisterNetworkCallback(callback) } }
    }

    // 从小程序退回宿主时刷新运行中实例，首页卡片条与切换面板据此更新。
    val lifecycleOwner = context as? androidx.lifecycle.LifecycleOwner
    DisposableEffect(lifecycleOwner) {
        if (lifecycleOwner == null) return@DisposableEffect onDispose {}
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) refresh()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                HostAppRepository.prepareImport(context, uri)
            }
            result.onSuccess { pendingImport = it }
                .onFailure { showMessage("导入失败：${it.message ?: "无法读取文件"}") }
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { permissionTick++ }

    val hub = remember(apps, catalog.remoteApps, appOrder) {
        HostAppOrder.sorted(buildHub(apps, catalog.remoteApps), appOrder)
    }
    val updates = remember(hub) { hub.filter { it.hasUpdate } }
    val installable = remember(hub) { hub.filter { it.needsInstall } }
    val recentHub = remember(hub, recentIds) {
        recentIds.mapNotNull { id -> hub.firstOrNull { it.appId == id } }
    }
    val visible = remember(filter, query, hub, updates, recentHub) {
        val base = when (filter) {
            HostFilter.Recent -> recentHub
            HostFilter.All -> hub
            HostFilter.Updates -> updates
        }
        if (query.isBlank()) {
            base
        } else {
            base.filter {
                it.name.contains(query, ignoreCase = true) ||
                    it.appId.contains(query, ignoreCase = true)
            }
        }
    }
    // 拖拽回调在 pointerInput 里，必须拿最新的展示列表，否则换位后会拿旧顺序判断。
    val currentVisible by rememberUpdatedState(visible)

    // 运行中卡片条 / 切换面板的数据：运行中按框架给的顺序，已回收按最近使用。
    val runningHub = remember(runningApps, hub) {
        runningApps.mapNotNull { snapshot -> hub.firstOrNull { it.appId == snapshot.appId } }
    }
    val recycledHub = remember(recentIds, runningApps, hub) {
        recentIds
            .filter { id -> runningApps.none { it.appId == id } }
            .mapNotNull { id -> hub.firstOrNull { it.appId == id } }
            .take(6)
    }

    /// 单卡关闭：只销毁该实例，用户数据保留；失败给提示。
    fun closeOneRunning(item: HostHubItem) {
        runCatching { Dimina.getInstance().closeMiniProgram(item.appId) }
            .onSuccess {
                refreshRunning()
                showMessage("已关闭 ${item.name}")
            }
            .onFailure { showMessage("关闭失败：${it.message ?: "未知错误"}") }
    }

    fun closeAllRunning() {
        runCatching { Dimina.getInstance().destroyAllMiniPrograms() }
            .onSuccess {
                refreshRunning()
                showMessage("已关闭全部小程序")
            }
            .onFailure { showMessage("关闭失败：${it.message ?: "未知错误"}") }
    }

    // 面板打开期间每分钟刷新一次相对时间。
    LaunchedEffect(showSwitcher) {
        while (showSwitcher) {
            delay(60_000)
            switcherTick++
        }
    }

    /**
     * 长按拖动排序：把 dragging 移到 over 的位置并持久化。
     * 顺序里还没有的（新装 / 新上架）先用当前展示顺序播种。
     */
    fun moveApp(dragging: String, over: String) {
        val base = if (appOrder.isEmpty() || dragging !in appOrder || over !in appOrder) {
            hub.map { it.appId }
        } else {
            appOrder
        }
        val from = base.indexOf(dragging)
        val to = base.indexOf(over)
        if (from < 0 || to < 0 || from == to) return
        val updated = base.toMutableList().apply { add(to, removeAt(from)) }
        appOrder = updated
        HostAppOrder.save(context, updated)
        // 换位时给一点触感反馈，拖动不至于「无声无息」。
        hostView.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    }

    val permissionStates = remember(permissionTick, showSettings) {
        HostPermissions.items.associateWith { HostPermissions.isGranted(context, it) }
    }
    val syncLabel = when (val state = catalog.syncState) {
        HostSyncState.Idle ->
            if (catalog.remoteApps.isEmpty()) "未同步 · 点此配置应用源"
            else "离线目录 · ${catalog.remoteApps.size} 个应用"
        HostSyncState.Syncing -> "正在同步…"
        is HostSyncState.Ok -> "已同步 · ${timeText(state.at)}"
        is HostSyncState.Failed -> state.message
    }
    val syncColor = when (catalog.syncState) {
        HostSyncState.Idle -> HostMuted.copy(alpha = 0.6f)
        HostSyncState.Syncing -> HostPrimary
        is HostSyncState.Ok -> HostGreen
        is HostSyncState.Failed -> HostRed
    }

    fun installOne(item: HostHubItem) {
        val remote = item.remote ?: return
        scope.launch {
            val result = catalog.install(remote)
            refresh()
            if (result.isSuccess) {
                selectedItem = null
                showMessage("已更新 ${remote.name}，下次打开生效")
            } else {
                val error = result.exceptionOrNull()
                showMessage("${remote.name}：${HostCatalogController.describe(error ?: Exception("安装失败"))}")
            }
        }
    }

    fun installAll(items: List<HostHubItem>, announce: Boolean = false) {
        scope.launch {
            var completed = 0
            items.forEach { item ->
                val remote = item.remote ?: return@forEach
                if (catalog.install(remote).isSuccess) completed++
                refresh()
            }
            if (completed > 0) {
                showMessage(
                    if (announce) "已自动更新 $completed 个应用，下次打开生效"
                    else "已安装/更新 $completed 个应用，下次打开生效"
                )
            }
        }
    }

    fun uninstall(app: HostApp, clearData: Boolean) {
        HostAppRepository.uninstall(app.appId, clearData) { result ->
            result.onSuccess {
                HostInstallOrigin.remove(context, app.appId)
                refresh()
                showMessage(if (clearData) "已卸载并清除数据 ${app.name}" else "已卸载 ${app.name}")
            }.onFailure {
                showMessage("卸载失败：${it.message ?: "未知错误"}")
            }
        }
    }

    val darkTheme = hostDarkTheme(catalog.config.themeMode, isSystemInDarkTheme())
    val palette = if (darkTheme) HostDarkPalette else HostLightPalette
    // 设置里改主题时立即更新状态栏/导航栏外观
    SideEffect {
        activity?.window?.let { window ->
            WindowInsetsControllerCompat(window, window.decorView).apply {
                isAppearanceLightStatusBars = !darkTheme
                isAppearanceLightNavigationBars = !darkTheme
            }
            @Suppress("DEPRECATION")
            window.statusBarColor = palette.bg.toArgb()
            @Suppress("DEPRECATION")
            window.navigationBarColor = palette.bg.toArgb()
        }
    }

    DiminaAndroidTheme(darkTheme = darkTheme, dynamicColor = false) {
    CompositionLocalProvider(LocalHostPalette provides palette) {
    Scaffold(
        modifier = modifier,
        containerColor = HostBg,
        snackbarHost = { SnackbarHost(snackbar) },
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(HostBg)
                .onGloballyPositioned { boxWindowPos = it.positionInWindow() },
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                HostHeader(
                    syncLabel = syncLabel,
                    syncColor = syncColor,
                    updateCount = updates.size,
                    onRefresh = { scope.launch { syncNow(true) } },
                    onUpdates = {
                        if (updates.isEmpty()) showSettings = true else showUpdates = true
                    },
                    onImport = { importLauncher.launch(IMPORT_MIME_TYPES) },
                    onSettings = { showSettings = true },
                )
                HostSearchBar(
                    query = query,
                    onQueryChange = { query = it },
                    onClear = { query = "" },
                    onSearch = { focusManager.clearFocus() },
                )
                FilterRow(
                    filter = filter,
                    recentCount = recentIds.size,
                    allCount = hub.size,
                    updateCount = updates.size,
                    listLayout = catalog.config.listLayout,
                    onSelect = { filter = it },
                    onToggleLayout = {
                        catalog.updateConfig { it.copy(listLayout = !it.listLayout) }
                    },
                )

                if (!network.connected) {
                    OfflineBanner()
                }

                LazyVerticalGrid(
                    columns = GridCells.Fixed(if (catalog.config.listLayout) 1 else 3),
                    state = gridState,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(top = 4.dp)
                        // 搜索框弹出键盘后，点列表空白处收起键盘，避免键盘一直压在首页上。
                        .pointerInput(Unit) {
                            detectTapGestures(onTap = { focusManager.clearFocus() })
                        }
                        .onGloballyPositioned { gridWindowPos = it.positionInWindow() },
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 28.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(if (catalog.config.listLayout) 10.dp else 12.dp),
                ) {
                    if (runningHub.isNotEmpty()) {
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            RunningStrip(
                                items = runningHub,
                                icons = catalog.icons,
                                now = System.currentTimeMillis(),
                                usedAt = { id -> RecentTimes.usedAt(context, id) },
                                onOpenAll = {
                                    refreshRunning()
                                    showSwitcher = true
                                },
                                onOpen = { item -> item.local?.let { openApp(it) } },
                            )
                        }
                    }

                    if (updates.isNotEmpty() && filter != HostFilter.Updates) {
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            UpdateBar(
                                count = updates.size,
                                onOpen = { showUpdates = true },
                            )
                        }
                    }

                    if (catalog.syncState is HostSyncState.Failed && catalog.remoteApps.isEmpty()) {
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            ErrorBanner(
                                message = (catalog.syncState as HostSyncState.Failed).message,
                                onRetry = { scope.launch { syncNow(true) } },
                            )
                        }
                    }

                    if (visible.isEmpty()) {
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            EmptyState(
                                query = query,
                                filter = filter,
                                hasRemote = catalog.remoteApps.isNotEmpty(),
                                hasLocal = apps.isNotEmpty(),
                                installableCount = installable.size,
                                sourceConfigured = catalog.config.source.isNotBlank(),
                                onInstallAll = { installAll(installable) },
                                onImport = { importLauncher.launch(IMPORT_MIME_TYPES) },
                                onConfigure = { showSettings = true },
                            )
                        }
                    } else {
                        val onActivate = { item: HostHubItem ->
                            if (System.currentTimeMillis() < suppressTapUntil) {
                                Unit
                            } else if (item.canOpen && !item.hasUpdate && item.local != null) {
                                openApp(item.local)
                            } else {
                                selectedItem = item
                            }
                        }
                        gridItems(visible, key = { it.appId }) { item ->
                            val isDragging = draggingId == item.appId
                            Box(
                                modifier = Modifier
                                    // 其余卡片换位时用弹簧过渡，避免生硬地瞬间跳位。
                                    .animateItem(
                                        placementSpec = spring(
                                            dampingRatio = 0.78f,
                                            stiffness = Spring.StiffnessMediumLow,
                                        ),
                                    )
                                    // 被拖起来的这张先藏起来，跟手的是上面的浮层，原位不留残影。
                                    .graphicsLayer { alpha = if (isDragging) 0f else 1f }
                                    .pointerInput(item.appId, filter == HostFilter.Recent) {
                                        var travelled = 0f
                                        var reorderable = false
                                        detectDragGesturesAfterLongPress(
                                            onDragStart = {
                                                dragOffset = Offset.Zero
                                                travelled = 0f
                                                // 最近使用是按使用时间自动排的，不参与手动排序。
                                                reorderable = filter != HostFilter.Recent
                                                if (reorderable) {
                                                    focusManager.clearFocus()
                                                    draggingId = item.appId
                                                    val cards = gridState.layoutInfo.visibleItemsInfo
                                                        .filter { it.key is String }
                                                    val info = cards.firstOrNull { it.key == item.appId }
                                                    if (info != null) {
                                                        dragPreviewOrigin = Offset(
                                                            info.offset.x.toFloat(),
                                                            info.offset.y.toFloat(),
                                                        )
                                                        dragPreviewSize = info.size
                                                    }
                                                    // 记录按下时的格子位置：之后布局在动，判断依据不能跟着动，
                                                    // 否则两张卡片会互相抢位、来回抖。
                                                    dragSlots = cards.map {
                                                        Rect(
                                                            left = it.offset.x.toFloat(),
                                                            top = it.offset.y.toFloat(),
                                                            right = (it.offset.x + it.size.width).toFloat(),
                                                            bottom = (it.offset.y + it.size.height).toFloat(),
                                                        )
                                                    }
                                                }
                                                // 长按已经算「排序 / 详情」，压掉随后可能补发的点击
                                                suppressTapUntil = System.currentTimeMillis() + 5_000
                                            },
                                            onDrag = { change, amount ->
                                                change.consume()
                                                dragOffset += amount
                                                travelled += amount.getDistance()

                                                val w = dragPreviewSize.width
                                                val h = dragPreviewSize.height
                                                if (reorderable && w > 0 && h > 0) {
                                                    val center = Offset(
                                                        dragPreviewOrigin.x + dragOffset.x + w / 2f,
                                                        dragPreviewOrigin.y + dragOffset.y + h / 2f,
                                                    )
                                                    val slot = dragSlots.indexOfFirst { it.contains(center) }
                                                    val targetId = currentVisible.getOrNull(slot)?.appId
                                                    if (targetId != null && targetId != item.appId) {
                                                        moveApp(item.appId, targetId)
                                                    }
                                                }
                                            },
                                            onDragEnd = {
                                                // 长按后没挪动就是「查看详情」，拖动过则已排序
                                                if (travelled <= 8f) selectedItem = item
                                                draggingId = null
                                                dragOffset = Offset.Zero
                                                suppressTapUntil = System.currentTimeMillis() + 350
                                            },
                                            onDragCancel = {
                                                draggingId = null
                                                dragOffset = Offset.Zero
                                                suppressTapUntil = System.currentTimeMillis() + 350
                                            },
                                        )
                                    },
                            ) {
                                if (catalog.config.listLayout) {
                                    AppListRow(
                                        item = item,
                                        bitmap = catalog.icons[item.appId],
                                        transfer = catalog.transfers[item.appId],
                                        onOpen = { onActivate(item) },
                                    )
                                } else {
                                    AppGridCard(
                                        item = item,
                                        bitmap = catalog.icons[item.appId],
                                        transfer = catalog.transfers[item.appId],
                                        onOpen = { onActivate(item) },
                                    )
                                }
                            }
                        }
                    }
                }
            }

            if (importing) {
                ImportingOverlay()
            }

            // 长按拖动时跟手的浮动卡片：位置只由手指位移决定，
            // 网格里的换位由弹簧动画补齐，两者互不干扰。
            val previewItem = visible.firstOrNull { it.appId == draggingId }
            if (previewItem != null && dragPreviewSize.width > 0 && dragPreviewSize.height > 0) {
                val density = LocalDensity.current
                val previewWidth = with(density) { dragPreviewSize.width.toDp() }
                val previewHeight = with(density) { dragPreviewSize.height.toDp() }
                val topLeft = gridWindowPos - boxWindowPos + dragPreviewOrigin + dragOffset
                Box(
                    modifier = Modifier
                        .offset { IntOffset(topLeft.x.roundToInt(), topLeft.y.roundToInt()) }
                        .size(previewWidth, previewHeight)
                        .shadow(16.dp, RoundedCornerShape(22.dp))
                        .graphicsLayer {
                            scaleX = 1.05f
                            scaleY = 1.05f
                        },
                ) {
                    if (catalog.config.listLayout) {
                        AppListRow(
                            item = previewItem,
                            bitmap = catalog.icons[previewItem.appId],
                            transfer = catalog.transfers[previewItem.appId],
                            onOpen = {},
                        )
                    } else {
                        AppGridCard(
                            item = previewItem,
                            bitmap = catalog.icons[previewItem.appId],
                            transfer = catalog.transfers[previewItem.appId],
                            onOpen = {},
                        )
                    }
                }
            }
        }
    }

    selectedItem?.let { item ->
        ModalBottomSheet(
            onDismissRequest = { selectedItem = null },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = HostSurface,
        ) {
            AppDetailSheet(
                item = item,
                catalog = catalog,
                onOpen = {
                    val local = item.local
                    selectedItem = null
                    if (local != null) openApp(local)
                },
                onInstall = { installOne(item) },
                onCheckUpdate = { scope.launch { syncNow(true) } },
                onUninstall = { clearData ->
                    val local = item.local
                    selectedItem = null
                    if (local != null) uninstall(local, clearData)
                },
            )
        }
    }

    if (showSettings) {
        ModalBottomSheet(
            onDismissRequest = { showSettings = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = HostSurface,
        ) {
            SettingsSheet(
                catalog = catalog,
                network = network,
                permissionStates = permissionStates,
                onRefreshNetwork = { network = context.currentNetworkSnapshot() },
                onRefreshCatalog = { scope.launch { syncNow(true) } },
                onRequestPermission = { item ->
                    val permissions = HostPermissions.items
                        .filter { it.available && it.permission != null }
                        .filterNot { HostPermissions.isGranted(context, it) }
                        .mapNotNull { it.permission }
                        .toTypedArray()
                    if (permissions.isEmpty()) {
                        HostPermissions.openAppSettings(context)
                    } else {
                        permissionLauncher.launch(permissions)
                    }
                },
                onOpenSettings = { HostPermissions.openAppSettings(context) },
            )
        }
    }

    if (showUpdates) {
        ModalBottomSheet(
            onDismissRequest = { showUpdates = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = HostSurface,
        ) {
            UpdateCenterSheet(
                items = updates,
                catalog = catalog,
                onUpdateAll = { installAll(updates) },
                onUpdateOne = { installOne(it) },
            )
        }
    }

    if (showSwitcher) {
        ModalBottomSheet(
            onDismissRequest = { showSwitcher = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = HostBg,
        ) {
            SwitcherSheet(
                running = runningHub,
                recycled = recycledHub,
                icons = catalog.icons,
                now = remember(switcherTick, showSwitcher) { System.currentTimeMillis() },
                usedAt = { id -> RecentTimes.usedAt(context, id) },
                onOpen = { item ->
                    showSwitcher = false
                    val local = item.local
                    if (local != null) {
                        scope.launch {
                            // 等面板收起再启动，避免转场叠在一起。
                            delay(220)
                            openApp(local)
                        }
                    }
                },
                onCloseOne = { item -> closeOneRunning(item) },
                onCloseAll = {
                    showSwitcher = false
                    showCloseAllConfirm = true
                },
            )
        }
    }

    if (showCloseAllConfirm) {
        AlertDialog(
            onDismissRequest = { showCloseAllConfirm = false },
            title = { Text("关闭全部小程序？") },
            text = {
                Text(
                    "将结束所有后台实例，页面栈会被清空；小程序包和用户数据保留。",
                    color = HostMuted,
                    fontSize = 13.sp,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    showCloseAllConfirm = false
                    closeAllRunning()
                }) {
                    Text("全部关闭", color = HostRed, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showCloseAllConfirm = false }) {
                    Text("取消", color = HostMuted)
                }
            },
        )
    }

    pendingImport?.let { pkg ->
        AlertDialog(
            onDismissRequest = { pendingImport = null },
            title = { Text("导入小程序") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(pkg.name, fontWeight = FontWeight.SemiBold, color = HostText)
                    Text("版本 ${pkg.versionName}", color = HostMuted, fontSize = 13.sp)
                    Text(pkg.appId, color = HostMuted, fontSize = 12.sp)
                    Text(
                        "导入后会覆盖同 appId 的本地包，用户数据默认保留。",
                        color = HostMuted,
                        fontSize = 13.sp,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingImport = null
                    importing = true
                    HostAppRepository.install(context, pkg) { result ->
                        importing = false
                        result.onSuccess {
                            HostInstallOrigin.record(context, pkg.appId, local = true)
                            refresh()
                            showMessage("已导入 ${pkg.name}")
                        }.onFailure {
                            showMessage("导入失败：${it.message ?: "未知错误"}")
                        }
                    }
                }) { Text("导入", color = HostPrimary) }
            },
            dismissButton = {
                TextButton(onClick = {
                    pkg.file.delete()
                    pendingImport = null
                }) { Text("取消", color = HostMuted) }
            },
            containerColor = HostSurface,
        )
    }
    }
    }
}

// MARK: - Hub

private fun buildHub(local: List<HostApp>, remote: List<HostRemoteApp>): List<HostHubItem> {
    val remoteMap = remote.associateBy { it.appId }
    val seen = mutableSetOf<String>()
    val items = mutableListOf<HostHubItem>()
    local.forEach { app ->
        items += HostHubItem(appId = app.appId, local = app, remote = remoteMap[app.appId])
        seen += app.appId
    }
    remote.forEach { app ->
        if (seen.add(app.appId)) {
            items += HostHubItem(appId = app.appId, local = null, remote = app)
        }
    }
    return items.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
}

enum class HostFilter(val title: String) {
    Recent("最近使用"),
    All("全部"),
    Updates("可更新"),
}

private fun timeText(millis: Long): String =
    SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(millis))

// MARK: - Header

@Composable
private fun HostHeader(
    syncLabel: String,
    syncColor: Color,
    updateCount: Int,
    onRefresh: () -> Unit,
    onUpdates: () -> Unit,
    onImport: () -> Unit,
    onSettings: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 12.dp, top = 14.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier
                .clip(CircleShape)
                .combinedClickable(onClick = onUpdates, onLongClick = onUpdates)
                .padding(vertical = 6.dp, horizontal = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(syncColor),
            )
            Spacer(Modifier.width(7.dp))
            Text(
                text = syncLabel,
                color = HostMuted,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (updateCount > 0) {
                Spacer(Modifier.width(6.dp))
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(HostPrimarySoft)
                        .padding(horizontal = 7.dp, vertical = 3.dp),
                ) {
                    Text(
                        text = "$updateCount 个可更新",
                        color = HostPrimary,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onRefresh, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Default.Refresh, contentDescription = "刷新应用目录", tint = HostText, modifier = Modifier.size(19.dp))
        }
        IconButton(onClick = onImport, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Default.Add, contentDescription = "导入小程序", tint = HostText, modifier = Modifier.size(21.dp))
        }
        IconButton(onClick = onSettings, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Default.Settings, contentDescription = "设置", tint = HostText, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun HostSearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    onClear: () -> Unit,
    onSearch: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 12.dp)
            .height(48.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(HostSurface)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Default.Search,
            contentDescription = null,
            tint = HostMuted,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(10.dp))
        BasicTextField(
            value = query,
            onValueChange = onQueryChange,
            modifier = Modifier.weight(1f),
            singleLine = true,
            textStyle = TextStyle(fontSize = 15.sp, color = HostText),
            cursorBrush = SolidColor(HostPrimary),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { onSearch() }),
        )
        if (query.isNotEmpty()) {
            IconButton(onClick = onClear, modifier = Modifier.size(28.dp)) {
                Icon(
                    Icons.Default.Close,
                    contentDescription = "清空",
                    tint = HostMuted,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun FilterRow(
    filter: HostFilter,
    recentCount: Int,
    allCount: Int,
    updateCount: Int,
    listLayout: Boolean,
    onSelect: (HostFilter) -> Unit,
    onToggleLayout: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HostFilter.entries.forEach { item ->
            val count = when (item) {
                HostFilter.Recent -> recentCount
                HostFilter.All -> allCount
                HostFilter.Updates -> updateCount
            }
            val selected = filter == item
            Row(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(if (selected) HostText else HostSurface)
                    .combinedClickable(onClick = { onSelect(item) }, onLongClick = { onSelect(item) })
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = item.title,
                    color = if (selected) HostSurface else HostMuted,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                )
                if (count > 0) {
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = "$count",
                        color = if (selected) HostSurface.copy(alpha = 0.75f) else HostMuted,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
        Spacer(Modifier.weight(1f))
        LayoutToggle(listLayout = listLayout, onToggle = onToggleLayout)
    }
}

/** 首页网格/单列切换，图标表示「点完会变成的布局」。 */
@Composable
private fun LayoutToggle(listLayout: Boolean, onToggle: () -> Unit) {
    Box(
        modifier = Modifier
            .size(32.dp)
            .clip(CircleShape)
            .background(HostSurface)
            .clickable(onClick = onToggle),
        contentAlignment = Alignment.Center,
    ) {
        // DrawScope 不是 Composable 上下文，颜色先取出再画
        val iconColor = HostText
        Canvas(Modifier.size(14.dp)) {
            if (listLayout) {
                // 当前单列，目标图标是网格。
                val cell = size.width * 0.38f
                val far = size.width - cell
                listOf(0f to 0f, far to 0f, 0f to far, far to far).forEach { (x, y) ->
                    drawRoundRect(
                        color = iconColor,
                        topLeft = Offset(x, y),
                        size = Size(cell, cell),
                        cornerRadius = CornerRadius(cell * 0.25f),
                    )
                }
            } else {
                // 当前网格，目标图标是单列。
                val thickness = size.height / 7f
                listOf(0f, (size.height - thickness) / 2f, size.height - thickness).forEach { y ->
                    drawRoundRect(
                        color = iconColor,
                        topLeft = Offset(0f, y),
                        size = Size(size.width, thickness),
                        cornerRadius = CornerRadius(thickness / 2f),
                    )
                }
            }
        }
    }
}

@Composable
private fun OfflineBanner() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(HostRed.copy(alpha = 0.08f))
            .padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Info, contentDescription = null, tint = HostRed, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(8.dp))
        Text("当前无网络，显示本地与缓存的目录", color = HostRed, fontSize = 12.sp)
    }
}

@Composable
private fun UpdateBar(count: Int, onOpen: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(HostPrimarySoft)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Refresh, contentDescription = null, tint = HostPrimary, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text("$count 个应用可更新", color = HostText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Text("下载完成后下次打开生效", color = HostMuted, fontSize = 11.sp)
        }
        Button(
            onClick = onOpen,
            shape = CircleShape,
            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp),
            colors = ButtonDefaults.buttonColors(containerColor = HostPrimary),
            modifier = Modifier.height(32.dp),
        ) {
            Text("全部更新", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun ErrorBanner(message: String, onRetry: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(HostSurface)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Info, contentDescription = null, tint = HostRed, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text("目录同步失败", color = HostText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Text(message, color = HostMuted, fontSize = 11.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        TextButton(onClick = onRetry) {
            Text("重试", color = HostPrimary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

// MARK: - Running / switcher

private fun hostRelativeTimeText(timestamp: Long, now: Long): String {
    if (timestamp <= 0L) return "刚刚"
    val seconds = ((now - timestamp) / 1000).coerceAtLeast(0)
    if (seconds < 60) return "刚刚"
    val minutes = seconds / 60
    if (minutes < 60) return "$minutes 分钟前"
    val hours = minutes / 60
    if (hours < 24) return "$hours 小时前"
    return "${hours / 24} 天前"
}

/** 首页顶部的「运行中」横条：只在有后台实例时出现，点卡片直接切回。 */
@Composable
private fun RunningStrip(
    items: List<HostHubItem>,
    icons: Map<String, Bitmap>,
    now: Long,
    usedAt: (String) -> Long,
    onOpenAll: () -> Unit,
    onOpen: (HostHubItem) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(HostSurface)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(HostGreen)
            )
            Spacer(Modifier.width(7.dp))
            Text(
                text = "运行中 ${items.size}",
                color = HostText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Text(
                text = "全部 ›",
                color = HostMuted,
                fontSize = 12.sp,
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(onClick = onOpenAll)
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }
        Spacer(Modifier.height(10.dp))
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            contentPadding = PaddingValues(vertical = 1.dp),
        ) {
            rowItems(items, key = { it.appId }) { item ->
                RunningCard(
                    item = item,
                    bitmap = icons[item.appId],
                    timeText = hostRelativeTimeText(usedAt(item.appId), now),
                    onClick = { onOpen(item) },
                )
            }
        }
    }
}

@Composable
private fun RunningCard(
    item: HostHubItem,
    bitmap: Bitmap?,
    timeText: String,
    onClick: () -> Unit,
) {
    Column(
        modifier = Modifier
            .width(132.dp)
            .height(96.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(HostBg.copy(alpha = 0.65f))
            .clickable(onClick = onClick)
            .padding(10.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            AppIcon(name = item.name, bitmap = bitmap, size = 34, corner = 11, fontSize = 15)
            Spacer(Modifier.weight(1f))
            Box(
                Modifier
                    .padding(top = 3.dp)
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(HostGreen)
            )
        }
        Spacer(Modifier.weight(1f))
        Text(
            text = item.name,
            color = HostText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = timeText,
            color = HostMuted,
            fontSize = 10.sp,
            maxLines = 1,
        )
    }
}

/** 切换面板：运行中的实例点击切回，已回收的按需重启。 */
@Composable
private fun SwitcherSheet(
    running: List<HostHubItem>,
    recycled: List<HostHubItem>,
    icons: Map<String, Bitmap>,
    now: Long,
    usedAt: (String) -> Long,
    onOpen: (HostHubItem) -> Unit,
    onCloseOne: (HostHubItem) -> Unit,
    onCloseAll: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(top = 8.dp, bottom = 28.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(HostGreen)
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = "运行中 ${running.size}",
                color = HostText,
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.height(18.dp))

        if (running.isEmpty()) {
            Text("当前没有运行中的小程序", color = HostMuted, fontSize = 13.sp)
        } else {
            SwitcherGrid(
                running, icons, now, usedAt,
                isRunning = true,
                onOpen = onOpen,
                onCloseOne = onCloseOne,
            )
        }

        if (recycled.isNotEmpty()) {
            Spacer(Modifier.height(18.dp))
            Text(
                text = "最近使用",
                color = HostMuted,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(10.dp))
            SwitcherGrid(
                recycled, icons, now, usedAt,
                isRunning = false,
                onOpen = onOpen,
                onCloseOne = null,
            )
        }

        if (running.isNotEmpty()) {
            Spacer(Modifier.height(18.dp))
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp)
                    .clip(RoundedCornerShape(15.dp))
                    .background(HostRed.copy(alpha = 0.1f))
                    .clickable(onClick = onCloseAll),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "全部关闭",
                    color = HostRed,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun SwitcherGrid(
    items: List<HostHubItem>,
    icons: Map<String, Bitmap>,
    now: Long,
    usedAt: (String) -> Long,
    isRunning: Boolean,
    onOpen: (HostHubItem) -> Unit,
    onCloseOne: ((HostHubItem) -> Unit)?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        items.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                row.forEach { item ->
                    SwitcherCard(
                        item = item,
                        bitmap = icons[item.appId],
                        timeText = if (isRunning) {
                            hostRelativeTimeText(usedAt(item.appId), now)
                        } else {
                            "按需重启"
                        },
                        isRunning = isRunning,
                        onClick = { onOpen(item) },
                        onClose = onCloseOne?.let { close -> { close(item) } },
                        modifier = Modifier.weight(1f),
                    )
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun SwitcherCard(
    item: HostHubItem,
    bitmap: Bitmap?,
    timeText: String,
    isRunning: Boolean,
    onClick: () -> Unit,
    onClose: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .heightIn(min = 116.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(HostSurface)
            .clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            AppIcon(name = item.name, bitmap = bitmap, size = 42, corner = 13, fontSize = 17)
            Spacer(Modifier.weight(1f))
            if (onClose != null) {
                // 单卡关闭按钮：嵌在卡片点击区里，需要独立可点区域。
                Box(
                    modifier = Modifier
                        .size(26.dp)
                        .clip(CircleShape)
                        .background(HostBg)
                        .clickable(onClick = onClose),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "关闭 ${item.name}",
                        tint = HostMuted,
                        modifier = Modifier.size(12.dp),
                    )
                }
            } else {
                Text(
                    text = "已回收",
                    color = HostMuted,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(HostBg)
                        .padding(horizontal = 7.dp, vertical = 3.dp),
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            text = item.name,
            color = HostText,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = timeText,
            color = HostMuted,
            fontSize = 10.sp,
            maxLines = 1,
        )
    }
}

// MARK: - Cards

@Composable
private fun AppGridCard(
    item: HostHubItem,
    bitmap: Bitmap?,
    transfer: HostTransferState?,
    onOpen: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .height(116.dp)
            .clip(RoundedCornerShape(22.dp))
            .clickable(onClick = onOpen),
        color = HostSurface,
        shape = RoundedCornerShape(22.dp),
        shadowElevation = 1.dp,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(12.dp),
        ) {
            Row(verticalAlignment = Alignment.Top) {
                AppIcon(name = item.name, bitmap = bitmap, size = 48, corner = 15, fontSize = 21)
                Spacer(Modifier.weight(1f))
                StatusBadge(item = item, transfer = transfer)
            }
            Spacer(Modifier.weight(1f))
            Text(
                text = item.name,
                color = HostText,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                lineHeight = 18.sp,
            )
            // 下载/安装中把版本行换成进度条，卡片高度保持不变。
            if (transfer?.isBusy == true) {
                ProgressBar(transfer?.progress?.toFloat(), Modifier.padding(top = 8.dp))
            } else {
                Text(
                    text = item.subtitle,
                    color = if (item.hasUpdate) HostPrimary else HostMuted,
                    fontSize = 10.sp,
                    maxLines = 1,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

/** 单列模式：图标 + 名称/版本 + 右侧状态，名称可以完整占一行。 */
@Composable
private fun AppListRow(
    item: HostHubItem,
    bitmap: Bitmap?,
    transfer: HostTransferState?,
    onOpen: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .height(72.dp)
            .clip(RoundedCornerShape(22.dp))
            .clickable(onClick = onOpen),
        color = HostSurface,
        shape = RoundedCornerShape(22.dp),
        shadowElevation = 1.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AppIcon(name = item.name, bitmap = bitmap, size = 48, corner = 15, fontSize = 21)
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(start = 12.dp),
            ) {
                Text(
                    text = item.name,
                    color = HostText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = item.subtitle,
                    color = if (item.hasUpdate) HostPrimary else HostMuted,
                    fontSize = 10.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            Spacer(Modifier.width(8.dp))
            StatusBadge(item = item, transfer = transfer)
        }
    }
}

@Composable
private fun StatusBadge(item: HostHubItem, transfer: HostTransferState?) {
    when {
        transfer is HostTransferState.Failed -> Badge("失败", HostRed, HostRed.copy(alpha = 0.12f))
        transfer?.isBusy == true -> Badge(
            when (transfer) {
                HostTransferState.Installing -> "安装中"
                HostTransferState.Verifying -> "校验中"
                else -> "下载中"
            },
            HostPrimary,
            HostPrimarySoft,
        )
        item.hasUpdate -> Badge("可更新", Color.White, HostPrimary)
        item.isRemoteOnly -> Badge("未安装", HostMuted, HostBg)
        // 只有用户自己从本地 ZIP 导入的包才标「导入」，云端下载的不标。
        item.local?.importedLocally == true -> Badge("导入", HostPrimary, HostPrimarySoft)
    }
}

@Composable
private fun Badge(text: String, textColor: Color, background: Color) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(background)
            .padding(horizontal = 6.dp, vertical = 3.dp),
    ) {
        Text(text, fontSize = 9.sp, color = textColor, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun ProgressBar(fraction: Float?, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(3.dp)
            .clip(CircleShape)
            .background(HostLine),
    ) {
        val width = (fraction ?: 0.35f).coerceIn(0.04f, 1f)
        Box(
            modifier = Modifier
                .fillMaxWidth(width)
                .height(3.dp)
                .clip(CircleShape)
                .background(HostPrimary),
        )
    }
}

@Composable
private fun AppIcon(
    name: String,
    bitmap: Bitmap?,
    size: Int,
    corner: Int,
    fontSize: Int,
) {
    if (bitmap != null) {
        Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(size.dp)
                .clip(RoundedCornerShape(corner.dp)),
        )
    } else {
        val base = Color(Utils.generateColorFromName(name).toInt())
        Box(
            modifier = Modifier
                .size(size.dp)
                .clip(RoundedCornerShape(corner.dp))
                .background(
                    Brush.linearGradient(
                        listOf(base.copy(alpha = 0.72f), base),
                    ),
                ),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = name.take(1).ifBlank { "?" },
                color = Color.White,
                fontSize = fontSize.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

@Composable
private fun EmptyState(
    query: String,
    filter: HostFilter,
    hasRemote: Boolean,
    hasLocal: Boolean,
    installableCount: Int,
    sourceConfigured: Boolean,
    onInstallAll: () -> Unit,
    onImport: () -> Unit,
    onConfigure: () -> Unit,
) {
    val title = when {
        query.isNotBlank() -> "没有匹配的小程序"
        filter == HostFilter.Updates -> "全部应用已是最新"
        hasRemote && !hasLocal -> "远程目录有应用可安装"
        else -> "还没有小程序"
    }
    val detail = when {
        query.isNotBlank() -> "换个关键词试试"
        filter == HostFilter.Updates -> "有新版本时会在这里出现"
        hasRemote && !hasLocal -> "点击全部安装，或进入设置检查应用源"
        !sourceConfigured -> "先配置 apps.json 地址，再拉取应用目录"
        else -> "从远程目录安装，或导入一个 ZIP 包"
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Default.Search,
            contentDescription = null,
            tint = HostMuted.copy(alpha = 0.5f),
            modifier = Modifier.size(42.dp),
        )
        Text(
            text = title,
            color = HostText,
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(top = 12.dp),
        )
        Text(
            text = detail,
            color = HostMuted,
            fontSize = 13.sp,
            modifier = Modifier.padding(top = 4.dp),
        )

        if (hasRemote && !hasLocal && query.isBlank() && installableCount > 0) {
            Button(
                onClick = onInstallAll,
                modifier = Modifier.padding(top = 14.dp),
                shape = RoundedCornerShape(14.dp),
            ) {
                Text("全部安装（$installableCount）")
            }
        }

        if (query.isBlank()) {
            Row(
                modifier = Modifier.padding(top = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                OutlinedButton(onClick = onImport, shape = RoundedCornerShape(14.dp)) {
                    Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("导入小程序")
                }
                if (!sourceConfigured) {
                    OutlinedButton(onClick = onConfigure, shape = RoundedCornerShape(14.dp)) {
                        Text("配置应用源", color = HostText)
                    }
                }
            }
        }
    }
}

@Composable
private fun ImportingOverlay() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.35f)),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(18.dp))
                .background(HostSurface)
                .padding(horizontal = 22.dp, vertical = 18.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = HostPrimary)
            Spacer(Modifier.width(14.dp))
            Text("正在安装小程序…", color = HostText, fontSize = 14.sp)
        }
    }
}

// MARK: - Detail

@Composable
private fun AppDetailSheet(
    item: HostHubItem,
    catalog: HostCatalogController,
    onOpen: () -> Unit,
    onInstall: () -> Unit,
    onCheckUpdate: () -> Unit,
    onUninstall: (Boolean) -> Unit,
) {
    var showUninstall by remember { mutableStateOf(false) }
    val transfer = catalog.transfers[item.appId]
    val remote = item.remote
    val minHost = remote?.minHostVersion
    val hostTooLow = minHost != null && HostCatalogController.compareVersion(catalog.hostVersion, minHost) < 0

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AppIcon(name = item.name, bitmap = catalog.icons[item.appId], size = 62, corner = 19, fontSize = 27)
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(item.name, color = HostText, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    if (remote?.force == true && item.hasUpdate) {
                        Spacer(Modifier.width(6.dp))
                        Badge("强制", HostRed, HostRed.copy(alpha = 0.12f))
                    }
                }
                Text(
                    text = item.subtitle,
                    color = HostMuted,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }

        Spacer(Modifier.height(16.dp))

        Surface(color = HostBg, shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(14.dp)) {
                DetailRow("appId", item.appId)
                DetailRow("本地版本", item.local?.versionName ?: "未安装")
                if (remote != null) {
                    DetailRow("远程版本", "${remote.versionName} (${remote.versionCode})")
                    remote.size?.takeIf { it > 0 }?.let {
                        DetailRow("安装包", HostCatalogController.formatBytes(it))
                    }
                    remote.publishedAt?.let { DetailRow("发布时间", it) }
                    remote.minHostVersion?.let { DetailRow("最低宿主", it) }
                }
                DetailRow("来源", item.local?.sourceLabel ?: "远程目录")
            }
        }

        remote?.notes?.takeIf { it.isNotBlank() }?.let { notes ->
            Spacer(Modifier.height(12.dp))
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(HostBg)
                    .padding(12.dp),
            ) {
                Text("更新说明", color = HostText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    text = notes,
                    color = HostMuted,
                    fontSize = 12.sp,
                    lineHeight = 18.sp,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }

        if (transfer != null) {
            Spacer(Modifier.height(12.dp))
            TransferRow(transfer)
        }

        if (hostTooLow && minHost != null) {
            Spacer(Modifier.height(12.dp))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(HostRed.copy(alpha = 0.08f))
                    .padding(horizontal = 12.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.Info, contentDescription = null, tint = HostRed, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(8.dp))
                Text("需要宿主版本 ≥ $minHost，请先升级 Dream Tapir", color = HostRed, fontSize = 12.sp)
            }
        }

        Spacer(Modifier.height(16.dp))

        when {
            remote != null && (item.hasUpdate || item.needsInstall) -> {
                Button(
                    onClick = onInstall,
                    enabled = transfer?.isBusy != true && !hostTooLow,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp),
                    shape = RoundedCornerShape(15.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (hostTooLow) HostMuted else HostPrimary,
                    ),
                ) {
                    Text(
                        if (item.hasUpdate) "更新到 v${remote.versionName}" else "安装 v${remote.versionName}",
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            item.canOpen -> {
                Button(
                    onClick = onOpen,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp),
                    shape = RoundedCornerShape(15.dp),
                ) {
                    Text("打开小程序", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            else -> {
                Button(
                    onClick = onCheckUpdate,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp),
                    shape = RoundedCornerShape(15.dp),
                ) {
                    Text("从目录重新获取", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }

        Spacer(Modifier.height(10.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(
                onClick = onCheckUpdate,
                modifier = Modifier
                    .weight(1f)
                    .height(46.dp),
                shape = RoundedCornerShape(14.dp),
            ) {
                Text("检查更新", color = HostText, fontSize = 13.sp)
            }
            OutlinedButton(
                onClick = { showUninstall = true },
                enabled = item.canOpen,
                modifier = Modifier
                    .weight(1f)
                    .height(46.dp),
                shape = RoundedCornerShape(14.dp),
            ) {
                Icon(Icons.Default.Delete, contentDescription = null, modifier = Modifier.size(16.dp), tint = HostRed)
                Spacer(Modifier.width(4.dp))
                Text("卸载", color = HostRed, fontSize = 13.sp)
            }
        }

        Text(
            text = "安装或更新完成后，下次打开小程序生效。内置应用卸载后会在下次启动时恢复。",
            color = HostMuted,
            fontSize = 11.sp,
            lineHeight = 16.sp,
            modifier = Modifier.padding(top = 12.dp),
        )
    }

    if (showUninstall) {
        AlertDialog(
            onDismissRequest = { showUninstall = false },
            title = { Text("卸载 ${item.name}？") },
            text = { Text("清除数据会移除该小程序的本地存储，操作不可恢复。", color = HostMuted) },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton(onClick = {
                        showUninstall = false
                        onUninstall(true)
                    }) { Text("卸载并清除数据", color = HostRed) }
                    TextButton(onClick = {
                        showUninstall = false
                        onUninstall(false)
                    }) { Text("卸载（保留数据）", color = HostRed) }
                }
            },
            dismissButton = {
                TextButton(onClick = { showUninstall = false }) { Text("取消", color = HostMuted) }
            },
            containerColor = HostSurface,
        )
    }
}

@Composable
private fun TransferRow(transfer: HostTransferState) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(HostBg)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        val label = when (transfer) {
            is HostTransferState.Failed -> transfer.message
            HostTransferState.Verifying -> "校验安装包…"
            HostTransferState.Installing -> "安装中…"
            is HostTransferState.Downloading -> {
                val value = transfer.value
                if (value >= 0) "下载中 ${(value * 100).toInt()}%" else "正在连接下载…"
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (transfer.isBusy) {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    strokeWidth = 2.dp,
                    color = if (transfer is HostTransferState.Failed) HostRed else HostPrimary,
                )
                Spacer(Modifier.width(8.dp))
            }
            Text(
                text = label,
                color = if (transfer is HostTransferState.Failed) HostRed else HostText,
                fontSize = 12.sp,
            )
        }
        transfer.progress?.let { value ->
            ProgressBar(value.toFloat(), Modifier.padding(top = 8.dp))
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(label, color = HostMuted, fontSize = 12.sp, modifier = Modifier.width(62.dp))
        Text(
            text = value,
            color = HostText,
            fontSize = 12.sp,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// MARK: - Update center

@Composable
private fun UpdateCenterSheet(
    items: List<HostHubItem>,
    catalog: HostCatalogController,
    onUpdateAll: () -> Unit,
    onUpdateOne: (HostHubItem) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
    ) {
        Text("更新中心", color = HostText, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Text(
            if (items.isEmpty()) "全部应用已是最新" else "${items.size} 个应用有新版本",
            color = HostMuted,
            fontSize = 12.sp,
            modifier = Modifier.padding(top = 4.dp),
        )

        Column(
            modifier = Modifier
                .padding(top = 14.dp)
                .heightIn(max = 420.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items.forEach { item ->
                val transfer = catalog.transfers[item.appId]
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(HostBg)
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    AppIcon(
                        name = item.name,
                        bitmap = catalog.icons[item.appId],
                        size = 40,
                        corner = 12,
                        fontSize = 16,
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(item.name, color = HostText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                        Text(
                            "v${item.versionName} → v${item.remote?.versionName.orEmpty()}",
                            color = HostMuted,
                            fontSize = 11.sp,
                        )
                        transfer?.progress?.let { value ->
                            ProgressBar(value.toFloat(), Modifier.padding(top = 6.dp))
                        }
                    }
                    if (transfer?.isBusy == true) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = HostPrimary,
                        )
                    } else {
                        TextButton(onClick = { onUpdateOne(item) }) {
                            Text("更新", color = HostPrimary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        Button(
            onClick = onUpdateAll,
            enabled = items.isNotEmpty(),
            modifier = Modifier
                .fillMaxWidth()
                .height(50.dp),
            shape = RoundedCornerShape(15.dp),
        ) {
            Text("全部更新（${items.size}）", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

// MARK: - Settings

@Composable
private fun SettingsSheet(
    catalog: HostCatalogController,
    network: NetworkSnapshot,
    permissionStates: Map<HostPermission, Boolean>,
    onRefreshNetwork: () -> Unit,
    onRefreshCatalog: () -> Unit,
    onRequestPermission: (HostPermission) -> Unit,
    onOpenSettings: () -> Unit,
) {
    var sourceDraft by remember { mutableStateOf(catalog.config.source) }
    var channelDraft by remember { mutableStateOf(catalog.config.channel) }
    var authUserDraft by remember { mutableStateOf(catalog.config.authUser) }
    var authPasswordDraft by remember { mutableStateOf(catalog.config.authPassword) }
    var showDiagnostics by remember { mutableStateOf(false) }
    var summary by remember { mutableStateOf(StorageSummary(0, 0, 0)) }
    var storageTick by remember { mutableIntStateOf(0) }

    LaunchedEffect(storageTick) {
        summary = catalog.storageSummary()
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
    ) {
        if (showDiagnostics) {
            DiagnosticsPanel(
                catalog = catalog,
                onBack = { showDiagnostics = false },
            )
            return@Column
        }

        Text("设置", color = HostText, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Text(
            "应用源、更新策略与系统权限",
            color = HostMuted,
            fontSize = 12.sp,
            modifier = Modifier.padding(top = 4.dp),
        )

        Spacer(Modifier.height(16.dp))
        Text("应用源", color = HostText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))

        SourceField(
            value = sourceDraft,
            placeholder = "https://example.com/apps.json",
            onValueChange = { sourceDraft = it },
        )
        Spacer(Modifier.height(8.dp))
        SourceField(
            value = channelDraft,
            placeholder = "渠道（prod / beta）",
            onValueChange = { channelDraft = it },
        )
        Spacer(Modifier.height(8.dp))
        SourceField(
            value = authUserDraft,
            placeholder = "访问用户名（未启用可留空）",
            onValueChange = { authUserDraft = it },
        )
        Spacer(Modifier.height(8.dp))
        SourceField(
            value = authPasswordDraft,
            placeholder = "访问密码",
            onValueChange = { authPasswordDraft = it },
        )
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = {
                    catalog.updateConfig {
                        it.copy(
                            source = sourceDraft.trim(),
                            channel = channelDraft.trim().ifBlank { "prod" },
                            authUser = authUserDraft.trim(),
                            authPassword = authPasswordDraft,
                        )
                    }
                    onRefreshCatalog()
                },
                modifier = Modifier
                    .weight(1f)
                    .height(40.dp),
                shape = RoundedCornerShape(12.dp),
            ) {
                Text("保存并刷新", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
            OutlinedButton(
                onClick = {
                    catalog.resetSource()
                    sourceDraft = catalog.config.source
                    channelDraft = "prod"
                    authUserDraft = ""
                    authPasswordDraft = ""
                    catalog.updateConfig {
                        it.copy(channel = "prod", authUser = "", authPassword = "")
                    }
                },
                modifier = Modifier
                    .weight(1f)
                    .height(40.dp),
                shape = RoundedCornerShape(12.dp),
            ) {
                Text("恢复默认", color = HostText, fontSize = 13.sp)
            }
        }
        Text(
            "地址支持直接填写 apps.json，或填写站点根路径自动补全 /apps.json。安装包与图标必须与应用源同域。若站点在宝塔开启了「密码访问」，填写对应的用户名和密码，目录、安装包、图标请求都会自动携带。",
            color = HostMuted,
            fontSize = 11.sp,
            lineHeight = 16.sp,
            modifier = Modifier.padding(top = 8.dp),
        )

        Spacer(Modifier.height(16.dp))
        ToggleRow(
            title = "自动检查更新",
            detail = "启动时同步应用目录",
            checked = catalog.config.autoCheck,
            onCheckedChange = { value -> catalog.updateConfig { it.copy(autoCheck = value) } },
        )
        Spacer(Modifier.height(8.dp))
        ToggleRow(
            title = "仅 Wi-Fi 自动下载",
            detail = "蜂窝网络下不自动下载安装包",
            checked = catalog.config.wifiOnlyAutoDownload,
            onCheckedChange = { value -> catalog.updateConfig { it.copy(wifiOnlyAutoDownload = value) } },
        )
        Spacer(Modifier.height(8.dp))
        ToggleRow(
            title = "自动安装更新",
            detail = "同步后自动下载并安装，下次打开生效",
            checked = catalog.config.autoInstall,
            onCheckedChange = { value -> catalog.updateConfig { it.copy(autoInstall = value) } },
        )
        Spacer(Modifier.height(8.dp))
        ToggleRow(
            title = "调试模式",
            detail = "打开后小程序内显示 vConsole 调试面板，下次打开小程序生效",
            checked = catalog.config.debugEnabled,
            onCheckedChange = { value ->
                catalog.updateConfig { it.copy(debugEnabled = value) }
                runCatching { Dimina.getInstance().setDebugMode(value) }
            },
        )

        Spacer(Modifier.height(16.dp))
        Text("外观", color = HostText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(
                HostCatalogConfig.THEME_SYSTEM to "跟随系统",
                HostCatalogConfig.THEME_LIGHT to "浅色",
                HostCatalogConfig.THEME_DARK to "深色",
            ).forEach { (mode, label) ->
                val selected = catalog.config.themeMode == mode
                Text(
                    text = label,
                    color = if (selected) HostSurface else HostMuted,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(if (selected) HostText else HostSurface)
                        .clickable { catalog.updateConfig { it.copy(themeMode = mode) } }
                        .padding(horizontal = 14.dp, vertical = 7.dp),
                )
            }
        }
        Text(
            "默认跟随系统深色模式切换，手动选择后立即生效",
            color = HostMuted,
            fontSize = 11.sp,
            modifier = Modifier.padding(top = 8.dp),
        )

        Spacer(Modifier.height(16.dp))
        Text("后台保活", color = HostText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(1, 2, 3, 5, 8).forEach { count ->
                val selected = catalog.config.maxBackgroundApps == count
                Text(
                    text = "$count 个",
                    color = if (selected) HostSurface else HostMuted,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(if (selected) HostText else HostSurface)
                        .clickable {
                            catalog.updateConfig { it.copy(maxBackgroundApps = count) }
                            App.applyRetention(count)
                        }
                        .padding(horizontal = 14.dp, vertical = 7.dp),
                )
            }
        }
        Text(
            "小程序退到后台后常驻，超出数量时回收最久未用的；调小后在下一次切换时生效",
            color = HostMuted,
            fontSize = 11.sp,
            modifier = Modifier.padding(top = 8.dp),
        )

        Spacer(Modifier.height(16.dp))
        Text("存储", color = HostText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Surface(color = HostBg, shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(vertical = 4.dp)) {
                StorageRow("已安装应用", HostCatalogController.formatBytes(summary.installed))
                HorizontalDivider(color = HostLine, modifier = Modifier.padding(horizontal = 14.dp))
                StorageRow("下载缓存", HostCatalogController.formatBytes(summary.downloads))
                HorizontalDivider(color = HostLine, modifier = Modifier.padding(horizontal = 14.dp))
                StorageRow("图标缓存", HostCatalogController.formatBytes(summary.icons))
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(
                onClick = {
                    catalog.clearDownloadCache()
                    storageTick++
                },
                modifier = Modifier
                    .weight(1f)
                    .height(38.dp),
                shape = RoundedCornerShape(12.dp),
            ) { Text("清理下载缓存", color = HostText, fontSize = 12.sp) }
            OutlinedButton(
                onClick = {
                    catalog.clearIconCache()
                    storageTick++
                },
                modifier = Modifier
                    .weight(1f)
                    .height(38.dp),
                shape = RoundedCornerShape(12.dp),
            ) { Text("清理图标缓存", color = HostText, fontSize = 12.sp) }
        }

        Spacer(Modifier.height(16.dp))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(HostBg)
                .combinedClickable(
                    onClick = { showDiagnostics = true },
                    onLongClick = { showDiagnostics = true },
                )
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.Info, contentDescription = null, tint = HostPrimary, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text("源诊断", color = HostText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                Text("检查连通性、TLS、鉴权与磁盘", color = HostMuted, fontSize = 11.sp)
            }
            Text("→", color = HostMuted, fontSize = 15.sp)
        }

        Spacer(Modifier.height(12.dp))
        NetworkCard(network = network, onRefresh = onRefreshNetwork)

        Spacer(Modifier.height(16.dp))
        Text("权限中心", color = HostText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Surface(color = HostBg, shape = RoundedCornerShape(18.dp), modifier = Modifier.fillMaxWidth()) {
            Column {
                HostPermissions.items.forEachIndexed { index, item ->
                    PermissionRow(
                        item = item,
                        granted = permissionStates[item] == true,
                        onRequest = { onRequestPermission(item) },
                    )
                    if (index < HostPermissions.items.size - 1) {
                        HorizontalDivider(color = HostLine, modifier = Modifier.padding(horizontal = 14.dp))
                    }
                }
            }
        }
        Text(
            "小程序内首次调用相机、定位等能力时，系统也会弹出授权。若已拒绝，请前往系统设置手动开启。",
            color = HostMuted,
            fontSize = 11.sp,
            lineHeight = 16.sp,
            modifier = Modifier.padding(top = 8.dp),
        )

        Spacer(Modifier.height(16.dp))
        OutlinedButton(
            onClick = onOpenSettings,
            modifier = Modifier
                .fillMaxWidth()
                .height(46.dp),
            shape = RoundedCornerShape(14.dp),
        ) {
            Icon(Icons.Default.Settings, contentDescription = null, modifier = Modifier.size(18.dp), tint = HostText)
            Spacer(Modifier.width(6.dp))
            Text("打开系统应用设置", color = HostText, fontSize = 14.sp)
        }
    }
}

@Composable
private fun SourceField(value: String, placeholder: String, onValueChange: (String) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(42.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(HostBg)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.weight(1f),
            singleLine = true,
            textStyle = TextStyle(fontSize = 13.sp, color = HostText),
            cursorBrush = SolidColor(HostPrimary),
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (value.isEmpty()) {
                        Text(placeholder, color = HostMuted, fontSize = 13.sp)
                    }
                    inner()
                }
            },
        )
    }
}

@Composable
private fun ToggleRow(
    title: String,
    detail: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(HostBg)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = HostText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(detail, color = HostMuted, fontSize = 11.sp, modifier = Modifier.padding(top = 2.dp))
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = HostPrimary,
            ),
        )
    }
}

@Composable
private fun StorageRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = HostText, fontSize = 13.sp)
        Spacer(Modifier.weight(1f))
        Text(value, color = HostMuted, fontSize = 12.sp)
    }
}

@Composable
private fun NetworkCard(network: NetworkSnapshot, onRefresh: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(
                (if (network.connected) HostGreen else HostRed).copy(alpha = 0.12f)
            )
            .combinedClickable(onClick = onRefresh, onLongClick = onRefresh)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(10.dp)
                .clip(CircleShape)
                .background(if (network.connected) HostGreen else HostRed),
        )
        Spacer(Modifier.width(10.dp))
        Column {
            Text(network.title, color = HostText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(network.detail, color = HostMuted, fontSize = 12.sp, modifier = Modifier.padding(top = 2.dp))
        }
    }
}

@Composable
private fun PermissionRow(item: HostPermission, granted: Boolean, onRequest: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(item.label, color = HostText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(item.description, color = HostMuted, fontSize = 11.sp, modifier = Modifier.padding(top = 2.dp))
        }
        if (granted) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Check, contentDescription = null, tint = HostGreen, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(4.dp))
                Text("已授权", color = HostGreen, fontSize = 12.sp)
            }
        } else {
            TextButton(onClick = onRequest) {
                Text("授权", color = HostPrimary, fontSize = 12.sp)
            }
        }
    }
}

@Composable
private fun DiagnosticsPanel(catalog: HostCatalogController, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        if (catalog.diagnostics.isEmpty()) {
            catalog.runDiagnostics()
        }
    }

    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onBack) {
            Text("← 返回", color = HostPrimary, fontSize = 13.sp)
        }
        Spacer(Modifier.weight(1f))
        TextButton(onClick = {
            if (!catalog.isDiagnosing) scope.launch { catalog.runDiagnostics() }
        }) {
            Text(if (catalog.isDiagnosing) "诊断中…" else "重新诊断", color = HostPrimary, fontSize = 13.sp)
        }
    }
    Text("源诊断", color = HostText, fontSize = 20.sp, fontWeight = FontWeight.Bold)
    Text("连通性、TLS、鉴权与存储", color = HostMuted, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))

    Spacer(Modifier.height(12.dp))
    catalog.diagnostics.forEach { line ->
        Text(
            text = line,
            color = HostText,
            fontSize = 12.sp,
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 8.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(HostBg)
                .padding(10.dp),
        )
    }
}
