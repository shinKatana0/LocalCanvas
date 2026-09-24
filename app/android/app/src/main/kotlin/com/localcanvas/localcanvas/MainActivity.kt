package com.localcanvas.localcanvas

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The one activity, plus the one channel this app writes itself.
 *
 * Everything else the app reaches the platform through is a published plugin
 * that registers itself. `HeicJpegConversion` is not: it is a dozen lines
 * around `ImageDecoder` that exist only for T-0280, and wiring them here is
 * smaller than a plugin would be.
 */
class MainActivity : FlutterActivity() {

    private var conversionChannel: MethodChannel? = null
    private var conversion: HeicJpegConversion? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The app's own cache directory, not the activity's: it outlives a
        // configuration change, which a fold is.
        val handler = HeicJpegConversion(applicationContext.cacheDir)
        val channel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HeicJpegConversion.CHANNEL)
        channel.setMethodCallHandler(handler)
        conversionChannel = channel
        conversion = handler
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        conversionChannel?.setMethodCallHandler(null)
        conversionChannel = null
        conversion?.dispose()
        conversion = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
