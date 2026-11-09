package com.dreamtapir.host

import android.app.Application
import com.didi.dimina.Dimina

class App: Application() {
    override fun onCreate() {
        super.onCreate()
        // 调试开关放在设置里，默认关闭；这里按上次保存的设置初始化。
        val debugEnabled = HostCatalogStore.loadConfig(this).debugEnabled
        Dimina.init(this, Dimina.DiminaConfig.Builder()
            .setDebugMode(debugEnabled)
            .build()
        )
    }
}