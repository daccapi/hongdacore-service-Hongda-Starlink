package com.hongda.starlink

import android.content.Context
import android.util.Log
import com.hongda.starlink.core.libbox.Libbox
import com.hongda.starlink.core.libbox.SetupOptions
import go.Seq
import java.io.File
import java.util.Locale

/** Initializes the vendored sing-box 1.13.18 mobile core once per app process. */
object HongdaCoreRuntime {
    private const val TAG = "HongdaCoreRuntime"
    @Volatile private var initialized = false

    @Synchronized
    fun ensureInitialized(context: Context) {
        if (initialized) return

        val appContext = context.applicationContext
        val baseDir = File(appContext.filesDir, "HongdaCore").apply { mkdirs() }
        val workingDir = (appContext.getExternalFilesDir("HongdaCore") ?: baseDir).apply { mkdirs() }
        val tempDir = File(appContext.cacheDir, "HongdaCore").apply { mkdirs() }

        // gomobile's runtime can use the Android context for lifecycle/JNI helpers.
        runCatching { Seq.setContext(appContext) }
            .onFailure { Log.d(TAG, "Seq.setContext: ${it.message}") }

        runCatching {
            Libbox.setLocale(Locale.getDefault().toLanguageTag().replace('-', '_'))
        }.onFailure { Log.d(TAG, "setLocale: ${it.message}") }

        val options = SetupOptions().apply {
            basePath = baseDir.absolutePath
            workingPath = workingDir.absolutePath
            tempPath = tempDir.absolutePath
            fixAndroidStack = true
            logMaxLines = 3000
            debug = BuildConfig.DEBUG
        }
        Libbox.setup(options)
        initialized = true
        Log.i(TAG, "HongdaCore initialized: ${Libbox.version()}")
    }

    fun available(): Boolean = runCatching {
        Class.forName("com.hongda.starlink.core.libbox.Libbox")
        true
    }.getOrDefault(false)

    fun version(context: Context): String? = runCatching {
        ensureInitialized(context)
        Libbox.version()
    }.getOrNull()
}
