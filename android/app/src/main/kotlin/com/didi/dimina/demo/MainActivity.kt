@file:OptIn(
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.material3.ExperimentalMaterial3Api::class,
)

package com.didi.dimina.demo

import android.app.Activity
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items as rowItems
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
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
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowInsetsControllerCompat
import com.didi.dimina.Dimina
import com.didi.dimina.common.Utils
import com.didi.dimina.ui.theme.DiminaAndroidTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val HostBg = Color(0xFFF3F5FB)
private val HostSurface = Color(0xFFFFFFFF)
private val HostPrimary = Color(0xFF3B5BFF)
private val HostPrimarySoft = Color(0xFFE9EDFF)
private val HostText = Color(0xFF171A22)
private val HostMuted = Color(0xFF7A8194)
private val HostLine = Color(0xFFE8EBF3)
private val HostGreen = Color(0xFF18A86B)
private val HostRed = Color(0xFFE5484D)

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val systemBarColor = HostBg.toArgb()
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.light(systemBarColor, systemBarColor),
            navigationBarStyle = SystemBarStyle.light(systemBarColor, systemBarColor),
        )
        @Suppress("DEPRECATION")
        window.statusBarColor = systemBarColor
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = true
            isAppearanceLightNavigationBars = true
        }

        setContent {
            DiminaAndroidTheme(darkTheme = false, dynamicColor = false) {
                HostShellScreen(modifier = Modifier.fillMaxSize())
            }
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

    var apps by remember { mutableStateOf<List<HostApp>>(emptyList()) }
    var recentIds by remember { mutableStateOf<List<String>>(emptyList()) }
    var query by remember { mutableStateOf("") }
    var selectedApp by remember { mutableStateOf<HostApp?>(null) }
    var showSettings by remember { mutableStateOf(false) }
    var pendingImport by remember { mutableStateOf<HostImportPackage?>(null) }
    var importing by remember { mutableStateOf(false) }
    var confirmUninstall by remember { mutableStateOf<HostApp?>(null) }
    var permissionTick by remember { mutableIntStateOf(0) }
    var updateStatus by remember { mutableStateOf("") }
    var updating by remember { mutableStateOf(false) }
    var network by remember { mutableStateOf(context.currentNetworkSnapshot()) }

    fun refresh() {
        apps = HostAppRepository.load(context)
        recentIds = RecentApps.load(context).filter { id -> apps.any { it.appId == id } }
    }

    fun showMessage(message: String) {
        scope.launch { snackbar.showSnackbar(message) }
    }

    fun openApp(app: HostApp) {
        recentIds = RecentApps.record(context, app.appId)
        if (activity != null) {
            Dimina.getInstance().startMiniProgram(activity, app.toMiniProgram())
        }
    }

    LaunchedEffect(Unit) { refresh() }

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

    val filtered = remember(query, apps) {
        if (query.isBlank()) apps else apps.filter {
            it.name.contains(query, ignoreCase = true) ||
                it.appId.contains(query, ignoreCase = true)
        }
    }
    val recentApps = remember(recentIds, apps) {
        recentIds.mapNotNull { id -> apps.firstOrNull { it.appId == id } }
    }
    val permissionStates = remember(permissionTick, showSettings) {
        HostPermissions.items.associateWith { HostPermissions.isGranted(context, it) }
    }

    Scaffold(
        modifier = modifier,
        containerColor = HostBg,
        snackbarHost = { SnackbarHost(snackbar) },
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(HostBg),
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                HostHeader(
                    appCount = apps.size,
                    onImport = { importLauncher.launch(IMPORT_MIME_TYPES) },
                    onSettings = { showSettings = true },
                )
                HostSearchBar(
                    query = query,
                    onQueryChange = { query = it },
                    onClear = { query = "" },
                    onSearch = {
                        focusManager.clearFocus()
                    },
                )
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(top = 4.dp),
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 28.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    if (recentApps.isNotEmpty()) {
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            SectionTitle("最近使用", "${recentApps.size}")
                        }
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            RecentAppsRow(
                                apps = recentApps,
                                onOpen = ::openApp,
                                onLongPress = { selectedApp = it },
                            )
                        }
                    }
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        SectionTitle("全部应用", "共 ${filtered.size} 个")
                    }
                    if (filtered.isEmpty()) {
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            EmptyState(
                                hasQuery = query.isNotBlank(),
                                onImport = { importLauncher.launch(IMPORT_MIME_TYPES) },
                            )
                        }
                    } else {
                        gridItems(filtered, key = { it.appId }) { app ->
                            AppGridCard(
                                app = app,
                                onOpen = { openApp(app) },
                                onLongPress = { selectedApp = app },
                            )
                        }
                    }
                }
            }

            if (importing) {
                ImportingOverlay()
            }
        }
    }

    selectedApp?.let { app ->
        ModalBottomSheet(
            onDismissRequest = {
                selectedApp = null
                updateStatus = ""
                updating = false
            },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = HostSurface,
        ) {
            AppDetailSheet(
                app = app,
                updateStatus = updateStatus,
                updating = updating,
                onOpen = {
                    selectedApp = null
                    openApp(app)
                },
                onCheckUpdate = {
                    updateStatus = "正在检查更新…"
                    updating = true
                    HostAppRepository.checkForUpdate(context, app) { message ->
                        activity?.runOnUiThread {
                            updating = false
                            updateStatus = message
                            refresh()
                            showMessage(message)
                        } ?: run {
                            updating = false
                            updateStatus = message
                            refresh()
                        }
                    }
                },
                onUninstall = {
                    selectedApp = null
                    confirmUninstall = app
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
                network = network,
                permissionStates = permissionStates,
                onRefreshNetwork = { network = context.currentNetworkSnapshot() },
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

    confirmUninstall?.let { app ->
        AlertDialog(
            onDismissRequest = { confirmUninstall = null },
            title = { Text("卸载 ${app.name}？") },
            text = {
                Text(
                    if (app.bundled) {
                        "将移除本地安装包并停止运行。内置版本会在下次启动时恢复，用户数据默认保留。"
                    } else {
                        "将移除已导入的小程序包，用户数据默认保留。"
                    },
                    color = HostMuted,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmUninstall = null
                    HostAppRepository.uninstall(app.appId) { result ->
                        result.onSuccess {
                            refresh()
                            showMessage("已卸载 ${app.name}")
                        }.onFailure {
                            showMessage("卸载失败：${it.message ?: "未知错误"}")
                        }
                    }
                }) { Text("卸载", color = HostRed) }
            },
            dismissButton = {
                TextButton(onClick = { confirmUninstall = null }) {
                    Text("取消", color = HostMuted)
                }
            },
            containerColor = HostSurface,
        )
    }
}

@Composable
private fun HostHeader(
    appCount: Int,
    onImport: () -> Unit,
    onSettings: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 12.dp, top = 14.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(42.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(
                    Brush.linearGradient(
                        listOf(Color(0xFF5B7BFF), Color(0xFF7A5CFF)),
                    ),
                ),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = "星",
                color = Color.White,
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "星河小程序",
                color = HostText,
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = "本地运行 · $appCount 个应用",
                color = HostMuted,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        IconButton(onClick = onImport) {
            Icon(Icons.Default.Add, contentDescription = "导入小程序", tint = HostText)
        }
        IconButton(onClick = onSettings) {
            Icon(Icons.Default.Settings, contentDescription = "网络与权限", tint = HostText)
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
            .padding(horizontal = 16.dp, vertical = 6.dp)
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
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (query.isEmpty()) {
                        Text("搜索名称或 appId", color = HostMuted, fontSize = 15.sp)
                    }
                    inner()
                }
            },
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
private fun SectionTitle(title: String, trailing: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 10.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            color = HostText,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.weight(1f))
        Text(text = trailing, color = HostMuted, fontSize = 12.sp)
    }
}

@Composable
private fun RecentAppsRow(
    apps: List<HostApp>,
    onOpen: (HostApp) -> Unit,
    onLongPress: (HostApp) -> Unit,
) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        contentPadding = PaddingValues(vertical = 2.dp),
    ) {
        rowItems(apps, key = { "recent-${it.appId}" }) { app ->
            Row(
                modifier = Modifier
                    .width(158.dp)
                    .clip(RoundedCornerShape(18.dp))
                    .background(HostSurface)
                    .combinedClickable(
                        onClick = { onOpen(app) },
                        onLongClick = { onLongPress(app) },
                    )
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AppIcon(app = app, size = 38, corner = 12, fontSize = 17)
                Spacer(Modifier.width(10.dp))
                Column {
                    Text(
                        text = app.name,
                        color = HostText,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = "v${app.versionName}",
                        color = HostMuted,
                        fontSize = 11.sp,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

@Composable
private fun AppGridCard(
    app: HostApp,
    onOpen: () -> Unit,
    onLongPress: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .height(142.dp)
            .clip(RoundedCornerShape(22.dp))
            .combinedClickable(onClick = onOpen, onLongClick = onLongPress),
        color = HostSurface,
        shape = RoundedCornerShape(22.dp),
        shadowElevation = 1.dp,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AppIcon(app = app, size = 48, corner = 15, fontSize = 21)
                Spacer(Modifier.weight(1f))
                if (app.installed && !app.bundled) {
                    Box(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(HostPrimarySoft)
                            .padding(horizontal = 6.dp, vertical = 3.dp),
                    ) {
                        Text("导入", fontSize = 9.sp, color = HostPrimary)
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            Text(
                text = app.name,
                color = HostText,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                lineHeight = 18.sp,
            )
            Text(
                text = "v${app.versionName} · ${app.sourceLabel}",
                color = HostMuted,
                fontSize = 10.sp,
                maxLines = 1,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun AppIcon(app: HostApp, size: Int, corner: Int, fontSize: Int) {
    val base = Color(Utils.generateColorFromName(app.name))
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
            text = app.name.take(1).ifBlank { "?" },
            color = Color.White,
            fontSize = fontSize.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun EmptyState(hasQuery: Boolean, onImport: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 56.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Default.Search,
            contentDescription = null,
            tint = HostMuted.copy(alpha = 0.5f),
            modifier = Modifier.size(42.dp),
        )
        Text(
            text = if (hasQuery) "没有匹配的小程序" else "还没有小程序",
            color = HostText,
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(top = 12.dp),
        )
        Text(
            text = if (hasQuery) "换个关键词试试" else "导入一个 ZIP 包开始使用",
            color = HostMuted,
            fontSize = 13.sp,
            modifier = Modifier.padding(top = 4.dp),
        )
        if (!hasQuery) {
            OutlinedButton(
                onClick = onImport,
                modifier = Modifier.padding(top = 16.dp),
                shape = RoundedCornerShape(14.dp),
            ) {
                Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("导入小程序")
            }
        }
    }
}

@Composable
private fun AppDetailSheet(
    app: HostApp,
    updateStatus: String,
    updating: Boolean,
    onOpen: () -> Unit,
    onCheckUpdate: () -> Unit,
    onUninstall: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AppIcon(app = app, size = 62, corner = 19, fontSize = 27)
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(app.name, color = HostText, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text(
                    text = "${app.sourceLabel} · v${app.versionName}",
                    color = HostMuted,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
        Spacer(Modifier.height(18.dp))
        Surface(
            color = HostBg,
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(modifier = Modifier.padding(14.dp)) {
                DetailRow("appId", app.appId)
                DetailRow("版本号", "${app.versionCode}")
                DetailRow("启动页", app.path ?: "默认")
                if (app.canUpdate) {
                    DetailRow("更新源", "已配置")
                }
            }
        }
        if (updateStatus.isNotEmpty()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(HostPrimarySoft)
                    .padding(horizontal = 12.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (updating) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                        color = HostPrimary,
                    )
                } else {
                    Icon(
                        Icons.Default.Info,
                        contentDescription = null,
                        tint = HostPrimary,
                        modifier = Modifier.size(16.dp),
                    )
                }
                Spacer(Modifier.width(8.dp))
                Text(updateStatus, color = HostPrimary, fontSize = 12.sp)
            }
        }
        Spacer(Modifier.height(18.dp))
        Button(
            onClick = onOpen,
            modifier = Modifier
                .fillMaxWidth()
                .height(50.dp),
            shape = RoundedCornerShape(15.dp),
            colors = ButtonDefaults.buttonColors(containerColor = HostPrimary),
        ) {
            Text("打开小程序", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(
                onClick = onCheckUpdate,
                modifier = Modifier
                    .weight(1f)
                    .height(46.dp),
                shape = RoundedCornerShape(14.dp),
                enabled = app.canUpdate && !updating,
            ) {
                Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(6.dp))
                Text(if (app.canUpdate) "检查更新" else "无更新源", fontSize = 13.sp)
            }
            OutlinedButton(
                onClick = onUninstall,
                modifier = Modifier
                    .weight(1f)
                    .height(46.dp),
                shape = RoundedCornerShape(14.dp),
                enabled = app.canUninstall,
            ) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = null,
                    modifier = Modifier.size(17.dp),
                    tint = if (app.canUninstall) HostRed else HostMuted,
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    "卸载",
                    fontSize = 13.sp,
                    color = if (app.canUninstall) HostRed else HostMuted,
                )
            }
        }
        Text(
            text = "长按应用卡片也可以打开此面板。内置应用卸载后会在下次启动时恢复。",
            color = HostMuted,
            fontSize = 11.sp,
            lineHeight = 16.sp,
            modifier = Modifier.padding(top = 14.dp),
        )
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = HostMuted, fontSize = 12.sp, modifier = Modifier.width(58.dp))
        Text(
            text = value,
            color = HostText,
            fontSize = 12.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun SettingsSheet(
    network: NetworkSnapshot,
    permissionStates: Map<HostPermission, Boolean>,
    onRefreshNetwork: () -> Unit,
    onRequestPermission: (HostPermission) -> Unit,
    onOpenSettings: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
    ) {
        Text("网络与权限", color = HostText, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Text(
            "宿主统一管理小程序运行所需的系统能力",
            color = HostMuted,
            fontSize = 12.sp,
            modifier = Modifier.padding(top = 4.dp),
        )
        Spacer(Modifier.height(16.dp))
        Surface(
            color = if (network.connected) Color(0xFFEAF8F1) else Color(0xFFFFF0F0),
            shape = RoundedCornerShape(18.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                modifier = Modifier.padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(if (network.connected) HostGreen else HostRed),
                )
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = network.title,
                        color = HostText,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(network.detail, color = HostMuted, fontSize = 12.sp)
                }
                IconButton(onClick = onRefreshNetwork) {
                    Icon(
                        Icons.Default.Refresh,
                        contentDescription = "刷新网络状态",
                        tint = HostMuted,
                    )
                }
            }
        }
        Spacer(Modifier.height(18.dp))
        Text("权限中心", color = HostText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Surface(
            color = HostBg,
            shape = RoundedCornerShape(18.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column {
                HostPermissions.items.forEachIndexed { index, item ->
                    val granted = permissionStates[item] == true
                    PermissionRow(
                        item = item,
                        granted = granted,
                        onAction = { onRequestPermission(item) },
                    )
                    if (index < HostPermissions.items.lastIndex) {
                        HorizontalDivider(
                            modifier = Modifier.padding(horizontal = 14.dp),
                            color = HostLine,
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(10.dp))
        Text(
            "小程序内首次调用相机、定位等能力时，系统也会弹出授权。若已拒绝，请前往系统设置手动开启。",
            color = HostMuted,
            fontSize = 11.sp,
            lineHeight = 16.sp,
        )
        Spacer(Modifier.height(14.dp))
        OutlinedButton(
            onClick = onOpenSettings,
            modifier = Modifier
                .fillMaxWidth()
                .height(46.dp),
            shape = RoundedCornerShape(14.dp),
        ) {
            Icon(Icons.Default.Settings, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("打开应用设置", fontSize = 14.sp)
        }
    }
}

@Composable
private fun PermissionRow(
    item: HostPermission,
    granted: Boolean,
    onAction: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(item.label, color = HostText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(
                text = if (item.available) item.description else "当前系统版本无需单独授权",
                color = HostMuted,
                fontSize = 11.sp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        if (granted) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Default.CheckCircle,
                    contentDescription = null,
                    tint = HostGreen,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(4.dp))
                Text("已授权", color = HostGreen, fontSize = 12.sp)
            }
        } else {
            TextButton(onClick = onAction, enabled = item.available) {
                Text("授权", color = HostPrimary, fontSize = 12.sp)
            }
        }
    }
}

@Composable
private fun ImportingOverlay() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0x66000000)),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            shape = RoundedCornerShape(18.dp),
            color = HostSurface,
            shadowElevation = 8.dp,
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 22.dp, vertical = 18.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(22.dp),
                    strokeWidth = 2.5.dp,
                    color = HostPrimary,
                )
                Spacer(Modifier.width(14.dp))
                Text("正在安装小程序…", color = HostText, fontSize = 14.sp)
            }
        }
    }
}

private val IMPORT_MIME_TYPES = arrayOf(
    "application/zip",
    "application/x-zip-compressed",
    "application/octet-stream",
)

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun HostShellPreview() {
    DiminaAndroidTheme {
        HostShellScreen()
    }
}
