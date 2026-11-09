package com.dreamtapir.host

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.SSLException

// MARK: - Models

data class HostRemoteApp(
    val appId: String,
    val name: String,
    val versionCode: Int,
    val versionName: String,
    val zip: String,
    val sha256: String?,
    val size: Long?,
    val icon: String?,
    val notes: String?,
    val force: Boolean,
    val minHostVersion: String?,
    val path: String?,
    val publishedAt: String?,
) {
    val id: String get() = appId

    companion object {
        fun from(json: JSONObject): HostRemoteApp? {
            val appId = json.optString("appId").trim()
            if (appId.isEmpty()) return null
            val zip = json.optString("zip")
                .ifBlank { json.optString("packageUrl") }
                .ifBlank { json.optString("url") }
            return HostRemoteApp(
                appId = appId,
                name = json.optString("name").ifBlank { appId },
                versionCode = json.optInt("versionCode", 0),
                versionName = json.optString("versionName").ifBlank { "1.0.0" },
                zip = zip,
                sha256 = json.optString("sha256").ifBlank { null },
                size = if (json.has("size")) json.optLong("size") else null,
                icon = json.optString("icon").ifBlank { null },
                notes = json.optString("notes").ifBlank { null },
                force = json.optBoolean("force", false),
                minHostVersion = json.optString("minHostVersion").ifBlank { null },
                path = json.optString("path").ifBlank { null },
                publishedAt = json.optString("publishedAt").ifBlank { null },
            )
        }
    }
}

data class HostCatalogConfig(
    val source: String = "",
    val channel: String = "prod",
    val authUser: String = "",
    val authPassword: String = "",
    val autoCheck: Boolean = true,
    val wifiOnlyAutoDownload: Boolean = true,
    val autoInstall: Boolean = false,
    /** 小程序调试面板（vConsole）开关，默认关闭，需要时在设置里打开。 */
    val debugEnabled: Boolean = false,
) {
    companion object {
        val Default = HostCatalogConfig()

        /** Preemptive HTTP Basic credential for the private site (宝塔「密码访问」). */
        fun basicAuthValue(user: String, password: String): String? {
            val trimmed = user.trim()
            if (trimmed.isEmpty()) return null
            val credential = "$trimmed:$password"
            val bytes = credential.toByteArray(Charsets.UTF_8)
            return "Basic " + android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
        }
    }
}

sealed interface HostSyncState {
    data object Idle : HostSyncState
    data object Syncing : HostSyncState
    data class Ok(val at: Long) : HostSyncState
    data class Failed(val message: String) : HostSyncState
}

sealed interface HostTransferState {
    val isBusy: Boolean
        get() = when (this) {
            is Downloading, Verifying, Installing -> true
            is Failed -> false
        }

    val progress: Double?
        get() = (this as? Downloading)?.value?.takeIf { it >= 0 }

    data class Downloading(val value: Double) : HostTransferState
    data object Verifying : HostTransferState
    data object Installing : HostTransferState
    data class Failed(val message: String) : HostTransferState
}

data class HostHubItem(
    val appId: String,
    val local: HostApp?,
    val remote: HostRemoteApp?,
) {
    val name: String get() = local?.name ?: remote?.name ?: appId
    val versionName: String get() = local?.versionName ?: remote?.versionName ?: "1.0.0"
    val installed: Boolean get() = local?.installed == true
    val bundled: Boolean get() = local?.bundled == true
    val canOpen: Boolean get() = local != null
    val isRemoteOnly: Boolean get() = local == null && remote != null

    val hasUpdate: Boolean
        get() {
            val local = local ?: return false
            val remote = remote ?: return false
            return local.installed && remote.versionCode > local.versionCode
        }

    val needsInstall: Boolean
        get() {
            val remote = remote ?: return false
            if (remote.zip.isBlank() || installed || hasUpdate) return false
            return local == null || remote.versionCode > local.versionCode
        }

    val subtitle: String
        get() {
            val remote = remote
            if (remote != null && hasUpdate) return "v$versionName → v${remote.versionName}"
            if (installed) return "v$versionName · 已安装"
            if (bundled) return "v$versionName · 内置"
            if (remote != null) return "未安装 · v${remote.versionName}"
            return "v$versionName"
        }
}

// MARK: - Persistence

object HostCatalogStore {
    private const val PREFS = "dimina_host_catalog"

    fun loadConfig(context: Context): HostCatalogConfig {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("initialized", false)) return HostCatalogConfig.Default
        return HostCatalogConfig(
            source = prefs.getString("source", "").orEmpty(),
            channel = prefs.getString("channel", "prod").orEmpty().ifBlank { "prod" },
            authUser = prefs.getString("auth_user", "").orEmpty(),
            authPassword = prefs.getString("auth_password", "").orEmpty(),
            autoCheck = prefs.getBoolean("auto_check", true),
            wifiOnlyAutoDownload = prefs.getBoolean("wifi_only", true),
            autoInstall = prefs.getBoolean("auto_install", false),
            debugEnabled = prefs.getBoolean("debug_enabled", false),
        )
    }

    fun saveConfig(context: Context, config: HostCatalogConfig) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("initialized", true)
            .putString("source", config.source)
            .putString("channel", config.channel)
            .putString("auth_user", config.authUser)
            .putString("auth_password", config.authPassword)
            .putBoolean("auto_check", config.autoCheck)
            .putBoolean("wifi_only", config.wifiOnlyAutoDownload)
            .putBoolean("auto_install", config.autoInstall)
            .putBoolean("debug_enabled", config.debugEnabled)
            .apply()
    }

    fun cachedCatalog(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString("catalog", null)

    fun saveCatalog(context: Context, text: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("catalog", text)
            .apply()
    }

    fun etag(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("etag", null)

    fun saveEtag(context: Context, etag: String?) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("etag", etag)
            .apply()
    }

    fun lastSync(context: Context): Long? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong("last_sync", 0L)
            .takeIf { it > 0L }

    fun saveLastSync(context: Context, millis: Long) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong("last_sync", millis)
            .apply()
    }
}

// MARK: - Controller

class HostCatalogController(
    private val context: Context,
    private val scope: CoroutineScope,
) {
    var config by mutableStateOf(HostCatalogStore.loadConfig(context))
        private set
    var remoteApps by mutableStateOf<List<HostRemoteApp>>(emptyList())
        private set
    var syncState by mutableStateOf<HostSyncState>(HostSyncState.Idle)
        private set
    var lastSync by mutableStateOf<Long?>(
        HostCatalogStore.lastSync(context)
    )
        private set
    var transfers by mutableStateOf<Map<String, HostTransferState>>(emptyMap())
        private set
    var icons by mutableStateOf<Map<String, Bitmap>>(emptyMap())
        private set
    var diagnostics by mutableStateOf<List<String>>(emptyList())
        private set
    var isDiagnosing by mutableStateOf(false)
        private set
    var catalogError by mutableStateOf<String?>(null)
        private set

    private val downloadDir = File(context.cacheDir, "host-downloads").apply { mkdirs() }
    private val iconDir = File(context.cacheDir, "host-icons").apply { mkdirs() }
    private val iconTasks = ConcurrentHashMap.newKeySet<String>()

    init {
        restoreCachedCatalog()
        loadCachedIcons()
    }

    val hostVersion: String
        get() = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: "1.0.0"

    fun updateConfig(block: (HostCatalogConfig) -> HostCatalogConfig) {
        val next = block(config)
        if (next == config) return
        config = next
        HostCatalogStore.saveConfig(context, next)
    }

    fun resetSource() {
        updateConfig { it.copy(source = "") }
    }

    private val authHeaderValue: String?
        get() = HostCatalogConfig.basicAuthValue(config.authUser, config.authPassword)

    private fun HttpURLConnection.applyAuth() {
        authHeaderValue?.let { setRequestProperty("Authorization", it) }
    }

    fun catalogUrl(): String? = buildCatalogUrl(config.source, config.channel)

    fun packageUrl(remote: HostRemoteApp): String? {
        val base = catalogUrl() ?: return null
        return resolve(remote.zip, base)
    }

    fun iconUrl(remote: HostRemoteApp): String? {
        val raw = remote.icon ?: return null
        val base = catalogUrl() ?: return null
        return resolve(raw, base)
    }

    private fun resolve(raw: String, base: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        return runCatching {
            val baseUrl = URL(base)
            val url = URL(baseUrl, trimmed)
            if (url.protocol != "https" && url.protocol != "http") return null
            if (!url.host.equals(baseUrl.host, ignoreCase = true)) return null
            url.toString()
        }.getOrNull()
    }

    // MARK: Sync

    suspend fun sync(force: Boolean) {
        if (syncState is HostSyncState.Syncing) return
        val url = catalogUrl()
        if (url == null) {
            val message = "尚未配置应用源地址"
            catalogError = message
            syncState = HostSyncState.Failed(message)
            return
        }
        syncState = HostSyncState.Syncing

        val result = withContext(Dispatchers.IO) {
            runCatching {
                val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 20_000
                    readTimeout = 20_000
                    requestMethod = "GET"
                    setRequestProperty("Accept", "application/json")
                    applyAuth()
                    if (!force) {
                        HostCatalogStore.etag(context)?.let {
                            setRequestProperty("If-None-Match", it)
                        }
                    }
                }
                try {
                    val code = connection.responseCode
                    if (code == HttpURLConnection.HTTP_NOT_MODIFIED) {
                        return@runCatching SyncOutcome.NotModified
                    }
                    if (code !in 200..299) {
                        throw IOException("服务器返回 HTTP $code")
                    }
                    val text = connection.inputStream.bufferedReader().use { it.readText() }
                    val json = JSONObject(text)
                    val array = json.optJSONArray("apps") ?: JSONArray()
                    val apps = buildList {
                        for (index in 0 until array.length()) {
                            array.optJSONObject(index)?.let { HostRemoteApp.from(it) }?.let(::add)
                        }
                    }
                    HostCatalogStore.saveCatalog(context, text)
                    HostCatalogStore.saveEtag(context, connection.getHeaderField("ETag"))
                    SyncOutcome.Success(apps)
                } finally {
                    connection.disconnect()
                }
            }
        }

        result.onSuccess { outcome ->
            val now = System.currentTimeMillis()
            when (outcome) {
                is SyncOutcome.NotModified -> {
                    lastSync = now
                    HostCatalogStore.saveLastSync(context, now)
                    syncState = HostSyncState.Ok(now)
                    catalogError = null
                }
                is SyncOutcome.Success -> {
                    remoteApps = outcome.apps
                    lastSync = now
                    HostCatalogStore.saveLastSync(context, now)
                    syncState = HostSyncState.Ok(now)
                    catalogError = null
                    loadCachedIcons()
                    downloadMissingIcons()
                }
            }
        }.onFailure { error ->
            val message = describe(error)
            catalogError = message
            syncState = HostSyncState.Failed(message)
        }
    }

    private sealed interface SyncOutcome {
        data object NotModified : SyncOutcome
        data class Success(val apps: List<HostRemoteApp>) : SyncOutcome
    }

    private fun restoreCachedCatalog() {
        val text = HostCatalogStore.cachedCatalog(context) ?: return
        runCatching {
            val json = JSONObject(text)
            val array = json.optJSONArray("apps") ?: JSONArray()
            remoteApps = buildList {
                for (index in 0 until array.length()) {
                    array.optJSONObject(index)?.let { HostRemoteApp.from(it) }?.let(::add)
                }
            }
        }
    }

    // MARK: Icons

    private fun iconFile(appId: String): File = File(iconDir, appId.replace(Regex("[^A-Za-z0-9]"), "_") + ".png")

    /** 已缓存到本地的应用图标，供宿主启动小程序时展示。 */
    fun iconFileFor(appId: String): File? = iconFile(appId).takeIf { it.isFile }

    private fun loadCachedIcons() {
        val missing = remoteApps.filter { !icons.containsKey(it.appId) }
        if (missing.isEmpty()) return
        scope.launch(Dispatchers.IO) {
            val loaded = mutableMapOf<String, Bitmap>()
            missing.forEach { app ->
                val file = iconFile(app.appId)
                if (file.isFile) {
                    BitmapFactory.decodeFile(file.path)?.let { loaded[app.appId] = it }
                }
            }
            if (loaded.isNotEmpty()) {
                withContext(Dispatchers.Main) { icons = icons + loaded }
            }
        }
    }

    private fun downloadMissingIcons() {
        remoteApps.forEach { app ->
            if (icons.containsKey(app.appId)) return@forEach
            if (!iconTasks.add(app.appId)) return@forEach
            val url = iconUrl(app) ?: run {
                iconTasks.remove(app.appId)
                return@forEach
            }
            scope.launch(Dispatchers.IO) {
                try {
                    val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                        connectTimeout = 15_000
                        readTimeout = 20_000
                        applyAuth()
                    }
                    try {
                        if (connection.responseCode !in 200..299) return@launch
                        val bytes = connection.inputStream.use { it.readBytes() }
                        val file = iconFile(app.appId)
                        file.writeBytes(bytes)
                        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                        if (bitmap != null) {
                            withContext(Dispatchers.Main) { icons = icons + (app.appId to bitmap) }
                        }
                    } finally {
                        connection.disconnect()
                    }
                } catch (_: Exception) {
                    // Letter avatar stays as fallback.
                } finally {
                    iconTasks.remove(app.appId)
                }
            }
        }
    }

    // MARK: Install

    suspend fun install(remote: HostRemoteApp): Result<Unit> {
        val url = packageUrl(remote)
            ?: return Result.failure(IOException("安装包地址不合法"))
        val minimum = remote.minHostVersion
        if (!minimum.isNullOrBlank() && compareVersion(hostVersion, minimum) < 0) {
            val error = IOException("需要宿主版本 ≥ $minimum")
            transfers = transfers + (remote.appId to HostTransferState.Failed(error.message ?: ""))
            return Result.failure(error)
        }

        val destination = File(downloadDir, "${remote.appId.replace(Regex("[^A-Za-z0-9]"), "_")}-${remote.versionCode}.zip")
        transfers = transfers + (remote.appId to HostTransferState.Downloading(-1.0))

        return try {
            withContext(Dispatchers.IO) {
                download(url, destination) { done, total ->
                    transfers = transfers + (
                        remote.appId to HostTransferState.Downloading(
                            if (total > 0) done.toDouble() / total.toDouble() else -1.0
                        )
                        )
                }
            }

            val expected = remote.sha256?.trim().orEmpty()
            if (expected.isNotEmpty()) {
                transfers = transfers + (remote.appId to HostTransferState.Verifying)
                val actual = withContext(Dispatchers.IO) { sha256(destination) }
                if (!actual.equals(expected, ignoreCase = true)) {
                    throw IOException("安装包校验失败，文件可能损坏")
                }
            }

            transfers = transfers + (remote.appId to HostTransferState.Installing)
            val result = withContext(Dispatchers.Main) {
                kotlin.coroutines.suspendCoroutine { continuation ->
                    DiminaHolder.install(context, remote.appId, destination) { outcome ->
                        continuation.resume(outcome)
                    }
                }
            }
            destination.delete()
            if (result.isFailure) {
                throw result.exceptionOrNull() ?: IOException("安装失败")
            }
            transfers = transfers - remote.appId
            Result.success(Unit)
        } catch (error: Exception) {
            destination.delete()
            transfers = transfers + (remote.appId to HostTransferState.Failed(describe(error)))
            Result.failure(error)
        }
    }

    fun clearTransfer(appId: String) {
        transfers = transfers - appId
    }

    private fun download(url: String, destination: File, onProgress: (Long, Long) -> Unit) {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 20_000
            readTimeout = 60_000
            instanceFollowRedirects = true
            applyAuth()
        }
        try {
            val code = connection.responseCode
            if (code !in 200..299) throw IOException("下载失败：HTTP $code")
            val total = connection.contentLengthLong
            connection.inputStream.use { input ->
                destination.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var done = 0L
                    var lastReport = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                        done += read
                        val now = System.currentTimeMillis()
                        if (now - lastReport > 150) {
                            lastReport = now
                            onProgress(done, total)
                        }
                    }
                    onProgress(done, total)
                }
            }
        } finally {
            connection.disconnect()
        }
    }

    // MARK: Storage

    suspend fun storageSummary(): StorageSummary = withContext(Dispatchers.IO) {
        StorageSummary(
            installed = directorySize(File(context.filesDir, "jsapp")),
            downloads = directorySize(downloadDir),
            icons = directorySize(iconDir),
        )
    }

    fun clearDownloadCache() {
        downloadDir.deleteRecursively()
        downloadDir.mkdirs()
    }

    fun clearIconCache() {
        iconDir.deleteRecursively()
        iconDir.mkdirs()
        icons = emptyMap()
        loadCachedIcons()
        downloadMissingIcons()
    }

    private fun directorySize(dir: File): Long {
        if (!dir.exists()) return 0L
        return dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
    }

    // MARK: Diagnostics

    suspend fun runDiagnostics() {
        isDiagnosing = true
        val lines = mutableListOf<String>()
        try {
            val url = catalogUrl()
            if (url == null) {
                lines += "应用源：未配置"
                lines += "请回到设置填写 apps.json 地址"
                diagnostics = lines
                return
            }
            lines += "应用源：$url"
            val start = System.currentTimeMillis()
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                        connectTimeout = 15_000
                        readTimeout = 15_000
                        requestMethod = "GET"
                        setRequestProperty("Accept", "application/json")
                        applyAuth()
                    }
                    try {
                        val code = connection.responseCode
                        val text = if (code in 200..299) {
                            connection.inputStream.bufferedReader().use { it.readText() }
                        } else {
                            ""
                        }
                        DiagResponse(
                            code = code,
                            text = text,
                            contentType = connection.getHeaderField("Content-Type"),
                            etag = connection.getHeaderField("ETag"),
                        )
                    } finally {
                        connection.disconnect()
                    }
                }
            }
            val elapsed = System.currentTimeMillis() - start
            result.onSuccess { response ->
                lines += "HTTP：${response.code} · $elapsed ms"
                lines += when (response.code) {
                    401, 403 ->
                        if (config.authUser.isBlank()) {
                            "鉴权：站点要求凭据，请在设置里填写用户名和密码"
                        } else {
                            "鉴权：用户名或密码不正确（HTTP ${response.code}）"
                        }
                    in 200..299 ->
                        if (config.authUser.isBlank()) {
                            "鉴权：站点未启用密码访问（建议在宝塔开启）"
                        } else {
                            "鉴权：凭据有效"
                        }
                    else -> "鉴权：服务器拒绝了请求"
                }
                response.contentType?.let { lines += "Content-Type：$it" }
                response.etag?.let { lines += "ETag：$it" }
                lines += "TLS：${if (url.startsWith("https")) "HTTPS 已启用" else "未使用 HTTPS"}"
                val apps = runCatching {
                    val array = JSONObject(response.text).optJSONArray("apps") ?: JSONArray()
                    array.length()
                }.getOrNull()
                if (apps != null) {
                    lines += "目录：$apps 个应用"
                } else {
                    lines += "目录：响应不是合法的 apps.json"
                }
            }.onFailure {
                lines += "请求失败（$elapsed ms）：${describe(it)}"
            }

            val stat = android.os.StatFs(context.filesDir.absolutePath)
            lines += "磁盘可用：${formatBytes(stat.availableBytes)}"
            lines += "宿主版本：$hostVersion"
            val summary = storageSummary()
            lines += "下载缓存：${formatBytes(summary.downloads)}"
            lines += "图标缓存：${formatBytes(summary.icons)}"
        } finally {
            diagnostics = lines
            isDiagnosing = false
        }
    }

    // MARK: Helpers

    companion object {
        fun buildCatalogUrl(source: String, channel: String): String? {
            var text = source.trim()
            if (text.isEmpty()) return null
            if (!text.lowercase(Locale.US).endsWith(".json")) {
                if (!text.endsWith("/")) text += "/"
                text += "apps.json"
            }
            val uri = runCatching { Uri.parse(text) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase(Locale.US) ?: return null
            if (scheme != "https" && scheme != "http") return null
            if (uri.host.isNullOrBlank()) return null
            if (channel.isNotBlank() && channel != "prod") {
                return uri.buildUpon().appendQueryParameter("channel", channel).build().toString()
            }
            return uri.toString()
        }

        fun compareVersion(lhs: String, rhs: String): Int {
            val left = lhs.split(".").map { it.toIntOrNull() ?: 0 }
            val right = rhs.split(".").map { it.toIntOrNull() ?: 0 }
            val count = maxOf(left.size, right.size)
            for (index in 0 until count) {
                val a = left.getOrElse(index) { 0 }
                val b = right.getOrElse(index) { 0 }
                if (a != b) return if (a < b) -1 else 1
            }
            return 0
        }

        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        fun formatBytes(bytes: Long): String {
            if (bytes < 1024) return "$bytes B"
            val units = arrayOf("KB", "MB", "GB")
            var value = bytes / 1024.0
            var index = 0
            while (value >= 1024 && index < units.size - 1) {
                value /= 1024
                index++
            }
            return String.format(Locale.US, "%.1f %s", value, units[index])
        }

        fun describe(error: Throwable): String = when (error) {
            is UnknownHostException -> "无法解析域名，请检查应用源"
            is SocketTimeoutException -> "请求超时，请稍后重试"
            is SSLException -> "TLS 证书校验失败"
            is IOException -> error.message ?: "网络请求失败"
            else -> error.message ?: "未知错误"
        }
    }
}

data class StorageSummary(
    val installed: Long,
    val downloads: Long,
    val icons: Long,
)

private data class DiagResponse(
    val code: Int,
    val text: String,
    val contentType: String?,
    val etag: String?,
)

/** Thin adapter so catalog code does not depend on Activity. */
private object DiminaHolder {
    fun install(
        context: Context,
        appId: String,
        file: File,
        onComplete: (Result<JSONObject>) -> Unit,
    ) {
        com.didi.dimina.Dimina.getInstance()
            .installMiniProgram(appId, file.absolutePath, onComplete)
    }
}
