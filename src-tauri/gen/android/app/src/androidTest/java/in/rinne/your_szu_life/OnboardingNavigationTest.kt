package `in`.rinne.your_szu_life

import android.os.SystemClock
import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.WebViewFeature
import androidx.lifecycle.Lifecycle
import org.json.JSONObject
import org.json.JSONTokener
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 在新建模拟器的空测试应用中运行；不会填写凭据、注销或清除现有账户。 */
class OnboardingNavigationTest {
  private fun webView(view: View): WebView? {
    if (view is WebView) return view
    if (view is ViewGroup) {
      for (index in 0 until view.childCount) webView(view.getChildAt(index))?.let { return it }
    }
    return null
  }

  private fun evaluate(scenario: ActivityScenario<MainActivity>, expression: String): JSONObject {
    val finished = CountDownLatch(1)
    var result: String? = null
    scenario.onActivity { activity ->
      val target = webView(activity.window.decorView)
      if (target == null) {
        result = "null"
        finished.countDown()
      } else {
        target.evaluateJavascript(expression) { value -> result = value; finished.countDown() }
      }
    }
    assertTrue("WebView evaluation timed out", finished.await(10, TimeUnit.SECONDS))
    val decoded = JSONTokener(checkNotNull(result)).nextValue()
    return if (decoded is String) JSONObject(decoded) else JSONObject()
  }

  private val snapshot = """
    JSON.stringify((function() {
      var button = Array.from(document.querySelectorAll('m-button')).find(function(el) {
        return el.textContent.trim() === '登录并继续';
      });
      var rect = button && button.getBoundingClientRect();
      var hit = rect && document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2);
      return {ready: document.querySelectorAll('.settings-form m-text-field').length === 2 && !!button,
        navCount: document.querySelectorAll('m-navigation-bar,m-navigation-rail').length,
        clickable: !!button && !button.disabled && hit === button,
        x: rect ? rect.x + rect.width / 2 : 0, y: rect ? rect.y + rect.height / 2 : 0,
        width: innerWidth, height: innerHeight,
        userAgent: navigator.userAgent, cssHasSupported: CSS.supports('selector(:has(*))'),
        validated: Array.from(document.querySelectorAll('m-snackbar')).some(function(el) {
          return (el.getAttribute('message') || '').indexOf('校园卡号必须是 6 位数字') >= 0;
        })};
    })())
  """.trimIndent()

  @Test fun loginActionRemainsTouchableWhenHasSelectorsAreUnavailable() {
    val scenario = ActivityScenario.launch(MainActivity::class.java)
    try {
      // First WebView startup and software shader compilation take longer on a shared host.
      val deadline = SystemClock.uptimeMillis() + 45000
      var state = JSONObject()
      while (SystemClock.uptimeMillis() < deadline) {
        state = evaluate(scenario, snapshot)
        if (state.optBoolean("ready")) break
        SystemClock.sleep(200)
      }
      val baseline = JSONObject()
        .put("userAgent", state.optString("userAgent", "unavailable"))
        .put("viewportWidthCssPx", state.optInt("width"))
        .put("viewportHeightCssPx", state.optInt("height"))
        .put("cssHasSupported", state.optBoolean("cssHasSupported"))
        .put("frontendReady", state.optBoolean("ready"))
        .put("navigationCount", state.optInt("navCount", -1))
        .put("buttonClickable", state.optBoolean("clickable"))
        .put("getCookieInfoSupported", WebViewFeature.isFeatureSupported(WebViewFeature.GET_COOKIE_INFO))
      InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
        putString("stream", "WEBVIEW_BASELINE: $baseline\n")
      })
      assertTrue("Requires a fresh test app and a WebView able to load the frontend", state.optBoolean("ready"))
      evaluate(scenario, """
        JSON.stringify((function() {
          function prune(owner) {
            for (var i = owner.cssRules.length - 1; i >= 0; i--) {
              var rule = owner.cssRules[i];
              if (rule.selectorText && rule.selectorText.indexOf(':has(') >= 0) owner.deleteRule(i);
              else if (rule.cssRules) prune(rule);
            }
          }
          Array.from(document.styleSheets).forEach(function(sheet) {try {prune(sheet);} catch (_) {}});
          return {removed:true};
        })())
      """.trimIndent())
      state = evaluate(scenario, snapshot)
      assertEquals(0, state.getInt("navCount"))
      assertTrue("Login action is covered or disabled", state.getBoolean("clickable"))
      scenario.onActivity { activity ->
        val target = checkNotNull(webView(activity.window.decorView))
        val x = (state.getDouble("x") * target.width / state.getInt("width")).toFloat()
        val y = (state.getDouble("y") * target.height / state.getInt("height")).toFloat()
        val now = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x, y, 0)
        val up = MotionEvent.obtain(now, now + 50, MotionEvent.ACTION_UP, x, y, 0)
        try { target.dispatchTouchEvent(down); target.dispatchTouchEvent(up) }
        finally { down.recycle(); up.recycle() }
      }
      val validationDeadline = SystemClock.uptimeMillis() + 3000
      while (SystemClock.uptimeMillis() < validationDeadline) {
        if (evaluate(scenario, snapshot).optBoolean("validated")) return
        SystemClock.sleep(100)
      }
      fail("Touch did not reach the credential validation handler")
    } finally {
      // Destroying Tauri's last Activity exits the process that also runs AndroidJUnitRunner.
      // Stop the Activity first; native-test lets the runner report results before process exit.
      scenario.moveToState(Lifecycle.State.CREATED)
    }
  }
}
