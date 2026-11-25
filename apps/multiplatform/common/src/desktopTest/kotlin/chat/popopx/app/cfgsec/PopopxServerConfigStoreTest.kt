package chat.popopx.app.cfgsec

import chat.popopx.common.cfgsec.PopopxServerConfigPendingAck
import chat.popopx.common.cfgsec.PopopxServerConfigSnapshot
import chat.popopx.common.cfgsec.PopopxServerConfigSourceChat
import chat.popopx.common.cfgsec.PopopxServerConfigStagedFrame
import chat.popopx.common.cfgsec.PopopxServerConfigStore
import chat.popopx.common.cfgsec.PopopxServerConfigVault
import chat.popopx.common.cfgsec.PopopxServerConfigVerdict
import com.russhwolf.settings.Settings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The device-state half of the contract: what this installation already did, and in which direction that record
// is allowed to move. Every case goes through a settings bag that lives in the test, because the app-wide
// `settings` writes real preference files on each put — and a floor raised by one test would then decide the next.

private const val KEY_A = "k-c88d4fd35d"
private const val KEY_B = "k-ad1dc5463a"

private class Cfg(val defaults: Settings = cfgSettings()) {
  val store = PopopxServerConfigStore(defaults)
}

private fun ack(seq: Long = 7, hash: String? = "06a413cfe750c6e2", chatApiId: Long = 4L) =
  PopopxServerConfigPendingAck.of(KEY_A, seq, hash, PopopxServerConfigSourceChat.DIRECT, chatApiId)

private fun snapshot(seq: Long) =
  PopopxServerConfigSnapshot.of(
    kid = KEY_A,
    seq = seq,
    introducedURIs = listOf("smp://aaa@smp1.popopx.im"),
    servers = cfgTable("smp://aaa@smp1.popopx.im"),
    takenAt = 1_796_000_000L,
  )

class PopopxServerConfigStoreTest {
  // MARK: - Floors

  @Test
  fun aFloorStartsAtZeroAndIsRecordedPerKey() {
    val cfg = Cfg()
    assertEquals(0L, cfg.store.floor(KEY_A))
    assertTrue(cfg.store.isAcceptable(KEY_A, 1))
    cfg.store.markAccepted(KEY_A, 7, emptyList())
    assertEquals(7L, cfg.store.floor(KEY_A))
    assertFalse(cfg.store.isAcceptable(KEY_A, 7))
    assertFalse(cfg.store.isAcceptable(KEY_A, 6))
    assertTrue(cfg.store.isAcceptable(KEY_A, 8))
    // The case the per-key structure exists for: a rotation's first generation must not be judged against a
    // floor that records what a *different* key published.
    assertEquals(0L, cfg.store.floor(KEY_B))
    assertTrue(cfg.store.isAcceptable(KEY_B, 1))
  }

  @Test
  fun anOlderGenerationNeverLowersAFloorAlreadyRaised() {
    val cfg = Cfg()
    cfg.store.markAccepted(KEY_A, 7, listOf("smp://aaa@smp11.popopx.im"))
    cfg.store.markAccepted(KEY_A, 5, listOf("smp://bbb@smp12.popopx.im"))
    assertEquals(7L, cfg.store.floor(KEY_A))
    // Ownership follows the newest acceptance rather than accumulating: a URI dropped from a later roster is no
    // longer something this device should still consider itself to have added.
    assertEquals(listOf("smp://bbb@smp12.popopx.im"), cfg.store.introducedURIs)
  }

  @Test
  fun anUnreadableFloorRecordIsAbsentRatherThanSatisfied() {
    val cfg = Cfg()
    cfg.defaults.putString(PopopxServerConfigStore.FLOOR_RECORDS, "{not json")
    assertEquals(emptyList(), cfg.store.floors)
    // Read-and-discard: the corrupt value does not outlive the read, so the next write starts from a clean key.
    assertNull(cfg.defaults.getStringOrNull(PopopxServerConfigStore.FLOOR_RECORDS))
    cfg.store.markAccepted(KEY_A, 3, emptyList())
    assertEquals(3L, cfg.store.floor(KEY_A))
  }

  @Test
  fun theTrackedListIsBoundedAndKeepsTheNewest() {
    val cfg = Cfg()
    // Through the real writer: `floors` is assignable, but the bound is what an acceptance enforces, so a test
    // that set the list directly would measure the test rather than the store.
    (1..20).forEach { cfg.store.markAccepted("k-%010d".format(it), it.toLong(), emptyList()) }
    val kept = cfg.store.floors
    assertEquals(16, kept.size)
    assertEquals(5L, kept.first().seq)
    assertEquals(20L, kept.last().seq)
    // The tail is what a device is offered against next, so trimming the old end costs nothing real: a
    // generation that fell off the front is below every generation the operator publishes afterwards.
    assertTrue(cfg.store.isAcceptable("k-%010d".format(20), 21))
    assertEquals(0L, cfg.store.floor("k-%010d".format(1)))
  }

  @Test
  fun theRecordKeysAreTheCrossPlatformValuesTheyClaimToBe() {
    val cfg = Cfg()
    cfg.store.markAccepted(KEY_A, 1, listOf("smp://aaa@smp1.popopx.im"))
    // Not implementation details: iOS writes the same names, which is what lets an operator compare two devices
    // side by side. Renaming one silently gives every upgraded device an empty history.
    assertNotNull(cfg.defaults.getStringOrNull("serverConfigFloors"))
    assertNotNull(cfg.defaults.getStringOrNull("serverConfigIntroducedURIs"))
    assertEquals("pending", cfg.defaults.getStringOrNull("serverConfigVerdict"))
    assertEquals("serverConfigFloors", PopopxServerConfigStore.FLOOR_RECORDS)
    assertEquals("serverConfigBrokenEntries", PopopxServerConfigStore.BROKEN_ENTRIES)
    assertEquals("serverConfigAckClaims", PopopxServerConfigStore.ACK_CLAIMS)
    assertEquals("serverConfigPendingAck", PopopxServerConfigStore.PENDING_ACK)
    assertEquals("serverConfigOfficialSubscription", PopopxServerConfigStore.OFFICIAL_SUBSCRIPTION)
    assertEquals("serverConfigSystemConfigChatIds", PopopxServerConfigStore.SYSTEM_CONFIG_CHAT_IDS)
    assertEquals("serverConfigRollback", PopopxServerConfigStore.SLOT_ROLLBACK)
    assertEquals("serverConfigStaged", PopopxServerConfigStore.SLOT_STAGED)
  }

  // MARK: - Revocation

  @Test
  fun revocationRaisesAFloorAndNeverLowersOne() {
    val cfg = Cfg()
    // `ms` of one revokes nothing, and it must not leave behind a record that reads as history.
    assertFalse(cfg.store.revoke(KEY_A, 1))
    assertFalse(cfg.store.revoke(KEY_A, 0))
    assertEquals(0L, cfg.store.floor(KEY_A))
    assertTrue(cfg.store.revoke(KEY_A, 5))
    assertEquals(4L, cfg.store.floor(KEY_A))
    assertFalse(cfg.store.isAcceptable(KEY_A, 4))
    assertTrue(cfg.store.isAcceptable(KEY_A, 5))
    // The direction that matters: replaying an unexpired older generation must not pull the floor down and put
    // a generation the device already acted on back into play.
    cfg.store.markAccepted(KEY_A, 9, emptyList())
    assertFalse(cfg.store.revoke(KEY_A, 5))
    assertEquals(9L, cfg.store.floor(KEY_A))
    // Scoped to the key that verified, so one rotation's withdrawal cannot void another key's history.
    assertTrue(cfg.store.revoke(KEY_B, 3))
    assertEquals(2L, cfg.store.floor(KEY_B))
    assertEquals(9L, cfg.store.floor(KEY_A))
    // Repeating a withdrawal moves nothing, which is what makes the return value worth logging.
    assertFalse(cfg.store.revoke(KEY_B, 3))
  }

  // MARK: - Broken generations

  @Test
  fun aRolledBackGenerationIsBurnedWithoutLoweringTheFloor() {
    val cfg = Cfg()
    cfg.store.markAccepted(KEY_A, 7, listOf("smp://aaa@smp1.popopx.im"))
    cfg.store.markRolledBack(KEY_A, 7)
    assertTrue(cfg.store.isBroken(KEY_A, 7))
    assertEquals(listOf("$KEY_A|7"), cfg.store.brokenEntries)
    // The floor stays raised, because the device really did see that generation; burning it is not a pardon.
    assertEquals(7L, cfg.store.floor(KEY_A))
    assertFalse(cfg.store.isAcceptable(KEY_A, 7))
    // The next generation is still welcome, so one failure is not a quarantine of the key.
    assertTrue(cfg.store.isAcceptable(KEY_A, 8))
    // The entry is the pair: the same number under a different key is a different config.
    assertFalse(cfg.store.isBroken(KEY_B, 7))
    assertEquals(PopopxServerConfigVerdict.ROLLED_BACK, cfg.store.verdict)
  }

  @Test
  fun brokenEntriesAreTrimmedFromTheOldEnd() {
    val cfg = Cfg()
    (1..20).forEach { cfg.store.markRolledBack(KEY_A, it.toLong()) }
    val kept = cfg.store.brokenEntries
    assertEquals(16, kept.size)
    assertTrue(kept.contains("$KEY_A|20"))
    assertFalse(kept.contains("$KEY_A|1"))
    assertTrue(cfg.store.isBroken(KEY_A, 20))
    assertFalse(cfg.store.isAcceptable(KEY_A, 20))
  }

  // MARK: - Verdict

  @Test
  fun theVerdictHasThreeValuesAndAnUnknownOneIsNothing() {
    val cfg = Cfg()
    assertNull(cfg.store.verdict)
    cfg.store.markAccepted(KEY_A, 1, emptyList())
    assertEquals(PopopxServerConfigVerdict.PENDING, cfg.store.verdict)
    cfg.store.markVerified()
    assertEquals(PopopxServerConfigVerdict.VERIFIED, cfg.store.verdict)
    cfg.defaults.putString(PopopxServerConfigStore.VERDICT, "superseded")
    assertNull(cfg.store.verdict)
    assertEquals("rolledBack", PopopxServerConfigVerdict.ROLLED_BACK.rawValue)
    assertEquals(PopopxServerConfigVerdict.ROLLED_BACK, PopopxServerConfigVerdict.fromRaw("rolledBack"))
    // An underscore spelling is a different string, not a near miss: the raw values are wire-visible in the
    // defaults dump, and a guess here would turn a rollback into a verdict nobody recorded.
    assertNull(PopopxServerConfigVerdict.fromRaw("rolled_back"))
    assertNull(PopopxServerConfigVerdict.fromRaw(null))
  }

  // MARK: - Receipts

  @Test
  fun aReceiptIsClaimedBeforeItIsSentAndReleasedWhenTheSendFails() {
    val cfg = Cfg()
    val receipt = ack()
    assertTrue(cfg.store.claimAck(receipt))
    assertFalse(cfg.store.claimAck(receipt))
    // The hash is not part of the identity, so a second look at the same generation with a different installed
    // body cannot reopen a receipt that is already owed.
    assertFalse(cfg.store.claimAck(ack(hash = "ffffffffffffffff")))
    assertEquals(1, cfg.store.ackClaims.size)
    cfg.store.releaseAckClaim(receipt)
    assertTrue(cfg.store.claimAck(receipt))
    // A different conversation is a different receipt, because that is where it has to be delivered.
    assertTrue(cfg.store.claimAck(ack(chatApiId = 5L)))
  }

  @Test
  fun theClaimListIsBoundedAndFallsOffTheOldEnd() {
    val cfg = Cfg()
    (1..20).forEach { assertTrue(cfg.store.claimAck(ack(seq = it.toLong()))) }
    val kept = cfg.store.ackClaims
    assertEquals(16, kept.size)
    assertEquals(20L, kept.last().seq)
    // The cost of the bound, stated rather than hidden: a receipt older than the window can be claimed again,
    // which is the same trade the floor list makes and is why a receipt is idempotent on the operator's side.
    assertTrue(cfg.store.claimAck(ack(seq = 1L)))
    val after = cfg.store.ackClaims
    assertEquals(16, after.size)
    assertEquals(6L, after.first().seq)
  }

  @Test
  fun theOwedReceiptSurvivesTheProcessAndIsNullable() {
    val cfg = Cfg()
    assertNull(cfg.store.pendingAck)
    cfg.store.pendingAck = ack()
    // A second store over the same bag is the same device after a restart, which is the only reason this slot
    // exists instead of an in-memory field.
    assertEquals(ack(), PopopxServerConfigStore(cfg.defaults).pendingAck)
    cfg.store.pendingAck = null
    assertNull(cfg.store.pendingAck)
    assertNull(cfg.defaults.getStringOrNull(PopopxServerConfigStore.PENDING_ACK))
    assertEquals("$KEY_A|7|direct|4", ack().claimKey)
  }

  @Test
  fun anUndecodableReceiptRecordIsTreatedAsAbsent() {
    val cfg = Cfg()
    cfg.defaults.putString(PopopxServerConfigStore.PENDING_ACK, """{"kid":"$KEY_A"}""")
    assertNull(cfg.store.pendingAck)
    assertNull(cfg.defaults.getStringOrNull(PopopxServerConfigStore.PENDING_ACK))
    // And a receipt can be recorded again afterwards, so a truncated write is not a permanent mute.
    cfg.store.pendingAck = ack()
    assertNotNull(cfg.store.pendingAck)
  }

  // MARK: - The protected tier

  @Test
  fun aSnapshotWrittenMidWindowDoesNotReplaceTheLastKnownGoodTable() {
    val cfg = Cfg()
    assertTrue(cfg.store.writeRollback(snapshot(7)))
    assertEquals(7L, cfg.store.existingRollbackSequence())
    // No window open, so a second snapshot is allowed: this is the ordinary successive-update case.
    assertTrue(cfg.store.writeRollback(snapshot(8)))
    cfg.store.markAccepted(KEY_A, 9, emptyList())
    assertFalse(cfg.store.writeRollback(snapshot(9)))
    // The refusal has to be the whole answer: the table still held is the pre-update one, not the bad frame's.
    assertEquals(8L, cfg.store.existingRollbackSequence())
    cfg.store.markVerified()
    assertTrue(cfg.store.writeRollback(snapshot(9)))
    assertEquals(9L, cfg.store.existingRollbackSequence())
    cfg.store.clearRollback()
    assertNull(cfg.store.readRollback())
    assertNull(cfg.store.existingRollbackSequence())
  }

  @Test
  fun aRollbackSnapshotCarriesTheWholeTableAndItsOwnSchemaVersion() {
    val cfg = Cfg()
    val held = snapshot(7)
    assertEquals(PopopxServerConfigSnapshot.SCHEMA_VERSION, held.schemaVersion)
    assertTrue(cfg.store.writeRollback(held))
    val read = cfg.store.readRollback()
    assertNotNull(read)
    assertEquals(held.introducedURIs, read.introducedURIs)
    assertEquals(held.takenAt, read.takenAt)
    assertEquals(held.kid, read.kid)
    // The rows travel intact, because restoring hands them straight back to the core and then re-reads them.
    assertEquals("smp://aaa@smp1.popopx.im", read.servers.first().smpServers.first().server)
  }

  @Test
  fun aStagedFrameIsReadAndDeletedInOneCall() {
    val cfg = Cfg()
    assertFalse(cfg.store.hasStagedFrame)
    assertNull(cfg.store.takeStaged())
    assertTrue(cfg.store.stage(PopopxServerConfigStagedFrame.of(MINIMAL_FRAME, PopopxServerConfigSourceChat.DIRECT, 3L)))
    assertTrue(cfg.store.hasStagedFrame)
    val first = cfg.store.takeStaged()
    assertNotNull(first)
    assertEquals(MINIMAL_FRAME, first.segment)
    assertEquals(PopopxServerConfigStagedFrame.SCHEMA_VERSION, first.schemaVersion)
    // The delete is part of the read, so a promotion that dies halfway cannot re-promote the same bytes forever.
    assertFalse(cfg.store.hasStagedFrame)
    assertNull(cfg.store.takeStaged())
  }

  @Test
  fun presenceIsNotReadability() {
    val cfg = Cfg()
    // A slot whose bytes will not open: `hasStagedFrame` answers from presence, every read answers absent.
    cfg.defaults.putString("${PopopxServerConfigStore.SLOT_STAGED}.ct", "!!not base64!!")
    cfg.defaults.putString("${PopopxServerConfigStore.SLOT_STAGED}.iv", "!!not base64!!")
    assertTrue(cfg.store.hasStagedFrame)
    assertNull(cfg.store.takeStaged())
    // And the failed read cleared it, which is the documented rule: the only way here twice is a wiped alias
    // with surviving ciphertext, i.e. a restored backup, and that must not be this device's rollback target.
    assertFalse(cfg.store.hasStagedFrame)
  }

  @Test
  fun aRecordFromAnotherBuildIsDiscardedRatherThanGuessedAt() {
    val cfg = Cfg()
    val vault = PopopxServerConfigVault(cfg.defaults)
    val oldStaged = """{"schemaVersion":1,"receivedAt":1,"segment":"$MINIMAL_FRAME","chatType":"direct","chatApiId":3}"""
    assertTrue(vault.write(PopopxServerConfigStore.SLOT_STAGED, PopopxServerConfigStore.STAGED_ALIAS, oldStaged))
    assertTrue(cfg.store.hasStagedFrame)
    assertNull(cfg.store.takeStaged())
    assertFalse(cfg.store.hasStagedFrame)

    val oldRollback = """{"schemaVersion":1,"takenAt":1,"kid":"$KEY_A","seq":7,"introducedURIs":[],"servers":[]}"""
    assertTrue(vault.write(PopopxServerConfigStore.SLOT_ROLLBACK, PopopxServerConfigStore.SNAPSHOT_ALIAS, oldRollback))
    assertNotNull(cfg.defaults.getStringOrNull("${PopopxServerConfigStore.SLOT_ROLLBACK}.ct"))
    assertNull(cfg.store.readRollback())
    assertNull(cfg.store.existingRollbackSequence())
    // The discard removes the slot, it does not shadow it.
    assertNull(cfg.defaults.getStringOrNull("${PopopxServerConfigStore.SLOT_ROLLBACK}.ct"))
    // And with nothing held a fresh write is allowed again, so a discarded record cannot wedge the tier.
    assertTrue(cfg.store.writeRollback(snapshot(7)))
  }

  @Test
  fun theProtectedTierRefusesAnEmptyOrOversizedBlobAndTheUpdateWithIt() {
    val cfg = Cfg()
    val vault = PopopxServerConfigVault(cfg.defaults)
    assertFalse(vault.write(PopopxServerConfigStore.SLOT_STAGED, PopopxServerConfigStore.STAGED_ALIAS, ""))
    assertFalse(cfg.store.hasStagedFrame)
    assertFalse(
      vault.write(
        PopopxServerConfigStore.SLOT_ROLLBACK,
        PopopxServerConfigStore.SNAPSHOT_ALIAS,
        "x".repeat(PopopxServerConfigStore.MAXIMUM_PROTECTED_CHARACTERS + 1),
      )
    )
    // The ceiling is a real gate, not a log line: a table too large to snapshot cannot be applied at all,
    // because a refused snapshot write is the handler's reason to refuse the frame.
    val huge = snapshotWithHugeTable(7)
    val encoded = PopopxServerConfigStore.json.encodeToString(PopopxServerConfigSnapshot.serializer(), huge)
    assertTrue(encoded.length > PopopxServerConfigStore.MAXIMUM_PROTECTED_CHARACTERS, "fixture too small: ${encoded.length}")
    assertFalse(cfg.store.writeRollback(huge))
    assertNull(cfg.store.readRollback())
  }

  /** Large enough that its JSON passes no ceiling: the point is that it does not. */
  private fun snapshotWithHugeTable(seq: Long): PopopxServerConfigSnapshot {
    val rows = (1..900).map { "smp://aaa%s@legacy%s.popopx.im".format(it, it) }
    return PopopxServerConfigSnapshot.of(kid = KEY_A, seq = seq, introducedURIs = rows, servers = cfgTable(*rows.toTypedArray()), takenAt = 1L)
  }

  // MARK: - Per-profile state

  @Test
  fun theOfficialSeedIsPerProfileNotPerDevice() {
    val cfg = Cfg()
    assertFalse(cfg.store.officialSubscriptionSeeded(1L))
    cfg.store.markOfficialSubscriptionSeeded(1L)
    assertTrue(cfg.store.officialSubscriptionSeeded(1L))
    // A second profile on the same installation has no conversations of its own yet, so a device-wide flag
    // would leave it permanently unsubscribed.
    assertFalse(cfg.store.officialSubscriptionSeeded(2L))
    assertFalse(cfg.store.officialSubscriptionSeeded(0L))
  }

  @Test
  fun hiddenChatIdsAreAdditivePerProfileAndIdempotent() {
    val cfg = Cfg()
    cfg.store.addSystemConfigChatId(11L, 1L)
    cfg.store.addSystemConfigChatId(11L, 1L)
    cfg.store.addSystemConfigChatId(12L, 1L)
    cfg.store.addSystemConfigChatId(13L, 2L)
    assertEquals(listOf(11L, 12L), cfg.store.systemConfigChatIds(1L))
    assertEquals(listOf(13L), cfg.store.systemConfigChatIds(2L))
    cfg.store.clearSystemConfigChatIds(2L)
    assertEquals(emptyList(), cfg.store.systemConfigChatIds(2L))
    // Clearing one profile leaves the other's list alone, and clearing an empty one is not a write.
    assertEquals(listOf(11L, 12L), cfg.store.systemConfigChatIds(1L))
    cfg.store.clearSystemConfigChatIds(2L)
    cfg.store.clearSystemConfigChatIds(3L)
    assertEquals(listOf(11L, 12L), cfg.store.systemConfigChatIds(1L))
    cfg.store.clearSystemConfigChatIds(1L)
    assertEquals(emptyList(), cfg.store.systemConfigChatIds(1L))
  }
}
