package chat.popopx.common.mesh

/**
 * The mesh's numbers, copied field for field from
 * apps/ios/PopopxMeshKit/Sources/PopopxMeshKit/Core/PopopxMeshConfig.swift — 28 values, verified
 * against the literals that Swift itself reports (see the vector run recorded in the phase-4
 * commit body). The Bluetooth names in comments are the Bitchat constants each value came from.
 *
 * Deliberately not a `data class` with mutable platform overrides: a number that differed between
 * the two apps would fork the protocol, and the whole point of this type is that it cannot.
 */
class PopopxMeshConfig(
  // MARK: Mesh flooding

  /** messageTTLDefault */
  val ttlDefault: Int = 7,
  /**
   * bleFragmentRelayTtlCap. Measured on iOS: no relay or fragment path ever reads it — only the UI
   * uses it as a hop-count ceiling (ChatsListView.swift:237, PopopxCabinView.swift:981,1353,2420,
   * PopopxMessageBubble.swift:794). Kept at the same value with the same non-use.
   */
  val fragmentRelayTtlCap: Int = 7,
  /** bleHighDegreeThreshold — above this neighbour count, broadcast TTL gets clamped. */
  val highDegreeThreshold: Int = 6,
  /** denseBroadcastTtlCap, the clamp itself. */
  val denseBroadcastTtlCap: Int = 5,
  /** bleDefaultFragmentSize — the payload slice that fits one MTU after framing. */
  val fragmentSize: Int = 469,
  /** bleMaxMTU */
  val maxMTU: Int = 512,
  /** bleFragmentLifetimeSeconds — an assembly older than this is dropped, not resumed. */
  val fragmentLifetime: Double = 30.0,
  /** bleMaxInFlightAssemblies */
  val maxInFlightAssemblies: Int = 128,
  /** bleFragmentRelayMinDelayMs / bleFragmentRelayMaxDelayMs — jitter before a relay re-floods. */
  val relayMinDelay: Double = 0.008,
  val relayMaxDelay: Double = 0.025,

  // MARK: Deduplication

  /** bleRecentPacketWindowSeconds / bleRecentPacketWindowMaxCount. */
  val recentPacketWindow: Double = 30.0,
  val recentPacketMaxCount: Int = 100,
  /** messageDedupMaxAgeSeconds / messageDedupMaxCount — the longer memory for whole messages. */
  val messageDedupMaxAge: Double = 300.0,
  val messageDedupMaxCount: Int = 1000,

  // MARK: Discovery and presence

  /** bleDutyOnDuration / bleDutyOffDuration — the scan duty cycle. */
  val scanOnDuration: Double = 5.0,
  val scanOffDuration: Double = 10.0,
  /** bleAnnounceIntervalSeconds */
  val announceInterval: Double = 4.0,
  /** bleConnectTimeoutSeconds */
  val connectTimeout: Double = 8.0,
  /** bleMaxCentralLinks — admission counts central links only. */
  val maxCentralLinks: Int = 6,
  /** bleMaintenanceInterval */
  val maintenanceInterval: Double = 5.0,

  // MARK: Reachability and delivery rules

  val peerReachabilityTimeout: Double = 15.0,
  val bleAckTimeout: Double = 5.0,
  val smpAckTimeout: Double = 3.0,

  // MARK: Transport identity

  /**
   * Bitchat advertises F47B5E2D-…-8E1D2C3A4B5C. POPOPX uses its own UUID so the two apps do not
   * answer each other's connections. A 128-bit UUID string — the Android adapter parses it into the
   * 16-bit/128-bit form BluetoothGatt wants.
   */
  val serviceUUID: String = "D3A6F5A1-2C4E-4B9A-8F7D-1E2C3B4A5960",
  val characteristicUUID: String = "B7C1D4E2-5A6F-4B3C-9D8E-0F1A2B3C4D5E",
  /**
   * iOS hands these to CBCentralManagerOptionRestoreIdentifierKey. Android has no state
   * restoration, so the strings exist here only so the two platforms' preference namespaces can be
   * compared; nothing reads them on Android.
   */
  val centralRestoreIdentifier: String = "chat.popopx.mesh.central",
  val peripheralRestoreIdentifier: String = "chat.popopx.mesh.peripheral",

  /**
   * ChaChaPoly2013 adds a 16-byte tag and POPOPX prepends a 12-byte nonce, so an encrypted frame is
   * 28 bytes longer than its plaintext. Bitchat's transportCiphertextOverhead is 20 because it
   * derives the nonce instead of sending it.
   */
  val noiseTransportOverhead: Int = 28,
) {
  companion object {
    val default: PopopxMeshConfig = PopopxMeshConfig()
  }
}
