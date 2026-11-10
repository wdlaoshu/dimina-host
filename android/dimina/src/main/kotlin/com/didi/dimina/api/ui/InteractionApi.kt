package com.didi.dimina.api.ui

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.toColorInt
import com.didi.dimina.R
import com.didi.dimina.api.APIResult
import com.didi.dimina.api.AsyncResult
import com.didi.dimina.api.BaseApiHandler
import com.didi.dimina.api.NoneResult
import com.didi.dimina.common.ApiUtils
import com.didi.dimina.ui.container.DiminaActivity
import org.json.JSONObject

private const val MODAL_MAX_HEIGHT_FRACTION = 0.9f

/**
 * Author: Doslin
 */
class InteractionApi : BaseApiHandler() {
    private companion object {
        const val SHOW_TOAST = "showToast"
        const val SHOW_MODAL = "showModal"
        const val SHOW_LOADING = "showLoading"
        const val HIDE_TOAST = "hideToast"
        const val HIDE_LOADING = "hideLoading"
        const val SHOW_ACTION_SHEET = "showActionSheet"
    }

    override val apiNames = setOf(SHOW_TOAST, SHOW_MODAL, SHOW_LOADING, HIDE_TOAST, HIDE_LOADING, SHOW_ACTION_SHEET)

    private var handler = Handler(Looper.getMainLooper())

    // Toast management
    private var dismissToast: Runnable? = null
    private var currentToastView: ComposeView? = null
    private var currentMaskView: View? = null
    private var currentModalView: ComposeView? = null
    private var currentModalMaskView: View? = null

    override fun handleAction(
        activity: DiminaActivity,
        appId: String,
        apiName: String,
        params: JSONObject,
        responseCallback: (String) -> Unit,
    ): APIResult {
        return when (apiName) {
            SHOW_TOAST -> {
                val title = params.getString("title") // Required
                val icon = params.optString("icon", "success") // Optional, default "success"
                val duration = params.optInt("duration", 1500) // Optional, default 1500
                val mask = params.optBoolean("mask", false) // Optional, default false
                showToast(
                    context = activity,
                    title = title,
                    icon = icon,
                    duration = duration,
                    mask = mask
                )
                AsyncResult(JSONObject().apply {
                    put("errMsg", "$SHOW_TOAST:ok")
                })
            }

            SHOW_MODAL -> {
                val title = params.optString("title", "")
                val content = params.optString("content", "")
                val showCancel = params.optBoolean("showCancel", true)
                val cancelText = params.optString("cancelText", "取消")
                val cancelColor = params.optString("cancelColor", "#000000")
                val confirmText = params.optString("confirmText", "确定")
                val confirmColor = params.optString("confirmColor", "#576B95")

                activity.cancelActiveWebViewTouch()
                showModal(
                    context = activity,
                    title = title,
                    content = content,
                    showCancel = showCancel,
                    cancelText = cancelText,
                    cancelColor = cancelColor,
                    confirmText = confirmText,
                    confirmColor = confirmColor
                ) { isConfirmed ->
                    val resultData = JSONObject().apply {
                        put("confirm", isConfirmed)
                        put("cancel", !isConfirmed)
                        put("errMsg", "$SHOW_MODAL:ok")
                    }
                    ApiUtils.invokeSuccess(params, resultData, responseCallback)
                    ApiUtils.invokeComplete(params, responseCallback)
                    return@showModal
                }
                NoneResult()
            }

            SHOW_LOADING -> {
                val title = params.getString("title") // Required
                val mask = params.optBoolean("mask", false) // Optional, default false
                showToast(
                    context = activity,
                    title = title,
                    icon = "loading",
                    duration = Int.MAX_VALUE,
                    mask = mask
                )
                AsyncResult(JSONObject().apply {
                    put("errMsg", "$SHOW_LOADING:ok")
                })
            }

            HIDE_TOAST -> {
                hideToast(activity)

                AsyncResult(JSONObject().apply {
                    put("errMsg", "$HIDE_TOAST:ok")
                })
            }

            HIDE_LOADING -> {
                hideToast(activity)

                AsyncResult(JSONObject().apply {
                    put("errMsg", "$HIDE_LOADING:ok")
                })
            }

            SHOW_ACTION_SHEET-> {
                val itemColor = params.optString("itemColor", "#000000")
                val itemList = params.optJSONArray("itemList")
                val list = itemList?.let {
                    (0 until it.length()).map { index -> it.getString(index) }
                } ?: emptyList<String>()

                activity.showActionSheet(list, itemColor) { index ->
                    if (index == -1) {
                        val resultData = JSONObject().apply {
                            put("errMsg", "$SHOW_ACTION_SHEET:fail cancel")
                        }
                        ApiUtils.invokeFail(params, resultData, responseCallback)
                    } else {
                        val resultData = JSONObject().apply {
                            put("tapIndex", index)
                            put("errMsg", "$SHOW_ACTION_SHEET:ok")
                        }
                        ApiUtils.invokeSuccess(params, resultData, responseCallback)
                    }
                    ApiUtils.invokeComplete(params, responseCallback)
                }
                NoneResult()
            }

            else -> super.handleAction(activity, appId, apiName, params, responseCallback)
        }
    }

    /**
     * Displays a custom modal using Jetpack Compose, centered on the screen.
     */
    private fun showModal(
        context: Context,
        title: String,
        content: String,
        showCancel: Boolean,
        cancelText: String,
        cancelColor: String,
        confirmText: String,
        confirmColor: String,
        onResult: (Boolean) -> Unit,
    ) {
        handler.post {
            val rootView = (context as Activity).window.decorView.rootView as ViewGroup

            // Remove any existing modal
            currentModalView?.let {
                rootView.removeView(it)
                currentModalView = null
            }

            currentModalMaskView?.let {
                rootView.removeView(it)
                currentModalMaskView = null
            }

            // Add mask
            val maskView = View(context).apply {
                setBackgroundColor(0x80000000.toInt())
                isClickable = true
            }
            rootView.addView(
                maskView,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            )
            currentModalMaskView = maskView

            // Add modal
            val composeView = ComposeView(context).apply {
                setContent {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .wrapContentSize(Alignment.Center)
                    ) {
                        ModalContent(
                            title = title,
                            content = content,
                            showCancel = showCancel,
                            cancelText = cancelText,
                            cancelColor = Color(cancelColor.toColorInt()),
                            confirmText = confirmText,
                            confirmColor = Color(confirmColor.toColorInt()),
                            onCancel = {
                                rootView.removeView(maskView)
                                rootView.removeView(currentModalView)
                                currentModalView = null
                                onResult(false)
                            },
                            onConfirm = {
                                rootView.removeView(maskView)
                                rootView.removeView(currentModalView)
                                currentModalView = null
                                onResult(true)
                            }
                        )
                    }
                }
            }
            rootView.addView(
                composeView,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            )
            currentModalView = composeView
        }
    }

    /**
     * Hides the currently displayed toast.
     */
    private fun hideToast(context: Context) {
        // Serialize hide with show, including calls arriving from the service thread.
        handler.post { removeCurrentToast() }
    }

    private fun removeCurrentToast() {
        dismissToast?.let { handler.removeCallbacks(it) }
        dismissToast = null
        // The caller may now be on another Activity. Remove from the owning parent.
        currentToastView?.let {
            (it.parent as? ViewGroup)?.removeView(it)
            it.disposeComposition()
        }
        currentToastView = null
        currentMaskView?.let { (it.parent as? ViewGroup)?.removeView(it) }
        currentMaskView = null
    }

    private fun showToast(
        context: Context,
        title: String,
        icon: String? = "success",
        duration: Int = 1500,
        mask: Boolean = false,
    ) {

        handler.post {
            // Only cancel the old timeout; queued API calls must retain FIFO order.
            removeCurrentToast()
            val activity = context as Activity
            if (activity.isFinishing || activity.isDestroyed) return@post
            val rootView = activity.window.decorView.rootView as ViewGroup

            if (mask) {
                val maskView = View(context).apply {
                    setBackgroundColor(0x80000000.toInt())
                    isClickable = true
                }
                rootView.addView(
                    maskView,
                    ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                    )
                )
                currentMaskView = maskView // Store reference

            }

            val composeView = ComposeView(context).apply {
                setContent {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .wrapContentSize(Alignment.Center)
                    ) {
                        ToastContent(
                            title = title,
                            icon = icon,
                            duration = duration.toLong()
                        )
                    }
                }
            }
            rootView.addView(
                composeView,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            )
            currentToastView = composeView // Store reference

            // A timeout belongs to this presentation, never to a later loading/toast.
            if (duration != Int.MAX_VALUE) {
                val dismiss = Runnable {
                    if (currentToastView === composeView) removeCurrentToast()
                }
                dismissToast = dismiss
                handler.postDelayed(dismiss, duration.toLong().coerceAtLeast(0))
            }
        }
    }
}

@Composable
fun ToastContent(
    title: String,
    icon: String?,
    duration: Long,
) {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { visible = true }

    val alpha by animateFloatAsState(
        targetValue = if (visible) 1f else 0f,
        animationSpec = tween(durationMillis = 160),
        label = "toastAlpha",
    )
    val scale by animateFloatAsState(
        targetValue = if (visible) 1f else 0.94f,
        animationSpec = spring(dampingRatio = 0.82f, stiffness = Spring.StiffnessMediumLow),
        label = "toastScale",
    )

    val hasBadge = icon == "success" || icon == "error" || icon == "loading"
    val shape = RoundedCornerShape(18.dp)

    // 深色毛玻璃卡片：宽度随文案自适应，不再固定 120x120 的灰方块。
    Row(
        modifier = Modifier
            .widthIn(min = if (hasBadge) 108.dp else 84.dp, max = 300.dp)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                this.alpha = alpha
            }
            .shadow(18.dp, shape)
            .background(Color(0xF01F1F22), shape)
            .border(1.dp, Color.White.copy(alpha = 0.12f), shape)
            .padding(
                start = if (hasBadge) 15.dp else 20.dp,
                end = if (hasBadge) 18.dp else 20.dp,
                top = 13.dp,
                bottom = 13.dp,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        when (icon) {
            "success" -> ToastBadge(tint = Color(0xFF34C759), drawableRes = R.drawable.ic_success)
            "error" -> ToastBadge(tint = Color(0xFFFF453A), drawableRes = R.drawable.ic_error)
            "loading" -> CircularProgressIndicator(
                color = Color.White,
                modifier = Modifier.size(22.dp),
                strokeWidth = 2.dp,
            )

            else -> Unit
        }

        Text(
            text = title,
            color = Color.White.copy(alpha = 0.96f),
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            textAlign = if (hasBadge) TextAlign.Start else TextAlign.Center,
            maxLines = 4,
        )
    }
}

/** 语义色圆底 + 白色符号，和宿主壳的提示样式保持一致。 */
@Composable
private fun ToastBadge(tint: Color, drawableRes: Int) {
    Box(
        modifier = Modifier
            .size(22.dp)
            .background(tint.copy(alpha = 0.2f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painter = painterResource(id = drawableRes),
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(13.dp),
        )
    }
}

/**
 * Composable function to define the modal UI.
 */
@Composable
fun ModalContent(
    title: String,
    content: String,
    showCancel: Boolean,
    cancelText: String,
    cancelColor: Color,
    confirmText: String,
    confirmColor: Color,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
) {
    BoxWithConstraints {
        val contentScrollState = rememberScrollState()
        Column(
            modifier = Modifier
                .width(280.dp)
                .heightIn(max = maxHeight * MODAL_MAX_HEIGHT_FRACTION)
                .background(Color.White, RoundedCornerShape(8.dp))
                .padding(top = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // Title
            if (title.isNotEmpty()) {
                Text(
                    text = title,
                    color = Color.Black,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 24.dp, end = 24.dp, bottom = 8.dp)
                )
            }

            // Content
            if (content.isNotEmpty()) {
                Box(
                    modifier = Modifier
                        .weight(1f, fill = false)
                        .fillMaxWidth()
                        .verticalScroll(contentScrollState)
                        .padding(start = 24.dp, top = 12.dp, end = 24.dp, bottom = 20.dp)
                ) {
                    Text(
                        text = content,
                        color = Color(0xFF7F7F7F),
                        fontSize = 16.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            HorizontalDivider(
                modifier = Modifier
                    .height(1.dp)
                    .fillMaxWidth(),
                color = Color.LightGray
            )

            // Buttons
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                if (showCancel) {
                    TextButton(
                        onClick = onCancel,
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight()
                    ) {
                        Text(
                            text = cancelText.take(4),
                            color = cancelColor,
                            fontSize = 16.sp
                        )
                    }

                    VerticalDivider(
                        modifier = Modifier
                            .width(1.dp)
                            .fillMaxHeight(),
                        color = Color.LightGray
                    )
                }

                TextButton(
                    onClick = onConfirm,
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                ) {
                    Text(
                        text = confirmText.take(4),
                        color = confirmColor,
                        fontSize = 16.sp
                    )
                }
            }
        }
    }
}
