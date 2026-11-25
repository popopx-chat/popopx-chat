package chat.popopx.common.eco

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.popopx.common.crypto.hexEncode
import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

// Ported from apps/ios/Shared/Features/ServiceAccount/PopopxEcoRouterAndDeepLink.swift:55-311.
//
// `@Observable` becomes Compose snapshot state, so a card bubble re-renders when the store changes it.
// `UserDefaults` becomes the app's own `Settings`, injected so a unit test can hand over an in-memory map.

/** The `UserDefaults` keys of this module, named in one place, exactly as iOS spells them. */
object PopopxEcoKeys {
  const val CHANNEL_INDEX = "popopx.eco.channels"
  const val EXPIRY_WARNING_DAYS = "popopx.eco.key.expiryWarningDays"
  const val MENUS = "popopx.eco.menus"
  const val MENU_REVISIONS = "popopx.eco.menu.revisions"
  const val CARDS = "popopx.eco.cards"
  const val PENDING_INTENTS = "popopx.eco.pendingIntents"

  val ALL_SETTINGS_KEYS = listOf(CHANNEL_INDEX, EXPIRY_WARNING_DAYS, MENUS, MENU_REVISIONS, CARDS, PENDING_INTENTS)

  const val SESSION_UID_PREFIX = "popopx.eco.session.uid."
  const val SESSION_SVC_PREFIX = "popopx.eco.session.svc."

  /**
   * The anti-theft wipe. iOS cannot enumerate Keychain accounts, so the caller hands over the ids it knows
   * about; every branch of this is user-triggered, and it is not a "clear cache" convenience.
   */
  fun wipe(contactIds: List<Long>, channelIds: List<String>, defaults: Settings = settings) {
    for (contactId in contactIds) {
      PopopxEcoSecrets.remove(PopopxEcoKeychain.sessionAccount(contactId), defaults)
      defaults.remove(SESSION_UID_PREFIX + contactId)
      defaults.remove(SESSION_SVC_PREFIX + contactId)
    }
    for (channelId in channelIds) {
      PopopxEcoSecrets.remove(PopopxEcoKeychain.channelAccount(channelId), defaults)
      PopopxEcoSecrets.remove(PopopxEcoKeychain.currentEpochAccount(channelId), defaults)
      for (epoch in 1..PopopxEcoLimits.MAXIMUM_STORED_EPOCHS) {
        PopopxEcoSecrets.remove(PopopxEcoKeychain.epochAccount(channelId, epoch), defaults)
      }
    }
    for (key in ALL_SETTINGS_KEYS) defaults.remove(key)
  }
}

/** What one frame did. The router logs it and the views act only on the ones a user can see. */
enum class PopopxEcoApplyOutcome {
  RENDERED_CARD,
  UPDATED_CARD,
  STORED_SESSION,
  STORED_MENU,
  ROTATED_KEY,
  IGNORED_STALE,
  REJECTED,
  KEYCHAIN_FAILED,
}

/** A one-shot message the router raised and a view is allowed to show. */
sealed class PopopxEcoNotice {
  data class KeyRotated(val channelId: String, val epoch: Int, val revoked: Boolean) : PopopxEcoNotice()

  /** The reason travels as a value; the view decides how much of it to say. */
  data class KeyRejected(val channelId: String, val reason: PopopxKeyRejection) : PopopxEcoNotice()

  data class InsufficientCredits(val required: Int) : PopopxEcoNotice()

  data object ActionFailed : PopopxEcoNotice()
}

/**
 * The Keychain half of a session handshake: the secret in the keystore under `session.<contactId>`, the
 * pseudonym beside it in plain settings. The uid is not a secret and the `open_url` path needs it without
 * touching the secret, so the two are stored apart exactly as on iOS.
 */
object PopopxEcoSessionStore {
  fun save(session: PopopxEcoSession, contactId: Long, defaults: Settings = settings): Boolean {
    val secret = session.secretBytes ?: return false
    if (!PopopxEcoSecrets.write(secret, PopopxEcoKeychain.sessionAccount(contactId), defaults)) return false
    defaults.putString(PopopxEcoKeys.SESSION_UID_PREFIX + contactId, session.pairwiseUid)
    session.serviceId?.let { defaults.putString(PopopxEcoKeys.SESSION_SVC_PREFIX + contactId, it) }
    return true
  }

  fun session(contactId: Long, defaults: Settings = settings): PopopxEcoSession? {
    val secret = PopopxEcoSecrets.read(PopopxEcoKeychain.sessionAccount(contactId), defaults) ?: return null
    val uid = defaults.getStringOrNull(PopopxEcoKeys.SESSION_UID_PREFIX + contactId)
    if (uid.isNullOrEmpty()) return null
    return PopopxEcoSession(uid, hexEncode(secret), defaults.getStringOrNull(PopopxEcoKeys.SESSION_SVC_PREFIX + contactId))
  }

  fun hasSession(contactId: Long, defaults: Settings = settings): Boolean = PopopxEcoSecrets.contains(PopopxEcoKeychain.sessionAccount(contactId), defaults)

  fun remove(contactId: Long, defaults: Settings = settings) {
    PopopxEcoSecrets.remove(PopopxEcoKeychain.sessionAccount(contactId), defaults)
    defaults.remove(PopopxEcoKeys.SESSION_UID_PREFIX + contactId)
    defaults.remove(PopopxEcoKeys.SESSION_SVC_PREFIX + contactId)
  }
}

/**
 * The cards and menus this device currently knows about. One object rather than a per-conversation model,
 * because a `cardId` is minted by the server and global: the bubble that renders it is looked up by that
 * id from a message in a conversation the store has no opinion about.
 */
class PopopxEcoStore(
  private val defaults: Settings = settings,
  private val keyRotation: PopopxChannelKeyRotation = PopopxChannelKeyRotation.shared,
) {
  private val json = Json { ignoreUnknownKeys = true }

  /** The newest known state of each card, which is also what makes "the bubble shows the latest state after a relaunch" true. */
  private val cards = mutableStateMapOf<String, PopopxServiceCard>()

  /** The live menu of each service account, by local contact id. Never persisted — see [loadIfNeeded]. */
  private val menus = mutableStateMapOf<Long, PopopxEcoMenu>()

  var pendingNotice: PopopxEcoNotice? by mutableStateOf(null)
    private set

  /** Per-action lockout so a double tap cannot fire two callbacks. Cleared when the card itself changes. */
  private val lockedActions = mutableSetOf<String>()

  private var loaded = false

  val storedCards: List<PopopxServiceCard>
    get() {
      loadIfNeeded()
      return cards.values.sortedByDescending { it.updatedAtMs }
    }

  fun loadIfNeeded() {
    if (loaded) return
    loaded = true
    val stored = defaults.getStringOrNull(PopopxEcoKeys.CARDS) ?: return
    val elements = try {
      json.parseToJsonElement(stored).jsonArray
    } catch (e: Exception) {
      return
    }
    cards.clear()
    for (element in elements) {
      val card = try {
        PopopxEcoWire.cardFromJson(element.jsonObject)
      } catch (e: Exception) {
        null
      } ?: continue
      if (card.isSane) cards[card.cardId] = card
    }
    // Menus are keyed by a local contact id, which is NOT portable: `ChatInfo.apiId` is a row number in
    // this device's database, so a menu restored under an id that now belongs to a different conversation
    // would hand one contact's buttons to another. They are rebuilt from inbound `menu_config` frames.
  }

  /** The state a bubble should render: the store's newest version, otherwise the payload of the message that created it. */
  fun rendered(card: PopopxServiceCard): PopopxServiceCard {
    loadIfNeeded()
    val current = cards[card.cardId] ?: return card
    // `>=` here while `apply` compares with `>`: on a tie the stored card wins when reading and the
    // incoming frame wins when writing. Two different questions, and the two operators are the answer.
    return if (current.updatedAtMs >= card.updatedAtMs) current else card
  }

  fun card(cardId: String): PopopxServiceCard? {
    loadIfNeeded()
    return cards[cardId]
  }

  fun liveMenu(contactId: Long): PopopxEcoMenu? {
    loadIfNeeded()
    return menus[contactId]
  }

  /**
   * The menu without the load. A composable reads menus during every frame, and [liveMenu]'s
   * [loadIfNeeded] writes the card map on its first call — a state write during composition. The load is also
   * pointless here: it restores cards only, never menus, which are rebuilt solely from inbound `menu_config`
   * frames. Same reason iOS's bar indexes `menus[contactId]` directly (BotMenuBarView.swift:27-31).
   */
  fun peekMenu(contactId: Long): PopopxEcoMenu? = menus[contactId]

  /**
   * The handshake half of one contact, read through this instance's settings.
   *
   * The getter exists so a caller cannot read the session from the platform defaults while this store wrote
   * it to the settings it was built with — the two ends of a pairwise secret have to be the same store or the
   * secret is unreachable, which is precisely what `PopopxEcoActionRunner`'s `open_url` gate reads.
   */
  fun session(contactId: Long): PopopxEcoSession? = PopopxEcoSessionStore.session(contactId, defaults)

  fun isActionLocked(cardId: String, actionId: String): Boolean = lockedActions.contains(lockKey(cardId, actionId))

  /**
   * `cardId` and `actionId` are joined with U+0001 rather than a printable character because both are
   * server-supplied and neither is forbidden from containing `-` or `:`; only a separator that cannot
   * appear in either half keeps the two pairs from colliding onto one key.
   */
  fun lock(cardId: String, actionId: String) {
    if (lockedActions.size >= MAXIMUM_LOCKED_ACTIONS) lockedActions.clear()
    lockedActions.add(lockKey(cardId, actionId))
  }

  fun apply(frame: PopopxEcoFrame, contactId: Long): PopopxEcoApplyOutcome {
    loadIfNeeded()
    return when (frame) {
      is PopopxEcoFrame.SessionHandshake -> {
        if (!frame.session.isSane) return PopopxEcoApplyOutcome.REJECTED
        if (PopopxEcoSessionStore.save(frame.session, contactId, defaults)) {
          PopopxEcoApplyOutcome.STORED_SESSION
        } else {
          PopopxEcoApplyOutcome.KEYCHAIN_FAILED
        }
      }

      is PopopxEcoFrame.MenuConfig -> {
        if (!frame.menu.isSane) return PopopxEcoApplyOutcome.REJECTED
        val existing = menus[contactId]
        val existingRevision = existing?.revision
        val revision = frame.menu.revision
        // A menu conflict is decided by `rev` alone, and only when BOTH sides carry one: an absent
        // revision is not zero, so an unversioned menu replaces what is stored rather than being dropped.
        if (existing != null && existingRevision != null && revision != null && revision < existingRevision) {
          return PopopxEcoApplyOutcome.IGNORED_STALE
        }
        menus[contactId] = frame.menu
        PopopxEcoApplyOutcome.STORED_MENU
      }

      is PopopxEcoFrame.ServiceCard -> {
        if (!frame.card.isSane) return PopopxEcoApplyOutcome.REJECTED
        val current = cards[frame.card.cardId]
        if (current != null && current.updatedAtMs > frame.card.updatedAtMs) return PopopxEcoApplyOutcome.IGNORED_STALE
        val wasCreate = frame.card.mode == PopopxServiceCard.Mode.CREATE
        cards[frame.card.cardId] = merged(frame.card, current)
        // A card change means whatever was in flight either landed or was replaced, so that lockout lifts.
        pruneLocks(frame.card.cardId)
        saveCards()
        if (wasCreate) PopopxEcoApplyOutcome.RENDERED_CARD else PopopxEcoApplyOutcome.UPDATED_CARD
      }

      is PopopxEcoFrame.ChannelKeyUpdate ->
        // `contactId` is safe to record as the issuer: the inbound gate refuses every frame but a card in a group.
        when (val result = keyRotation.apply(frame.update, contactId)) {
          is PopopxKeyRotationResult.Installed -> {
            pendingNotice = PopopxEcoNotice.KeyRotated(frame.update.channelId, result.epoch, result.revoked.isNotEmpty())
            PopopxEcoApplyOutcome.ROTATED_KEY
          }

          is PopopxKeyRotationResult.AlreadyCurrent -> PopopxEcoApplyOutcome.IGNORED_STALE

          is PopopxKeyRotationResult.Rejected -> {
            pendingNotice = PopopxEcoNotice.KeyRejected(frame.update.channelId, result.reason)
            PopopxEcoApplyOutcome.REJECTED
          }
        }
    }
  }

  /**
   * Merge an update into what is on screen. Absent sections mean "unchanged", not "cleared": a frame that
   * carries only `progress` would otherwise wipe the title and the buttons. `fields` and `actions` are
   * replaced wholesale when present, because a partial grid row is not a meaning anyone can read.
   */
  private fun merged(new: PopopxServiceCard, old: PopopxServiceCard?): PopopxServiceCard {
    if (old == null) return new
    return old.copy(
      title = if (new.title.isNotEmpty()) new.title else old.title,
      body = new.body ?: old.body,
      fields = if (new.fields.isNotEmpty()) new.fields else old.fields,
      actions = if (new.actions.isNotEmpty()) new.actions else old.actions,
      progress = new.progress ?: old.progress,
      expiresAtMs = new.expiresAtMs ?: old.expiresAtMs,
      // Style always overwrites: the server is allowed to repaint a card it has already sent.
      style = new.style,
      updatedAtMs = maxOf(old.updatedAtMs, new.updatedAtMs),
      // An update never stays an update. What is stored is the card's current state, and a bubble that
      // renders it must not re-send a confirmation for something that already landed.
      mode = PopopxServiceCard.Mode.CREATE,
    )
  }

  private fun pruneLocks(cardId: String) {
    val prefix = lockKey(cardId, "")
    lockedActions.removeAll { it.startsWith(prefix) }
  }

  private fun saveCards() {
    // Bounded history, oldest `ut` dropped first. Because the cap is enforced this way the store is a view
    // of the newest MAXIMUM_STORED_CARDS cards and NOT a replayable audit chain.
    val sorted = cards.values.sortedBy { it.updatedAtMs }
    val keep = if (sorted.size <= PopopxEcoLimits.MAXIMUM_STORED_CARDS) {
      sorted
    } else {
      sorted.subList(sorted.size - PopopxEcoLimits.MAXIMUM_STORED_CARDS, sorted.size)
    }
    // The map is rebuilt from the kept list rather than merely trimmed, so a dropped card cannot survive as a key.
    cards.clear()
    cards.putAll(keep.associateBy { it.cardId })
    defaults.putString(PopopxEcoKeys.CARDS, JsonArray(keep.map { PopopxEcoWire.cardToJson(it) }).toString())
  }

  fun takeNotice(): PopopxEcoNotice? {
    val notice = pendingNotice
    pendingNotice = null
    return notice
  }

  fun raise(notice: PopopxEcoNotice) {
    pendingNotice = notice
  }

  companion object {
    /** The instance the app uses. Tests construct their own over an in-memory [Settings]. */
    val shared: PopopxEcoStore = PopopxEcoStore()

    /** Bounded so a long-lived process cannot grow the set past usefulness. */
    private const val MAXIMUM_LOCKED_ACTIONS = 256
  }
}

/** U+0001: a character that cannot appear in either half of a lockout key. */
private fun lockKey(cardId: String, actionId: String): String = cardId + 1.toChar() + actionId