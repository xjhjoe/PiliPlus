package io.leancast.app

import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * LeftTopCast: TV-friendly controls that never extend into a damaged right strip.
 * DPAD up/down selects a row; DPAD left/right changes its value.
 */
class MainActivity : AppCompatActivity() {
    private lateinit var settings: Settings
    private lateinit var screen: FrameLayout
    private lateinit var safePanel: LinearLayout
    private lateinit var widthRow: TextView
    private lateinit var heightRow: TextView
    private lateinit var autoRow: TextView
    private lateinit var serviceRow: TextView
    private lateinit var stateLine: TextView
    private val minPercent = 40
    private val maxPercent = 100
    private val step = 5

    override fun attachBaseContext(newBase: android.content.Context) {
        super.attachBaseContext(Settings.wrapLocale(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = 5894 or 1024 or 512

        screen = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        safePanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(12), dp(18), dp(10))
            background = GradientDrawable().apply {
                setColor(Color.rgb(13, 22, 37))
            }
        }

        addLabel("LeftTopCast  ·  左上角投屏", 22f, Color.WHITE, bold = true)
        addLabel("PiliPlus / 哔哩哔哩 DLNA 接收器", 13f, Color.rgb(148, 163, 184))
        widthRow = actionRow { adjustWidth(step) }
        heightRow = actionRow { adjustHeight(step) }
        autoRow = actionRow {
            settings.autostart = !settings.autostart
            render()
        }
        serviceRow = actionRow {
            if (CastBus.session == null) ReceiverService.start(this)
            else ReceiverService.stop(this)
            render()
        }
        actionRow {
            settings.safeWidthPercent = 75
            settings.safeHeightPercent = 75
            applySafeRect()
            render()
        }.text = "恢复默认画面 (75% × 75%)"
        stateLine = addLabel("", 12f, Color.rgb(125, 211, 252))
        addLabel("↑↓ 选择项目   ←→ 调宽高   OK 确认", 12f, Color.rgb(148, 163, 184))

        screen.addView(safePanel)
        setContentView(screen)
        applySafeRect()
        render()
        widthRow.requestFocus()
        ReceiverService.start(this)
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun addLabel(value: String, size: Float, color: Int, bold: Boolean = false): TextView {
        val view = TextView(this).apply {
            text = value
            setTextSize(size)
            setTextColor(color)
            gravity = Gravity.CENTER_VERTICAL
            if (bold) typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(3), dp(3), dp(3), dp(4))
        }
        safePanel.addView(view)
        return view
    }

    private fun actionRow(onClick: () -> Unit): TextView {
        val view = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(17f)
            gravity = Gravity.CENTER_VERTICAL
            isFocusable = true
            isClickable = true
            setPadding(dp(13), dp(7), dp(8), dp(7))
            background = bg(false)
            setOnFocusChangeListener { v, focused -> v.background = bg(focused) }
            setOnClickListener { onClick() }
        }
        safePanel.addView(view, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = dp(5) })
        return view
    }

    private fun bg(focused: Boolean) = GradientDrawable().apply {
        setColor(if (focused) Color.rgb(35, 77, 115) else Color.rgb(29, 44, 64))
        cornerRadius = dp(8).toFloat()
        setStroke(dp(if (focused) 2 else 1), if (focused) Color.CYAN else Color.rgb(43, 61, 83))
    }

    private fun adjustWidth(delta: Int) {
        settings.safeWidthPercent = (settings.safeWidthPercent + delta).coerceIn(minPercent, maxPercent)
        applySafeRect()
        render()
    }

    private fun adjustHeight(delta: Int) {
        settings.safeHeightPercent = (settings.safeHeightPercent + delta).coerceIn(minPercent, maxPercent)
        applySafeRect()
        render()
    }

    private fun applySafeRect() {
        val metrics = resources.displayMetrics
        val w = (metrics.widthPixels * settings.safeWidthPercent / 100f).toInt().coerceAtLeast(1)
        val h = (metrics.heightPixels * settings.safeHeightPercent / 100f).toInt().coerceAtLeast(1)
        val lp = FrameLayout.LayoutParams(w, h, Gravity.TOP or Gravity.LEFT)
        safePanel.layoutParams = lp
    }

    private fun render() {
        widthRow.text = "可视宽度  " + settings.safeWidthPercent + "%  （← -5% / → +5%）"
        heightRow.text = "可视高度  " + settings.safeHeightPercent + "%  （← -5% / → +5%）"
        autoRow.text = "开机自动接收  " + if (settings.autostart) "开" else "关"
        serviceRow.text = "投屏接收  " + if (CastBus.session != null) "运行中 (OK 停止)" else "未运行 (OK 启动)"
        stateLine.text = "设备名：" + settings.friendlyName() + "    同一 Wi-Fi 下使用 TV 投屏"
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (currentFocus == widthRow) {
            if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT) { adjustWidth(-step); return true }
            if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) { adjustWidth(step); return true }
        }
        if (currentFocus == heightRow) {
            if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT) { adjustHeight(-step); return true }
            if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) { adjustHeight(step); return true }
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density + .5f).toInt()
}
