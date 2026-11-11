package com.didi.dimina.core

/** SDK defaults, not a promise about another client's cache capacity. */
data class RetentionPolicy(
    val maxBackgroundApps: Int = 3,
    // 默认常驻：不因超时而回收；为 0 时后台实例只受数量上限与内存压力约束。
    val backgroundTimeoutMs: Long = 0,
) {
    init {
        require(maxBackgroundApps >= 0) { "maxBackgroundApps must be non-negative" }
        require(backgroundTimeoutMs >= 0) { "backgroundTimeoutMs must be non-negative" }
    }
}

/** Pure policy: timestamps are monotonic, duplicate hide never extends the lease. */
internal class BackgroundRetention {
    var policy = RetentionPolicy()
    private val hidden = linkedMapOf<String, Long>()
    fun hide(id: String, now: Long) { hidden.putIfAbsent(id, now) }
    fun forget(id: String) { hidden.remove(id) }
    fun clear() { hidden.clear() }
    fun collect(now: Long, pressure: Boolean, canEvict: (String) -> Boolean): List<String> {
        val candidates = hidden.entries.filter { canEvict(it.key) }.sortedBy { it.value }
        val victims = mutableListOf<String>()
        for ((id, since) in candidates) {
            if (pressure || candidates.size - victims.size > policy.maxBackgroundApps ||
                (policy.backgroundTimeoutMs > 0 && now - since >= policy.backgroundTimeoutMs)) {
                victims.add(id)
                hidden.remove(id)
            }
        }
        return victims
    }
    fun nextDelay(now: Long, canEvict: (String) -> Boolean): Long? {
        if (policy.backgroundTimeoutMs == 0L) return null
        val since = hidden.filterKeys(canEvict).values.minOrNull() ?: return null
        return (policy.backgroundTimeoutMs - (now - since)).coerceAtLeast(1)
    }
}
