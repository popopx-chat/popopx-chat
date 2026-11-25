package chat.popopx.app.cfgsec

import chat.popopx.common.cfgsec.PopopxOfficialConfigLinks
import chat.popopx.common.cfgsec.PopopxServerConfigMerge
import chat.popopx.common.cfgsec.PopopxServerConfigPendingAck
import chat.popopx.common.cfgsec.PopopxServerConfigProbeVerdict
import chat.popopx.common.cfgsec.PopopxServerConfigSignalHandler
import chat.popopx.common.cfgsec.PopopxServerConfigSnapshot
import chat.popopx.common.cfgsec.PopopxServerConfigSourceChat
import chat.popopx.common.cfgsec.PopopxServerConfigStagedFrame
import chat.popopx.common.cfgsec.PopopxServerConfigStore
import chat.popopx.common.cfgsec.PopopxServerConfigVerdict
import chat.popopx.common.cfgsec.PopopxServerConfigWire
import chat.popopx.common.cfgsec.PopopxServerEntry
import chat.popopx.common.model.ChatType
import chat.popopx.common.model.SMPServerSummary
import chat.popopx.common.model.ServerOperator
import chat.popopx.common.model.ServerProtocol
import chat.popopx.common.model.UserOperatorServers
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

// The state machine: the order the six steps run in, which of them can stop the update, and what the device is
// willing to say about it afterwards.
//
// Every frame is one of the three the repository's own generator minted, so the pipeline is driven by real
// signed bytes instead of a hand-built payload that could agree with the implementation by construction. The
// probe window is awaited through `probeJob` rather than polled, because the window is launched and a polled
// assertion can pass by being early.

private const val SMP11 = "smp11.popopx.im"
private const val SMP12 = "smp12.popopx.im"
private const val SMP13 = "smp13.popopx.im"
private const val LEGACY_URI = "smp://aaaa@legacy.popopx.im"
private const val CHAT_API_ID = 4L
private const val ITEM_ID = 9L
private const val STALE_ACK = "::popopx_sys::SERVER_CFG_ACK::7"

private class Drive(val transport: CfgTransportDouble = CfgTransportDouble()) {
  val defaults = cfgSettings()
  val store = PopopxServerConfigStore(defaults)
  val logs = mutableListOf<String>()
  var now: Long = NOW
  val handler = cfgHandler(store, transport, now = { now }, log = { logs.add(it) })

  /** A reachable answer for both hosts the full frame names, which is all a cluster needs. */
  fun reachable() {
    transport.rows = listOf(cfgSummary(SMP11, connected = 1), cfgSummary(SMP12, connected = 1))
  }

  fun unreachable() {
    transport.rows = listOf(cfgSummary(SMP11, errors = 1), cfgSummary(SMP12, errors = 1))
  }

  /** Neither the session counters nor a direct test has anything to say. */
  fun inconclusive() {
    transport.rows = emptyList()
    transport.directTest = null
  }

  suspend fun receive(text: String, chatType: ChatType = ChatType.Direct, chatApiId: Long = CHAT_API_ID) {
    handler.observeIncoming(chatType, chatApiId, ITEM_ID, text)
    handler.probeJob?.join()
  }

  /** The server rows of one table, spelled the way the assertions read them. */
  fun rows(table: List<UserOperatorServers> = transport.table): List<String> = table.first().smpServers.map { it.server }

  fun hadLog(fragment: String): Boolean = logs.any { it.contains(fragment) }
}

class PopopxServerConfigHandlerTest {
  // MARK: - Address building

  @Test
  fun paddedCompletesOnlyAFortyThreeCharacterKey() {
    val unpadded = "QqYUUR-FYesxbsSt3w2zhmKHHbxSkmwLtuX0T3gATmI"
    assertEquals(43, unpadded.length)
    assertEquals("$unpadded=", PopopxServerConfigSignalHandler.padded(unpadded))
    // A key that is already padded, and one of no meaningful length, are passed through rather than "fixed":
    // inventing a different amount of padding would be worse than none.
    assertEquals("$unpadded=", PopopxServerConfigSignalHandler.padded("$unpadded="))
    assertEquals("abc", PopopxServerConfigSignalHandler.padded("abc"))
    assertEquals("", PopopxServerConfigSignalHandler.padded(""))
  }

  @Test
  fun anAddressIsTheKeyAtCommaJoinedHostnamesAndNothingElse() {
    val key = "QqYUUR-FYesxbsSt3w2zhmKHHbxSkmwLtuX0T3gATmI="
    val entry = PopopxServerEntry(key, SMP11, null)
    assertEquals(SMP11_URI, PopopxServerConfigSignalHandler.serverURI(entry, key))
    // Both names go into one address, in the order the core should walk them, so an onion alternate is not a
    // second server row.
    val withOnion = PopopxServerEntry(key, SMP11, "abcdefghijklm0123456789abcdef0123456789abcd.onion")
    assertEquals("smp://$key@$SMP11,abcdefghijklm0123456789abcdef0123456789abcd.onion", PopopxServerConfigSignalHandler.serverURI(withOnion, key))
    // A duplicated name has nothing to be dialled in order, and an empty key would build an address with no
    // server in it; both refuse rather than produce a row the core cannot use.
    assertNull(PopopxServerConfigSignalHandler.serverURI(PopopxServerEntry(key, SMP11, SMP11), key))
    assertNull(PopopxServerConfigSignalHandler.serverURI(entry, ""))
    // The scheme comes from an exhaustive `when`, not from the enum constant: `ServerAddress.uri` interpolates
    // `SMP`, while every shipped preset and every iOS address is lower case.
    assertFalse(PopopxServerConfigSignalHandler.serverURI(entry, key)!!.startsWith("SMP://"))
  }

  // MARK: - The merge

  @Test
  fun theMergeInsertsWhereTheCoreSaidAndLeavesWhatItDoesNotOwnAlone() {
    val current = cfgTable(LEGACY_URI, "smp://user@user.popopx.chat")
    val merge = PopopxServerConfigSignalHandler.mergedServers(current, listOf(SMP11_URI), listOf(LEGACY_URI)) { _ ->
      ServerProtocol.SMP to null
    }
    assertNotNull(merge)
    assertEquals(listOf(SMP11_URI), merge.introduced)
    // Removal is bounded by the owned list, never by `preset`: the legacy row this mechanism added is replaced by
    // the new roster, and the user's own server survives even though the roster does not name it.
    assertEquals(listOf("smp://user@user.popopx.chat", SMP11_URI), merge.servers.first().smpServers.map { it.server })
    // A row the new roster still names is not deleted and re-added, which is what keeps a rotation from throwing
    // away the core's test result for it — and what makes the "already installed" branch detectable.
    val rotation = PopopxServerConfigSignalHandler.mergedServers(current, listOf(LEGACY_URI), listOf(LEGACY_URI)) { _ ->
      ServerProtocol.SMP to null
    }
    assertNotNull(rotation)
    assertEquals(emptyList(), rotation.introduced)
    assertEquals(current, rotation.servers)
  }

  @Test
  fun aMergeThatCannotBePlacedIsARefusalRatherThanANoOp() {
    val current = cfgTable(LEGACY_URI)
    // Null means "there is no correct place for this row". Returning the input would read as "nothing to do", and
    // the caller would raise the floor for a table it never changed.
    assertNull(PopopxServerConfigSignalHandler.mergedServers(current, listOf(SMP11_URI), emptyList()) { _ -> null })
    assertNull(
      PopopxServerConfigSignalHandler.mergedServers(current, listOf(SMP11_URI), emptyList()) { _ ->
        ServerProtocol.XFTP to null
      }
    )
    // An operator group that is not in the table cannot hold the row either.
    val stranger = ServerOperator.sampleData1.copy(operatorId = 9_999L)
    assertNull(
      PopopxServerConfigSignalHandler.mergedServers(current, listOf(SMP11_URI), emptyList()) { _ ->
        ServerProtocol.SMP to stranger
      }
    )
    val plain = PopopxServerConfigSignalHandler.mergedServers(current, listOf(SMP11_URI), emptyList()) { _ ->
      ServerProtocol.SMP to null
    }
    assertNotNull(plain)
    assertEquals(listOf(LEGACY_URI, SMP11_URI), plain.servers.first().smpServers.map { it.server })
    // The row shape is the manual add flow's: unpreset, untested, enabled, not deleted, unlinked.
    val inserted = plain.servers.first().smpServers.last()
    assertFalse(inserted.preset)
    assertTrue(inserted.enabled)
    assertFalse(inserted.deleted)
    assertNull(inserted.tested)
    assertNull(inserted.serverId)
  }

  @Test
  fun ownershipIsOnlyWhatTheMergeInsertedOrAlreadyHad() {
    val merge = PopopxServerConfigMerge(cfgTable(SMP11_URI), listOf(SMP11_URI))
    // SMP12 was requested and not inserted, but this device introduced it earlier and the roster kept it, so it
    // stays the mechanism's own; a name that is neither would not be.
    assertEquals(
      listOf(SMP11_URI, SMP12_URI),
      PopopxServerConfigSignalHandler.ownedURIs(merge, listOf(SMP11_URI, SMP12_URI), listOf(SMP12_URI)),
    )
    assertEquals(
      listOf(SMP11_URI),
      PopopxServerConfigSignalHandler.ownedURIs(merge, listOf(SMP11_URI, SMP12_URI), emptyList()),
    )
    assertEquals(
      emptyList(),
      PopopxServerConfigSignalHandler.ownedURIs(merge, listOf(SMP12_URI), emptyList()),
    )
  }

  @Test
  fun theProbeAnswersForTheExactHostAndNeverForOneThatMerelyContainsIt() {
    val handler = PopopxServerConfigSignalHandler
    assertEquals(handler.judge(listOf(cfgSummary(SMP11, connected = 1)), SMP11_URI), PopopxServerConfigProbeVerdict.REACHABLE)
    assertEquals(handler.judge(listOf(cfgSummary(SMP11, errors = 1)), SMP11_URI), PopopxServerConfigProbeVerdict.UNREACHABLE)
    // The core may write the row with a port appended, and that is still this cluster.
    assertEquals(handler.judge(listOf(cfgSummary("$SMP11:443", connected = 1)), SMP11_URI), PopopxServerConfigProbeVerdict.REACHABLE)
    assertEquals(handler.judge(listOf(cfgSummary(SMP11.uppercase(), connected = 1)), SMP11_URI), PopopxServerConfigProbeVerdict.REACHABLE)
    // An idle device has sessions for nothing, an unknown row says nothing, and no rows at all is not evidence.
    assertEquals(handler.judge(emptyList(), SMP11_URI), PopopxServerConfigProbeVerdict.INCONCLUSIVE)
    assertEquals(handler.judge(listOf(cfgSummary(SMP11)), SMP11_URI), PopopxServerConfigProbeVerdict.INCONCLUSIVE)
    assertEquals(handler.judge(listOf(SMPServerSummary(smpServer = SMP11)), SMP11_URI), PopopxServerConfigProbeVerdict.INCONCLUSIVE)
    // The anti-case that matters: a foreign row that merely embeds one of these names would close the window
    // positively on a configuration that never worked.
    assertEquals(handler.judge(listOf(cfgSummary("evil.$SMP11", connected = 1)), SMP11_URI), PopopxServerConfigProbeVerdict.INCONCLUSIVE)
    // A first row without sessions is skipped rather than ending the look.
    assertEquals(
      handler.judge(listOf(SMPServerSummary(smpServer = SMP11), cfgSummary(SMP11, connected = 1)), SMP11_URI),
      PopopxServerConfigProbeVerdict.REACHABLE,
    )
  }

  @Test
  fun everyChatThatIsNotDirectIsAGroupForReceiptPurposes() {
    val handler = PopopxServerConfigSignalHandler
    assertEquals(handler.sourceChat(ChatType.Direct), PopopxServerConfigSourceChat.DIRECT)
    assertEquals(handler.sourceChat(ChatType.Group), PopopxServerConfigSourceChat.GROUP)
    // A local profile is not a conversation the frame arrived in either, and answering it would be an uplink.
    assertEquals(handler.sourceChat(ChatType.Local), PopopxServerConfigSourceChat.GROUP)
    assertEquals(handler.sourceChat(ChatType.ContactRequest), PopopxServerConfigSourceChat.GROUP)
  }

  // MARK: - The receive path

  @Test
  fun ordinaryTextIsNotTouchedAtAll() = runBlocking {
    val drive = Drive()
    drive.receive("did you get the files I sent?")
    assertEquals(emptyList(), drive.transport.deletedRows)
    assertEquals(emptyList(), drive.transport.replacedTables)
    assertEquals(emptyList(), drive.transport.sentTexts)
    assertNull(drive.store.verdict)
    assertFalse(drive.store.hasStagedFrame)
  }

  @Test
  fun aFrameThatDoesNotVerifyNamesNothingAndStillDeletesTheRow() = runBlocking {
    // A signature from a key outside the trust list. The failure has to be silent on the wire, for two separate
    // reasons: the grammar cannot express a refusal, and naming the check that caught a forgery is an oracle.
    val drive = Drive()
    val untrusted = cfgHandler(drive.store, drive.transport, now = { drive.now }, keys = listOf(ByteArray(32)), log = { drive.logs.add(it) })
    untrusted.observeIncoming(ChatType.Direct, CHAT_API_ID, ITEM_ID, FULL_FRAME)
    untrusted.probeJob?.join()
    assertEquals(listOf(Triple(ChatType.Direct, CHAT_API_ID, ITEM_ID)), drive.transport.deletedRows)
    assertEquals(emptyList(), drive.transport.sentTexts)
    assertEquals(emptyList(), drive.transport.replacedTables)
    assertEquals(0L, drive.store.floor(FIXTURE_KEY_ID))
    assertNull(drive.store.verdict)
    assertTrue(drive.hadLog("frame refused:"))
  }

  @Test
  fun aSupersededGenerationIsAnsweredWithoutInstallingAnything() = runBlocking {
    val drive = Drive()
    drive.store.markAccepted(FIXTURE_KEY_ID, 7, listOf(LEGACY_URI))
    drive.receive(FULL_FRAME)
    // Same generation, so nothing is applied, and the receipt omits the body hash that would claim it was
    // installed.
    assertEquals(emptyList(), drive.transport.replacedTables)
    assertEquals(listOf(STALE_ACK), drive.transport.sentTexts)
    assertNull(drive.store.pendingAck)
    assertTrue(drive.hadLog("superseded"))
    // The frame's own withdrawal (`ms: 5`) is below a floor of 7, so it changes nothing, and the record this
    // device holds is still what the next frame is measured against.
    assertEquals(7L, drive.store.floor(FIXTURE_KEY_ID))
    assertNull(drive.store.existingRollbackSequence())
  }

  @Test
  fun aWithdrawalIsPersistedEvenWhenTheInstallRefuses() = runBlocking {
    val drive = Drive()
    drive.store.markAccepted(FIXTURE_KEY_ID, 3, emptyList())
    // `ms: 5` voids everything below 5, and that has to survive even though nothing was installed: the operator
    // asked for generations 1-4 to be dead, not for them to be dead only if this device also liked the new table.
    drive.transport.validationErrors = 1
    drive.receive(FULL_FRAME)
    assertEquals(4L, drive.store.floor(FIXTURE_KEY_ID))
    assertEquals(emptyList(), drive.transport.replacedTables)
    assertNull(drive.store.existingRollbackSequence())
    // The refusal happens before the snapshot and before the verdict is advanced, so a device that owes the
    // operator a probe window still owes it: claiming `verified` here would close a window that never opened.
    assertEquals(PopopxServerConfigVerdict.PENDING, drive.store.verdict)
    assertTrue(drive.hadLog("the core refused the merged table"))
  }

  @Test
  fun aFullFrameReachesTheCoreThroughTheWholePipeline() = runBlocking {
    val drive = Drive()
    drive.reachable()
    drive.receive(FULL_FRAME)
    assertEquals(listOf(LEGACY_URI, SMP11_URI, SMP12_URI), drive.rows(drive.transport.replacedTables.single()))
    assertEquals(7L, drive.store.floor(FIXTURE_KEY_ID))
    assertEquals(listOf(SMP11_URI, SMP12_URI), drive.store.introducedURIs)
    // The table is read to be merged, then re-read after the replacement so the core's ids for the new rows are
    // known to this device; skipping that is what breaks deleting a newly added server later.
    assertEquals(2, drive.transport.serverTableReads)
    assertEquals(1, drive.transport.statsResets)
    assertEquals(PopopxServerConfigVerdict.VERIFIED, drive.store.verdict)
    assertNull(drive.store.existingRollbackSequence())
    assertEquals(listOf(FULL_ACK), drive.transport.sentTexts)
    assertNull(drive.store.pendingAck)
    assertEquals(listOf(Triple(ChatType.Direct, CHAT_API_ID, ITEM_ID)), drive.transport.deletedRows)
  }

  @Test
  fun aRotationReplacesOwnedRowsAndKeepsTheOnesTheCoreStillNames() = runBlocking {
    val drive = Drive()
    drive.reachable()
    drive.receive(FULL_FRAME)
    // Generation 12 names a different host with one of the same keys, and it is `ack: off`.
    drive.transport.rows = listOf(cfgSummary(SMP13, connected = 1))
    drive.receive(ROTATED_FRAME)
    assertEquals(12L, drive.store.floor(FIXTURE_KEY_ID))
    assertEquals(listOf(LEGACY_URI, SMP13_URI), drive.rows(drive.transport.replacedTables.last()))
    // Ownership moved with the roster: the two rows this mechanism added and the new frame does not name are no
    // longer its problem, and the user's own row was never.
    assertEquals(listOf(SMP13_URI), drive.store.introducedURIs)
    assertEquals(PopopxServerConfigVerdict.VERIFIED, drive.store.verdict)
    assertEquals(1, drive.transport.sentTexts.size)
  }

  @Test
  fun aClusterThatProvesNothingLeavesTheWindowOpenWithTheSnapshotHeld() = runBlocking {
    val drive = Drive()
    drive.inconclusive()
    drive.receive(FULL_FRAME)
    assertEquals(1, drive.transport.replacedTables.size)
    assertEquals(PopopxServerConfigVerdict.PENDING, drive.store.verdict)
    assertEquals(7L, drive.store.existingRollbackSequence())
    assertEquals(PopopxServerConfigSnapshot.SCHEMA_VERSION, assertNotNull(drive.store.readRollback()).schemaVersion)
    // The receipt waits for a verdict: sending one now would claim an outcome this device does not have.
    assertEquals(emptyList(), drive.transport.sentTexts)
    val pending = assertNotNull(drive.store.pendingAck)
    assertEquals(7L, pending.seq)
    assertEquals(FULL_BODY_HASH, pending.bodyHash)
    assertEquals(FIXTURE_KEY_ID, pending.kid)
    assertTrue(drive.hadLog("inconclusive"))
  }

  @Test
  fun anUnreachableClusterRestoresTheTableItHeldBefore() = runBlocking {
    val drive = Drive()
    drive.unreachable()
    drive.receive(FULL_FRAME)
    assertEquals(2, drive.transport.replacedTables.size)
    // The restore hands back the snapshot's rows, which are the table as it was before the update.
    assertEquals(listOf(LEGACY_URI), drive.rows(drive.transport.replacedTables[1]))
    assertEquals(PopopxServerConfigVerdict.ROLLED_BACK, drive.store.verdict)
    assertTrue(drive.store.isBroken(FIXTURE_KEY_ID, 7))
    // The floor stays raised: the device really did see generation 7, and burning it is not the same as
    // pretending it never arrived.
    assertEquals(7L, drive.store.floor(FIXTURE_KEY_ID))
    assertEquals(emptyList(), drive.store.introducedURIs)
    assertNull(drive.store.existingRollbackSequence())
    // The receipt still goes: the device did install generation 7, and the rollback is a separate fact the
    // grammar cannot state.
    assertEquals(listOf(FULL_ACK), drive.transport.sentTexts)
  }

  @Test
  fun aReplacementTheCoreRejectsBurnsTheGenerationWithoutRestoring() = runBlocking {
    val drive = Drive(CfgTransportDouble(replaces = false))
    drive.reachable()
    drive.receive(FULL_FRAME)
    assertEquals(1, drive.transport.replacedTables.size)
    assertEquals(PopopxServerConfigVerdict.ROLLED_BACK, drive.store.verdict)
    assertTrue(drive.store.isBroken(FIXTURE_KEY_ID, 7))
    assertNull(drive.store.existingRollbackSequence())
    // No receipt: the device never reached the point of owing one, and a rollback of a table that never landed
    // is not something the operator needs counted.
    assertNull(drive.store.pendingAck)
    assertEquals(emptyList(), drive.transport.sentTexts)
    assertTrue(drive.hadLog("the core rejected the replacement"))
  }

  @Test
  fun aFrameThatArrivesWhileBackgroundedWaitsForALaunchThatCanWatch() = runBlocking {
    val drive = Drive(CfgTransportDouble(applicationActive = false))
    drive.receive(FULL_FRAME)
    assertEquals(emptyList(), drive.transport.replacedTables)
    assertTrue(drive.store.hasStagedFrame)
    // The withdrawal was applied even so, and the install is a delay rather than a concession.
    assertEquals(4L, drive.store.floor(FIXTURE_KEY_ID))
    assertNull(drive.store.verdict)
    // `receivedAt` comes from the wall clock here, so the install window is measured against it.
    drive.now = System.currentTimeMillis() / 1000 + 60
    drive.transport.applicationActive = true
    drive.reachable()
    drive.handler.promoteStagedIfNeeded()
    drive.handler.probeJob?.join()
    assertFalse(drive.store.hasStagedFrame)
    assertEquals(7L, drive.store.floor(FIXTURE_KEY_ID))
    assertEquals(1, drive.transport.replacedTables.size)
    assertEquals(PopopxServerConfigVerdict.VERIFIED, drive.store.verdict)
    assertEquals(listOf(FULL_ACK), drive.transport.sentTexts)
    assertTrue(drive.hadLog("promoting a staged frame"))
  }

  @Test
  fun aStagedFrameThatOutlivedItsInstallWindowIsDroppedNotInstalled() = runBlocking {
    val drive = Drive()
    assertTrue(drive.store.stage(PopopxServerConfigStagedFrame.of(FULL_FRAME, PopopxServerConfigSourceChat.DIRECT, CHAT_API_ID, receivedAt = NOW)))
    // The operator's own patience limit, applied to the only path that can exceed it: `iw` is 7200 here.
    drive.now = NOW + 7201
    drive.reachable()
    drive.handler.promoteStagedIfNeeded()
    drive.handler.probeJob?.join()
    assertEquals(emptyList(), drive.transport.replacedTables)
    assertFalse(drive.store.hasStagedFrame)
    assertEquals(4L, drive.store.floor(FIXTURE_KEY_ID))
    assertEquals(emptyList(), drive.transport.sentTexts)
    assertTrue(drive.hadLog("outlived its install window"))
  }

  @Test
  fun stagedBytesThatNoLongerVerifyAreDiscardedRatherThanRetried() = runBlocking {
    val drive = Drive()
    // Staged bytes are re-verified on promotion, so a frame that was never valid, or whose expiry passed while it
    // waited, lands here instead of being kept for another launch.
    val junk = "${PopopxServerConfigWire.CONFIG_PREFIX}POPOPXCFG1-eNqx.AAAA"
    assertTrue(drive.store.stage(PopopxServerConfigStagedFrame.of(junk, PopopxServerConfigSourceChat.DIRECT, CHAT_API_ID, receivedAt = NOW)))
    drive.reachable()
    drive.handler.promoteStagedIfNeeded()
    drive.handler.probeJob?.join()
    assertFalse(drive.store.hasStagedFrame)
    assertEquals(emptyList(), drive.transport.replacedTables)
    assertEquals(0L, drive.store.floor(FIXTURE_KEY_ID))
    assertTrue(drive.hadLog("staged frame refused:"))
  }

  @Test
  fun aWindowTheProcessDidNotFinishIsSettledByTheNextLaunch() = runBlocking {
    val drive = Drive()
    drive.inconclusive()
    drive.receive(FULL_FRAME)
    assertEquals(PopopxServerConfigVerdict.PENDING, drive.store.verdict)
    // Same defaults, same device, new process: the window is reopened from the record rather than from memory,
    // and the receipt that was stored mid-window is what gets delivered.
    val transport = CfgTransportDouble(
      table = drive.transport.replacedTables.single(),
      rows = listOf(cfgSummary(SMP11, connected = 1)),
    )
    val store = PopopxServerConfigStore(drive.defaults)
    val logs = mutableListOf<String>()
    cfgHandler(store, transport, now = { NOW }, log = { logs.add(it) }).promoteStagedIfNeeded()
    assertEquals(PopopxServerConfigVerdict.VERIFIED, store.verdict)
    assertNull(store.existingRollbackSequence())
    assertEquals(listOf(FULL_ACK), transport.sentTexts)
    assertNull(store.pendingAck)
  }

  @Test
  fun aWindowThatTurnsBadOnTheNextLaunchRollsBackFromTheSnapshot() = runBlocking {
    val drive = Drive()
    drive.inconclusive()
    drive.receive(FULL_FRAME)
    val transport = CfgTransportDouble(
      table = drive.transport.replacedTables.single(),
      rows = listOf(cfgSummary(SMP11, errors = 1), cfgSummary(SMP12, errors = 1)),
    )
    val store = PopopxServerConfigStore(drive.defaults)
    cfgHandler(store, transport, now = { NOW }).promoteStagedIfNeeded()
    // The relaunch restores from the snapshot, which is the only record of what the device held beforehand.
    assertEquals(listOf(LEGACY_URI), drive.rows(transport.replacedTables.single()))
    assertEquals(PopopxServerConfigVerdict.ROLLED_BACK, store.verdict)
    assertTrue(store.isBroken(FIXTURE_KEY_ID, 7))
    assertEquals(listOf(FULL_ACK), transport.sentTexts)
  }

  @Test
  fun aSnapshotThatNoUpdateOwnsIsDroppedRatherThanKeptAsAFallback() = runBlocking {
    val drive = Drive()
    // The kill this branch exists for: the snapshot was written, and the process died before the floor was
    // raised, so nothing in the device's history claims it.
    assertTrue(drive.store.writeRollback(PopopxServerConfigSnapshot.of(FIXTURE_KEY_ID, 7, emptyList(), cfgTable(LEGACY_URI), takenAt = NOW)))
    assertEquals(7L, drive.store.existingRollbackSequence())
    drive.inconclusive()
    drive.handler.promoteStagedIfNeeded()
    assertNull(drive.store.existingRollbackSequence())
    assertEquals(emptyList(), drive.transport.replacedTables)
    // Holding it would let a later, unrelated failure restore the wrong moment.
    assertNull(drive.store.verdict)
  }

  @Test
  fun aReceiptForAGenerationTheDeviceHasMovedPastIsDroppedNotSentLate() = runBlocking {
    val drive = Drive()
    drive.store.pendingAck = PopopxServerConfigPendingAck.of(FIXTURE_KEY_ID, 7, FULL_BODY_HASH, PopopxServerConfigSourceChat.DIRECT, CHAT_API_ID)
    // A newer generation arrived by some other path, so this receipt would be counted as an acknowledgement of a
    // device state that no longer exists.
    drive.store.markAccepted(FIXTURE_KEY_ID, 8, emptyList())
    drive.handler.promoteStagedIfNeeded()
    assertEquals(emptyList(), drive.transport.sentTexts)
    assertNull(drive.store.pendingAck)
  }

  @Test
  fun aReceiptThatFailedToSendReleasesItsClaimForTheNextAttempt() = runBlocking {
    val drive = Drive(CfgTransportDouble(sends = false))
    drive.reachable()
    drive.receive(FULL_FRAME)
    assertEquals(emptyList(), drive.transport.sentTexts)
    assertNull(drive.store.pendingAck)
    // The claim is released, which is what keeps the receipt at-most-once with a retry path rather than
    // at-least-once: a held claim would mute every later receipt for this generation.
    assertEquals(emptyList(), drive.store.ackClaims)
    assertTrue(drive.hadLog("the receipt was not delivered"))
  }

  @Test
  fun oneGenerationIsReceiptedOnceEvenWhenItArrivesTwice() = runBlocking {
    val drive = Drive()
    drive.reachable()
    drive.receive(FULL_FRAME)
    drive.receive(FULL_FRAME)
    assertEquals(1, drive.transport.replacedTables.size)
    assertEquals(listOf(FULL_ACK), drive.transport.sentTexts)
    assertEquals(1, drive.store.ackClaims.size)
    assertEquals(PopopxServerConfigVerdict.VERIFIED, drive.store.verdict)
  }

  @Test
  fun aFramePostedToAGroupIsAppliedButNeverAnswered() = runBlocking {
    val drive = Drive()
    drive.reachable()
    // `ack: on` in the body, so the only thing suppressing the receipt is the kind of chat it arrived in.
    drive.receive(FULL_FRAME, ChatType.Group, 12L)
    assertEquals(7L, drive.store.floor(FIXTURE_KEY_ID))
    assertEquals(1, drive.transport.replacedTables.size)
    assertEquals(PopopxServerConfigVerdict.VERIFIED, drive.store.verdict)
    // Nothing was owed and nothing was stored to owe later: the receipt is the one uplink this feature promises
    // never to open into a group.
    assertEquals(emptyList(), drive.transport.sentTexts)
    assertNull(drive.store.pendingAck)
    assertEquals(listOf(Triple(ChatType.Group, 12L, ITEM_ID)), drive.transport.deletedRows)
  }

  @Test
  fun nothingIsInstalledWhileTheDeviceHasNoSignedInUser() = runBlocking {
    val drive = Drive(CfgTransportDouble(userId = null))
    drive.reachable()
    drive.receive(FULL_FRAME)
    assertEquals(emptyList(), drive.transport.replacedTables)
    assertNull(drive.store.existingRollbackSequence())
    assertNull(drive.store.verdict)
    assertEquals(emptyList(), drive.transport.sentTexts)
    // The withdrawal still lands, because it is not a change to this user's table but a fact about the key.
    assertEquals(4L, drive.store.floor(FIXTURE_KEY_ID))
    // The machine line still leaves the conversation: a row nobody can act on is noise in a chat list.
    assertEquals(1, drive.transport.deletedRows.size)
    assertTrue(drive.hadLog("no signed-in user"))
  }

  @Test
  fun oneUnusableEntryRefusesTheWholeFrameRatherThanInstallingPartOfIt() = runBlocking {
    val transport = CfgTransportDouble()
    transport.acceptServerUri = { false }
    val drive = Drive(transport)
    drive.reachable()
    drive.receive(FULL_FRAME)
    // Installing one of two servers and reporting the generation as applied would leave the device believing it
    // holds a cluster the operator never finished describing.
    assertEquals(emptyList(), drive.transport.replacedTables)
    assertNull(drive.store.existingRollbackSequence())
    assertNull(drive.store.verdict)
    assertTrue(drive.hadLog("could not be turned into an address"))
  }

  // MARK: - Official subscriptions

  @Test
  fun theTwoOfficialAddressesAreWrittenAsTheyAreDeployed() {
    // Both are wire values, checked by shape: a bare domain has no A record, and a dropped `?c=` leaves the
    // address without the key it has to be dialled with.
    assertTrue(PopopxOfficialConfigLinks.CHANNEL_URI.startsWith("https://smp2.popopx.im/g#"))
    assertTrue(PopopxOfficialConfigLinks.BOT_URI.startsWith("https://smp6.popopx.im/a#"))
    assertTrue(PopopxOfficialConfigLinks.CHANNEL_URI.contains("?c="))
    assertTrue(PopopxOfficialConfigLinks.BOT_URI.contains("?c="))
    assertEquals(2_500L, PopopxOfficialConfigLinks.SEEDING_DELAY_MILLIS)
  }

  @Test
  fun seedingJoinsBothConversationsAndRecordsOnlyWhatWasSilenced() = runBlocking {
    val drive = Drive(CfgTransportDouble(joins = cfgJoin()))
    drive.handler.seedOfficialSubscriptions()
    assertEquals(
      listOf(PopopxOfficialConfigLinks.CHANNEL_URI, PopopxOfficialConfigLinks.BOT_URI),
      drive.transport.joinedURIs,
    )
    assertEquals(listOf(ChatType.Group to 11L, ChatType.Direct to 12L), drive.transport.silencedChats)
    assertEquals(listOf(11L, 12L), drive.store.systemConfigChatIds(1L))
    assertTrue(drive.store.officialSubscriptionSeeded(1L))
    // Once per profile, ever: a user who leaves either conversation is never put back into it.
    drive.handler.seedOfficialSubscriptions()
    assertEquals(2, drive.transport.joinedURIs.size)
    // A second profile on the same installation has no conversations of its own yet.
    drive.transport.userId = 2L
    drive.handler.seedOfficialSubscriptions()
    assertEquals(4, drive.transport.joinedURIs.size)
    assertTrue(drive.store.officialSubscriptionSeeded(2L))
    assertEquals(listOf(11L, 12L), drive.store.systemConfigChatIds(1L))
  }

  @Test
  fun aJoinThatNeverLandsStillMarksTheProfileWhichIsTheDocumentedTrade() = runBlocking {
    // The marker is written before the first request goes out, and this is the case that costs something: a
    // server unreachable on the device's first launch leaves the profile unsubscribed until a frame arrives some
    // other way. Nothing downstream of a failed join is attempted, so no id is recorded for a chat that does not
    // exist on this device.
    val drive = Drive()
    drive.handler.seedOfficialSubscriptions()
    assertTrue(drive.store.officialSubscriptionSeeded(1L))
    assertEquals(
      listOf(PopopxOfficialConfigLinks.CHANNEL_URI, PopopxOfficialConfigLinks.BOT_URI),
      drive.transport.joinedURIs,
    )
    assertEquals(emptyList(), drive.transport.silencedChats)
    assertEquals(emptyList(), drive.store.systemConfigChatIds(1L))
    // One shot per profile, ever — a permanently failed seed is not retried into an join loop.
    drive.handler.seedOfficialSubscriptions()
    assertEquals(2, drive.transport.joinedURIs.size)
  }

  @Test
  fun anUnsilenceableChatIsNotRecordedEvenThoughTheJoinLanded() = runBlocking {
    // The other half of the same rule: the conversation exists, the silence did not take, and an id recorded here
    // would hide a chat that still notifies from every list that is supposed to show it.
    val drive = Drive(CfgTransportDouble(joins = cfgJoin(), silences = false))
    drive.handler.seedOfficialSubscriptions()
    assertTrue(drive.store.officialSubscriptionSeeded(1L))
    assertEquals(
      listOf(ChatType.Group to 11L, ChatType.Direct to 12L),
      drive.transport.silencedChats,
    )
    assertEquals(emptyList(), drive.store.systemConfigChatIds(1L))
    assertTrue(drive.hadLog("could not be silenced"))
  }
}
