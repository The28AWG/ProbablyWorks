package com.the28awg.probably_works

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(this, RunService::class.java)
                        .putExtra(RunService.EXTRA_TITLE, call.argument<String>("title"))
                        .putExtra(RunService.EXTRA_TEXT, call.argument<String>("text"))
                        .putExtra(RunService.EXTRA_CHANNEL, call.argument<String>("channel"))
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    } catch (error: Exception) {
                        // Например, запуск из фона запрещён системой: ход продолжится без сервиса.
                        result.error("start_failed", error.message, null)
                    }
                }
                "stop" -> {
                    stopService(Intent(this, RunService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        private const val CHANNEL = "probably_works/run_service"
    }
}
