package chat.popopx.common.duress

import java.io.File

/**
 * Desktop has no panic wipe, and this object is the proof of that rather than a port of it.
 *
 * The three-tap gate is mounted behind `appPlatform.isAndroid`, so nothing in the desktop UI can reach here; the
 * actual exists because `commonMain` declares the factory. Every step refuses, and [termination] is deliberately
 * null — an unimplemented wipe on a developer's machine must not be able to end the process, and a null here is
 * recorded by the manager as the failure it is (`missingTerminationIsAFailure`).
 */
private object PopopxNoPanicWipeHost : PopopxPanicWipeHost {
  override fun stopOutbound(): List<String> = listOf("not implemented on this platform")

  override fun burnKeys(): String = "not implemented on this platform"

  override fun clearInMemoryMirrors(): List<String> = listOf("not implemented on this platform")

  override fun eraseIdentityMapping(): List<String> = listOf("not implemented on this platform")

  override fun sandboxDirectories(): List<File> = emptyList()

  override fun applicationDatabaseFile(): File? = null

  override fun termination(): ((Int) -> Unit)? = null
}

actual fun popopxAppPanicWipeHost(): PopopxPanicWipeHost = PopopxNoPanicWipeHost
