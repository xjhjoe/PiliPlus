#!/usr/bin/env python3
"""Patch Apache-2.0 LeanCast into a left/top safe-area DLNA receiver for old Android TVs."""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
src = root / "app/src/main/java/io/leancast/app"
assert (src / "PlayerActivity.kt").exists(), "LeanCast source tree not found"

# App id is distinct from LeanCast, so it does not overwrite the original app.
gradle = root / "app/build.gradle.kts"
body = gradle.read_text()
assert 'applicationId = "io.leancast"' in body
body = body.replace('applicationId = "io.leancast"', 'applicationId = "io.lefttop.cast"', 1)
body = body.replace('versionName = ciVersionName ?: "0.2.7"',
                    'versionName = ciVersionName ?: "0.1.0"', 1)
body = body.replace('versionCode = ciVersionCode ?: 10', 'versionCode = ciVersionCode ?: 1', 1)
gradle.write_text(body)

# Save screen-width and screen-height independently. The PlayerView preserves
# video aspect ratio itself (FIT), so user settings do not stretch the picture.
settings_path = src / "Settings.kt"
s = settings_path.read_text()
needle = '    var autostart: Boolean'
assert needle in s
addition = '''    var safeWidthPercent: Int
        get() = prefs.getInt("safe_width_pct", 75).coerceIn(40, 100)
        set(value) = prefs.edit().putInt("safe_width_pct", value.coerceIn(40, 100)).apply()

    var safeHeightPercent: Int
        get() = prefs.getInt("safe_height_pct", 75).coerceIn(40, 100)
        set(value) = prefs.edit().putInt("safe_height_pct", value.coerceIn(40, 100)).apply()

'''
s = s.replace(needle, addition + needle, 1)
settings_path.write_text(s)

# Keep the whole video, subtitle overlay and OSD INSIDE a top-left stage.
player_path = src / "PlayerActivity.kt"
p = player_path.read_text()
needle = '        playerView = PlayerView(this).apply {'
assert needle in p
p = p.replace(needle, '''        val stage = FrameLayout(this)
        root.addView(
            stage,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
                Gravity.TOP or Gravity.LEFT,
            ),
        )

''' + needle, 1)
assert '        root.addView(playerView)' in p
p = p.replace('        root.addView(playerView)', '        stage.addView(playerView)', 1)
for name in ['topBar', 'centerPill', 'bottomBar']:
    needle = '        root.addView(\n            ' + name + ','
    assert needle in p, 'cannot find ' + name
    p = p.replace(needle, '        stage.addView(\n            ' + name + ',', 1)
needle = '        setContentView(root)\n        CastBus.session?.addListener(sessionListener)'
assert needle in p
p = p.replace(needle, '''        setContentView(root)
        root.post {
            val prefs = Settings(this)
            val safeW = (root.width * prefs.safeWidthPercent / 100f).toInt().coerceAtLeast(1)
            val safeH = (root.height * prefs.safeHeightPercent / 100f).toInt().coerceAtLeast(1)
            stage.layoutParams = FrameLayout.LayoutParams(
                safeW, safeH, Gravity.TOP or Gravity.LEFT,
            )
        }
        CastBus.session?.addListener(sessionListener)''', 1)
player_path.write_text(p)

# A dedicated TV-remote dashboard: ALL visible content stays in the safe zone.
main = r'''package io.leancast.app

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import io.leancast.domain.cast.TransportState

class MainActivity : AppCompatActivity() {
    private lateinit var settings: Settings
    private lateinit var canvas: FrameLayout
    private lateinit var panel: LinearLayout
    private lateinit var widthRow: TextView
    private lateinit var heightRow: TextView
    private lateinit var serviceRow: TextView
    private lateinit var autostartRow: TextView
    private lateinit var detail: TextView

    private var row = 0
    private val ticker = Handler(Looper.getMainLooper())
    private val poll = object : Runnable {
        override fun run() {
            refresh()
            ticker.postDelayed(this, 1200L)
        }
    }

    override fun attachBaseContext(newBase: android.content.Context) {
        super.attachBaseContext(Settings.wrapLocale(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY

        canvas = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.TOP
            setPadding(dp(17), dp(12), dp(17), dp(9))
            setBackgroundColor(Color.rgb(13, 22, 37))
        }
        panel.addView(label("左上角投屏  LeftTop Cast", 22f, Color.WHITE, true))
        panel.addView(label("PiliPlus / 哔哩哔哩 · DLNA 接收器", 12f, 0xFF94A3B8.toInt()))
        panel.addView(label("↑↓ 选项目    ←→ 调尺寸    确认键切换服务", 12f, 0xFF67E8F9.toInt()))

        widthRow = rowText()
        heightRow = rowText()
        serviceRow = rowText()
        autostartRow = rowText()
        panel.addView(widthRow)
        panel.addView(heightRow)
        panel.addView(serviceRow)
        panel.addView(autostartRow)

        panel.addView(label("菜单键：恢复 75% × 75%   返回键：退出页面", 12f, 0xFF94A3B8.toInt()))
        detail = label("", 12f, 0xFFCBD5E1.toInt())
        panel.addView(detail)
        canvas.addView(panel)
        setContentView(canvas)
        canvas.post { resizeSafeArea() }
        // The receiver remains running even after closing this screen.
        ReceiverService.start(this)
        refresh()
    }

    override fun onResume() {
        super.onResume()
        ticker.post(poll)
    }

    override fun onPause() {
        ticker.removeCallbacks(poll)
        super.onPause()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density + 0.5f).toInt()

    private fun label(value: String, sp: Float, color: Int, bold: Boolean = false): TextView =
        TextView(this).apply {
            text = value
            textSize = sp
            setTextColor(color)
            if (bold) typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(2), dp(1), dp(2), dp(1))
        }

    private fun rowText(): TextView =
        label("", 16f, Color.WHITE, true).apply {
            setPadding(dp(11), dp(5), dp(11), dp(5))
            gravity = Gravity.CENTER_VERTICAL
        }

    private fun resizeSafeArea() {
        if (canvas.width == 0 || canvas.height == 0) return
        val width = (canvas.width * settings.safeWidthPercent / 100f).toInt().coerceAtLeast(1)
        val height = (canvas.height * settings.safeHeightPercent / 100f).toInt().coerceAtLeast(1)
        panel.layoutParams = FrameLayout.LayoutParams(width, height, Gravity.TOP or Gravity.LEFT)
        refresh()
    }

    private fun refresh() {
        if (!::widthRow.isInitialized) return
        widthRow.text = "画面宽度    " + settings.safeWidthPercent + "%   ◀  ▶"
        heightRow.text = "画面高度    " + settings.safeHeightPercent + "%   ◀  ▶"
        serviceRow.text = "DLNA 接收    " + (if (CastBus.session == null) "已停止" else "运行中") + "   [OK]"
        autostartRow.text = "开机启动    " + (if (settings.autostart) "已开启" else "已关闭") + "   [OK]"
        val rows = arrayOf(widthRow, heightRow, serviceRow, autostartRow)
        for (i in rows.indices) {
            val active = i == row
            val bg = GradientDrawable().apply {
                cornerRadius = dp(8).toFloat()
                setColor(if (active) 0xFF164E63.toInt() else 0xFF18273C.toInt())
                if (active) setStroke(dp(2), 0xFF38BDF8.toInt())
            }
            rows[i].background = bg
        }
        detail.text = "投屏设备： " + settings.friendlyName() +
            "\n地址： " + (CastBus.endpoint.ifBlank { "正在连接 Wi-Fi..." }) +
            "\n手机与电视连接同一个 Wi-Fi，PiliPlus 视频页点击 TV 投屏。"
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        return when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> {
                row = (row + 3) % 4
                refresh()
                true
            }
            KeyEvent.KEYCODE_DPAD_DOWN -> {
                row = (row + 1) % 4
                refresh()
                true
            }
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                val delta = if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) 5 else -5
                when (row) {
                    0 -> settings.safeWidthPercent = settings.safeWidthPercent + delta
                    1 -> settings.safeHeightPercent = settings.safeHeightPercent + delta
                }
                resizeSafeArea()
                true
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                when (row) {
                    2 -> if (CastBus.session == null) ReceiverService.start(this)
                         else ReceiverService.stop(this)
                    3 -> settings.autostart = !settings.autostart
                }
                refresh()
                true
            }
            KeyEvent.KEYCODE_MENU -> {
                settings.safeWidthPercent = 75
                settings.safeHeightPercent = 75
                resizeSafeArea()
                true
            }
            else -> super.onKeyDown(keyCode, event)
        }
    }
}
'''
(src / "MainActivity.kt").write_text(main)

# Standalone branding, with correct labels in both locales.
for values, title in [('values', 'LeftTop Cast'), ('values-zh', '左上角投屏')]:
    path = root / 'app/src/main/res' / values / 'strings.xml'
    t = path.read_text()
    t, n = re.subn(r'(<string name="app_name">).*?(</string>)',
                   lambda m: m.group(1) + title + m.group(2), t, count=1)
    assert n == 1
    path.write_text(t)

print("Patched LeftTop Cast 0.1.0, targeting Android 5.0+")
