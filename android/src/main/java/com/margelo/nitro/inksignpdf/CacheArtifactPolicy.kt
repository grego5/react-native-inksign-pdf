package com.margelo.nitro.inksignpdf

import android.content.Context
import android.content.pm.PackageManager
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID

/**
 * Immutable ownership policy for artifacts created by the Android module.
 * Startup scanning and runtime allocation/deletion deliberately share this
 * policy so no caller-owned source path can become a cleanup candidate.
 */
internal class CacheArtifactPolicy private constructor(
  val root: File,
  private val debugArtifactsEnabled: Boolean,
) {
  fun allocateSignedOutput(): File = allocateReservedFile("signed-", ".pdf")

  fun allocateDebugRecording(): File {
    check(debugArtifactsEnabled) { "Stroke trace recording is available only in debug builds" }
    return allocateReservedFile("android-stroke-", ".csv")
  }

  fun allocateExportScratch(): File = allocateReservedFile(".signed-", ".tmp")

  fun allocateStagedInput(): File = allocateReservedFile(".input-", ".tmp")

  fun validatedSignedOutput(path: String, source: File): File {
    if (path.isBlank()) throw invalidOutputPath("The export path is invalid")
    val output = try {
      File(path).canonicalFile
    } catch (error: IOException) {
      throw invalidOutputPath("The export path is invalid", error)
    } catch (error: SecurityException) {
      throw invalidOutputPath("The export path is invalid", error)
    }
    val parent = output.parentFile
    if (output == source || output.isDirectory || !SIGNED_OUTPUT.matches(output.name) ||
      !isOwnedDirectChild(output) || parent == null || !parent.isDirectory || !parent.canWrite()
    ) {
      throw invalidOutputPath("The export destination is not a native cache output")
    }
    return output
  }

  fun deleteExact(file: File) {
    val candidate = try {
      file.canonicalFile
    } catch (_: IOException) {
      return
    } catch (_: SecurityException) {
      return
    }
    if (!isOwnedDirectChild(candidate) || Files.isSymbolicLink(file.toPath())) return
    try {
      Files.deleteIfExists(file.toPath())
    } catch (_: IOException) {
      // Cleanup is best effort; an in-use or externally changed artifact is
      // safer left for the next startup scan than followed recursively.
    } catch (_: SecurityException) {
      // The same containment checks apply when permissions change at runtime.
    }
  }

  private fun allocateReservedFile(prefix: String, suffix: String): File {
    repeat(MAX_ALLOCATION_ATTEMPTS) {
      val candidate = File(root, "$prefix${UUID.randomUUID()}$suffix")
      if (!isOwnedDirectChild(candidate)) error("Cache artifact path escaped the cache root")
      try {
        if (candidate.createNewFile()) return candidate
      } catch (error: IOException) {
        throw PdfSessionException(
          "cache_unavailable",
          "Unable to allocate a native cache artifact",
          error,
        )
      } catch (error: SecurityException) {
        throw PdfSessionException(
          "cache_unavailable",
          "Unable to allocate a native cache artifact",
          error,
        )
      }
    }
    throw PdfSessionException(
      "cache_unavailable",
      "Unable to allocate a unique native cache artifact",
    )
  }

  private fun isOwnedDirectChild(file: File): Boolean =
    file.parentFile?.canonicalFile == root && file.canonicalFile.parentFile == root

  private fun isKnownStartupArtifact(file: File): Boolean {
    if (Files.isSymbolicLink(file.toPath()) || !file.isFile) return false
    if (!isOwnedDirectChild(file)) return false
    return SIGNED_OUTPUT.matches(file.name) || EXPORT_SCRATCH.matches(file.name) ||
      STAGED_INPUT.matches(file.name) ||
      (debugArtifactsEnabled && DEBUG_RECORDING.matches(file.name))
  }

  private fun scavenge() {
    root.listFiles()?.forEach { child ->
      if (isKnownStartupArtifact(child)) deleteExact(child)
    }
  }

  companion object {
    const val CACHE_DIRECTORY_NAME_METADATA =
      "com.margelo.nitro.inksignpdf.CACHE_DIRECTORY_NAME"
    private const val DEFAULT_DIRECTORY_NAME = "inksignpdf"
    private const val MAX_ALLOCATION_ATTEMPTS = 32
    private val SIGNED_OUTPUT = Regex("signed-[^/\\\\]+\\.pdf")
    private val EXPORT_SCRATCH = Regex("\\.signed-[^/\\\\]+\\.tmp")
    private val STAGED_INPUT = Regex("\\.input-[^/\\\\]+\\.tmp")
    private val DEBUG_RECORDING = Regex("android-stroke-[^/\\\\]+\\.csv")

    @Volatile private var initialized: CacheArtifactPolicy? = null
    private val initializationLock = Any()

    fun initialize(context: Context): CacheArtifactPolicy {
      initialized?.let { return it }
      return synchronized(initializationLock) {
        initialized ?: create(context.applicationContext).also { initialized = it }
      }
    }

    private fun create(context: Context): CacheArtifactPolicy {
      val leaf = configuredLeafName(context)
      val cacheRoot = context.cacheDir.canonicalFile
      val root = File(cacheRoot, leaf).canonicalFile
      require(root.parentFile == cacheRoot) {
        "Native cache directory must remain beneath Context.cacheDir"
      }
      require(root.mkdirs() || root.isDirectory) {
        "Unable to create the native cache directory"
      }
      return CacheArtifactPolicy(root, BuildConfig.DEBUG).also { it.scavenge() }
    }

    private fun configuredLeafName(context: Context): String {
      val metadata = try {
        context.packageManager.getApplicationInfo(
          context.packageName,
          PackageManager.GET_META_DATA,
        ).metaData
      } catch (error: PackageManager.NameNotFoundException) {
        throw IllegalStateException("Unable to read native cache configuration", error)
      }
      val configured = metadata?.getString(CACHE_DIRECTORY_NAME_METADATA)
      val leaf = configured ?: DEFAULT_DIRECTORY_NAME
      require(isValidLeafName(leaf)) {
        "CACHE_DIRECTORY_NAME must be one non-empty directory component"
      }
      return leaf
    }

    private fun isValidLeafName(value: String): Boolean {
      if (value.isEmpty() || value == "." || value == ".." || value.indexOf('\u0000') >= 0) {
        return false
      }
      if (value.contains('/') || value.contains('\\')) return false
      return !File(value).isAbsolute
    }

    private fun invalidOutputPath(
      message: String,
      cause: Throwable? = null,
    ): PdfSessionException =
      PdfSessionException("invalid_output_path", message, cause)
  }
}
