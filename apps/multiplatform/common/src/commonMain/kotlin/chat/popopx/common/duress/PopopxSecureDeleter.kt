package chat.popopx.common.duress

import java.io.File
import java.io.RandomAccessFile
import kotlin.random.Random

/**
 * Overwrite-then-delete, for the files whose contents must not survive a wipe.
 *
 * Mirrors `PopopxMeshSecureDeleter` (apps/ios/PopopxMeshKit/Sources/PopopxMeshUI/PanicWipeManager.swift:228-353),
 * including the parts that look like decoration and are not:
 *
 * - Two passes, zeros **then** random. One pass overwrites the bytes but leaves a pattern whose boundary is the
 *   file's old length; the second makes the whole region look like noise.
 * - One handle for both passes, seek back to 0 between them. iOS's comment (line 333) is the reason: a handle per
 *   pass leaves a window in which the file can be renamed out from under the second write, and then the pass
 *   lands on a file that is no longer the one being erased.
 * - The SQLCipher companions. A `-wal` holds pages that are not in the main file yet, so erasing only the main
 *   file leaves readable chat rows behind; `-shm` and `-journal` are the same problem in smaller form.
 * - Deepest-first directory traversal, because a file inside a subdirectory has to be gone before its parent is
 *   removed.
 *
 * What this is *not*: it is not a secure-delete guarantee. Android gives an app no control over the flash
 * translation layer, and the same device may hold a cloud backup. iOS says the equivalent at its header (B:221-
 * 227) — full-disk encryption remains the real defence — so this is depth added to a defence that already
 * exists, not a claim that a wiped file is unrecoverable.
 */
class PopopxSecureDeleter(private val random: Random = Random.Default) {
  companion object {
    /** 64 KiB, enough to cover a pass without holding a copy of a large database in memory. */
    const val PATTERN_BYTE_COUNT: Int = 64 * 1024

    /** SQLCipher's companions, in the order iOS builds them. */
    val COMPANION_SUFFIXES: List<String> = listOf("-wal", "-shm", "-journal")

    /** The suffixes a directory walk skips, which is the same list — see [eraseDirectory] for why that matters. */
    private val SKIPPED_SUFFIXES: List<String> = COMPANION_SUFFIXES
  }

  /** What the overwrite failed on, with the path so a journal can name the file that survived. */
  class Failure(val kind: Kind, val path: String, val underlying: String) : Exception("$kind at $path: $underlying") {
    enum class Kind { WriteFailed, DirectoryUnusable }
  }

  fun companionFiles(file: File): List<File> =
    COMPANION_SUFFIXES.map { suffix -> File(file.path + suffix) }

  /**
   * The bytes one pass writes: `count` zeroes, or a random pattern when randomised.
   *
   * Exposed for the same reason iOS's is `static` and called from its own tests: the difference between the two
   * passes has to be observable somewhere, and a buffer of all zeros for `randomised = false` is the whole rule.
   */
  internal fun passBuffer(byteCount: Int, randomised: Boolean): ByteArray {
    if (byteCount <= 0) return ByteArray(0)
    val buffer = ByteArray(byteCount)
    if (randomised) random.nextBytes(buffer)
    return buffer
  }

  /**
   * Overwrite the file and its companions, then remove them.
   *
   * Returns false when the file was never there — which is the honest answer for "nothing was erased", and the
   * caller's journal must not count it. A removal that fails after the overwrite throws: the bytes are gone but
   * the name is not, and that is a different state from success.
   */
  fun eraseFile(file: File): Boolean {
    if (!file.exists()) return false
    val targets = (listOf(file) + companionFiles(file)).filter { it.exists() }
    for (target in targets) {
      val length = target.length().toInt().coerceAtLeast(0)
      if (length > 0) overwrite(target, length)
      if (target.exists() && !target.delete()) {
        throw Failure(Failure.Kind.WriteFailed, target.path, "delete after overwrite failed")
      }
    }
    return true
  }

  /**
   * Every regular file under [directory], deepest first, then the (now empty) directory itself. Returns the paths
   * whose bytes were overwritten, so a report can count them.
   *
   * A missing directory returns the empty list rather than an error: "there was nothing here" is what a device
   * that never used the feature reports, and it is not a failure of the wipe. A directory that survives its own
   * removal *is* a failure, because the caller promised the tree was gone.
   *
   * Companion-suffixed paths are skipped here — they are reached through [eraseFile] of their main file. Deviation
   * carried over deliberately: an orphan `-wal` with no main file survives, exactly as it does on iOS (B:310).
   * Fixing it would mean the two platforms disagree about what "erased" covers, and the iOS behaviour is the one
   * the design document promises.
   */
  fun eraseDirectory(directory: File): List<String> {
    if (!directory.exists()) return emptyList()
    // `walkTopDown()` yields pre-order, so reversing it puts the deepest entries first — the same trick iOS's
    // `enumerator` + `.reversed()` plays, and the root is dropped because iOS's enumerator never yields it either.
    val found = directory.walkTopDown().drop(1).toList().asReversed()
    val erased = mutableListOf<String>()
    for (item in found) {
      if (SKIPPED_SUFFIXES.any { item.path.endsWith(it) }) continue
      if (item.isDirectory) {
        // Swallowed, as iOS swallows it: a non-empty subdirectory left by an entry we skipped is not worth
        // aborting the rest of the sweep for, and the root removal below still reports the truth.
        runCatching { item.delete() }
      } else if (eraseFile(item)) {
        erased.add(item.path)
      }
    }
    if (directory.exists() && !directory.delete()) {
      throw Failure(Failure.Kind.DirectoryUnusable, directory.path, "directory survived removal")
    }
    return erased
  }

  /** The two passes, written through one handle so nothing renames the file out from under them. */
  private fun overwrite(file: File, byteCount: Int) {
    try {
      RandomAccessFile(file, "rw").use { handle ->
        for (randomised in booleanArrayOf(false, true)) {
          val buffer = passBuffer(minOf(byteCount, PATTERN_BYTE_COUNT), randomised)
          handle.seek(0)
          var written = 0
          while (written < byteCount) {
            val chunk = minOf(buffer.size, byteCount - written)
            if (chunk <= 0) break
            handle.write(buffer, 0, chunk)
            written += chunk
          }
          handle.fd.sync()
        }
      }
    } catch (e: Exception) {
      throw Failure(Failure.Kind.WriteFailed, file.path, e.message ?: e.javaClass.simpleName)
    }
  }
}
