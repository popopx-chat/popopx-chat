package chat.popopx.common.commerce

import chat.popopx.common.eco.PopopxEcoSecrets
import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer

/**
 * The slot names of this module, spelled exactly as the iOS keychain spells them
 * (`PopopxBadgeCreditsModels.swift:1413-1454`). They are the settings keys too.
 *
 * Every name carries the literal `popopx.commerce.` prefix so that this module's rows, the database passphrase
 * family and duress's own `popopx.duress.*` namespace can never overwrite one another (`:1410-1412`).
 */
object PopopxCommerceKeys {
  const val BADGE_RECORD = "popopx.commerce.badge"
  const val TRIAL_GUARD = "popopx.commerce.trial"
  const val VOUCHERS = "popopx.commerce.vouchers"
  const val WALLET = "popopx.commerce.wallet"
  const val LEDGER = "popopx.commerce.ledger"
  const val REPLAY_GUARD = "popopx.commerce.replay"
  const val SIGNING_KEY = PopopxCommerceSignature.ACCOUNT_SIGNING_KEY
  const val PENDING_PACKETS = "popopx.commerce.pending-packets"
  const val CHANNEL_TICKETS = "popopx.commerce.channel-tickets"
  const val PROFILE_RECEIPTS = "popopx.commerce.profile-receipts"
  const val RECEIVED_PAYMENT_TX_HASHES = "popopx.commerce.received-payment-txhashes"
  const val COSMETICS = "popopx.commerce.cosmetics"
  const val EPHEMERAL_CONNECTIONS = "popopx.commerce.ephemeral-connections"

  /**
   * This device's install fingerprint, the second half of the trial badge's replay prevention (`:1427-1429`). Its
   * own slot, never shared with the temporary connection: that one is overwritten repeatedly by the redemption
   * flow, and overwriting the fingerprint once would let the trial badge be claimed without limit.
   */
  const val INSTALL_IDENTITY = "popopx.commerce.install-identity"

  /** The authorisation text (grant) whose signature the receiving side verified (`:1430-1432`). */
  const val GRANTS = "popopx.commerce.grants"

  /** The credit twins of [GRANTS]; a different type under the same voucher-id keys, so it cannot share the slot (`:1433-1435`). */
  const val CREDIT_GRANTS = "popopx.commerce.credit-grants"

  /**
   * The gift message the giver typed for one card, keyed by voucher id (`:1436-1444`).
   *
   * Its own slot rather than a field of [PopopxNodeVoucher] on purpose: that row's encoding is the double-spend
   * record and cannot take a free-text column without a migration. Nor can the message ride on the stored code:
   * the envelope has no message field and only its digest is kept. A card minted before this slot existed has no
   * row here, which is exactly the state such a card is in today.
   */
  const val VOUCHER_NOTES = "popopx.commerce.voucher-notes"

  // Discover's service subscriptions, the bonded Mac node and its receipts: three slots rather than one because
  // they fail differently (`:1445-1453`). They belong to the Discover lane and are named here so the wipe below is
  // the complete answer.
  const val DISCOVER_SUBSCRIPTIONS = "popopx.commerce.discover-subscriptions"
  const val DISCOVER_NODE_BINDING = "popopx.commerce.discover-node-binding"
  const val DISCOVER_INBOX = "popopx.commerce.discover-inbox"

  /** Every slot, in the iOS declaration order, which is what [PopopxCommerceStore.wipeAll] iterates. */
  val ALL: List<String> = listOf(
    BADGE_RECORD, TRIAL_GUARD, VOUCHERS, WALLET, LEDGER, REPLAY_GUARD, SIGNING_KEY, PENDING_PACKETS,
    CHANNEL_TICKETS, PROFILE_RECEIPTS, RECEIVED_PAYMENT_TX_HASHES, COSMETICS, EPHEMERAL_CONNECTIONS,
    INSTALL_IDENTITY, GRANTS, CREDIT_GRANTS, VOUCHER_NOTES, DISCOVER_SUBSCRIPTIONS, DISCOVER_NODE_BINDING,
    DISCOVER_INBOX,
  )

  /**
   * The slots that hold SECRET material and therefore go through the keystore wrapper instead of plain settings.
   * The list is short on purpose and the reason is stated once, in [PopopxCommerceStore].
   */
  val SECRET_SLOTS: List<String> = listOf(BADGE_RECORD, TRIAL_GUARD, WALLET, SIGNING_KEY, INSTALL_IDENTITY)
}

/**
 * The persistence layer: 20 slot names, two stores.
 *
 * ### Why two, and which row goes where
 * iOS keeps all twenty in the keychain with `AfterFirstUnlockThisDeviceOnly` (`:1456-1462`). Here the split is by
 * size and by what a row is for:
 *  - **secret rows** — the badge record, the trial guard, the wallet, the signing scalar and the install
 *    fingerprint — go through [PopopxEcoSecrets], the app's own keystore wrapper (an AndroidKeyStore AES-GCM key
 *    per alias on Android, the platform pass-through on desktop). That wrapper caps an item at 4096 bytes, which
 *    is exactly the shape of the iOS "one Keychain blob per table" limit it replaces.
 *  - **bulk tables** — vouchers, ledger, replay guard, packets, tickets, receipts, tx hashes, cosmetics, grants and
 *    notes — are JSON in plain [Settings]. A 200-voucher table is far over that 4096-byte cap, and inventing a
 *    chunked cipher format to squeeze it in would be a second keystore with a second failure mode. The eco module
 *    made the same call for the same reason (`PopopxEcoStore`), and these tables carry no key material: what is in
 *    them is counts, ids and digests.
 *
 * The `ThisDeviceOnly` half of the iOS attribute — "never let a voucher travel to a second machine, where a double
 * spend would be true on both at once" — is a platform property of the keychain and of Android's
 * `directBoot`-excluded storage, not something this file can assert. It is stated here so the next reader knows
 * which half of the guarantee is NOT provided by these two lines of code.
 */
class PopopxCommerceStore(private val defaults: Settings = settings) {
  // MARK: secret rows

  fun readSecret(slot: String): ByteArray? = PopopxEcoSecrets.read(slot, defaults)

  fun writeSecret(data: ByteArray, slot: String): Boolean = PopopxEcoSecrets.write(data, slot, defaults)

  fun containsSecret(slot: String): Boolean = PopopxEcoSecrets.contains(slot, defaults)

  fun removeSecret(slot: String) {
    PopopxEcoSecrets.remove(slot, defaults)
  }

  /** The badge record is a secret row on iOS (`:1414`), so its JSON travels through the wrapper like any other secret. */
  fun readBadgeRecord(): PopopxBadgeRecord? =
    readSecret(PopopxCommerceKeys.BADGE_RECORD)?.decodeToString()?.let { text ->
      try {
        commerceJson.decodeFromJsonElement(PopopxBadgeRecord.serializer(), commerceParse(text))
      } catch (e: Exception) {
        // A row this module cannot read is a row that must not silently light a badge; it is also the one case
        // where deleting it is the wrong answer, because the trial guard would then allow a second claim.
        null
      }
    }

  fun writeBadgeRecord(record: PopopxBadgeRecord): Boolean = writeSecret(encodeRow(PopopxBadgeRecord.serializer(), record), PopopxCommerceKeys.BADGE_RECORD)

  fun readWallet(): PopopxCreditsWallet? =
    readSecret(PopopxCommerceKeys.WALLET)?.decodeToString()?.let { text ->
      try {
        commerceJson.decodeFromJsonElement(PopopxCreditsWallet.serializer(), commerceParse(text))
      } catch (e: Exception) {
        null
      }
    }

  fun writeWallet(wallet: PopopxCreditsWallet): Boolean = writeSecret(encodeRow(PopopxCreditsWallet.serializer(), wallet), PopopxCommerceKeys.WALLET)

  // MARK: bulk table rows

  fun <T> readList(serializer: KSerializer<T>, slot: String): MutableList<T> {
    val text = defaults.getStringOrNull(slot) ?: return mutableListOf()
    return try {
      commerceJson.decodeFromString(ListSerializer(serializer), text).toMutableList()
    } catch (e: Exception) {
      mutableListOf()
    }
  }

  fun <T> writeList(serializer: KSerializer<T>, slot: String, values: List<T>): Boolean =
    put(slot, encodeRow(ListSerializer(serializer), values))

  fun <K, V> readMap(keySerializer: KSerializer<K>, valueSerializer: KSerializer<V>, slot: String): MutableMap<K, V> {
    val text = defaults.getStringOrNull(slot) ?: return mutableMapOf()
    return try {
      commerceJson.decodeFromString(MapSerializer(keySerializer, valueSerializer), text).toMutableMap()
    } catch (e: Exception) {
      mutableMapOf()
    }
  }

  fun <K, V> writeMap(
    keySerializer: KSerializer<K>,
    valueSerializer: KSerializer<V>,
    slot: String,
    values: Map<K, V>,
  ): Boolean = put(slot, encodeRow(MapSerializer(keySerializer, valueSerializer), values))

  /** The tx-hash set is persisted as a list: a `Set` has no stable order, and an unstable order rewrites the row on every save. */
  fun readStringSet(slot: String): MutableSet<String> =
    readList(String.serializer(), slot).toMutableSet()

  fun writeStringSet(slot: String, values: Collection<String>): Boolean =
    writeList(String.serializer(), slot, values.toList())

  /**
   * One object in one slot — the shape [PopopxReplayGuard] has, and the reason the list and map forms above are not
   * enough. A row that fails to decode reads as absent, and the caller mints a fresh one, which is what iOS's
   * `decode … ?? PopopxReplayGuard()` does (`PopopxCreditsManager.swift:72`).
   */
  fun <T> readObject(serializer: KSerializer<T>, slot: String): T? {
    val text = defaults.getStringOrNull(slot) ?: return null
    return try {
      commerceJson.decodeFromString(serializer, text)
    } catch (e: Exception) {
      null
    }
  }

  fun <T> writeObject(value: T, serializer: KSerializer<T>, slot: String): Boolean =
    put(slot, encodeRow(serializer, value))

  private fun <T> encodeRow(serializer: SerializationStrategy<T>, value: T): ByteArray =
    commerceJson.encodeToString(serializer, value).encodeToByteArray()

  private fun put(slot: String, body: ByteArray): Boolean = try {
    defaults.putString(slot, body.decodeToString())
    true
  } catch (e: Exception) {
    false
  }

  /**
   * Wipes every trace this module left (`:1512-1515`), the emergency self-destruct and "clear my data" both call
   * it. Both stores are covered because the slots are enumerated from one list, which is the same reason iOS
   * iterates `allCases`: a slot added to the enum and not to the wipe leaves somebody's gift message behind.
   */
  fun wipeAll() {
    for (slot in PopopxCommerceKeys.ALL) {
      if (PopopxCommerceKeys.SECRET_SLOTS.contains(slot)) removeSecret(slot) else defaults.remove(slot)
    }
  }
}
