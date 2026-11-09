package com.dreamtapir.host

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.didi.dimina.Dimina
import com.didi.dimina.bean.MiniProgram
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.ZipFile

data class HostApp(
    val appId: String,
    val name: String,
    val path: String?,
    val versionCode: Int,
    val versionName: String,
    val updateManifestUrl: String,
    val bundled: Boolean,
    val installed: Boolean,
) {
    val sourceLabel: String
        get() = when {
            installed && bundled -> "已安装"
            installed -> "已导入"
            else -> "内置"
        }

    val canUpdate: Boolean
        get() = updateManifestUrl.isNotBlank()

    val canUninstall: Boolean
        get() = installed

    fun toMiniProgram(iconPath: String? = null): MiniProgram = MiniProgram(
        appId = appId,
        name = name,
        path = path,
        versionCode = versionCode,
        versionName = versionName,
        updateManifestUrl = updateManifestUrl,
        iconPath = iconPath,
    )
}

data class HostImportPackage(
    val appId: String,
    val name: String,
    val versionCode: Int,
    val versionName: String,
    val file: File,
)

object HostAppRepository {

    fun load(context: Context): List<HostApp> {
        val bundled = readBundled(context)
        val installed = readInstalled(context)
        val merged = LinkedHashMap<String, HostApp>()
        bundled.forEach { merged[it.appId] = it }
        installed.forEach { app ->
            val isBundled = merged.containsKey(app.appId)
            merged[app.appId] = app.copy(bundled = isBundled)
        }
        return merged.values.sortedWith(
            compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }
        )
    }

    private fun readBundled(context: Context): List<HostApp> {
        val folders = runCatching { context.assets.list("jsapp")?.toList().orEmpty() }
            .getOrDefault(emptyList())
        return folders.mapNotNull { folder ->
            val json = runCatching {
                context.assets.open("jsapp/$folder/config.json")
                    .bufferedReader()
                    .use { it.readText() }
                    .let(::JSONObject)
            }.getOrNull() ?: return@mapNotNull null
            json.toHostApp(bundled = true, installed = false)
        }
    }

    private fun readInstalled(context: Context): List<HostApp> {
        val root = File(context.filesDir, "jsapp")
        if (!root.isDirectory) return emptyList()
        return root.listFiles().orEmpty().mapNotNull { dir ->
            if (!dir.isDirectory || dir.name.startsWith(".")) return@mapNotNull null
            val config = File(dir, "config.json")
            if (!config.isFile) return@mapNotNull null
            val json = runCatching { JSONObject(config.readText()) }.getOrNull()
                ?: return@mapNotNull null
            if (json.optString("appId") != dir.name) return@mapNotNull null
            if (!File(dir, "main/app-config.json").isFile || !File(dir, "main/logic.js").isFile) {
                return@mapNotNull null
            }
            json.toHostApp(bundled = false, installed = true)
        }
    }

    private fun JSONObject.toHostApp(bundled: Boolean, installed: Boolean): HostApp? {
        val appId = optString("appId").trim()
        if (appId.isEmpty() || appId.contains('/') || appId.contains('\\')) return null
        return HostApp(
            appId = appId,
            name = optString("name").ifBlank { appId },
            path = optString("path").ifBlank { null },
            versionCode = optInt("versionCode", 0),
            versionName = optString("versionName").ifBlank { "1.0.0" },
            updateManifestUrl = optString("updateManifestUrl"),
            bundled = bundled,
            installed = installed,
        )
    }

    fun prepareImport(context: Context, uri: Uri): Result<HostImportPackage> = runCatching {
        val dir = File(context.cacheDir, "host-import").apply { mkdirs() }
        val file = File(dir, "import-${System.currentTimeMillis()}.zip")
        context.contentResolver.openInputStream(uri)?.use { input ->
            file.outputStream().use { output -> input.copyTo(output) }
        } ?: error("无法读取所选文件")

        val config = readConfigFromZip(file)
        val appId = config.optString("appId").trim()
        require(appId.isNotEmpty()) { "ZIP 内的 config.json 缺少 appId" }
        require(!appId.contains('/') && !appId.contains('\\')) { "appId 不合法" }
        HostImportPackage(
            appId = appId,
            name = config.optString("name").ifBlank { appId },
            versionCode = config.optInt("versionCode", 0),
            versionName = config.optString("versionName").ifBlank { "1.0.0" },
            file = file,
        )
    }

    private fun readConfigFromZip(file: File): JSONObject = ZipFile(file).use { zip ->
        val entry = zip.entries().asSequence()
            .filter { it.name == "config.json" || it.name.endsWith("/config.json") }
            .minByOrNull { it.name.count { char -> char == '/' } }
            ?: error("ZIP 内未找到 config.json")
        val text = zip.getInputStream(entry).bufferedReader().use { it.readText() }
        JSONObject(text)
    }

    fun install(
        context: Context,
        pkg: HostImportPackage,
        onComplete: (Result<JSONObject>) -> Unit,
    ) {
        Dimina.getInstance().installMiniProgram(pkg.appId, pkg.file.absolutePath) { result ->
            pkg.file.delete()
            onComplete(result)
        }
    }

    fun uninstall(
        appId: String,
        clearUserData: Boolean = false,
        onComplete: (Result<Unit>) -> Unit,
    ) {
        Dimina.getInstance().uninstallMiniProgram(
            appId = appId,
            clearUserData = clearUserData,
            completion = onComplete,
        )
    }

    fun checkForUpdate(
        context: Context,
        app: HostApp,
        onComplete: (String) -> Unit,
    ) {
        if (!app.canUpdate) {
            onComplete("未配置更新地址")
            return
        }
        val lastEvent = AtomicReference("")
        Thread {
            val result = runCatching {
                com.didi.dimina.core.RemoteUpdateManager.checkForUpdate(
                    context.applicationContext,
                    app.toMiniProgram(),
                    notify = { event -> lastEvent.set(event) },
                )
            }
            val message = result.fold(
                onSuccess = {
                    when (lastEvent.get()) {
                        "updateready" -> "发现新版本，已下载，下次启动生效"
                        "updating" -> "正在下载更新"
                        "updatefail" -> "更新失败，请稍后重试"
                        "noupdate" -> "已是最新版本"
                        else -> "更新检查完成"
                    }
                },
                onFailure = { error -> "更新失败：${error.message ?: "未知错误"}" },
            )
            onComplete(message)
        }.start()
    }
}

object RecentApps {
    private const val PREFS = "dimina_host_shell"
    private const val KEY = "recent_app_ids"
    private const val MAX = 8

    fun load(context: Context): List<String> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, "").orEmpty()
        return raw.split('|').filter { it.isNotBlank() }
    }

    fun record(context: Context, appId: String): List<String> {
        val updated = (listOf(appId) + load(context).filterNot { it == appId }).take(MAX)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, updated.joinToString("|"))
            .apply()
        return updated
    }
}

data class NetworkSnapshot(
    val connected: Boolean,
    val type: String,
    val validated: Boolean,
    val metered: Boolean,
) {
    val title: String
        get() = when {
            !connected -> "未连接"
            type.isNotBlank() -> type
            else -> "未知网络"
        }

    val detail: String
        get() = when {
            !connected -> "小程序网络请求不可用"
            validated -> if (metered) "已连接 · 计费网络" else "已连接 · 网络正常"
            else -> "已连接 · 暂未验证互联网"
        }
}

fun Context.currentNetworkSnapshot(): NetworkSnapshot {
    val manager = getSystemService(ConnectivityManager::class.java)
    val network = manager.activeNetwork
    val caps = network?.let(manager::getNetworkCapabilities)
    val connected = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    val type = when {
        caps == null -> ""
        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "蜂窝网络"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "以太网"
        caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
        else -> "其他网络"
    }
    return NetworkSnapshot(
        connected = connected,
        type = type,
        validated = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true,
        metered = manager.isActiveNetworkMetered,
    )
}

data class HostPermission(
    val key: String,
    val label: String,
    val description: String,
    val permission: String?,
    val minSdk: Int = 0,
) {
    val available: Boolean
        get() = Build.VERSION.SDK_INT >= minSdk
}

object HostPermissions {
    val items: List<HostPermission> = listOf(
        HostPermission(
            key = "camera",
            label = "相机",
            description = "扫码、拍照与视频通话",
            permission = Manifest.permission.CAMERA,
        ),
        HostPermission(
            key = "microphone",
            label = "麦克风",
            description = "录音、语音消息与通话",
            permission = Manifest.permission.RECORD_AUDIO,
        ),
        HostPermission(
            key = "location",
            label = "定位",
            description = "附近服务、地图与打卡",
            permission = Manifest.permission.ACCESS_FINE_LOCATION,
        ),
        HostPermission(
            key = "notifications",
            label = "通知",
            description = "更新提醒与消息通知",
            permission = if (Build.VERSION.SDK_INT >= 33) {
                Manifest.permission.POST_NOTIFICATIONS
            } else {
                null
            },
            minSdk = 33,
        ),
        HostPermission(
            key = "photos",
            label = "照片",
            description = "选择图片、保存到相册",
            permission = if (Build.VERSION.SDK_INT >= 33) {
                Manifest.permission.READ_MEDIA_IMAGES
            } else {
                Manifest.permission.READ_EXTERNAL_STORAGE
            },
        ),
    )

    fun isGranted(context: Context, item: HostPermission): Boolean {
        if (!item.available) return true
        val permission = item.permission ?: return true
        return ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED
    }

    fun openAppSettings(context: Context) {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }
}
