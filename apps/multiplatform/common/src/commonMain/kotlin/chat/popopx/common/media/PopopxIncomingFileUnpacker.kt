package chat.popopx.common.media

import java.io.File

// Ported from `PopopxIncomingFileUnpacker` in apps/ios/Shared/Features/MediaCompression/PopopxIncomingFileUnpacker.swift.
//
// The receiving half keeps iOS's two decisions: the plaintext cache is rebuilt on demand rather than kept warm,
// because the OS may reclaim it between two taps, and the purge is synchronous because the emergency wipe calls it
// immediately before the process is terminated.
//
// Not mounted this phase, deliberately: the outgoing side emits no container (ruling 1) and a frame written by iOS
// is LZFSE, which this side reports as CONTAINER_UNSUPPORTED_CODEC rather than guessing. So there is no
// Android-produced container to open and no iOS-produced one to unpack, and showing a restored name for a file
// that cannot be opened would be worse than showing the real one.

object PopopxIncomingFileUnpacker {
  fun isContainer(file: File): Boolean = PopopxDocumentContainer.isContainer(file)

  fun isContainerNamed(fileName: String): Boolean = PopopxDocumentContainer.isContainerNamed(fileName)

  /** The name shown in the bubble: `notes.md.ppxlz` becomes `notes.md`. */
  fun displayNameFor(fileName: String): String {
    if (!isContainerNamed(fileName)) return fileName
    val stem = fileName.dropLast(PopopxDocumentContainer.PATH_EXTENSION.count() + 1)
    return if (stem.isEmpty()) fileName else stem
  }

  /** The cache path for a container, only when a usable unpacked copy exists. */
  fun cachedFile(container: File): File? {
    val directory = runCatching { PopopxMediaEngineCore.unpackedDirectory() }.getOrNull() ?: return null
    val candidate = File(directory, PopopxDocumentContainer.displayName(container))
    return if (candidate.isFile && candidate.length() > 0L) candidate else null
  }

  suspend fun unpack(container: File): PopopxUnpackResult {
    cachedFile(container)?.let { return PopopxUnpackResult.Success(it) }
    return PopopxMediaEngine.shared.unpack(container)
  }

  /** Used by the open path: a container becomes its unpacked file, anything else is returned untouched. */
  suspend fun prepareForOpening(file: File): PopopxOpenableFile {
    if (!isContainer(file)) return PopopxOpenableFile(file, unpacked = false, message = null)
    return when (val result = unpack(file)) {
      is PopopxUnpackResult.Success -> PopopxOpenableFile(result.file, unpacked = true, message = null)
      is PopopxUnpackResult.Failure -> PopopxOpenableFile(file, unpacked = false, message = PopopxMediaCopy.unpackFailed())
    }
  }

  /**
   * Physically clears both plaintext caches: the documents unpacked on the receiving side and the recompressed
   * copies the sending side leaves behind. Synchronous and non-isolated by necessity: it runs off the main thread
   * from the lifecycle observer and from the emergency wipe immediately before the process is terminated. Only the
   * contents are removed; the engine recreates both directories on demand.
   */
  fun purgeTemporaryDirectories() {
    for (directory in cacheDirectories()) clear(directory)
  }

  fun cacheDirectories(): List<File> {
    val directories = mutableListOf<File>()
    runCatching { PopopxMediaEngineCore.workingDirectory() }.getOrNull()?.let { directories.add(it) }
    runCatching { PopopxMediaEngineCore.unpackedDirectory() }.getOrNull()?.let { directories.add(it) }
    return directories
  }

  /** Bytes reclaimed by the last purge, so the wipe journal can record what it actually removed. */
  private fun clear(directory: File) {
    val entries = runCatching { directory.listFiles() }.getOrNull() ?: return
    for (entry in entries) {
      // iOS passes `.skipsHiddenFiles`; a dot-file here is the platform's, not ours.
      if (entry.name.startsWith(".")) continue
      runCatching { if (entry.isDirectory) deleteRecursively(entry) else entry.delete() }
    }
  }

  private fun deleteRecursively(directory: File): Boolean {
    directory.listFiles()?.forEach { child ->
      if (child.isDirectory) deleteRecursively(child) else child.delete()
    }
    return directory.delete()
  }
}

class PopopxOpenableFile(
  val file: File,
  val unpacked: Boolean,
  val message: String?,
) {
  val displayName: String get() = PopopxIncomingFileUnpacker.displayNameFor(file.name)
}
