package com.dreamtapir.host

import android.app.Application
import com.didi.dimina.Dimina
import com.didi.dimina.core.RetentionPolicy

class App: Application() {
    override fun onCreate() {
        super.onCreate()
        // 调试开关放在设置里，默认关闭；这里按上次保存的设置初始化。
        val config = HostCatalogStore.loadConfig(this)
        Dimina.init(this, Dimina.DiminaConfig.Builder()
            .setDebugMode(config.debugEnabled)
            .build()
        )
        applyRetention(config.maxBackgroundApps)
    }

    companion object {
        /** 后台常驻：不超时回收，只保留 maxBackgroundApps 个，超出杀最久未用的。 */
        fun applyRetention(maxBackgroundApps: Int) {
            Dimina.getInstance().configureRetention(
                RetentionPolicy(maxBackgroundApps = maxBackgroundApps, backgroundTimeoutMs = 0)
            )
        }
    }
}