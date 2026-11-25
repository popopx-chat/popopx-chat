package chat.popopx.common.media

import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings

// Ported from apps/ios/Shared/Features/MediaCompression/PopopxMediaCompressionSettings.swift.
//
// iOS keeps the three values in memory on a @MainActor singleton and writes them in `didSet`. Here they are
// read through the app's own `Settings` on every access, which is what lets a unit test drive the whole
// gating layer over an in-memory map and keeps a write made off the main thread from going stale. Same keys,
// same defaults, same combination rule.

enum class PopopxImageQualityPreset(val rawValue: String, val maxDimensionInPixels: Int, val jpegQuality: Double) {
  DATA_SAVER("dataSaver", 1080, 0.6),
  STANDARD_HD("standardHD", 1600, 0.75);

  companion object {
    /** An unknown or absent stored value falls back to [STANDARD_HD], as `PopopxImageQualityPreset(rawValue:) ?? .standardHD` does. */
    fun stored(defaults: Settings): PopopxImageQualityPreset =
      fromRawValue(defaults.getStringOrNull(PopopxMediaSettingsKeys.IMAGE_QUALITY_PRESET)) ?: STANDARD_HD

    fun fromRawValue(value: String?): PopopxImageQualityPreset? = entries.firstOrNull { it.rawValue == value }
  }
}

object PopopxMediaSettingsKeys {
  const val ENGINE_ENABLED = "popopx.media.engineEnabled"
  const val STRICT_GROUP_COMPRESSION = "popopx.media.strictGroupCompression"
  const val IMAGE_QUALITY_PRESET = "popopx.media.imageQualityPreset"
}

class PopopxMediaSettings(private val defaults: Settings = settings) {
  /** Master switch. Off means attachments are handed to the core exactly as picked. */
  var isEngineEnabled: Boolean
    get() = defaults.getBoolean(PopopxMediaSettingsKeys.ENGINE_ENABLED, true)
    set(value) {
      defaults.putBoolean(PopopxMediaSettingsKeys.ENGINE_ENABLED, value)
    }

  /** Large-group flow control: force compression plus the post-compression size ceiling. */
  var isStrictGroupCompressionEnabled: Boolean
    get() = defaults.getBoolean(PopopxMediaSettingsKeys.STRICT_GROUP_COMPRESSION, true)
    set(value) {
      defaults.putBoolean(PopopxMediaSettingsKeys.STRICT_GROUP_COMPRESSION, value)
    }

  var imageQualityPreset: PopopxImageQualityPreset
    get() = PopopxImageQualityPreset.stored(defaults)
    set(value) {
      defaults.putString(PopopxMediaSettingsKeys.IMAGE_QUALITY_PRESET, value.rawValue)
    }

  /** A file still larger than this after compression is not sent in a large group. */
  val sizeCeiling: Long get() = MAX_COMPRESSED_SEND_BYTES

  fun appliesToGroup(memberCount: Int): Boolean =
    isEngineEnabled && isStrictGroupCompressionEnabled && memberCount >= LARGE_GROUP_MEMBER_THRESHOLD

  companion object {
    const val MAX_COMPRESSED_SEND_BYTES: Long = 5_000_000L
    const val LARGE_GROUP_MEMBER_THRESHOLD: Int = 50

    val shared: PopopxMediaSettings = PopopxMediaSettings()
  }
}
