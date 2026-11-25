package chat.popopx.common.discover

import chat.popopx.common.eco.PopopxEcoSecrets
import chat.popopx.common.platform.Log
import chat.popopx.common.platform.TAG
import chat.popopx.common.platform.settings
import com.russhwolf.settings.Settings
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The 30-day cycle engine, its persistence and its one-time notices
 * (DiscoverSubscriptionManager.swift:157-573, plus the sheet's paste path in
 * MacNodePairingSheet.swift:179-198).
 *
 * Three MEASURED properties of the Swift, each kept because it is the security or money story:
 *
 *  1. THE TRIGGERS ARE ONLY FOREGROUND AND PULL-TO-REFRESH. iOS has no timer, no push, no
 *     background task for this engine: `sweep` runs from `onSceneActive`
 *     (DiscoverSubscriptionManager.swift:199-202, called from MainTabView's `.task` and every
 *     `scenePhase == .active`) and from the plaza's `.refreshable` (PopopxDiscoverView.swift:79).
 *     This port exposes exactly [onForeground] and [onPullToRefresh]; a scheduler wired elsewhere
 *     would let the cycle renew itself without the user ever opening the app, which is the thing
 *     the file's comment about "a renewal Apple did not approve" (:392-393) is guarding.
 *  2. THE CHARGE COMMITS BEFORE THE STATE WRITE, AND A FAILED STATE WRITE DOES NOT ROLL BACK THE
 *     CHARGE. [activate] pays the ledger first; if the keystore then refuses the activation row,
 *     the iOS code logs the loss (:295) and throws `persistenceFailed` while KEEPING the row in
 *     memory for the session (:291-297) — the debit stands, because this layer does not own the
 *     wallet and a blind second debit later would be worse. The identical ordering and non-rollback
 *     is ported; [PopopxActivationResult.PersistenceFailed] is that branch, and
 *     `chargeCommittedBeforeFailedStateWrite` pins it.
 *  3. RENEWALS NEVER BILL BACKWARDS: `expiresAtMs = max(existing expiry, now) + cycle` (:365). A
 *     device that slept through two cycles pays for one and keeps the time it already bought.
 *
 * PERSISTENCE DEVIATION, deliberate: iOS keeps subscriptions, the binding AND the inbox in the
 * Keychain (:184-186). Here the first two go through the app's shared keystore
 * ([PopopxEcoSecrets] — no second keystore), but the INBOX is stored as plain settings text,
 * because a full 10×40-card history can exceed that keystore's 4096-byte-per-secret ceiling
 * (PopopxEcoSecrets.kt:41) and a silently-failing write would lose receipts. Result cards are
 * display data produced by a renderer, not a credential (see [PopopxNodeResultCard]), so plaintext
 * at rest costs nothing the model does not already leak to the screen.
 */
class PopopxSubscriptionEngine(
  private val defaults: Settings = settings,
  /**
   * The commerce wallet, behind a seam: this module never owns a ledger. It is a `var` because the app installs it
   * at startup — [shared] is built before the commerce singleton is reachable from here, and an unwired engine
   * charges nothing, which is the honest behaviour of a build with no wallet.
   */
  var ledger: PopopxDiscoverLedger = PopopxDiscoverLedger.UNPAID,
  /**
   * Read once, never requested (DiscoverSubscriptionManager.swift:172-174): posting a notice must
   * not be the reason a permission dialog appears the first time a cycle lapses. The default says
   * "not authorised", so an un-wired build degrades to the in-app badge only.
   */
  private val notificationsAuthorised: () -> Boolean = { false },
  /** The `UNUserNotificationCenter.add` leg (:426-431). Returning false is the "could not be posted" error path. */
  private val shortfallPoster: (PopopxShortfallNotice) -> Boolean = { false },
  /**
   * `PopopxSilentSignalingRouter.sendNodeCommand(_:toContactId:)` (:496, :510). The seam is
   * synchronous here because this module holds no coroutine scope; the app-side router port makes
   * it suspending and adapts. Returning true is "delivered", which is what confirms the handshake.
   */
  private val nodeCommandSender: (command: PopopxNodeCommand, contactId: Long) -> Boolean = { _, _ -> false },
  /**
   * `PopopxEcoDeepLinkHandler.handle` (MacNodePairingSheet.swift:184-188): pasted pairing text is
   * offered to the eco protocol FIRST, because that lane is another agent's package and this one
   * must not import it. Default false = nothing else claimed the text.
   */
  private val ecoLinkConsumed: (String) -> Boolean = { false },
  /** TIME SEAM: every clock read in this class goes through it, in milliseconds like the stored model. */
  private val nowMs: () -> Long = { System.currentTimeMillis() },
  /** The `os.Logger` lines (subsystem "com.popopxchat.popopx", category "discover"); no-op by default. */
  private val logger: (String) -> Unit = {},
) {
  companion object {
    /**
     * The module's own `shared`, as on iOS (:158), wired to the platform defaults and the real
     * logger. Tests must NOT use it: the desktop `settings`/`Log` actuals touch the user's own
     * preference store, so a test constructs its own engine over `PropertiesSettings`.
     */
    val shared: PopopxSubscriptionEngine = PopopxSubscriptionEngine(logger = { Log.i(TAG, it) })
  }

  // MARK: State

  private var subscriptionRows: MutableList<PopopxDiscoverSubscription> = ArrayList()
  private var bindingRecord: PopopxMacNodeBinding? = null
  private val inboxRows: LinkedHashMap<String, MutableList<PopopxNodeResultCard>> = LinkedHashMap()
  /**
   * MEASURED: session-only on iOS too (:169, and `loadIfNeeded` never decodes it) — the set is
   * what makes an expired row read as `awaitingBalance` instead of plain `expired` until the app
   * is relaunched. It is deliberately NOT persisted, so a restart re-derives it from silence.
   */
  private val awaitingBalance: MutableSet<PopopxNodeServiceId> = LinkedHashSet()

  private var loaded = false
  var lastSweepAtMs: Long? = null
    private set

  /** `subscriptions` (:160). A copy: iOS's is `private(set)` and views must not append to it. */
  val subscriptions: List<PopopxDiscoverSubscription>
    get() {
      loadIfNeeded()
      return subscriptionRows.toList()
    }

  /** `binding` (:161): the one Mac this device remembers, or null. */
  val binding: PopopxMacNodeBinding?
    get() {
      loadIfNeeded()
      return bindingRecord
    }

  /** `nodeContactId` (:477-480): the contact the node answers on, when this device knows it. */
  val nodeContactId: Long?
    get() {
      loadIfNeeded()
      return bindingRecord?.contactId
    }

  val servicesAwaitingBalance: Set<PopopxNodeServiceId>
    get() {
      loadIfNeeded()
      return awaitingBalance.toSet()
    }

  // MARK: Loading

  /** `loadIfNeeded` (:181-188), minus `refreshNotificationAuthorization` — that is the host's job behind [notificationsAuthorised]. */
  private fun loadIfNeeded() {
    if (loaded) return
    loaded = true
    subscriptionRows = readSubscriptionRows()
    bindingRecord = readBinding()
    readInboxInto(inboxRows)
  }

  /**
   * `save` (:204-211) mirrored item for item: an empty subscription list REMOVES its keystore
   * account rather than writing "[]", the binding lives in its own slot via [saveBinding], and the
   * inbox is rewritten whole. Return value is whether the subscription write succeeded, which only
   * [activate] consults (deviation, KDoc at [activate]: iOS ignores every save failure except
   * activate's, and so does this — but it has to be returned to be ignored honestly).
   */
  private fun save(): Boolean {
    val subscriptionsOk =
      if (subscriptionRows.isEmpty()) {
        PopopxEcoSecrets.remove(PopopxDiscoverStore.ACCOUNT_SUBSCRIPTIONS, defaults)
        true
      } else {
        writeSecret(subscriptionText().encodeToByteArray(), PopopxDiscoverStore.ACCOUNT_SUBSCRIPTIONS)
      }
    writeInboxPlain()
    return subscriptionsOk
  }

  /** `saveBinding` (:213-219). iOS ignores the write result (`_ = encode`); this returns it so [bond] can be honest. */
  private fun saveBinding(): Boolean {
    val record = bindingRecord
    if (record == null) {
      PopopxEcoSecrets.remove(PopopxDiscoverStore.ACCOUNT_NODE_BINDING, defaults)
      return true
    }
    return writeSecret(popopxJsonEncode(PopopxMacNodeBinding.toJson(record)).encodeToByteArray(), PopopxDiscoverStore.ACCOUNT_NODE_BINDING)
  }

  private fun writeSecret(data: ByteArray, account: String): Boolean = PopopxEcoSecrets.write(data, account, defaults)

  // MARK: Reading state

  fun subscriptionFor(serviceId: PopopxNodeServiceId): PopopxDiscoverSubscription? {
    loadIfNeeded()
    return subscriptionRows.firstOrNull { it.serviceId == serviceId }
  }

  /** `status(for:now:)` (:228-243), labels and usability included. */
  fun statusFor(serviceId: PopopxNodeServiceId, now: Long = nowMs()): PopopxDiscoverServiceStatus {
    loadIfNeeded()
    val row = subscriptionRows.firstOrNull { it.serviceId == serviceId }
      ?: return if (serviceId.cycleCost.isRenewable) PopopxDiscoverServiceStatus.NotActivated else PopopxDiscoverServiceStatus.Metered
    if (row.isActive(now)) {
      val soon = row.millisecondsRemaining(now) <= PopopxDiscoverLimits.RENEWAL_WINDOW_MILLIS
      return if (soon) {
        PopopxDiscoverServiceStatus.ExpiringToday(row.autoRenew)
      } else {
        PopopxDiscoverServiceStatus.Active(row.autoRenew)
      }
    }
    // Past expiry, "I stopped it" and "it could not pay" are not one message (:237-239), and only
    // the second may nag about balance (:142-150). `awaitingBalance` exists only while this
    // session remembers a failed sweep for that service.
    if (!row.autoRenew || row.serviceId.cycleCost.renewalCredits == null) return PopopxDiscoverServiceStatus.Expired
    if (serviceId in awaitingBalance) {
      val overdueDays = (-row.millisecondsRemaining(now)).coerceAtLeast(0L) / 1_000L / PopopxDiscoverLimits.SECONDS_PER_DAY
      return PopopxDiscoverServiceStatus.AwaitingBalance(overdueDays.toInt())
    }
    return PopopxDiscoverServiceStatus.Expired
  }

  /** `activeCount` (:245-248). */
  val activeCount: Int
    get() {
      loadIfNeeded()
      val now = nowMs()
      return subscriptionRows.count { it.isActive(now) }
    }

  /**
   * `activeCountByFilter` (:255-265): a filter with nothing live gets NO entry, not a zero — the
   * chip shows nothing rather than a number a glance already sees.
   */
  fun activeCountByFilter(): Map<PopopxDiscoverFilter, Int> {
    loadIfNeeded()
    val now = nowMs()
    val live = subscriptionRows.filter { it.isActive(now) }.map { it.serviceId }
    if (live.isEmpty()) return emptyMap()
    val counts = LinkedHashMap<PopopxDiscoverFilter, Int>()
    counts[PopopxDiscoverFilter.ALL] = live.size
    for (filter in listOf(PopopxDiscoverFilter.PRODUCTIVITY, PopopxDiscoverFilter.COMPUTE, PopopxDiscoverFilter.SANCTUARY)) {
      val matching = live.count { filter.matches(it.section) }
      if (matching > 0) counts[filter] = matching
    }
    return counts
  }

  // MARK: Activating

  /**
   * `activate(_:now:)` (:273-299). The debit happens FIRST and the row write SECOND, and a write
   * that fails does not undo the debit (class KDoc item 2): the row stays in this session's memory,
   * the log line is kept verbatim in spirit, and [PopopxActivationResult.PersistenceFailed] is
   * returned where iOS threw `persistenceFailed`. `ledger` owns the wallet; this module cannot and
   * does not pretend to roll it back.
   */
  fun activate(serviceId: PopopxNodeServiceId, now: Long = nowMs()): PopopxActivationResult {
    loadIfNeeded()
    if (subscriptionRows.any { it.serviceId == serviceId }) return PopopxActivationResult.AlreadyActive(serviceId)
    val credits = serviceId.cycleCost.renewalCredits
      ?: // A metered service has no cycle to buy; a nominal figure would print a price nothing
      // charges and a balance nothing debits (:276-281).
      return PopopxActivationResult.ActivationNotSupported(serviceId)
    val charged =
      try {
        ledger.payForService(credits, PopopxDiscoverCopy.ledgerActivationNote(serviceId.title, PopopxDiscoverLimits.CYCLE_DAYS))
      } catch (_: Exception) {
        false
      }
    if (!charged) return PopopxActivationResult.ChargeRefused(serviceId, credits, ledger.balance)
    val rows = ArrayList(subscriptionRows.filter { it.serviceId != serviceId })
    rows.add(PopopxDiscoverSubscription.new(serviceId, now))
    subscriptionRows = rows
    awaitingBalance.remove(serviceId)
    if (!save()) {
      logger("discover: activation row for ${serviceId.rawValue} could not reach the keychain")
      return PopopxActivationResult.PersistenceFailed(serviceId, credits)
    }
    logger("discover: activated ${serviceId.rawValue} for $credits credits")
    return PopopxActivationResult.Charged(serviceId, credits, rows.last().expiresAtMs)
  }

  /** `setAutoRenew(_:for:)` (:301-307). Turning renewals back ON clears the notice marker, so the next lapse may warn once. */
  fun setAutoRenew(enabled: Boolean, serviceId: PopopxNodeServiceId) {
    loadIfNeeded()
    val index = subscriptionRows.indexOfFirst { it.serviceId == serviceId }
    if (index < 0) return
    val row = subscriptionRows[index]
    subscriptionRows[index] =
      if (enabled) row.copy(autoRenew = true, shortfallNoticeExpiresAtMs = null) else row.copy(autoRenew = false)
    save()
  }

  /** `stop(_:)` (:311-316): the row goes, the inbox STAYS — a cancelled service's results are still the user's proof the Mac ran. */
  fun stop(serviceId: PopopxNodeServiceId) {
    loadIfNeeded()
    subscriptionRows = ArrayList(subscriptionRows.filterNot { it.serviceId == serviceId })
    awaitingBalance.remove(serviceId)
    save()
  }

  // MARK: The cycle sweep

  /**
   * `sweep(now:)` (:326-380): per-row outcomes, never an abort — one unpaid balance must not stop
   * the other nine rows (:105-106). A charge refusal (Swift's `payForService` throw) records
   * `balanceShort` WITHOUT a notice (:355-362): the money layer said no, which the user already
   * sees as the badge; only the balance-preflight short posts (:347).
   *
   * Renewal math is `max(existingExpiry, now) + cycle` (:365, class KDoc item 3): no back-billing
   * for time the user already paid for, whatever the device was doing meanwhile.
   */
  fun sweep(now: Long = nowMs()): List<PopopxDiscoverRenewalOutcome> {
    loadIfNeeded()
    lastSweepAtMs = now
    val outcomes = ArrayList<PopopxDiscoverRenewalOutcome>()
    val rows = ArrayList(subscriptionRows)
    var changed = false
    for (index in rows.indices) {
      val row = rows[index]
      val serviceId = row.serviceId
      val credits = serviceId.cycleCost.renewalCredits
      if (credits == null) {
        outcomes.add(PopopxDiscoverRenewalOutcome.NotRenewable(serviceId))
        continue
      }
      if (!row.renewalWindowOpen(now)) {
        outcomes.add(PopopxDiscoverRenewalOutcome.NotDue(serviceId))
        continue
      }
      val balance = ledger.balance
      if (balance < credits) {
        outcomes.add(PopopxDiscoverRenewalOutcome.BalanceShort(serviceId, credits, balance))
        awaitingBalance.add(serviceId)
        changed = true
        rows[index] = postShortfallNotice(row, credits, balance)
        continue
      }
      val paid =
        try {
          ledger.payForService(credits, PopopxDiscoverCopy.ledgerRenewalNote(serviceId.title, PopopxDiscoverLimits.CYCLE_DAYS))
        } catch (_: Exception) {
          false
        }
      if (!paid) {
        // The wallet re-checked and refused. Same visible outcome as a short balance, reached by a
        // different route, recorded as one — and no notice (:356-362). The balance is RE-READ for
        // the outcome because the refusal may have moved it.
        outcomes.add(PopopxDiscoverRenewalOutcome.BalanceShort(serviceId, credits, ledger.balance))
        awaitingBalance.add(serviceId)
        changed = true
        continue
      }
      val renewed =
        row.copy(
          expiresAtMs = maxOf(row.expiresAtMs, now) + PopopxDiscoverLimits.CYCLE_MILLIS,
          lastRenewalAtMs = now,
          cyclesPaid = row.cyclesPaid + 1,
          shortfallNoticeExpiresAtMs = null,
        )
      rows[index] = renewed
      awaitingBalance.remove(serviceId)
      changed = true
      outcomes.add(PopopxDiscoverRenewalOutcome.Renewed(serviceId, credits, renewed.expiresAtMs))
      logger("discover: renewed ${serviceId.rawValue}, cycle ${renewed.cyclesPaid}")
    }
    if (changed) {
      subscriptionRows = rows
      save()
    }
    return outcomes
  }

  /** `start()`/`onSceneActive(now:)` (:190-202) — trigger 1 of 2. See the class KDoc. */
  fun onForeground(now: Long = nowMs()): List<PopopxDiscoverRenewalOutcome> {
    loadIfNeeded()
    return sweep(now)
  }

  /** The plaza's `.refreshable { data.sweep() }` (PopopxDiscoverView.swift:79) — trigger 2 of 2. */
  fun onPullToRefresh(now: Long = nowMs()): List<PopopxDiscoverRenewalOutcome> {
    loadIfNeeded()
    return sweep(now)
  }

  /**
   * `postShortfallNotice` (:394-432): ONE notice per lapse, keyed to the expiry the notice was
   * posted for — a service that stays unpaid for a week must not grow the notification list on
   * every launch (:391-393, :400). The marker is set even when notifications are unauthorised, so
   * permission arriving later does not retroactively spam the same lapse; the in-app badge carries
   * the truth meanwhile. Returns the row with its marker updated.
   */
  private fun postShortfallNotice(row: PopopxDiscoverSubscription, required: Int, balance: Int): PopopxDiscoverSubscription {
    if (row.shortfallNoticeExpiresAtMs == row.expiresAtMs) return row
    val serviceId = row.serviceId
    awaitingBalance.add(serviceId)
    if (!notificationsAuthorised()) {
      logger("discover: shortfall notice suppressed for ${serviceId.rawValue}, notifications not authorised")
      return row.copy(shortfallNoticeExpiresAtMs = row.expiresAtMs)
    }
    val notice =
      PopopxShortfallNotice(
        serviceId = serviceId,
        title = PopopxDiscoverCopy.SHORTFALL_TITLE,
        body = PopopxDiscoverCopy.shortfallBody(serviceId.title, required, balance),
        // The delivery identity, spelled as iOS builds it (:418-419): one request per expiry.
        requestIdentifier = "popopx.discover.shortfall.${serviceId.rawValue}.${row.expiresAtMs}",
        channelId = PopopxDiscoverLimits.SHORTFALL_CHANNEL_ID,
      )
    if (!shortfallPoster(notice)) {
      // A notice this device could not post is not retried forever and not reported as posted
      // (:426-431) — the marker above already stands, which IS the no-retry rule.
      logger("discover: shortfall notice could not be posted")
    }
    return row.copy(shortfallNoticeExpiresAtMs = row.expiresAtMs)
  }

  // MARK: Inbox

  /**
   * `recordInbound(text:fromPairedNode:now:)` (:443-447).
   *
   * The caller supplies `fromPairedNode`, and this engine NEVER infers it: an unpaired text that
   * looks like a result card returns null here, which on iOS means the bubble renders exactly as
   * it arrived — the result card is a renderer, not a filter ([PopopxNodeResultCard] KDoc).
   */
  fun recordInboundText(text: String, fromPairedNode: Boolean, now: Long = nowMs()): PopopxNodeResultCard? {
    loadIfNeeded()
    val card = PopopxNodeResultCard.detect(text, fromPairedNode, now) ?: return null
    return storeCard(card)
  }

  /** `recordInbound(command:now:)` (:453-456): a marked NODE_CMD that came back — the inbox is the only place it can be read. */
  fun recordInboundCommand(command: PopopxNodeCommand, now: Long = nowMs()): PopopxNodeResultCard {
    loadIfNeeded()
    return storeCard(PopopxNodeResultCard.decodeCommand(command, now))
  }

  /** `store(_:)` (:458-467): newest first, capped at [PopopxDiscoverLimits.MAXIMUM_INBOX_ROWS] per service. */
  private fun storeCard(card: PopopxNodeResultCard): PopopxNodeResultCard {
    val rows = inboxRows.getOrPut(card.serviceId.rawValue) { ArrayList() }
    rows.add(0, card)
    if (rows.size > PopopxDiscoverLimits.MAXIMUM_INBOX_ROWS) {
      repeat(rows.size - PopopxDiscoverLimits.MAXIMUM_INBOX_ROWS) { rows.removeAt(rows.size - 1) }
    }
    save()
    return card
  }

  /** `results(for:)` (:469-472), newest first. */
  fun resultsFor(serviceId: PopopxNodeServiceId): List<PopopxNodeResultCard> {
    loadIfNeeded()
    return inboxRows[serviceId.rawValue]?.toList() ?: emptyList()
  }

  // MARK: Pairing and bonding

  /**
   * The sheet's paste-accept path (MacNodePairingSheet.swift:179-198), in the iOS order:
   * trimmed text, empty means ignore (not even a notice), the eco protocol gets first refusal on
   * anything that is its own deep link, and ONLY THEN the pairing decode. Every pairing failure
   * collapses to [PopopxPairingAccept.Rejected], whose only user-visible content is the one
   * generic sentence — the typed reason stays inside [PopopxNodePairing.evaluate].
   */
  fun acceptPastedCode(text: String, now: Long = nowMs()): PopopxPairingAccept {
    val trimmed = text.trim { it.isWhitespace() }
    if (trimmed.isEmpty()) return PopopxPairingAccept.Ignored
    if (ecoLinkConsumed(trimmed)) return PopopxPairingAccept.HandledByAnotherProtocol
    return when (val verdict = PopopxNodePairing.evaluate(trimmed, now)) {
      is PopopxPairingVerdict.Accepted -> PopopxPairingAccept.Pending(verdict.offer)
      is PopopxPairingVerdict.Rejected -> PopopxPairingAccept.Rejected
    }
  }

  /**
   * `bond(_:now:)` (:520-525): the pending record every accepted offer leaves, even before a chat
   * exists — `canAttemptHandshake` needs it. iOS ignores the keystore result here (`_ = encode`,
   * :523 via :213-219); this returns it so a caller CAN say "bonded, but not yet saved" instead of
   * guessing (deviation, reported).
   */
  fun bond(offer: PopopxNodePairingOffer, now: Long = nowMs()): Boolean {
    loadIfNeeded()
    bindingRecord = PopopxMacNodeBinding.of(offer, now)
    logger("discover: bonded node ${offer.nodeId.take(8)}")
    return saveBinding()
  }

  /**
   * `attach(contactId:displayName:)` (:531-538): the conversation the user just opened with the
   * node, recorded EXPLICITLY — nothing on this device can tell "the chat for the Mac" from "the
   * chat for a person", and a wrong guess sends control signals into someone's private thread.
   */
  fun attach(contactId: Long, displayName: String) {
    loadIfNeeded()
    val record = bindingRecord ?: return
    bindingRecord = record.copy(contactId = contactId, contactDisplayName = displayName)
    saveBinding()
  }

  fun renameBinding(label: String) {
    loadIfNeeded()
    val record = bindingRecord ?: return
    bindingRecord = record.copy(deviceLabel = label)
    saveBinding()
  }

  /** `confirmHandshake()` (:548-554): once confirmed it is never re-written. */
  fun confirmHandshake() {
    loadIfNeeded()
    val record = bindingRecord ?: return
    if (record.handshakeConfirmed) return
    bindingRecord = record.copy(handshakeConfirmed = true)
    saveBinding()
  }

  /** `unbind()` (:556-560): forgets the node, keeps subscriptions, inbox and credits untouched. */
  fun unbind() {
    loadIfNeeded()
    bindingRecord = null
    saveBinding()
  }

  /**
   * `eraseLocalState()` (:565-572) — the non-duress "clear my data" path; the emergency wipe on iOS
   * reaches the same slots through `PopopxCommerceKeychain.removeAll()`. Note the iOS ordering
   * quirk kept: memory is cleared BEFORE the saves, which is what makes `save()` write the empty
   * list — and an empty list REMOVES the account (:205-206), which is why removal works here.
   */
  fun eraseLocalState() {
    subscriptionRows = ArrayList()
    inboxRows.clear()
    bindingRecord = null
    awaitingBalance.clear()
    loaded = true
    save()
    saveBinding()
  }

  // MARK: Node command path

  /**
   * `dispatch(_:now:)` (:489-499). The refusal order is the Swift's, and each guard is load-bearing:
   * `isAcceptedByNode` first because a command the host's own parser rejects is a bug the user
   * would discover by reading a card in another language (:485-488); the contact next; and a
   * RENEWABLE service only while its status `isUsable` — a metered service has no cycle status to
   * gate on and dispatches freely. Delivery confirms the handshake (:497).
   */
  fun dispatch(action: PopopxNodeMenuAction, now: Long = nowMs()): Boolean {
    loadIfNeeded()
    val command = action.command
    val contactId = nodeContactId
    if (!command.isAcceptedByNode || contactId == null) return false
    if (action.serviceId.cycleCost.renewalCredits != null && !statusFor(action.serviceId, now).isUsable) return false
    val delivered =
      try {
        nodeCommandSender(command, contactId)
      } catch (_: Exception) {
        false
      }
    if (delivered) confirmHandshake()
    return delivered
  }

  /**
   * `sendHandshake(now:)` (:507-516). MEASURED, and it contradicts the feature's own name file:
   * the handshake does NOT use a `system::pair_ack` form — the host's parser rejects any serviceId
   * outside its ten engines (`NodeWire.parseCommand`, MacNodeModels.swift:127-128, cited at
   * :502-506), so `edge_compute_mesh::status` with a pairing probe is the real shape: engine-known,
   * model-free, argument-free.
   */
  fun sendHandshake(now: Long = nowMs()): Boolean {
    loadIfNeeded()
    val contactId = nodeContactId ?: return false
    val command = PopopxNodeCommand(PopopxNodeServiceId.EdgeComputeMesh, "status", "{\"probe\":\"pairing\"}")
    val delivered =
      try {
        nodeCommandSender(command, contactId)
      } catch (_: Exception) {
        false
      }
    if (delivered) confirmHandshake()
    return delivered
  }

  // MARK: Storage plumbing

  private fun subscriptionText(): String =
    popopxJsonArrayText(subscriptionRows.map { PopopxDiscoverSubscription.toJson(it) })

  private fun readSubscriptionRows(): MutableList<PopopxDiscoverSubscription> {
    val bytes = PopopxEcoSecrets.read(PopopxDiscoverStore.ACCOUNT_SUBSCRIPTIONS, defaults) ?: return ArrayList()
    val parsed = popopxJsonDecode(bytes.decodeToString()) as? JsonArray ?: return ArrayList()
    val rows = ArrayList<PopopxDiscoverSubscription>()
    for (element in parsed) {
      val obj = element as? JsonObject ?: continue
      val row = PopopxDiscoverSubscription.fromJson(obj) ?: continue
      rows.add(row)
    }
    return rows
  }

  private fun readBinding(): PopopxMacNodeBinding? {
    val bytes = PopopxEcoSecrets.read(PopopxDiscoverStore.ACCOUNT_NODE_BINDING, defaults) ?: return null
    val obj = popopxJsonDecode(bytes.decodeToString()) as? JsonObject ?: return null
    return PopopxMacNodeBinding.fromJson(obj)
  }

  private fun readInboxInto(target: LinkedHashMap<String, MutableList<PopopxNodeResultCard>>) {
    val text = defaults.getStringOrNull(PopopxDiscoverStore.KEY_INBOX) ?: return
    val obj = popopxJsonDecode(text) as? JsonObject ?: return
    for ((key, element) in obj) {
      val serviceId = PopopxNodeServiceId.from(key) ?: continue // an unknown service id drops its rows, as an unknown Codable enum key would
      val array = element as? JsonArray ?: continue
      val cards = ArrayList<PopopxNodeResultCard>()
      for (item in array) {
        val card = PopopxNodeResultCard.fromJson(item as? JsonObject ?: continue) ?: continue
        cards.add(card)
      }
      if (cards.isNotEmpty()) target[key] = cards
    }
  }

  private fun writeInboxPlain() {
    val members = LinkedHashMap<String, JsonElement>()
    for ((key, cards) in inboxRows) {
      members[key] = JsonArray(cards.map { PopopxNodeResultCard.toJson(it) })
    }
    defaults.putString(PopopxDiscoverStore.KEY_INBOX, JsonObject(members).toString())
  }
}

/** Where this module's data rests on the device. Account names mirror iOS's Keychain slots (:26-29, `PopopxCommerceKeychainItem`). */
object PopopxDiscoverStore {
  /** keystore: `[PopopxDiscoverSubscription]` JSON — a paid entitlement list, secret by meaning. */
  const val ACCOUNT_SUBSCRIPTIONS = "popopx.discover.subscriptions"

  /** keystore: the one `PopopxMacNodeBinding` JSON — it names the node's key, same class of data. */
  const val ACCOUNT_NODE_BINDING = "popopx.discover.node.binding"

  /** plain settings: the whole inbox as one JSON object (class KDoc explains the split). */
  const val KEY_INBOX = "popopx.discover.inbox"
}

/**
 * The wallet, as the Discover module needs it (Swift: `PopopxCreditsManager.shared.balance` and
 * `.payForService(amount:note:)`, :282, :342-351). `chat.popopx.common.commerce` is another
 * agent's lane; the app wires this seam to it. [balance] is read PER ROW during a sweep (:342),
 * because the first renewal may debit the wallet the second row is about to ask.
 */
interface PopopxDiscoverLedger {
  val balance: Int

  /** True = charged. False mirrors a thrown `payForService` (insufficient balance, closed wallet). */
  fun payForService(amount: Int, note: String): Boolean

  companion object {
    /** An unwired wallet: nothing held, nothing chargeable. A fresh build behaves like an empty account. */
    val UNPAID: PopopxDiscoverLedger =
      object : PopopxDiscoverLedger {
        override val balance: Int get() = 0

        override fun payForService(amount: Int, note: String): Boolean = false
      }
  }
}

/** One activated service (DiscoverSubscriptionManager.swift:38-88). Keys are the iOS Codable member names. */
data class PopopxDiscoverSubscription(
  val serviceId: PopopxNodeServiceId,
  val activatedAtMs: Long,
  val expiresAtMs: Long,
  val autoRenew: Boolean,
  val cyclesPaid: Int,
  val lastRenewalAtMs: Long?,
  val shortfallNoticeExpiresAtMs: Long?,
) {
  val id: String get() = serviceId.rawValue

  /** `isActive(at:)` (:68-70): the expiry instant itself is already inactive. */
  fun isActive(nowMs: Long): Boolean = nowMs < expiresAtMs

  /** `millisecondsRemaining(at:)` (:72-74): negative once expired, and the sweep must not clamp it away. */
  fun millisecondsRemaining(nowMs: Long): Long = expiresAtMs - nowMs

  /** `daysRemaining(at:)` (:76-78): whole days left, floored at zero. */
  fun daysRemaining(nowMs: Long): Int = (millisecondsRemaining(nowMs).coerceAtLeast(0L) / 1_000L / PopopxDiscoverLimits.SECONDS_PER_DAY).toInt()

  /**
   * `renewalWindowOpen(at:)` (:83-88): auto-renew on, the cycle priced in credits, the row still
   * ACTIVE, and at most 24 h of validity left — the window refuses to take money for time the
   * user already bought (:80-82), and a row already past expiry is not renewed here at all: it
   * stays visible as `awaitingBalance`/`expired` until the user tops up and the next sweep… which,
   * MEASURED, still requires `isActive`, so a lapsed cycle is revived only by re-activating.
   */
  fun renewalWindowOpen(nowMs: Long): Boolean =
    autoRenew &&
      serviceId.cycleCost.renewalCredits != null &&
      isActive(nowMs) &&
      millisecondsRemaining(nowMs) <= PopopxDiscoverLimits.RENEWAL_WINDOW_MILLIS

  /** `init(serviceId:now:)` (:55-64). MEASURED: auto-renew starts ON — `autoRenew = true`, :60 —
   * even though the detail sheet's comment claims the default is off (DiscoverServiceDetailSheet.swift);
   * the row constructor is the behaviour, the comment is prose. Cycles paid starts at 1: the first
   * activation IS a paid cycle. */
  companion object {
    fun new(serviceId: PopopxNodeServiceId, nowMs: Long): PopopxDiscoverSubscription =
      PopopxDiscoverSubscription(
        serviceId = serviceId,
        activatedAtMs = nowMs,
        expiresAtMs = nowMs + PopopxDiscoverLimits.CYCLE_MILLIS,
        autoRenew = true,
        cyclesPaid = 1,
        lastRenewalAtMs = null,
        shortfallNoticeExpiresAtMs = null,
      )

    fun fromJson(json: JsonObject): PopopxDiscoverSubscription? {
      val serviceId =
        PopopxNodeServiceId.from((json["serviceId"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null)
          ?: return null
      val activatedAtMs = json.longOf("activatedAtMs") ?: return null
      val expiresAtMs = json.longOf("expiresAtMs") ?: return null
      val autoRenew = json.booleanOf("autoRenew") ?: return null
      val cyclesPaid = json.intOf("cyclesPaid") ?: return null
      return PopopxDiscoverSubscription(
        serviceId = serviceId,
        activatedAtMs = activatedAtMs,
        expiresAtMs = expiresAtMs,
        autoRenew = autoRenew,
        cyclesPaid = cyclesPaid,
        lastRenewalAtMs = json.longOfOrNull("lastRenewalAtMs"),
        shortfallNoticeExpiresAtMs = json.longOfOrNull("shortfallNoticeExpiresAtMs"),
      )
    }

    private fun JsonObject.longOf(key: String): Long? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toLongOrNull()

    private fun JsonObject.intOf(key: String): Int? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toIntOrNull()

    private fun JsonObject.booleanOf(key: String): Boolean? =
      (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.let { if (it == "true") true else if (it == "false") false else null }

    /** Absent OR JSON null reads as null (Codable's decodeIfPresent); a wrong type drops the row. */
    private fun JsonObject.longOfOrNull(key: String): Long? {
      val element = this[key] ?: return null
      val primitive = element as? JsonPrimitive ?: return null
      if (primitive is JsonNull || primitive.isString) return null
      return primitive.content.toLongOrNull()
    }

    fun toJson(row: PopopxDiscoverSubscription): JsonObject {
      val members = LinkedHashMap<String, JsonElement>()
      members["serviceId"] = JsonPrimitive(row.serviceId.rawValue)
      members["activatedAtMs"] = JsonPrimitive(row.activatedAtMs)
      members["expiresAtMs"] = JsonPrimitive(row.expiresAtMs)
      members["autoRenew"] = JsonPrimitive(row.autoRenew)
      members["cyclesPaid"] = JsonPrimitive(row.cyclesPaid)
      row.lastRenewalAtMs?.let { members["lastRenewalAtMs"] = JsonPrimitive(it) }
      row.shortfallNoticeExpiresAtMs?.let { members["shortfallNoticeExpiresAtMs"] = JsonPrimitive(it) }
      return JsonObject(members)
    }
  }
}

/** `PopopxDiscoverRenewalOutcome` (:107-118): what one row's renewal attempt reported, per row, never an abort. */
sealed class PopopxDiscoverRenewalOutcome {
  abstract val serviceId: PopopxNodeServiceId

  data class Renewed(override val serviceId: PopopxNodeServiceId, val credits: Int, val expiresAtMs: Long) : PopopxDiscoverRenewalOutcome()

  data class NotDue(override val serviceId: PopopxNodeServiceId) : PopopxDiscoverRenewalOutcome()

  data class BalanceShort(override val serviceId: PopopxNodeServiceId, val required: Int, val balance: Int) : PopopxDiscoverRenewalOutcome()

  data class NotRenewable(override val serviceId: PopopxNodeServiceId) : PopopxDiscoverRenewalOutcome()
}

/**
 * The badge both the plaza and the detail sheet read (:122-150), so "is this service running" has
 * one answer. [isUsable] is the gate [PopopxSubscriptionEngine.dispatch] obeys: `awaitingBalance`
 * LOOKS active to a badge but is never a free day of compute (:142-149).
 */
sealed class PopopxDiscoverServiceStatus {
  data object NotActivated : PopopxDiscoverServiceStatus()

  data class Active(val autoRenew: Boolean) : PopopxDiscoverServiceStatus()

  data class ExpiringToday(val autoRenew: Boolean) : PopopxDiscoverServiceStatus()

  data class AwaitingBalance(val daysOverdue: Int) : PopopxDiscoverServiceStatus()

  data object Expired : PopopxDiscoverServiceStatus()

  data object Metered : PopopxDiscoverServiceStatus()

  /** `label` (:130-140), spelled from the iOS localization keys — see the catalog file's header for why keys are the values here. */
  val label: String
    get() =
      when (this) {
        NotActivated -> PopopxDiscoverCopy.STATUS_NOT_SUBSCRIBED
        is Active -> if (autoRenew) PopopxDiscoverCopy.STATUS_RUNNING_AUTO_RENEW else PopopxDiscoverCopy.STATUS_RUNNING
        is ExpiringToday -> PopopxDiscoverCopy.STATUS_EXPIRING_SOON
        is AwaitingBalance -> PopopxDiscoverCopy.STATUS_NEEDS_BALANCE
        Expired -> PopopxDiscoverCopy.STATUS_PAUSED
        Metered -> PopopxDiscoverCopy.USAGE_BASED_PRICE
      }

  val isUsable: Boolean
    get() =
      when (this) {
        is Active, is ExpiringToday, Metered -> true
        NotActivated, is AwaitingBalance, Expired -> false
      }
}

/** What [PopopxSubscriptionEngine.activate] reports. iOS throws two of these and returns void for the rest; the sealed type says all five. */
sealed class PopopxActivationResult {
  data class Charged(val serviceId: PopopxNodeServiceId, val credits: Int, val expiresAtMs: Long) : PopopxActivationResult()

  /** `guard subscription(for:) == nil else { return }` (:275) — not an error, a no-op. */
  data class AlreadyActive(val serviceId: PopopxNodeServiceId) : PopopxActivationResult()

  /** `PopopxDiscoverError.activationNotSupported` (:276-281): the mesh node, priced per job. */
  data class ActivationNotSupported(val serviceId: PopopxNodeServiceId) : PopopxActivationResult() {
    val notice: String get() = PopopxDiscoverCopy.activationNotSupportedNotice(serviceId.title)
  }

  /** The wallet refused the debit: no row was written, no money moved that this call retries blindly. */
  data class ChargeRefused(val serviceId: PopopxNodeServiceId, val required: Int, val balance: Int) : PopopxActivationResult() {
    val notice: String get() = PopopxDiscoverCopy.insufficientCreditsNotice(serviceId.title, required, balance)
  }

  /**
   * `PopopxDiscoverError.persistenceFailed` (:290-296): the DEBIT IS COMMITTED and NOT rolled back,
   * the row lives in memory for this session, and the next launch re-reads the truth from the
   * keystore. Surfaced, never hidden — that is the point of the type existing.
   */
  data class PersistenceFailed(val serviceId: PopopxNodeServiceId, val creditsCharged: Int) : PopopxActivationResult() {
    val notice: String get() = PopopxDiscoverCopy.PERSISTENCE_FAILED_NOTICE
  }
}

/** The one notice the engine may post (Swift: an `UNNotificationRequest`, :407-425). All fields are wire-fixed strings. */
data class PopopxShortfallNotice(
  val serviceId: PopopxNodeServiceId,
  val title: String,
  val body: String,
  /** "popopx.discover.shortfall.<raw>.<expiresAtMs>" (:418-419): the dedupe identity, one request per expiry. */
  val requestIdentifier: String,
  /** [PopopxDiscoverLimits.SHORTFALL_CHANNEL_ID], the literal. */
  val channelId: String,
)

/** What the paste field does with a pasted string (MacNodePairingSheet.swift:179-198). */
sealed class PopopxPairingAccept {
  /** Empty paste: ignored without a notice — deleting the code you pasted is not worth an alert. */
  data object Ignored : PopopxPairingAccept()

  /** The text belonged to another protocol and that protocol took it (class seam KDoc). */
  data object HandledByAnotherProtocol : PopopxPairingAccept()

  /** Verified and live. The view decides whether to [PopopxSubscriptionEngine.bond]; pairing never auto-bonds. */
  data class Pending(val offer: PopopxNodePairingOffer) : PopopxPairingAccept()

  /**
   * Every other outcome — not a code, bad signature, stale, wrong type — collapsed into ONE public
   * value carrying only the generic sentence. That is the anti-oracle contract
   * (MacNodePairingSheet.swift:177-178): the caller structurally cannot tell "not a code" from
   * "forged code". Tests read the typed reason from [PopopxNodePairing.evaluate], not from here.
   */
  data object Rejected : PopopxPairingAccept() {
    val userNotice: String get() = PopopxDiscoverCopy.GENERIC_PAIRING_NOTICE
  }
}

/**
 * The copy this module's BEHAVIOUR depends on. Pairing notices, ledger remarks and the notice body
 * are stored or matched downstream, so they live here as constants, not in a resource layer
 * (rationale: PopopxDiscoverCatalog.kt header). Values are the iOS English keys, verbatim.
 */
object PopopxDiscoverCopy {
  /** `DiscoverCopy.pairingFailed` (DiscoverCatalogModels.swift:766): the ONLY public answer to any pairing failure. */
  const val GENERIC_PAIRING_NOTICE = "That code is not a current Mac node credential"

  const val STATUS_RUNNING = "Running"
  const val STATUS_RUNNING_AUTO_RENEW = "Running · auto-renew"
  const val STATUS_PAUSED = "Paused"
  const val STATUS_EXPIRING_SOON = "Expires today"
  const val STATUS_NOT_SUBSCRIBED = "Not activated"
  const val STATUS_NEEDS_BALANCE = "Waiting for credits"
  const val USAGE_BASED_PRICE = "Metered, settled per job"

  /** `PopopxDiscoverError.persistenceFailed` (DiscoverSubscriptionManager.swift:598). */
  const val PERSISTENCE_FAILED_NOTICE =
    "This device could not store the activation. The credits were not spent twice; reopen Discover."

  const val NO_NODE_BONDED_NOTICE = "No Mac node is bonded, so there is nothing to run this on."

  const val SHORTFALL_TITLE = "Compute credits are not enough"

  /** Frozen at the moment of the charge (:619-621): these two remarks are STORED DATA. */
  fun ledgerActivationNote(serviceTitle: String, days: Int): String = "Activated $serviceTitle for $days days"

  fun ledgerRenewalNote(serviceTitle: String, days: Int): String = "Renewed $serviceTitle for $days days from the credit balance"

  fun shortfallBody(serviceTitle: String, required: Int, balance: Int): String =
    "$serviceTitle renews in less than a day and costs $required credits. This wallet holds $balance."

  fun activationNotSupportedNotice(serviceTitle: String): String =
    "$serviceTitle is settled per job, so there is no 30-day activation to buy."

  fun insufficientCreditsNotice(serviceTitle: String, required: Int, balance: Int): String =
    "$serviceTitle costs $required Compute Credits and this wallet holds $balance."
}
