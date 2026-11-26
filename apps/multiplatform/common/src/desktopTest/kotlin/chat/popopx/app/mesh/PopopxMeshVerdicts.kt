package chat.popopx.app.mesh

import chat.popopx.common.mesh.PopopxMeshMessageType
import chat.popopx.common.mesh.PopopxNoiseCounterPlacement
import chat.popopx.common.mesh.PopopxNoiseError
import chat.popopx.common.mesh.PopopxNoiseXXHandshake

/**
 * The vectors were printed by Swift, so a Kotlin verdict has to be rendered the way Swift prints it
 * before the two can be compared at all.
 *
 * What is reproduced here is the machine-readable part of `String(describing:)` - the case name and
 * its arguments - and not the prose: iOS' error cases carry no message while ours do, and the two
 * languages spell cases differently. Every line here was read off
 * `apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Crypto/PopopxNoiseXX.swift:26-53` and
 * `Protocol/PopopxMeshProtocol.swift:22-44`; a value with no mapping fails the test instead of being
 * guessed at, so a new case cannot quietly turn a real difference into a passing comparison.
 */
internal object PopopxMeshVerdicts {
  /** An unsigned field, printed the way Swift prints `UInt64` and the way the vectors recorded it. */
  fun unsigned(value: Long): String = java.lang.Long.toUnsignedString(value)

  fun swift(error: PopopxNoiseError): String =
    when (error) {
      PopopxNoiseError.ProtocolNameMismatch -> "protocolNameMismatch"
      PopopxNoiseError.PeerKeyUnusable -> "peerKeyUnusable"
      PopopxNoiseError.LocalKeyUnusable -> "localKeyUnusable"
      PopopxNoiseError.DecryptionFailed -> "decryptionFailed"
      PopopxNoiseError.LocalNonceExhausted -> "localNonceExhausted"
      PopopxNoiseError.PeerNonceExhausted -> "peerNonceExhausted"
      PopopxNoiseError.HandshakeNotComplete -> "handshakeNotComplete"
      is PopopxNoiseError.MessageTooShort ->
        "messageTooShort(bytes: ${error.bytes}, required: ${error.required})"
      is PopopxNoiseError.Replayed -> "replayed(counter: ${unsigned(error.counter)})"
      is PopopxNoiseError.CounterOutsideWindow ->
        "counterOutsideWindow(counter: ${unsigned(error.counter)}, windowStart: ${unsigned(error.windowStart)})"
      is PopopxNoiseError.KeyLengthInvalid -> "keyLengthInvalid(bytes: ${error.bytes})"
      is PopopxNoiseError.HandshakeOutOfOrder -> "handshakeOutOfOrder(role: ${swift(error.role)})"
    }

  /** The role inside `handshakeOutOfOrder`, module-qualified exactly as Swift's mirror prints it. */
  fun swift(role: PopopxNoiseXXHandshake.Role): String =
    "PopopxMeshKit.PopopxNoiseXXHandshake.Role.$role"

  fun swift(type: PopopxMeshMessageType?): String {
    if (type == null) return "nil"
    val case =
      when (type) {
        PopopxMeshMessageType.ANNOUNCE -> "announce"
        PopopxMeshMessageType.MESSAGE -> "message"
        PopopxMeshMessageType.LEAVE -> "leave"
        PopopxMeshMessageType.NOISE_HANDSHAKE -> "noiseHandshake"
        PopopxMeshMessageType.NOISE_ENCRYPTED -> "noiseEncrypted"
        PopopxMeshMessageType.FRAGMENT -> "fragment"
        PopopxMeshMessageType.PING -> "ping"
        PopopxMeshMessageType.PONG -> "pong"
        PopopxMeshMessageType.PAIRING_REQUEST -> "pairingRequest"
        PopopxMeshMessageType.PAIRING_ACK -> "pairingAck"
        PopopxMeshMessageType.DELIVERY_ACK -> "deliveryAck"
        PopopxMeshMessageType.GROUP_STATE -> "groupState"
        PopopxMeshMessageType.GROUP_MESSAGE -> "groupMessage"
      }
    return "Optional(PopopxMeshKit.PopopxMeshMessageType.$case)"
  }

  /** The three words the replay window vectors use for a counter's position. */
  fun swift(placement: PopopxNoiseCounterPlacement): String =
    when (placement) {
      PopopxNoiseCounterPlacement.ACCEPT -> "accept"
      PopopxNoiseCounterPlacement.DUPLICATE -> "duplicate"
      PopopxNoiseCounterPlacement.TOO_OLD -> "tooOld"
    }

  /**
   * The tool's `probe`: the call was expected to throw, so its own success is reported with the
   * wording the vectors recorded ([surprise], e.g. "accepted (unexpected)").
   */
  fun probe(surprise: String, block: () -> Unit): String =
    try {
      block()
      surprise
    } catch (error: PopopxNoiseError) {
      swift(error)
    }

  /** The tool's `probeOk`: a success is the expected outcome and is reported as [accepted]. */
  fun probeOk(accepted: String, block: () -> Unit): String =
    try {
      block()
      accepted
    } catch (error: PopopxNoiseError) {
      swift(error)
    }
}
