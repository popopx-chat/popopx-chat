package chat.popopx.common.cfgsec

import chat.popopx.common.crypto.base64Decode
import chat.popopx.common.crypto.base64Encode
import chat.popopx.common.model.UserOperatorServers
import chat.popopx.common.platform.cryptor
import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

// Persistence for the signed cluster configuration, ported from
// apps/ios/Shared/Features/ServerConfigSync/PopopxServerConfigStore.swift (617 lines).
//
// iOS splits two tiers: `UserDefaults` for the small records that decide whether a frame is worth acting on,
// and files with complete file protection for the two blobs that are only read when something went wrong. The
// Android equivalent of the second tier is not a file — it is the app's own `cryptor`, an AndroidKeyStore
// AES-GCM key per alias, which is the same seam `PopopxEcoSecrets` used for the iOS Keychain in phase 2. That
// substitution is deviation 1 in the commit body: the protection comes from the keystore rather than from
// Data Protection, and the desktop actual of `cryptor` is the plaintext pass-through it has always been.
//
// The state model follows the wire contract rather than the shape a dictionary suggests. `seq` is the
// generation, monotonic per signing key and never derived from a clock; `exp` is a lifetime. Gaps in `seq` are
// legal — a reserved generation that was never published leaves a hole — so the floor is a floor, not a count.
//
// `pol.ms` is the revocation lever and it is the one place a floor moves: the operator signs a higher minimum
// to pull a bad generation out from under every device. Everything else here moves in the fail-safe direction,
// and the floor is raised at accept time *before* applying, so a crash between raising it and finishing the
// apply cannot lead to the same bad configuration being applied again when the delivery guarantee re-presents
// the same message.
//
// Nothing here reaches the core. The store answers "what did we already accept"; the API calls live in the
// signal handler.

enum class PopopxServerConfigVerdict(val rawValue: String) {
  PENDING("pending"),
  VERIFIED("verified"),
  ROLLED_BACK("rolledBack");

  companion object {
    fun fromRaw(value: String?): PopopxServerConfigVerdict? = entries.firstOrNull { it.rawValue == value }
  }
}

/**
 * The highest generation this device has acted on for one signing key.
 *
 * Keyed by `kid` rather than stored as a single number because a rotation resets the counter: the new key's
 * first generation is 1, and a device holding a global floor of 7 would refuse every frame the replacement key
 * ever signs. That failure mode is silent — the device simply never updates again — which is why it is worth
 * the extra level of structure.
 */
@Serializable
data class PopopxServerConfigFloor(val kid: String, val seq: Long)

/** Which kind of conversation a frame arrived in. */
@Serializable
enum class PopopxServerConfigSourceChat(val rawValue: String) {
  DIRECT("direct"),
  GROUP("group");

  companion object {
    fun fromRaw(value: String?): PopopxServerConfigSourceChat? = entries.firstOrNull { it.rawValue == value }
  }
}

/**
 * The state of the server table immediately before an update was applied.
 *
 * `servers` is the full table exactly as the core returned it, because rollback sends these rows back and then
 * re-reads — which is how the manual save flow learns server ids. A partial snapshot could not do that.
 * `introducedURIs` travels alongside it so a rollback restores *ownership* as well as addresses; without it the
 * device would believe the rows it just wrote back were its own to delete on the next update.
 */
@Serializable
data class PopopxServerConfigSnapshot(
  val schemaVersion: Int,
  /** Seconds since the epoch, the strategy iOS's encoder is configured with. */
  val takenAt: Long,
  val kid: String,
  val seq: Long,
  val introducedURIs: List<String>,
  val servers: List<UserOperatorServers>,
) {
  companion object {
    /** Disk-format version, deliberately separate from the payload's wire version: this is about whether
     * *this record* can be read, and a schema change here discards rather than guesses. */
    const val SCHEMA_VERSION: Int = 2

    fun of(
      kid: String,
      seq: Long,
      introducedURIs: List<String>,
      servers: List<UserOperatorServers>,
      takenAt: Long = System.currentTimeMillis() / 1000,
    ): PopopxServerConfigSnapshot =
      PopopxServerConfigSnapshot(SCHEMA_VERSION, takenAt, kid, seq, introducedURIs, servers)
  }
}

/**
 * The receipt this device owes an operator, and how to route it.
 *
 * No outcome field: the receipt grammar is `::<seq>[::<bh>]`, which can state that a device received a
 * generation and which body it installed, and nothing else. A refusal therefore cannot be reported at all —
 * reporting one as a bare `<seq>` would be counted by the operator's roll-up as an acknowledged device, which
 * is a false coverage claim rather than a partial one. Hence: acknowledge what was installed and what was
 * legitimately stale, stay silent about everything refused.
 */
@Serializable
data class PopopxServerConfigPendingAck(
  val kid: String,
  val seq: Long,
  /** Body hash of the configuration that was installed, or null when the receipt reports a generation not installed. */
  val bodyHash: String?,
  val chatType: String,
  val chatApiId: Long,
) {
  /** Identity for dedupe purposes: everything except the hash. */
  val claimKey: String get() = "$kid|$seq|$chatType|$chatApiId"

  companion object {
    fun of(
      kid: String,
      seq: Long,
      bodyHash: String?,
      chatType: PopopxServerConfigSourceChat,
      chatApiId: Long,
    ): PopopxServerConfigPendingAck = PopopxServerConfigPendingAck(kid, seq, bodyHash, chatType.rawValue, chatApiId)
  }
}

/**
 * A frame that arrived at a moment it could not be applied.
 *
 * Stores the received *segment text*, not the decoded payload: a staged frame is still untrusted until it is
 * verified, verification runs over exactly these bytes, and the body is no longer separable from its compressed
 * form once inflated. Re-verifying on promotion also means an expiry that passed while the frame sat there is
 * honoured instead of baked in.
 */
@Serializable
data class PopopxServerConfigStagedFrame(
  val schemaVersion: Int,
  val receivedAt: Long,
  /** The whole line, prefix included, as it arrived. */
  val segment: String,
  val chatType: String,
  val chatApiId: Long,
) {
  companion object {
    const val SCHEMA_VERSION: Int = 2

    fun of(
      segment: String,
      chatType: PopopxServerConfigSourceChat,
      chatApiId: Long,
      receivedAt: Long = System.currentTimeMillis() / 1000,
    ): PopopxServerConfigStagedFrame =
      PopopxServerConfigStagedFrame(SCHEMA_VERSION, receivedAt, segment, chatType.rawValue, chatApiId)
  }
}

class PopopxServerConfigStore(private val defaults: Settings = settings) {
  /** How many floor records, broken entries and receipts are kept. Bounded because each is a JSON blob a device
   * could otherwise accumulate forever; the newest entries are the ones that matter, since an old generation is
   * below its floor by the time any list is anywhere near this length. Sixteen is four times the number of keys
   * a rotation can plausibly involve. */
  private val maximumTrackedRecords: Int = 16

  // MARK: Floors

  /** Every recorded floor, oldest first. */
  var floors: List<PopopxServerConfigFloor>
    get() = decodeList(FLOOR_RECORDS, floorRecords)
    set(value) {
      encode(FLOOR_RECORDS, floorRecords, value)
    }

  /** The generation this device last acted on for one key, or zero when it has never seen that key. */
  fun floor(kid: String): Long = floors.firstOrNull { it.kid == kid }?.seq ?: 0L

  /** Whether a generation is worth acting on: strictly above that key's floor, and not known to fail. */
  fun isAcceptable(kid: String, seq: Long): Boolean = seq > floor(kid) && !isBroken(kid, seq)

  /** Records an acceptance and the URIs it introduced, and opens a probe window (`pending`). */
  fun markAccepted(kid: String, seq: Long, introducedURIs: List<String>) {
    val records = floors.toMutableList()
    val index = records.indexOfFirst { it.kid == kid }
    if (index >= 0) {
      records[index] = records[index].copy(seq = maxOf(records[index].seq, seq))
    } else {
      records.add(PopopxServerConfigFloor(kid, seq))
    }
    floors = trimTail(records)
    setIntroducedURIs(introducedURIs)
    defaults.putString(VERDICT, PopopxServerConfigVerdict.PENDING.rawValue)
  }

  /** Closes the probe window successfully. */
  fun markVerified() {
    defaults.putString(VERDICT, PopopxServerConfigVerdict.VERIFIED.rawValue)
  }

  /**
   * Records a rollback: the generation is burned and the floor stays raised, because the device *did* see that
   * generation. Ownership of the server rows is not touched here — the caller restores it from the snapshot,
   * which is the only record of what the device owned beforehand.
   */
  fun markRolledBack(kid: String, seq: Long) {
    val broken = trimTail(brokenEntries + brokenEntry(kid, seq))
    encode(BROKEN_ENTRIES, stringRecords, broken)
    defaults.putString(VERDICT, PopopxServerConfigVerdict.ROLLED_BACK.rawValue)
  }

  val verdict: PopopxServerConfigVerdict?
    get() = PopopxServerConfigVerdict.fromRaw(defaults.getStringOrNull(VERDICT))

  // MARK: Revocation

  /**
   * Applies the operator's revocation lever: `pol.ms` declares a minimum live generation, so every generation
   * of *this key* below it is voided by raising the recorded floor to `ms - 1`.
   *
   * One direction only, and that is the whole point of the lever. Pulling a recorded floor *down* to `ms - 1`
   * is what would let a still-unexpired generation the device had already acted on be re-installed by replaying
   * it. The corrected roster a withdrawal is followed by always carries a higher generation, so a floor that
   * only ever rises loses nothing the operator needs.
   *
   * Scoped to the key that verified: a ratchet published for one rotation must not void another key's history.
   *
   * Returns whether anything moved, which is what makes the call worth logging: a device already above the
   * declared baseline changes nothing.
   */
  fun revoke(kid: String, minSeq: Long): Boolean {
    if (minSeq < 1) return false
    val target = minSeq - 1
    val records = floors.toMutableList()
    val index = records.indexOfFirst { it.kid == kid }
    if (index < 0) {
      // Nothing recorded for this key: a baseline of zero needs no record, and `ms` of one revokes nothing.
      if (target <= 0) return false
      records.add(PopopxServerConfigFloor(kid, target))
      floors = records
      return true
    }
    if (records[index].seq >= target) return false
    records[index] = records[index].copy(seq = target)
    floors = records
    return true
  }

  // MARK: Broken generations

  /** Generations that were applied and then rolled back, as `kid|seq` strings. Never retried. */
  val brokenEntries: List<String>
    get() = decodeList(BROKEN_ENTRIES, stringRecords)

  fun isBroken(kid: String, seq: Long): Boolean = brokenEntries.contains(brokenEntry(kid, seq))

  // MARK: Ownership

  /**
   * The SMP server URIs this mechanism added, and therefore the only rows it may remove.
   *
   * Ownership is tracked by URI, never by `preset`: `preset` is the core's own notion and is true for the
   * shipped default servers, so claiming by it would let a signed frame delete rows the installation itself put
   * there, let alone rows the user added.
   */
  val introducedURIs: List<String>
    get() = decodeList(INTRODUCED_URIS, stringRecords)

  fun setIntroducedURIs(uris: List<String>) {
    encode(INTRODUCED_URIS, stringRecords, uris)
  }

  // MARK: Official subscription

  /**
   * Whether the two official conversations were joined for one profile.
   *
   * Keyed by profile, unlike every other key here: the floors, receipts and ownership list describe what this
   * *device* did to its server table, which is one table shared by all profiles, whereas a subscription is a
   * chat and a chat belongs to one profile. A second profile on the same device has no conversations of its own
   * yet, so a device-wide flag would leave it permanently unsubscribed.
   */
  fun officialSubscriptionSeeded(userId: Long): Boolean =
    defaults.getBoolean("$OFFICIAL_SUBSCRIPTION.$userId", false)

  fun markOfficialSubscriptionSeeded(userId: Long) {
    defaults.putBoolean("$OFFICIAL_SUBSCRIPTION.$userId", true)
  }

  // MARK: System config chat ids

  /**
   * The chat ids this mechanism opened for one profile, used to keep them out of every list the user reads.
   *
   * iOS holds `[userId: [chatId]]` as JSON data; the same map goes in as JSON text, keyed by the profile id as
   * it is spelled in the iOS key.
   */
  fun systemConfigChatIds(userId: Long): List<Long> = systemConfigChatRecord()[userId.toString()].orEmpty()

  fun addSystemConfigChatId(chatId: Long, userId: Long) {
    val record = systemConfigChatRecord().toMutableMap()
    val ids = (record[userId.toString()] ?: emptyList()).toMutableList()
    if (ids.contains(chatId)) return
    ids.add(chatId)
    record[userId.toString()] = ids
    encode(SYSTEM_CONFIG_CHAT_IDS, chatIdRecords, record)
  }

  fun clearSystemConfigChatIds(userId: Long) {
    val record = systemConfigChatRecord().toMutableMap()
    if (!record.containsKey(userId.toString())) return
    record.remove(userId.toString())
    encode(SYSTEM_CONFIG_CHAT_IDS, chatIdRecords, record)
  }

  private fun systemConfigChatRecord(): Map<String, List<Long>> =
    decodeValue(SYSTEM_CONFIG_CHAT_IDS, chatIdRecords) ?: emptyMap()

  // MARK: Receipt dedupe

  /** Claims the right to send one receipt, returning false when it is already claimed. */
  fun claimAck(ack: PopopxServerConfigPendingAck): Boolean {
    val claims = ackClaims.toMutableList()
    if (claims.any { it.claimKey == ack.claimKey }) return false
    claims.add(ack)
    ackClaims = trimTail(claims)
    return true
  }

  /** Releases a claim so a failed send can be retried. */
  fun releaseAckClaim(ack: PopopxServerConfigPendingAck) {
    ackClaims = ackClaims.filter { it.claimKey != ack.claimKey }
  }

  var ackClaims: List<PopopxServerConfigPendingAck>
    get() = decodeList(ACK_CLAIMS, ackClaimRecords)
    private set(value) {
      encode(ACK_CLAIMS, ackClaimRecords, value)
    }

  /**
   * The receipt that is owed but not yet sent.
   *
   * Durable rather than in-memory on purpose: a receipt is only worth sending once the probe window has a
   * verdict, and the window is exactly the thing a backgrounded or killed process interrupts. Without this slot
   * the operator would lose the receipt for the one outcome they most want to know about — the update that had
   * to be rolled back.
   */
  var pendingAck: PopopxServerConfigPendingAck?
    get() = decodeValue(PENDING_ACK, PopopxServerConfigPendingAck.serializer())
    set(value) {
      if (value == null) defaults.remove(PENDING_ACK) else encode(PENDING_ACK, PopopxServerConfigPendingAck.serializer(), value)
    }
  // MARK: Protected blobs

  /**
   * Writes the pre-apply snapshot. False means the caller must not apply.
   *
   * Overwriting an existing snapshot is refused unless the previous update was verified: a snapshot taken
   * *before* an unverified update is the last known good table, and replacing it mid-window would leave the
   * device holding the bad configuration as its own fallback.
   */
  fun writeRollback(snapshot: PopopxServerConfigSnapshot): Boolean {
    if (verdict == PopopxServerConfigVerdict.PENDING && existingRollbackSequence() != null) return false
    return vault.write(SLOT_ROLLBACK, SNAPSHOT_ALIAS, json.encodeToString(PopopxServerConfigSnapshot.serializer(), snapshot))
  }

  fun readRollback(): PopopxServerConfigSnapshot? =
    readProtected(SLOT_ROLLBACK, SNAPSHOT_ALIAS, PopopxServerConfigSnapshot.serializer(), PopopxServerConfigSnapshot.SCHEMA_VERSION) { it.schemaVersion }

  fun clearRollback() {
    vault.remove(SLOT_ROLLBACK, SNAPSHOT_ALIAS)
  }

  /** The generation the held snapshot belongs to, without handing the caller the whole table. */
  fun existingRollbackSequence(): Long? = readRollback()?.seq

  fun stage(frame: PopopxServerConfigStagedFrame): Boolean =
    vault.write(SLOT_STAGED, STAGED_ALIAS, json.encodeToString(PopopxServerConfigStagedFrame.serializer(), frame))

  /**
   * Consumes a staged frame: read and delete in one call, so a promotion that crashes halfway cannot
   * re-promote the same frame forever. Re-verification on the promotion path is what keeps this safe — the
   * deleted bytes are the bytes that get checked again.
   */
  fun takeStaged(): PopopxServerConfigStagedFrame? {
    val frame = readProtected(SLOT_STAGED, STAGED_ALIAS, PopopxServerConfigStagedFrame.serializer(), PopopxServerConfigStagedFrame.SCHEMA_VERSION) { it.schemaVersion }
    clearStaged()
    return frame
  }

  fun clearStaged() {
    vault.remove(SLOT_STAGED, STAGED_ALIAS)
  }

  /** Whether anything is waiting for a promotion. Presence of the slot, not its readability. */
  val hasStagedFrame: Boolean
    get() = vault.contains(SLOT_STAGED)

  private fun <T> readProtected(slot: String, alias: String, serializer: KSerializer<T>, expectedSchemaVersion: Int, versionOf: (T) -> Int): T? {
    val raw = vault.read(slot, alias) ?: return null
    val value = runCatching { json.decodeFromString(serializer, raw) }.getOrNull()
    if (value == null || versionOf(value) != expectedSchemaVersion) {
      // Corrupt, or written by a build whose format this one cannot read: treated as absent, which is the same
      // answer as "nothing staged", and never as "apply whatever the last bytes were".
      vault.remove(slot, alias)
      return null
    }
    return value
  }

  // MARK: Records

  private val vault = PopopxServerConfigVault(defaults)

  private fun <T> decodeList(key: String, serializer: KSerializer<List<T>>): List<T> {
    val raw = defaults.getStringOrNull(key) ?: return emptyList()
    val value = runCatching { json.decodeFromString(serializer, raw) }.getOrNull()
    if (value == null) {
      // A record this build cannot read is treated as absent, never as satisfied: an empty floor list
      // re-admits generations the device did apply, which is the recoverable direction because applying a
      // generation twice is a no-op — the merge is by URI and an owned URI that is already present is left
      // alone. An empty *broken* list re-admits a generation that broke connectivity, which the probe window
      // catches and rolls back again. Both end in a working device.
      defaults.remove(key)
      return emptyList()
    }
    return value
  }

  private fun <T> decodeValue(key: String, serializer: KSerializer<T>): T? {
    val raw = defaults.getStringOrNull(key) ?: return null
    val value = runCatching { json.decodeFromString(serializer, raw) }.getOrNull()
    if (value == null) defaults.remove(key)
    return value
  }

  private fun <T> encode(key: String, serializer: SerializationStrategy<T>, value: T) {
    defaults.putString(key, json.encodeToString(serializer, value))
  }

  private fun <T> trimTail(records: List<T>): List<T> =
    if (records.size > maximumTrackedRecords) records.takeLast(maximumTrackedRecords) else records

  private fun brokenEntry(kid: String, seq: Long): String = "$kid|$seq"

  companion object {
    const val FLOOR_RECORDS: String = "serverConfigFloors"
    const val BROKEN_ENTRIES: String = "serverConfigBrokenEntries"
    const val ACK_CLAIMS: String = "serverConfigAckClaims"
    const val INTRODUCED_URIS: String = "serverConfigIntroducedURIs"
    const val VERDICT: String = "serverConfigVerdict"
    const val PENDING_ACK: String = "serverConfigPendingAck"
    const val OFFICIAL_SUBSCRIPTION: String = "serverConfigOfficialSubscription"
    const val SYSTEM_CONFIG_CHAT_IDS: String = "serverConfigSystemConfigChatIds"

    /** iOS writes these two as files (`rollback.json`, `staged.json`); here they are protected slots. */
    const val SLOT_ROLLBACK: String = "serverConfigRollback"
    const val SLOT_STAGED: String = "serverConfigStaged"
    const val SNAPSHOT_ALIAS: String = "popopx.server_config.rollback"
    const val STAGED_ALIAS: String = "popopx.server_config.staged"

    /** Largest plaintext the protected tier will hold. Beyond it a write fails, so the update is refused. */
    const val MAXIMUM_PROTECTED_CHARACTERS: Int = 32_768

    /** The strict parser every record in this file goes through, mirroring iOS's default `JSONDecoder`. */
    internal val json = Json { isLenient = false; ignoreUnknownKeys = false; encodeDefaults = true }

    private val stringRecords = ListSerializer(String.serializer())
    private val chatIdRecords = MapSerializer(String.serializer(), ListSerializer(Long.serializer()))
    private val floorRecords = ListSerializer(PopopxServerConfigFloor.serializer())
    private val ackClaimRecords = ListSerializer(PopopxServerConfigPendingAck.serializer())

    val shared: PopopxServerConfigStore = PopopxServerConfigStore()
  }
}

/**
 * The protected tier: one JSON text per slot, sealed with an AndroidKeyStore key and stored base64 beside the
 * iv, exactly the shape `PopopxEcoSecrets` uses for the iOS Keychain.
 *
 * A slot that cannot be opened is *removed* rather than retried, because the only way to get here twice is a
 * keystore alias that was wiped while its ciphertext survived — a backup restore — and a snapshot from a
 * previous install must not be offered as this device's rollback target.
 */
internal class PopopxServerConfigVault(private val defaults: Settings) {
  fun write(slot: String, alias: String, text: String): Boolean {
    if (text.isEmpty() || text.length > PopopxServerConfigStore.MAXIMUM_PROTECTED_CHARACTERS) return false
    return try {
      val (cipherText, iv) = cryptor.encryptText(text, alias)
      defaults.putString("$slot.ct", base64Encode(cipherText))
      defaults.putString("$slot.iv", base64Encode(iv))
      true
    } catch (e: Exception) {
      false
    }
  }

  fun read(slot: String, alias: String): String? = try {
    val cipherText = defaults.getStringOrNull("$slot.ct") ?: return null
    val iv = defaults.getStringOrNull("$slot.iv") ?: return null
    val cipherBytes = base64Decode(cipherText) ?: return null
    val ivBytes = base64Decode(iv) ?: return null
    cryptor.decryptData(cipherBytes, ivBytes, alias)
  } catch (e: Exception) {
    // Android's `decryptData` raises as well as returning null when the database passphrase is random; a
    // configuration slot must never be the thing that surfaces an error to the user.
    null
  }

  fun contains(slot: String): Boolean =
    defaults.getStringOrNull("$slot.ct") != null && defaults.getStringOrNull("$slot.iv") != null

  fun remove(slot: String, alias: String) {
    try {
      cryptor.deleteKey(alias)
    } catch (e: Exception) {
      // The alias may never have been created; the slots are the part that must go.
    }
    defaults.remove("$slot.ct")
    defaults.remove("$slot.iv")
  }
}

