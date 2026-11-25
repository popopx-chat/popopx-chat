package chat.popopx.app.eco

import chat.popopx.common.eco.PopopxEcoMarker
import com.russhwolf.settings.PropertiesSettings
import com.russhwolf.settings.Settings
import java.util.Properties

// Shared fixtures for the eco protocol tests.
//
// Why `PropertiesSettings(Properties()) { }` and not the app's own `settings`: the desktop actual of
// `chat.popopx.common.platform.settings` is wired to a flush lambda that writes
// `~/Library/Preferences/…` on EVERY put, so a test that touched it would edit the developer's real
// preferences. An empty `Properties` with a no-op writer is the same interface with no side effects.

internal fun ecoSettings(): Settings = PropertiesSettings(Properties()) { }

internal fun ecoFrameText(json: String): String = PopopxEcoMarker.MARKER + json

/** A `ku` plaintext, written in the field order the envelope's own decoder reads. */
internal fun epochSecretPayload(
  epoch: Int,
  keyBase64Url: String,
  publicKeyBase64Url: String? = null,
  expiresAtMs: Long? = null,
): ByteArray =
  buildString {
    append("{\"epoch\":").append(epoch)
    append(",\"keyBase64URL\":\"").append(keyBase64Url).append('"')
    if (publicKeyBase64Url != null) append(",\"publicKeyBase64URL\":\"").append(publicKeyBase64Url).append('"')
    if (expiresAtMs != null) append(",\"expiresAtMs\":").append(expiresAtMs)
    append('}')
  }.encodeToByteArray()
