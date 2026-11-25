package chat.popopx.common.cfgsec

import chat.popopx.common.model.Chat
import chat.popopx.common.model.ChatType
import chat.popopx.common.model.SMPServerSummary
import chat.popopx.common.model.ServerOperator
import chat.popopx.common.model.ServerProtocol
import chat.popopx.common.model.UserOperatorServers
import chat.popopx.common.model.UserServer
import chat.popopx.common.platform.Log
import chat.popopx.common.platform.appPlatform
import chat.popopx.common.platform.chatModel
import chat.popopx.common.views.usersettings.networkAndServers.serverProtocolAndOperator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

// The apply/prove/roll-back half of the signed cluster configuration, ported from
// apps/ios/Shared/Features/ServerConfigSync/PopopxServerConfigSignalHandler.swift.
//
// This is the only place in the app that changes the SMP server table because something a peer sent, and it is
// deliberately the most conservative path in the feature: an update is applied only when it can be undone, and
// it is kept only when it can be shown to work. The order is the design, and every step exists because of what
// happens if it is skipped:
//
//   1. verify the signature over the received bytes         — otherwise anyone could move this device
//   2. apply any revocation the frame declares, then refuse a generation at or below that key's floor
//                                                           — otherwise a redelivered message re-applies
//                                                            a superseded cluster
//   3. read the live table, merge, and have the core validate the result
//                                                           — the update merges, it never replaces, and the
//                                                            core is the authority on what it accepts
//   4. write the rollback snapshot                          — if this fails, stop: an applied configuration
//                                                            with no way back is the one state to avoid
//   5. raise the floor, then replace the table              — the floor moves with the snapshot already on
//                                                            disk, so a crash cannot re-live it
//   6. watch the result, then keep it or restore            — a cluster that turns out to be dead is reverted
//                                                            before the user notices
//
// Nothing here reaches the user: no alert, no banner, and no row left in the timeline. The frame is deleted
// once handled, and the only thing this module sends is itself a suppressed control frame.
//
// The core and the chat model sit behind [PopopxServerConfigTransport] for the reason iOS gives for making
// `decide`/`classify`/`judge` static: a step of this state machine — "the snapshot could not be written, so
// nothing was applied" — is otherwise reachable only on a machine with an agent, a signed-in profile and a
// network. The bound implementation is `PopopxServerConfigHostTransport`; the arithmetic stays here.

/** A merged table, and the subset of the requested rows the merge actually inserted. */
class PopopxServerConfigMerge(
  val servers: List<UserOperatorServers>,
  val introduced: List<String>,
)

/** A conversation an official address turned into, as far as this module needs to know about it. */
class PopopxOfficialJoin(val chatType: ChatType, val chatApiId: Long)

/**
 * Whether this process is in a state where a probe window can be watched.
 *
 * iOS reads `UIApplication.shared.applicationState`; the Android counterpart is a `ProcessLifecycleOwner`
 * observation, and this module lives in `commonMain`, which declares no dependency on it. The app's own
 * lifecycle callback sets this flag, and the default of `true` is what keeps desktop — which has never had a
 * background state in this port — and a unit test from needing an observer at all.
 */
object PopopxServerConfigForeground {
  @Volatile
  var active: Boolean = true
}

/** The effectful surface the handler drives. Every method answers "did it work", never "show something". */
interface PopopxServerConfigTransport {
  /** Null when no profile is signed in: nothing may be applied to a database with no user. */
  suspend fun signedInUserId(): Long?

  /** The live operator table, or null when it could not be read. */
  suspend fun serverTable(): List<UserOperatorServers>?

  /** Replacing the table. False means the core refused it, which burns the generation. */
  suspend fun replaceTable(servers: List<UserOperatorServers>): Boolean

  /** Validation *errors* only; -1 when the core could not be asked, which is not a refusal. */
  suspend fun validationErrorCount(servers: List<UserOperatorServers>): Int

  suspend fun resetSessionStats(): Boolean

  /** The agent's own session rows, which is where a live connection shows up without probing for one. */
  suspend fun serverRows(): List<SMPServerSummary>

  /** Null means the test did not run, which is "no verdict" rather than "failed". */
  suspend fun directTest(uri: String): Boolean?

  /** Whether the core parses this address, tried before it is offered to the table. */
  fun acceptsServerUri(uri: String): Boolean

  suspend fun sendText(chatType: ChatType, chatApiId: Long, text: String): Boolean

  suspend fun deleteRow(chatType: ChatType, chatApiId: Long, itemId: Long): Boolean

  suspend fun silenceChat(chatType: ChatType, chatApiId: Long): Boolean

  /** Plan and join one official address without a dialog, a sheet, or a navigated chat. */
  suspend fun joinOfficial(uri: String): PopopxOfficialJoin?
}

class PopopxServerConfigSignalHandler internal constructor(
  private val store: PopopxServerConfigStore = PopopxServerConfigStore.shared,
  private val transport: PopopxServerConfigTransport = PopopxServerConfigHostTransport,
  /**
   * The decoder, injected rather than called, because no test target holds the production private half. The
   * default is the pinned trust root, and only a test replaces it: a caller that supplied its own key list
   * would void every property this module exists to hold.
   */
  private val decode: (String, Long) -> PopopxServerConfigDecode =
    { text, at -> PopopxServerConfigWire.decodeConfigFrame(text, at) },
  /**
   * Which group a new row belongs in, injected for the same reason the decoder is: the app's own predicate ends
   * in `ServerAddress.parseServerAddress`, which crosses JNI into the core, and no test JVM links that library.
   * Production keeps the manual add flow's answer, so the placement rules stay the app's rather than the test's.
   */
  private val placement: (uri: String, current: List<UserOperatorServers>) -> Pair<ServerProtocol, ServerOperator?>? =
    { uri, current -> serverProtocolAndOperator(userServer(uri), current) },
  private val now: () -> Long = { System.currentTimeMillis() / 1000 },
  private val wait: suspend (Long) -> Unit = { millis -> delay(millis) },
  private val applicationActive: () -> Boolean = { PopopxServerConfigForeground.active },
  private val log: (String) -> Unit = { text -> Log.d(TAG, text) },
) {
  /**
   * The one probe window this process owns. Starting a second cancels the first: two windows judging the same
   * table could roll back a configuration the later one proved good.
   *
   * Internal rather than private only so a test can join it: the window is launched, so without the handle a
   * suite would have to poll the store for the verdict instead of awaiting the job that writes it.
   */
  internal var probeJob: Job? = null

  /** Keeps a second frame from being applied while the first is in flight, which would snapshot a table already mid-change. */
  private var applying = false

  private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

  // MARK: - Receive path

  /**
   * Handles one text message, if and only if it is a configuration frame.
   *
   * Wrapped end to end because this runs inside the received-message path: a defect here must cost one
   * configuration update, not the chat.
   */
  suspend fun observeIncoming(chatType: ChatType, chatApiId: Long, itemId: Long, text: String) {
    if (!PopopxServerConfigWire.isControlText(text)) return
    runCatching {
      val source = PopopxServerConfigSource(sourceChat(chatType), chatApiId)
      when (val decision = decide(text)) {
        is PopopxServerConfigDecision.Refused ->
          // No receipt for a refusal, for the two independent reasons iOS records at the top of its handler:
          // the grammar cannot express one, and naming the check that caught a forgery hands the attacker an
          // oracle. The row is still deleted below, so a refused line cannot accumulate.
          log("frame refused: ${decision.reason.rawValue}")
        is PopopxServerConfigDecision.Stale -> {
          // A generation the device will not act on can still carry the instruction that voids the one it
          // holds, so the revocation is applied here too rather than only on the path that installs.
          applyRevocation(decision.frame)
          log("generation ${decision.frame.payload.seq} superseded")
          if (owesReceipt(decision.frame.payload.policy, source)) sendReceipt(decision.frame, source, installed = false)
        }
        is PopopxServerConfigDecision.Ready -> {
          applyRevocation(decision.frame)
          if (applying || !applicationActive()) {
            // Not now: keep the received line and apply when the device can watch the result. The staged frame
            // is re-verified and re-decided on promotion, so this is a delay and not a concession.
            if (store.stage(PopopxServerConfigStagedFrame.of(text, source.chatType, source.chatApiId))) {
              log("frame staged for a session that can watch the result")
            } else {
              log("frame could not be staged, dropped")
            }
          } else {
            apply(decision.frame, source)
          }
        }
      }
      transport.deleteRow(chatType, chatApiId, itemId)
    }.onFailure { log("handling failed: ${it::class.simpleName}") }
  }

  // MARK: - Decision

  private fun decide(text: String): PopopxServerConfigDecision {
    val state = PopopxServerConfigDecisionState.current(store)
    return when (val decoded = decode(text, now())) {
      is PopopxServerConfigDecode.Refused -> PopopxServerConfigDecision.Refused(decoded.reason)
      is PopopxServerConfigDecode.Accepted -> PopopxServerConfigDecisionEngine.classify(decoded.frame, state)
    }
  }

  private fun owesReceipt(policy: PopopxServerConfigPolicy, source: PopopxServerConfigSource): Boolean =
    PopopxServerConfigDecisionEngine.owesReceipt(policy, source)

  /**
   * Persists the revocation a frame declares, so the next frame from this key is measured against it even if
   * this process never sees another one.
   *
   * Called for every verified frame, including the stale ones. Scoped to the key that verified, because a
   * ratchet written for one rotation must not silently void another key's history.
   */
  private fun applyRevocation(frame: PopopxServerConfigFrame) {
    val payload = frame.payload
    if (payload.policy.minSeq <= store.floor(payload.keyId)) return
    if (store.revoke(payload.keyId, payload.policy.minSeq)) {
      log("generations below ${payload.policy.minSeq} revoked for ${payload.keyId}")
    }
  }

  // MARK: - Apply

  private suspend fun apply(frame: PopopxServerConfigFrame, source: PopopxServerConfigSource) {
    applying = true
    try {
      val payload = frame.payload
      val kid = payload.keyId
      val seq = payload.seq
      if (transport.signedInUserId() == null) {
        log("no signed-in user, nothing applied")
        return
      }

      // Every SMP entry becomes one row, and one unusable entry fails the whole frame: installing four of five
      // servers and reporting the generation as applied would leave the device believing it holds a cluster the
      // operator never finished describing.
      val uris = mutableListOf<String>()
      for (entry in payload.smpServers) {
        val uri = serverURI(entry)
        if (uri == null) {
          log("a server entry could not be turned into an address")
          return
        }
        if (!uris.contains(uri)) uris.add(uri)
      }
      if (uris.isEmpty()) {
        log("the frame names no usable server")
        return
      }

      val current = transport.serverTable() ?: run {
        log("the server table could not be read")
        return
      }
      val owned = store.introducedURIs
      val merge = mergedServers(current, uris, owned) { uri -> placement(uri, current) } ?: run {
        log("no server group could hold this cluster")
        return
      }
      if (merge.servers == current) {
        // The exact cluster is already installed — usually a rotation, where a new key re-signs the servers the
        // previous one introduced. Raising the floor without touching the table is the honest answer, and
        // ownership is carried over unchanged so the rows that are already there stay removable. There is
        // nothing to prove, so the window opens already closed.
        store.markAccepted(kid, seq, owned)
        store.markVerified()
        log("generation $seq was already installed")
        if (owesReceipt(payload.policy, source)) sendReceipt(frame, source, installed = true)
        return
      }

      // Errors only. The warnings this app can raise for a server table (no chat relays, no name servers) are
      // not caused by adding an SMP row, and refusing on one would blame the operator's cluster for the
      // device's own configuration.
      if (transport.validationErrorCount(merge.servers) > 0) {
        log("the core refused the merged table")
        return
      }

      if (!store.writeRollback(PopopxServerConfigSnapshot.of(kid, seq, owned, current))) {
        log("no rollback slot could be written, refusing to apply")
        return
      }
      store.markAccepted(kid, seq, ownedURIs(merge, uris, owned))
      if (!transport.replaceTable(merge.servers)) {
        // The replacement never landed, so the live table is still the one in the snapshot: no restore call is
        // needed, only a burned generation. A core that rejects this table will reject it every time it is
        // offered.
        store.markRolledBack(kid, seq)
        store.clearRollback()
        log("the core rejected the replacement")
        return
      }
      // Re-read so the core's ids for the new rows are known to this device. Skipping this is what breaks
      // deleting a newly added server later.
      transport.serverTable()
      if (!transport.resetSessionStats()) log("session stats not reset, the window will rely on the direct test")
      if (owesReceipt(payload.policy, source)) {
        // Durable, not in-memory: the verdict at the end of the window is exactly the thing a backgrounded
        // process interrupts, and the rollback is the outcome the operator most needs to hear about.
        store.pendingAck = PopopxServerConfigPendingAck.of(kid, seq, frame.bodyHash, source.chatType, source.chatApiId)
      }
      log("generation $seq applied, probing ${uris.size} servers")
      beginProbeWindow(uris)
    } finally {
      applying = false
    }
  }

  // MARK: - Probe window

  private fun beginProbeWindow(uris: List<String>) {
    probeJob?.cancel()
    probeJob = scope.launch {
      wait(FIRST_PROBE_MILLIS)
      if (!isActive) return@launch
      // Early success is decisive and worth taking; early failure proves nothing yet, so the first look can
      // only end the window positively.
      if (clusterVerdict(uris) == PopopxServerConfigProbeVerdict.REACHABLE) {
        finishVerified()
        return@launch
      }
      wait(SECOND_PROBE_MILLIS)
      if (!isActive) return@launch
      if (!applicationActive()) {
        // Backgrounded inside the window: decide nothing. The grace period left is not enough to tell a slow
        // network from a dead one, and `settlePendingWindow` finishes the job on the next foreground.
        log("probe window left open, the app is not active")
        return@launch
      }
      when (clusterVerdict(uris)) {
        PopopxServerConfigProbeVerdict.REACHABLE -> finishVerified()
        PopopxServerConfigProbeVerdict.UNREACHABLE -> restore()
        PopopxServerConfigProbeVerdict.INCONCLUSIVE -> log("probe inconclusive, the window stays open")
      }
    }
  }

  /**
   * One look at the introduced cluster as a whole.
   *
   * A cluster is a set of servers reached through several names, and the device is healthy when it is connected
   * to any of them, so one positive answer ends the window. Ending it negatively takes every answer being
   * negative: a roster with one dead address and five unknown ones is not evidence that the cluster does not
   * work, and rolling back on that would let a single broken machine retire a whole generation.
   */
  private suspend fun clusterVerdict(uris: List<String>): PopopxServerConfigProbeVerdict {
    var seen = 0
    var allUnreachable = true
    for (uri in uris) {
      val verdict = probeVerdict(uri)
      if (verdict == PopopxServerConfigProbeVerdict.REACHABLE) return PopopxServerConfigProbeVerdict.REACHABLE
      if (verdict != PopopxServerConfigProbeVerdict.UNREACHABLE) allUnreachable = false
      seen += 1
    }
    return if (seen > 0 && allUnreachable) PopopxServerConfigProbeVerdict.UNREACHABLE
    else PopopxServerConfigProbeVerdict.INCONCLUSIVE
  }

  /** One look at one address: session counters first, a direct test when they are silent. */
  private suspend fun probeVerdict(uri: String): PopopxServerConfigProbeVerdict {
    val verdict = judge(transport.serverRows(), uri)
    if (verdict != PopopxServerConfigProbeVerdict.INCONCLUSIVE) return verdict
    return when (transport.directTest(uri)) {
      null -> PopopxServerConfigProbeVerdict.INCONCLUSIVE
      true -> PopopxServerConfigProbeVerdict.REACHABLE
      false -> {
        // Any recorded failure is decisive here, including an authentication refusal: all of them mean this
        // device cannot use this address, which is what a rollback is for.
        log("direct test failed for $uri")
        PopopxServerConfigProbeVerdict.UNREACHABLE
      }
    }
  }

  private suspend fun finishVerified() {
    store.markVerified()
    store.clearRollback()
    log("configuration verified")
    settleReceipt()
  }

  /**
   * Returns the table to the snapshot taken before the update.
   *
   * The generation to burn comes from the snapshot rather than from the caller, because by the time a window
   * ends the process may have restarted, and the only trustworthy record of what was applied is the record that
   * made the rollback possible.
   */
  private suspend fun restore() {
    val snapshot = store.readRollback() ?: run {
      log("the probe failed with no snapshot held, the table is left as it is")
      return
    }
    probeJob?.cancel()
    if (!transport.replaceTable(snapshot.servers)) {
      // The old table did not go back, so the device is still running the cluster that failed to prove itself.
      // Nothing is burned and nothing is cleared: the window stays pending, and the next launch runs this
      // restore again. A rollback recorded as done while the live table says otherwise is the one outcome worse
      // than not attempting it, because it is the record the operator reads.
      log("the previous table could not be restored, the snapshot is kept")
      return
    }
    transport.serverTable()
    // Ownership goes back with the table: the rows the failed update added are gone, and the rows it would have
    // removed are present again and still ours.
    store.setIntroducedURIs(snapshot.introducedURIs)
    store.markRolledBack(snapshot.kid, snapshot.seq)
    store.clearRollback()
    log("generation ${snapshot.seq} rolled back after a failed probe")
    settleReceipt()
  }

  // MARK: - Launch promotion

  /**
   * Settles a window the previous process never finished, then applies anything that was staged.
   *
   * Called when the chat list is up, not from a constructor: both halves need a signed-in user, and the staged
   * half needs the conversations loaded before it can deliver the promised receipt.
   */
  suspend fun promoteStagedIfNeeded() {
    if (transport.signedInUserId() == null) return
    settlePendingWindow()
    val staged = store.takeStaged() ?: return
    val chatType = PopopxServerConfigSourceChat.fromRaw(staged.chatType) ?: return
    val source = PopopxServerConfigSource(chatType, staged.chatApiId)
    val instant = now()
    when (val decision = decide(staged.segment)) {
      is PopopxServerConfigDecision.Refused ->
        // Staged bytes that no longer verify are discarded, not retried: the only honest reading is that they
        // were never valid. An expiry that passed while the frame waited lands here too, which is why the
        // staged record keeps the received line instead of the decoded payload.
        log("staged frame refused: ${decision.reason.rawValue}")
      is PopopxServerConfigDecision.Stale -> {
        applyRevocation(decision.frame)
        if (owesReceipt(decision.frame.payload.policy, source)) sendReceipt(decision.frame, source, installed = false)
      }
      is PopopxServerConfigDecision.Ready -> {
        applyRevocation(decision.frame)
        // The operator's own patience limit, applied to the only path that can exceed it. A frame held past its
        // install window is dropped rather than installed: a generation the operator has moved on from is
        // exactly what a delayed install would put back.
        if (instant - staged.receivedAt > decision.frame.payload.policy.installWindowSeconds) {
          log("staged frame outlived its install window")
          return
        }
        log("promoting a staged frame")
        apply(decision.frame, source)
      }
    }
  }

  /** Closes a window that was interrupted, and drops a snapshot that no update owns. */
  private suspend fun settlePendingWindow() {
    if (store.verdict != PopopxServerConfigVerdict.PENDING || store.introducedURIs.isEmpty()) {
      // A snapshot with no pending update describes a table that was never left behind — usually a process
      // killed between writing the snapshot and raising the floor. Holding it would let a later failure restore
      // the wrong moment.
      if (store.verdict != PopopxServerConfigVerdict.PENDING && store.existingRollbackSequence() != null) {
        store.clearRollback()
      }
      settleReceipt()
      return
    }
    when (clusterVerdict(store.introducedURIs)) {
      PopopxServerConfigProbeVerdict.REACHABLE -> finishVerified()
      PopopxServerConfigProbeVerdict.UNREACHABLE -> restore()
      // Still no evidence: leave the window open rather than keep a configuration that was never proven. A
      // relaunch into a working network settles it; one into a broken network rolls it back. The snapshot, not
      // this function, is what makes either outcome possible.
      PopopxServerConfigProbeVerdict.INCONCLUSIVE -> log("the pending window is still unresolved")
    }
  }

  /**
   * Sends the receipt the store is holding, if any, and only once.
   *
   * Reached from both ends of the probe window and from a launch that interrupted one, which is the only way a
   * verdict reached in a process that then died still produces a receipt. `claimAck` is what makes the three
   * call sites safe to leave in place.
   */
  private suspend fun settleReceipt() {
    val pending = store.pendingAck ?: return
    if (pending.seq != store.floor(pending.kid)) {
      // The receipt belongs to a generation the device has moved past. Dropping it rather than sending it late
      // keeps an operator's count of acknowledged devices honest.
      store.pendingAck = null
      return
    }
    store.pendingAck = null
    val chatType = PopopxServerConfigSourceChat.fromRaw(pending.chatType) ?: return
    deliverReceipt(pending, PopopxServerConfigSource(chatType, pending.chatApiId))
  }

  // MARK: - Receipt

  private suspend fun sendReceipt(
    frame: PopopxServerConfigFrame,
    source: PopopxServerConfigSource,
    installed: Boolean,
  ) {
    val ack = PopopxServerConfigPendingAck.of(
      frame.payload.keyId,
      frame.payload.seq,
      // No body hash when the device did not install this configuration: the hash is the half of a receipt
      // that claims it did.
      if (installed) frame.bodyHash else null,
      source.chatType,
      source.chatApiId,
    )
    deliverReceipt(ack, source)
  }

  /**
   * One receipt, at most once per generation per conversation.
   *
   * The claim is taken before the send and released if it fails, making the receipt at-most-once with a retry
   * path rather than at-least-once: two receipts for one generation would be counted by an operator as two
   * devices. The direct-chat test lives here as well as at the call sites, so that a future caller cannot
   * reintroduce the uplink this feature promises never to send into a group.
   */
  private suspend fun deliverReceipt(ack: PopopxServerConfigPendingAck, source: PopopxServerConfigSource) {
    if (source.chatType != PopopxServerConfigSourceChat.DIRECT) {
      log("receipt suppressed, the frame did not arrive in a direct chat")
      return
    }
    if (!store.claimAck(ack)) return
    val text = PopopxServerConfigWire.ackFrame(ack.seq, ack.bodyHash) ?: run {
      store.releaseAckClaim(ack)
      return
    }
    // The conversation the frame came from is the one the receipt goes back to, and a direct frame's chat id is
    // a contact id by construction.
    if (!transport.sendText(ChatType.Direct, ack.chatApiId, text)) {
      log("the receipt was not delivered")
      store.releaseAckClaim(ack)
    }
  }

  // MARK: - Address building

  /**
   * The address for one entry, or null when neither spelling of its key is an address this core accepts.
   *
   * Both spellings are tried for the reason recorded on [padded]: the signature covers an unpadded
   * fingerprint while the published roster and the shipped presets are padded. The padded form is offered
   * first, and a device that has to fall back says so rather than quietly installing a different string from
   * the one the operator published.
   */
  private fun serverURI(entry: PopopxServerEntry): String? {
    val paddedKey = padded(entry.key)
    val candidates = if (paddedKey == entry.key) listOf(entry.key) else listOf(paddedKey, entry.key)
    for ((index, key) in candidates.withIndex()) {
      val uri = serverURI(entry, key) ?: continue
      if (!transport.acceptsServerUri(uri)) continue
      if (index > 0) log("the padded key for ${entry.host} was refused, installed the unpadded spelling")
      return uri
    }
    return null
  }

  // MARK: - Official subscriptions

  /**
   * Join the two conversations the signed configuration travels over: once per profile, and with nothing
   * presented to the user.
   *
   * The channel is where `SERVER_CFG_V1` arrives; the service account is where the receipt for an applied
   * generation goes, which is the reason a receipt is only ever owed for a direct chat. Both are ordinary
   * conversations as far as the core is concerned, so both are joined through a connection plan — the plan is
   * the only call that turns a short link into the link the core connects with, and the only one that answers
   * "this connection already exists" *before* a second one is made.
   *
   * The marker is written before the first request goes out, not after the last one succeeds. A profile that
   * joined the channel and then lost the process must not rejoin it on the next launch, and a user who later
   * leaves either conversation must never be put back into it. What that costs is a subscription that failed at
   * its only attempt: a device whose server was unreachable on its first launch stays unsubscribed until a
   * frame arrives some other way. The trade is the one the feature asks for, and the failure is logged rather
   * than hidden so it is at least diagnosable.
   */
  suspend fun seedOfficialSubscriptions() {
    val userId = transport.signedInUserId() ?: return
    if (store.officialSubscriptionSeeded(userId)) return
    store.markOfficialSubscriptionSeeded(userId)
    joinAndSilence(PopopxOfficialConfigLinks.CHANNEL_URI, userId)
    joinAndSilence(PopopxOfficialConfigLinks.BOT_URI, userId)
  }

  private suspend fun joinAndSilence(uri: String, userId: Long) {
    val joined = transport.joinOfficial(uri) ?: return
    if (!transport.silenceChat(joined.chatType, joined.chatApiId)) {
      log("an official chat could not be silenced")
      return
    }
    // Persisted only once the chat is actually quiet: an id recorded for a chat that still notifies would hide
    // a conversation that was never silenced.
    store.addSystemConfigChatId(joined.chatApiId, userId)
  }

  companion object {
    private const val TAG = "popopx-server-config"

    /** Probe offsets: three seconds after the replacement, then seven more — the point by which an
     * unreachable host has failed to connect and a healthy one has finished. */
    const val FIRST_PROBE_MILLIS: Long = 3_000L
    const val SECOND_PROBE_MILLIS: Long = 7_000L

    /** base64url of 32 bytes is 43 characters and one `=` completes it. Anything else is passed through: the
     * decoder does not require padding, and inventing a different amount would be worse than none. */
    fun padded(key: String): String =
      if (key.length == PopopxServerConfigLimits.SERVER_KEY_CHARACTERS) key + "=" else key

    /**
     * The one address spelling for one entry, or null when it has no hostnames to be dialled.
     *
     * `ServerAddress.uri` is deliberately not used: it interpolates the Kotlin enum *constant* (`SMP`), while
     * iOS's `ServerProtocol` case names and every shipped preset in this repository are lower case
     * (`smp://abcd@…`, `PopopxAPI.kt:5167`, `Presets.hs:69`), and `PopopxAPI.kt` is out of this phase's scope.
     * The scheme therefore comes from an exhaustive `when`, which fails to compile if a protocol is added.
     */
    fun serverURI(entry: PopopxServerEntry, key: String): String? {
      val hostnames = entry.hostnames
      // The rule `ServerAddress.valid` applies, restated because the struct itself cannot be used here.
      if (hostnames.isEmpty() || hostnames.toSet().size != hostnames.size) return null
      if (key.isEmpty()) return null
      return "${scheme(ServerProtocol.SMP)}://$key@${hostnames.joinToString(",")}"
    }

    private fun scheme(protocol: ServerProtocol): String = when (protocol) {
      ServerProtocol.SMP -> "smp"
      ServerProtocol.XFTP -> "xftp"
    }

    /**
     * Which URIs this mechanism may delete on a later update.
     *
     * A row that was already in the table and was not ours stays not-ours: a user who added the same server by
     * hand keeps it, and the signed frame must not acquire the right to remove it. Rows the merge actually
     * inserted, and rows this mechanism introduced earlier and the new roster still names, are the two kinds it
     * owns.
     */
    fun ownedURIs(
      merge: PopopxServerConfigMerge,
      requested: List<String>,
      previouslyOwned: List<String>,
    ): List<String> =
      requested.filter { merge.introduced.contains(it) || previouslyOwned.contains(it) }

    /** The row shape every server table already uses: unpreset, untested, enabled, not deleted. */
    fun userServer(uri: String): UserServer =
      UserServer(
        remoteHostId = null,
        serverId = null,
        server = uri,
        preset = false,
        tested = null,
        enabled = true,
        deleted = false,
      )

    /**
     * Merges a cluster into the table without touching anything the mechanism did not introduce.
     *
     * Null means "there is no correct place for one of these rows", which the caller must treat as a refusal —
     * returning the input unchanged would be mistaken for "nothing to do".
     *
     * Removal is bounded by the owned-URI list, never by `preset` and never by protocol: the user's own
     * servers, the shipped defaults, XFTP rows and chat relays are copied through untouched. `preset` is the
     * core's own flag and is true for the installation's default servers, so claiming by it would let a signed
     * frame delete rows the app itself put there. A row the new roster still names survives the sweep, which is
     * what keeps a rotation from deleting and re-adding the same server — and, with it, from throwing away the
     * core's test result for that row. Placement is the manual add flow's own predicate, injected so the
     * arithmetic below is decidable without the core's address parser.
     */
    fun mergedServers(
      current: List<UserOperatorServers>,
      uris: List<String>,
      owned: List<String>,
      placement: (uri: String) -> Pair<ServerProtocol, ServerOperator?>? =
        { uri -> serverProtocolAndOperator(userServer(uri), current) },
    ): PopopxServerConfigMerge? {
      val merged = current.mapTo(mutableListOf()) { group ->
        group.copy(
          smpServers = group.smpServers.filter { row -> !owned.contains(row.server) || uris.contains(row.server) }
        )
      }
      val introduced = mutableListOf<String>()
      for (uri in uris) {
        val alreadyPresent = merged.any { group -> group.smpServers.any { row -> row.server == uri } }
        if (alreadyPresent) continue
        val placed = placement(uri) ?: return null
        if (placed.first != ServerProtocol.SMP) return null
        val index = merged.indexOfFirst { it.operator?.operatorId == placed.second?.operatorId }
        if (index < 0) return null
        merged[index] = merged[index].copy(smpServers = merged[index].smpServers + userServer(uri))
        introduced.add(uri)
      }
      return PopopxServerConfigMerge(merged, introduced)
    }

    /**
     * Reads the session counters for the introduced cluster.
     *
     * The same decision over the rows themselves rather than over the summary wrapper, split out for iOS's
     * reason: a `PresentedServersSummary` cannot be built by anything that is not the agent
     * (`AgentSMPServerStatsData` has 33 required integers and no defaults). The rule about which rows count is
     * the part worth testing, and it belongs to the rows, not to the wrapper around them.
     *
     * Matching is derived from the URI being installed rather than from any brand rule, and the tolerance is
     * only about shape: `SMPServerSummary.smpServer` is written by the core, and its exact spelling is not
     * defined anywhere in this repository's Kotlin sources, so the URI itself is tried first and its hostnames
     * second. What must never happen is a rollback decided by a row that was not found — an idle device has
     * sessions for nothing.
     *
     * The URI itself, then a row whose host is exactly one of the names once any port the core appended is
     * removed. A `contains` test would let a foreign row that merely embeds one of these names answer for the
     * cluster, and in the reachable direction that is the one mistake this window cannot afford: it would close
     * positively on a configuration that never worked. A missed row answers inconclusive and leaves the window
     * open, which is the safe side of the same ambiguity.
     */
    fun judge(rows: List<SMPServerSummary>, uri: String): PopopxServerConfigProbeVerdict {
      val hostnames = uri.substringAfterLast("@")
        .split(",")
        .filter { it.isNotEmpty() }
        .map { it.lowercase() }
      val mine = rows.filter { row ->
        val server = row.smpServer.lowercase()
        server == uri.lowercase() || hostnames.contains(server.substringBefore(":"))
      }
      val sessions = mine.mapNotNull { it.sessions }.firstOrNull()
        ?: return PopopxServerConfigProbeVerdict.INCONCLUSIVE
      if (sessions.ssConnected > 0) return PopopxServerConfigProbeVerdict.REACHABLE
      if (sessions.ssErrors > 0) return PopopxServerConfigProbeVerdict.UNREACHABLE
      return PopopxServerConfigProbeVerdict.INCONCLUSIVE
    }

    /** The model's chat type as this module spells it: everything that is not one-to-one is a group. */
    fun sourceChat(chatType: ChatType): PopopxServerConfigSourceChat =
      if (chatType == ChatType.Direct) PopopxServerConfigSourceChat.DIRECT else PopopxServerConfigSourceChat.GROUP

    val shared: PopopxServerConfigSignalHandler by lazy { PopopxServerConfigSignalHandler() }
  }
}

/**
 * The two official addresses, written exactly as they are deployed.
 *
 * Both strings are wire values, so neither is assembled at runtime; they are verbatim from
 * `PopopxServerConfigSignalHandler.swift:921-923`, which is the source of truth for this feature. The fragment
 * selects the conversation and the `?c=` query carries the SMP server key hash, so a dropped query leaves the
 * address without the key it has to be dialled with.
 */
object PopopxOfficialConfigLinks {
  /** Read-only configuration channel; the server pins the member role to `observer`. */
  const val CHANNEL_URI =
    "https://smp2.popopx.im/g#AbX7ZWizYxULjL-QpOGJLJm7C33BcXIsLc61IVOa8zM?c=4bJjC-wqSpviWwuDnkhSKTD4V8mYxpLqj4aiCUSfGfA"

  /** One-to-one service account: silent delivery, and where a receipt for an applied generation goes. */
  const val BOT_URI =
    "https://smp6.popopx.im/a#ZwDniscH42Q2di4Ti-2MJns_ow7OasGL1BwoDoVBnis?c=2bIUdRa7VJeB2tx9W3gwaOJ2Sv72fH8Pc_uM9l9r4hM"

  /** How long the app waits after the chat list appears before joining anything. The list is the first point
   * at which a profile is certainly loaded, and the core is still finishing its own start-up work inside that
   * window; a request issued there is one that can fail with no dialog left to explain it. */
  const val SEEDING_DELAY_MILLIS: Long = 2_500L
}

/**
 * Whether a conversation is one of the official configuration chats this module joined by itself, and must
 * therefore never be drawn.
 *
 * The ids come from the store rather than from the addresses above because what is hidden is the *chat*: a
 * profile that joined the channel has an ordinary contact or group row, and only the recorded id says that this
 * row is the mechanism's own. iOS applies the same test at every surface that lists conversations
 * (`ChatsListView.swift:494-501`, `PopopxContactsView.swift:401/426/436/1274`,
 * `ChatItemForwardingView.swift:30`) and to the unread total (`ChatModel.swift:1194-1197`), for one reason that
 * applies here too: a conversation the user never asked for, sitting in the list with an unread dot, reads as a
 * message from a stranger.
 *
 * False off Android. Desktop has never run this module, so a configuration chat cannot exist there, and the
 * filter must not be a new term in a shared view's predicate for a platform that has nothing to hide.
 */
fun popopxServerConfigHiddenChat(chat: Chat): Boolean {
  if (!appPlatform.isAndroid) return false
  val userId = chatModel.currentUser.value?.userId ?: return false
  return PopopxServerConfigStore.shared.systemConfigChatIds(userId).contains(chat.chatInfo.apiId)
}
