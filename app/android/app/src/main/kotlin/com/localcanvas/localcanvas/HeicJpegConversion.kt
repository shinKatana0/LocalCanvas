package com.localcanvas.localcanvas

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Decodes one HEIC/HEIF photo with Android's own decoder and writes it out as
 * a JPEG in this app's cache.
 *
 * This is the whole Android half of T-0280. The Dart side decides *which* file
 * to send here, from the file's own bytes; this side only decodes and encodes.
 *
 * WHY ImageDecoder AND NOT A LIBRARY. Converting a HEIC needs an HEVC decoder,
 * and the phone already has one: `ImageDecoder` (API 28) reads HEIF through
 * the platform's own media stack. Linking an image codec into the APK to
 * repeat something the system does is a dependency this app does not need.
 *
 * WHAT IT PROMISES, AND WHAT IT REFUSES TO PRETEND. `null` is a legitimate
 * answer and means "not converted": Android 8 and below have no HEIF decoder
 * at all, and a file this device cannot read is not an error worth a dialog.
 * The Dart side uploads the original and the gateway's own refusal (T-0127) is
 * what the person sees. An error result is reserved for a call that was
 * malformed, which is a programming mistake and not a phone's limitation.
 *
 * ORIENTATION. The picture must come out upright, and `ImageDecoder` is what
 * is relied on for it: unlike `BitmapFactory` it applies the source's own
 * orientation while decoding, so the bitmap handed to `compress` is already
 * the right way up and nothing here rotates it a second time. Rotating it here
 * as well would turn a correct picture on its side, which is why there is no
 * belt-and-braces `ExifInterface` pass.
 *
 * That is the decoder's behaviour as the platform states it, and it has NOT
 * been observed on a device from this repository: nothing here runs Android
 * code. It is on a foldable's smoke list -- photograph something in portrait, pick
 * it, and look at whether the preview stands up.
 *
 * THREADS. A camera photo is tens of megapixels and decoding one on the
 * platform thread would freeze the interface while the picker closes. The work
 * runs on a single background thread and the answer is posted back to the main
 * looper, because a `MethodChannel.Result` may only be answered there.
 */
class HeicJpegConversion(private val cacheDir: File) : MethodChannel.MethodCallHandler {

    private val workers: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != METHOD) {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("bad-arguments", "$METHOD needs a path", null)
            return
        }
        val quality = (call.argument<Int>("quality") ?: DEFAULT_QUALITY).coerceIn(1, 100)
        workers.execute {
            // Nothing that happens to one photo may take the app down with it:
            // an OutOfMemoryError on a very large picture is exactly the case
            // where uploading the original and letting the gateway speak is
            // better than a crash.
            val converted =
                try {
                    convert(File(path), quality)
                } catch (error: Throwable) {
                    null
                }
            main.post { result.success(converted) }
        }
    }

    /** Frees the decode thread. Called when the engine this is attached to goes. */
    fun dispose() {
        workers.shutdown()
    }

    /**
     * The path of the JPEG written, or `null` when this device did not produce
     * one.
     *
     * The version check is here, immediately before the only API 28 call, so
     * that it guards that call for the reader and for Android Lint alike.
     */
    private fun convert(source: File, quality: Int): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        if (!source.isFile) return null

        val bitmap =
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(source)) { decoder, _, _ ->
                // compress() cannot read a hardware bitmap's pixels. decodeBitmap
                // already defaults to software; saying so keeps the one thing this
                // whole method depends on from being an assumption.
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.isMutableRequired = false
            }
        try {
            val directory = File(cacheDir, DIRECTORY)
            if (!directory.isDirectory && !directory.mkdirs()) return null
            prune(directory)
            val jpeg = File.createTempFile(PREFIX, ".jpg", directory)
            var written = false
            try {
                FileOutputStream(jpeg).use { out ->
                    written = bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
                }
            } finally {
                // A half-written JPEG is worse than none: it would upload and
                // fail somewhere further along.
                if (!written) jpeg.delete()
            }
            return if (written) jpeg.absolutePath else null
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * Keeps this directory to the [KEEP] most recent conversions.
     *
     * A converted photo has to outlive the pick that produced it -- it is what
     * gets uploaded -- so it cannot be deleted on the way out, and a phone
     * whose owner picks a hundred photos would otherwise hold a hundred JPEGs
     * until Android next swept the cache. Several may be live at once (a form
     * with more than one picture field), hence a handful rather than one.
     *
     * It says where it believes it is before it deletes anything, and it
     * touches only files this class itself wrote: its own subdirectory, its own
     * name prefix, its own extension.
     */
    private fun prune(directory: File) {
        if (directory.name != DIRECTORY) return
        val ours =
            directory.listFiles { file ->
                file.isFile && file.name.startsWith(PREFIX) && file.name.endsWith(".jpg")
            }
                ?: return
        if (ours.size < KEEP) return
        val oldestFirst = ours.sortedBy { it.lastModified() }
        for (index in 0 until (ours.size - KEEP + 1)) {
            oldestFirst[index].delete()
        }
    }

    companion object {
        /** The channel name, matching `platform_image_converter.dart`. */
        const val CHANNEL = "com.localcanvas.localcanvas/heic_jpeg"

        const val METHOD = "heicToJpeg"

        /** Only ever used if the Dart side sent no quality; it always does. */
        const val DEFAULT_QUALITY = 92

        /** Under the app's own cache, so nothing else on the phone is touched. */
        const val DIRECTORY = "localcanvas_converted"

        const val PREFIX = "localcanvas-heic-"

        const val KEEP = 8
    }
}
