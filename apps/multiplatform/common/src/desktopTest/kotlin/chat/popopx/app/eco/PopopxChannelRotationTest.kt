package chat.popopx.app.eco

import chat.popopx.common.crypto.base64UrlEncode
import chat.popopx.common.crypto.ed25519KeyPair
import chat.popopx.common.eco.PopopxChannelBase64
import chat.popopx.common.eco.PopopxChannelEnvelope
import chat.popopx.common.eco.PopopxChannelKeyRotation
import chat.popopx.common.eco.PopopxChannelKeyUpdate
import chat.popopx.common.eco.PopopxEcoApplyOutcome
import chat.popopx.common.eco.PopopxEcoFrame
import chat.popopx.common.eco.PopopxEcoKeychain
import chat.popopx.common.eco.PopopxEcoKeys
import chat.popopx.common.eco.PopopxEcoLimits
import chat.popopx.common.eco.PopopxEcoNotice
import chat.popopx.common.eco.PopopxEcoSecrets
import chat.popopx.common.eco.PopopxEcoStore
import chat.popopx.common.eco.PopopxKeyRejection
import chat.popopx.common.eco.PopopxKeyRotationResult
import com.russhwolf.settings.Settings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The `ku` path end to end: a frame as a channel issuer would post it — the new epoch secret encrypted
// under the key this device already holds, signed by the channel's Ed25519 identity key — applied through
// the same order of checks iOS uses (ChannelKeyRotationManager.swift:620-780).

/** One derivation for every 32-byte key in this file, so "sealed under epoch n" and "stored epoch n" agree. */
private fun keyFor(epoch: Int): ByteArray = ByteArray(32) { (it + epoch).toByte() }

private const val RELAY = "smp1.popopx.test"
private const val CHANNEL = "chan.1"

class PopopxChannelRotationTest {
  private val identity = ed25519KeyPair()
  private val privateKey = identity.first
  private val publicKey = identity.second
  private val publicBase64URL = base64UrlEncode(publicKey)

  private fun link(id: String = CHANNEL, masterEpoch: Int = 1, identity: ByteArray = publicKey) =
    "popopx://channel/$RELAY/$id#key=${base64UrlEncode(keyFor(masterEpoch))}&pub=${base64UrlEncode(identity)}"

  /**
   * The issuer side. `envelopeEpoch` is separate from `toEpoch` because only [PopopxChannelKeyUpdate.isSane]
   * compares them, and one refusal test needs them equal on purpose.
   */
  private fun update(
    forChannel: String = CHANNEL,
    sealedUnder: Int,
    toEpoch: Int,
    revokePrevious: Boolean = false,
    plaintext: ByteArray? = null,
    signer: ByteArray = privateKey,
    envelopeEpoch: Int = toEpoch,
    sealedWith: ByteArray? = null,
    newKey: ByteArray? = null,
  ): PopopxChannelKeyUpdate {
    val body = plaintext ?: epochSecretPayload(toEpoch, base64UrlEncode(newKey ?: keyFor(toEpoch)))
    val envelope = PopopxChannelEnvelope(envelopeEpoch, "", "", "")
      .seal(sealedWith ?: keyFor(sealedUnder), signer, forChannel, body)!!
    return PopopxChannelKeyUpdate(forChannel, sealedUnder, revokePrevious, envelope)
  }

  private fun rotation(defaults: Settings = ecoSettings()): PopopxChannelKeyRotation =
    PopopxChannelKeyRotation(defaults).also { it.importPublicURI(link()) }

  @Test
  fun aPublicURIStoresEpochOneKeyAndTheIdentityKeySeparatelyFromTheIndex() {
    val defaults = ecoSettings()
    val manager = PopopxChannelKeyRotation(defaults)
    assertTrue(manager.importPublicURI(link()))
    val state = manager.channel(CHANNEL)
    assertNotNull(state)
    assertEquals(1, state.currentEpoch)
    assertEquals(listOf(1), state.epochs.map { it.epoch })
    assertEquals(publicKey.toList(), state.identityKeyData?.toList())
    // The index in settings is metadata only; the key itself is a keystore item, so a settings backup
    // alone cannot decrypt a single channel message. `save` therefore BLANKS the field, and the blank has to
    // be the whole story: one epoch row, key empty, identity key and epoch number still present.
    val index = defaults.getStringOrNull(PopopxEcoKeys.CHANNEL_INDEX)!!
    assertFalse(index.contains(base64UrlEncode(keyFor(1))), index)
    assertTrue(index.contains("\"keyBase64URL\":\"\""), index)
    assertTrue(index.contains("\"epoch\":1") && index.contains(publicBase64URL), index)
    assertEquals(keyFor(1).toList(), PopopxEcoSecrets.read(PopopxEcoKeychain.epochAccount(CHANNEL, 1), defaults)?.toList())
  }

  @Test
  fun reimportingTheSameLinkIsANoOpAndATakeoverIsRefusedOnlyWhereSomethingWasPaid() {
    val manager = rotation()
    assertTrue(manager.importPublicURI(link()))
    val otherPublic = ed25519KeyPair().second
    manager.channelTicketExists = { it == CHANNEL }
    assertFalse(manager.importPublicURI(link(masterEpoch = 5, identity = otherPublic)))
    // With nothing paid the answer is "allowed", and that is all it is: for a channel already stored, iOS
    // answers the takeover question without replacing anything (ChannelKeyRotationManager.swift:583-591), so
    // the old identity key keeps verifying frames until a signed handover arrives inside one.
    manager.channelTicketExists = { false }
    assertTrue(manager.importPublicURI(link(masterEpoch = 5, identity = otherPublic)))
    assertEquals(1, manager.channel(CHANNEL)!!.currentEpoch)
    assertEquals(publicKey.toList(), manager.channel(CHANNEL)!!.identityKeyData?.toList())
  }

  @Test
  fun aRotationSealedUnderTheCurrentEpochInstallsTheNewOne() {
    val manager = rotation()
    assertEquals(PopopxKeyRotationResult.Installed(2, emptyList()), manager.apply(update(sealedUnder = 1, toEpoch = 2), 7L))
    val state = manager.channel(CHANNEL)!!
    assertEquals(2, state.currentEpoch)
    assertEquals(listOf(1, 2), state.epochs.map { it.epoch })
    assertEquals(keyFor(2).toList(), state.currentKey?.keyData?.toList())
  }

  /** Every refusal has its own reason, and the order of the checks is the order below proves. */
  @Test
  fun everyRefusalPathReportsTheReasonThatStopsIt() {
    val manager = rotation()

    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.UNKNOWN_CHANNEL),
      manager.apply(update(forChannel = "chan.2", sealedUnder = 1, toEpoch = 2), 7L),
    )

    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.OUT_OF_RANGE),
      manager.apply(update(sealedUnder = 1, toEpoch = 2, envelopeEpoch = 1), 7L),
    )

    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.SIGNATURE_INVALID),
      manager.apply(update(sealedUnder = 1, toEpoch = 2, signer = ed25519KeyPair().first), 7L),
    )

    // The signature covers the ciphertext, so a flipped tag is caught BEFORE the cipher is offered: the
    // decryption is not an oracle for an attacker who cannot sign.
    val valid = update(sealedUnder = 1, toEpoch = 2)
    val tampered = valid.envelope.ciphertextBytes!!.copyOf().also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() }
    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.SIGNATURE_INVALID),
      manager.apply(valid.copy(envelope = valid.envelope.copy(ciphertextBase64 = PopopxChannelBase64.encode(tampered))), 7L),
    )

    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.UNKNOWN_SEALED_EPOCH),
      manager.apply(update(sealedUnder = 9, toEpoch = 2), 7L),
    )

    // Right signature, wrong key underneath it: the tag refuses, and nothing is stored.
    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.DECRYPT_FAILED),
      manager.apply(update(sealedUnder = 1, toEpoch = 2, sealedWith = keyFor(8)), 7L),
    )

    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.MALFORMED_PAYLOAD),
      manager.apply(update(sealedUnder = 1, toEpoch = 2, plaintext = "hello".encodeToByteArray()), 7L),
    )

    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.MALFORMED_PAYLOAD),
      manager.apply(update(sealedUnder = 1, toEpoch = 2, newKey = ByteArray(31)), 7L),
    )

    assertEquals(1, manager.channel(CHANNEL)!!.epochs.size)
  }

  /** A re-send is a no-op that still records the issuer; an older epoch is refused as the replay it is. */
  @Test
  fun aReplayedEpochIsAlreadyCurrentAndAnOlderOneIsRefused() {
    val manager = rotation()
    manager.apply(update(sealedUnder = 1, toEpoch = 2), 42L)

    assertEquals(
      PopopxKeyRotationResult.AlreadyCurrent(2),
      manager.apply(update(sealedUnder = 2, toEpoch = 2, envelopeEpoch = 3, newKey = keyFor(99)), 43L),
    )
    // The one fact worth keeping from a re-send is who issued it, because `rotate:` is addressed to it.
    assertEquals(43L, manager.channel(CHANNEL)!!.issuerContactId)
    assertEquals(keyFor(2).toList(), manager.channel(CHANNEL)!!.currentKey?.keyData?.toList())

    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.EPOCH_NOT_NEWER),
      manager.apply(update(sealedUnder = 2, toEpoch = 1, envelopeEpoch = 3), 43L),
    )
  }

  /** `rp` is revocation: the others are marked AND their key material deleted, since a revoked key that still opens a frame is not revoked. */
  @Test
  fun revokingPreviousEpochsDeletesTheirKeyMaterial() {
    val defaults = ecoSettings()
    val manager = PopopxChannelKeyRotation(defaults)
    manager.importPublicURI(link())
    manager.apply(update(sealedUnder = 1, toEpoch = 2), 7L)
    manager.apply(update(sealedUnder = 2, toEpoch = 3), 7L)

    assertEquals(PopopxKeyRotationResult.Installed(4, listOf(1, 2, 3)), manager.apply(update(sealedUnder = 3, toEpoch = 4, revokePrevious = true), 7L))
    val state = manager.channel(CHANNEL)!!
    assertEquals(listOf(1, 2, 3), state.epochs.filter { it.revoked }.map { it.epoch })
    assertEquals(4, state.currentEpoch)
    for (epoch in 1..3) assertNull(PopopxEcoSecrets.read(PopopxEcoKeychain.epochAccount(CHANNEL, epoch), defaults))
    assertNotNull(PopopxEcoSecrets.read(PopopxEcoKeychain.epochAccount(CHANNEL, 4), defaults))
    assertEquals(4, PopopxEcoSecrets.readEpochNumber(PopopxEcoKeychain.currentEpochAccount(CHANNEL), defaults))
    // A revoked epoch may not seal a new frame even though its number is still in the index.
    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.UNKNOWN_SEALED_EPOCH),
      manager.apply(update(sealedUnder = 1, toEpoch = 5), 7L),
    )
  }

  @Test
  fun storedEpochsAreCappedAtThirtyLowestNumberFirst() {
    val manager = rotation()
    for (epoch in 2..(PopopxEcoLimits.MAXIMUM_STORED_EPOCHS + 5)) {
      assertTrue(
        manager.apply(update(sealedUnder = epoch - 1, toEpoch = epoch), 7L) is PopopxKeyRotationResult.Installed,
        "epoch $epoch was not installed",
      )
    }
    val state = manager.channel(CHANNEL)!!
    assertEquals(PopopxEcoLimits.MAXIMUM_STORED_EPOCHS, state.epochs.size)
    assertEquals(6, state.epochs.minOf { it.epoch })
    assertEquals(state.epochs.maxOf { it.epoch }, state.currentEpoch)
  }

  @Test
  fun anIdentityKeyHandoverReplacesTheTrustRootOrIsRefused() {
    val manager = rotation()
    val next = ed25519KeyPair()
    val nextPrivate = next.first
    val nextPublic = next.second
    val handover = update(
      sealedUnder = 1,
      toEpoch = 2,
      plaintext = epochSecretPayload(2, base64UrlEncode(keyFor(2)), base64UrlEncode(nextPublic)),
    )
    assertEquals(PopopxKeyRotationResult.Installed(2, emptyList()), manager.apply(handover, 7L))
    assertEquals(nextPublic.toList(), manager.channel(CHANNEL)!!.identityKeyData?.toList())
    // The next frame must come from the NEW key, which is what makes the handover more than a rename.
    assertTrue(
      manager.apply(update(sealedUnder = 2, toEpoch = 3, signer = nextPrivate), 7L) is PopopxKeyRotationResult.Installed,
    )
    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.SIGNATURE_INVALID),
      manager.apply(update(sealedUnder = 3, toEpoch = 4, signer = privateKey), 7L),
    )

    val thirdPublic = ed25519KeyPair().second
    manager.channelIssuerConflict = { _, _ -> true }
    assertEquals(
      PopopxKeyRotationResult.Rejected(PopopxKeyRejection.ISSUER_CONFLICT),
      manager.apply(
        update(
          sealedUnder = 3,
          toEpoch = 5,
          plaintext = epochSecretPayload(5, base64UrlEncode(keyFor(5)), base64UrlEncode(thirdPublic)),
          signer = nextPrivate,
        ),
        7L,
      ),
    )
    assertEquals(3, manager.channel(CHANNEL)!!.currentEpoch)
  }

  @Test
  fun theStoreRoutesKeyUpdatesAndRaisesTheNoticeAUserCanActOn() {
    val defaults = ecoSettings()
    val manager = PopopxChannelKeyRotation(defaults)
    manager.importPublicURI(link())
    val store = PopopxEcoStore(defaults, manager)

    assertEquals(PopopxEcoApplyOutcome.ROTATED_KEY, store.apply(PopopxEcoFrame.ChannelKeyUpdate(update(sealedUnder = 1, toEpoch = 2)), 9L))
    assertEquals(PopopxEcoNotice.KeyRotated(CHANNEL, 2, false), store.takeNotice())
    assertNull(store.takeNotice())

    // A refused rotation raises a rejection notice, and the caller decides how much of it to say.
    store.apply(PopopxEcoFrame.ChannelKeyUpdate(update(sealedUnder = 1, toEpoch = 3, signer = ed25519KeyPair().first)), 9L)
    val notice = store.takeNotice()
    assertTrue(notice is PopopxEcoNotice.KeyRejected)
    assertEquals(PopopxKeyRejection.SIGNATURE_INVALID, (notice as PopopxEcoNotice.KeyRejected).reason)
    assertEquals(PopopxEcoApplyOutcome.IGNORED_STALE, store.apply(PopopxEcoFrame.ChannelKeyUpdate(update(sealedUnder = 2, toEpoch = 2, envelopeEpoch = 3)), 9L))
    assertNull(store.takeNotice())
  }

  @Test
  fun aReloadRestoresTheChannelAndDropsOneWhoseKeystoreItemsAreGone() {
    val defaults = ecoSettings()
    val manager = PopopxChannelKeyRotation(defaults)
    manager.importPublicURI(link())
    manager.apply(update(sealedUnder = 1, toEpoch = 2), 7L)

    val reloaded = PopopxChannelKeyRotation(defaults)
    val state = reloaded.channel(CHANNEL)
    assertNotNull(state)
    assertEquals(2, state.currentEpoch)
    assertEquals(listOf(1, 2), state.epochs.map { it.epoch })
    assertEquals(keyFor(2).toList(), state.currentKey?.keyData?.toList())

    PopopxEcoSecrets.remove(PopopxEcoKeychain.epochAccount(CHANNEL, 1), defaults)
    PopopxEcoSecrets.remove(PopopxEcoKeychain.epochAccount(CHANNEL, 2), defaults)
    val orphaned = PopopxChannelKeyRotation(defaults)
    assertNull(orphaned.channel(CHANNEL))
    // …but the metadata row survived, so tapping the link again brings the channel back.
    assertTrue(orphaned.importPublicURI(link()))
    assertEquals(1, orphaned.channel(CHANNEL)!!.currentEpoch)
  }

  @Test
  fun theMemberSideRequestNamesTheChannelAndNothingElse() {
    assertEquals("rotate:$CHANNEL", rotation().rotationRequestText(CHANNEL))
  }

  @Test
  fun theExpiryWarningClampsAndAnUnsetValueFallsBackToSevenDays() {
    val defaults = ecoSettings()
    assertEquals(PopopxEcoLimits.DEFAULT_EXPIRY_WARNING_DAYS, PopopxChannelKeyRotation(defaults).expiryWarningDays)
    val manager = PopopxChannelKeyRotation(defaults)
    manager.loadIfNeeded()
    manager.setExpiryWarningDays(0)
    assertEquals(PopopxEcoLimits.MINIMUM_EXPIRY_WARNING_DAYS, manager.expiryWarningDays)
    manager.setExpiryWarningDays(5000)
    assertEquals(PopopxEcoLimits.MAXIMUM_EXPIRY_WARNING_DAYS, manager.expiryWarningDays)
    val reloaded = PopopxChannelKeyRotation(defaults)
    // Read at load time, not at init: iOS deliberately loads in the views' `task`, because a Keychain read
    // before the device knows whether it is unlocked makes absent items indistinguishable from none.
    assertEquals(PopopxEcoLimits.DEFAULT_EXPIRY_WARNING_DAYS, reloaded.expiryWarningDays)
    reloaded.loadIfNeeded()
    assertEquals(PopopxEcoLimits.MAXIMUM_EXPIRY_WARNING_DAYS, reloaded.expiryWarningDays)
  }
}
