package chat.popopx.common.mesh

import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings

/**
 * The plaza's local display name — `PopopxMeshUI/PopopxMeshKillSwitch.swift:129-190` (`PopopxMeshNicknameStore`).
 *
 * A replacement, not a port (§6.10): iOS keeps one JSON file in the mesh sandbox so a panic wipe deletes it with
 * the folder; Android's mesh state already lives in the app's one key-value store (see [PopopxMeshSecretStore]),
 * so the nickname sits there under its own literal key, and [PopopxMeshWipe.eraseMappings] removes it in the
 * same step that erases the switches. It is display state, never a secret: it is advertised in the announce
 * payload and nothing hands it to the SMP path.
 */
class PopopxMeshNicknameStore(private val defaults: Settings = settings) {

  /** null when nothing was ever saved, when the stored value is blank, or when the store cannot be read. */
  fun read(): String? {
    val stored = runCatching { defaults.getStringOrNull(KEY) }.getOrNull() ?: return null
    return clamped(stored)
  }

  /**
   * Writes the clamped name, or removes the key when there is nothing left, so "no nickname" has one
   * representation instead of three.
   */
  fun write(raw: String) {
    val name = clamped(raw)
    if (name == null) defaults.remove(KEY) else defaults.putString(KEY, name)
  }

  fun clear() {
    defaults.remove(KEY)
  }

  companion object {
    /** iOS clamps, never refuses: a nickname must not grow the announce payload by typing. */
    const val MAX_CHARACTERS: Int = 32

    /** What the plaza shows for a peer that never announced a name (`PopopxMeshNicknameStore.defaultNickname`). */
    const val DEFAULT_NICKNAME: String = "mesh user"

    /** `PopopxMeshNicknameStore.fileName`'s payload field, as a settings key. */
    const val KEY: String = "chat.popopx.mesh.nickname"

    /**
     * Trims and cuts on code-point boundaries, so a pasted emoji cannot be split in half the way iOS'
     * grapheme-boundary cut prevents.
     */
    fun clamped(raw: String?): String? {
      val trimmed = raw?.trim().orEmpty()
      if (trimmed.isEmpty()) return null
      val points = trimmed.codePointCount(0, trimmed.length)
      if (points <= MAX_CHARACTERS) return trimmed
      return trimmed.substring(0, trimmed.offsetByCodePoints(0, MAX_CHARACTERS))
    }
  }
}