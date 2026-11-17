#!/usr/bin/env python3
"""Apply LeftTopCast TV safe-area UI to the Apache-2.0 LeanCast receiver."""
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "leancast" / "app" / "src" / "main"
KT = APP / "java" / "io" / "leancast" / "app"

# Retain LeanCast's renderer and UPnP implementation, only replace TV UI.
shutil.copyfile(ROOT / "lefttopcast" / "MainActivity.kt", KT / "MainActivity.kt")

settings = KT / "Settings.kt"
source = settings.read_text()
needle = "    companion object {"
assert source.count(needle) == 1
source = source.replace(needle, """
    /** Persisted fraction of the physical TV panel that still works. */
    var safeWidthPercent: Int
        get() = prefs.getInt("safe_width_percent", 75).coerceIn(40, 100)
        set(value) = prefs.edit().putInt("safe_width_percent", value.coerceIn(40, 100)).apply()

    var safeHeightPercent: Int
        get() = prefs.getInt("safe_height_percent", 75).coerceIn(40, 100)
        set(value) = prefs.edit().putInt("safe_height_percent", value.coerceIn(40, 100)).apply()

""" + needle)
settings.write_text(source)

player = KT / "PlayerActivity.kt"
source = player.read_text()
start = source.index("    override fun onCreate(savedInstanceState: Bundle?) {")
end = source.index("    override fun onDestroy() {", start)
new_create = """
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = 5894 or 1024 or 512

        // The full TV display stays black. Only the physical top-left rectangle
        // contains content. Restrict BOTH player and OSD to the same frame.
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        val safeViewport = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            clipChildren = true
            clipToPadding = true
        }
        val settings = Settings(this)
        val metrics = resources.displayMetrics
        val safeWidth = (metrics.widthPixels * settings.safeWidthPercent / 100f)
            .toInt().coerceAtLeast(1)
        val safeHeight = (metrics.heightPixels * settings.safeHeightPercent / 100f)
            .toInt().coerceAtLeast(1)

        playerView = PlayerView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            useController = false
            isFocusable = false
            // Preserve video aspect ratio; letterboxing is inside safe viewport.
            resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT
        }
        safeViewport.addView(playerView)

        topBar = buildTopBar()
        centerPill = buildCenterPill()
        bottomBar = buildBottomBar()
        safeViewport.addView(
            topBar, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP
            )
        )
        safeViewport.addView(
            centerPill, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        )
        safeViewport.addView(
            bottomBar, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM
            )
        )
        root.addView(
            safeViewport,
            FrameLayout.LayoutParams(safeWidth, safeHeight, Gravity.TOP or Gravity.LEFT)
        )
        setContentView(root)
        CastBus.session?.addListener(sessionListener)
        showOsdBars(persistent = false)
    }

"""
source = source[:start] + new_create + source[end:]
player.write_text(source)

# Distinguishable DLNA renderer name without disrupting the upstream renderer.
for p in [APP / "res" / "values" / "strings.xml",
          APP / "res" / "values-zh" / "strings.xml"]:
    s = p.read_text()
    s, count = re.subn(
        r'(<string name="app_name">)[^<]+(</string>)',
        r'\g<1>LeftTopCast TV\g<2>',
        s,
        count=1
    )
    assert count == 1, p
    p.write_text(s)

# Separate app ID so installing this cannot replace the existing LeanCast.
gradle = ROOT / "leancast" / "app" / "build.gradle.kts"
s = gradle.read_text().replace('applicationId = "io.leancast"', 'applicationId = "io.lefttopcast.tv"')
s = s.replace('versionName = ciVersionName ?: "0.2.7"', 'versionName = ciVersionName ?: "1.0.0"')
assert 'applicationId = "io.lefttopcast.tv"' in s
gradle.write_text(s)
print("LeftTopCast patch applied.")
