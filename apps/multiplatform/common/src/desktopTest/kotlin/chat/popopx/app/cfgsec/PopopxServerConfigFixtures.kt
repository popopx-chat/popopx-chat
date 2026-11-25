package chat.popopx.app.cfgsec

import chat.popopx.common.cfgsec.PopopxServerConfigTrust
import chat.popopx.common.cfgsec.PopopxServerConfigWire
import chat.popopx.common.model.ServerOperator
import chat.popopx.common.model.ServerProtocol
import chat.popopx.common.model.SMPServerSummary
import chat.popopx.common.model.ServerSessions
import chat.popopx.common.model.UserOperatorServers
import chat.popopx.common.model.UserServer
import chat.popopx.common.cfgsec.PopopxOfficialConfigLinks
import chat.popopx.common.cfgsec.PopopxOfficialJoin
import chat.popopx.common.cfgsec.PopopxServerConfigTransport
import chat.popopx.common.cfgsec.PopopxServerConfigSignalHandler
import chat.popopx.common.cfgsec.PopopxServerConfigStore
import chat.popopx.common.model.ChatType
import com.russhwolf.settings.PropertiesSettings
import com.russhwolf.settings.Settings
import kotlinx.coroutines.delay
import java.util.Properties

// Real frames, minted by the repository's own generator (`scripts/ios/server-config-mint.swift`) on 2026-11-25,
// plus the doubles the handler test drives its state machine with.
//
// The tokens are the only hard evidence this round that Kotlin and Swift agree about the wire: each was signed
// outside this suite by the same code path the operator uses, so an assertion that one of them decodes proves the
// framing, the deflate container, the body grammar and the signature domain against bytes this repository did not
// write. The bodies are also what the assertions below quote, so a fixture that stopped matching its own
// compressed bytes would fail rather than drift.
//
// The signing key is a locally generated throwaway seed, never the operator key, which is why the trust anchor is
// injected: `PopopxServerConfigWire.decodeConfigFrame` takes a caller-supplied key list exactly so a fixture can
// travel the whole pipeline. Production always uses the pinned root.

/** The public half of the fixture key, as the generator reported it. */
internal const val FIXTURE_KEY_HEX =
  "5ce7021d3ae1820a645bdf23748f755957748f89b0629375426c62da2a5a8a4d"

/** The key id the generator derived for it, and which every fixture body carries as `kid`. */
internal const val FIXTURE_KEY_ID = "k-c88d4fd35d"

/** The instant the generator stamped these frames. */
internal const val ISSUED_AT = 1795614944L

/** Every fixture shares one expiry: 2026-12-02T13:55:43Z. */
internal const val EXPIRES_AT = 1796219743L

/** A `now` inside the validity window, used by every decode that is expected to succeed. */
internal const val NOW = 1796000000L

internal val FIXTURE_KEYS: List<ByteArray> = listOf(PopopxServerConfigTrust.decodeKeyHex(FIXTURE_KEY_HEX)!!)

/** One SMP server, `ack: off`, `pol.ms: 1` — the smallest frame the grammar admits. */
internal const val MINIMAL_FRAME =
  "::popopx_sys::SERVER_CFG_V1::POPOPXCFG1-eNolj7sOwjAMRf_Fc0EJSZ8bCwLBAgUJhBhKm0DUpg8aaKDi3zGtPPjo-vrK7uEFEXWgFc3Qc5VBBPkkDYKMy4y5GTggyhTFT4ioEoM-P3Q9ykPu4szWg-DNaOhzhkkahfMZts3pcNhNFifR2msbG9bNPne9Xi6vNs51tzHPI9mz23yvVzBsUTqtKyw7VRouFwesNP8opNLIER6iSN4jqlSMUFcFRD0kaY5HVlJimm6HZ1QHEfMIwb0KhT8Yg2aP8ICQ7_cHBmNJHQ.05dHVUI1yVXl4s2DAvXcd1O89Bry15fax5PC3FzR4GnMSUuH7Ah927EN-wQIulH80nzjgxuJ_9jlooVCcmNwBA"

/** Two SMP, one XFTP, one notification, one relay, one TURN entry, `ack: on`, `pol.ms: 5`, generation 7. */
internal const val FULL_FRAME =
  "::popopx_sys::SERVER_CFG_V1::POPOPXCFG1-eNpdkltvolAUhf_Lfh1ogHO4Jn0YpdYLaqnSyphmAohK8QByEzX-99lQHzoND6zsfdaXxVlcoQZD5KAIj2CoHMTRBgyI-UDTNnS7IfIGOAiTAIcXHWXklXhe1WVFpDqluGuybqBIoq5SgiSGg_Ua7KPrOK_8wA2Lxi8WJTlJlz2bDId-s4jZySqrlbAku99LNoLOJYoPWYpP8xAx-ODWIAbErIbpYP6m7c6XZURrphSXxbtF2G7jBOKrqVV_XnqWe7bvBOk74YODZlt-hRm741FRSypNi1XOp379l8w9RWHjevppzjzxGEdZPmarfdyGaW30Byoptx1pJSSJmpEXZxnThRwdCPVHflEciKOabt1Lq2E87S-FM__kQOf6mSkPD965Q3VK_bbmwBdms4s0mJvv5fDTfU6p5egZ9ab9_j7Mavl07vsTFk0cO3Q7WBSEiLoClgJllScFMvZ3_R8Yr4G27ZR5uw0yHFWosDhNEhSdEiPY7ni1bbvt2vpli_Z8Np30rHHtydWWPuVN_szUVfDYXlBX-d15wxxZegDjCl4QozlN8AgrwJAx4Al_K0kQ8LtTMBR8l-WhFVQThNvtH7WSwoI.O5SNKlNjVMnGkepY1L_9RYCUafDjaiz0--rqMk5yfHRBnFVOzRTuXidLEFxR3a41qbK-VIOVgJmaH6a-aY1pCw"

/** Generation 12 from the same key, one new SMP host — the rotation case. */
internal const val ROTATED_FRAME =
  "::popopx_sys::SERVER_CFG_V1::POPOPXCFG1-eNpdkF1vgjAUhv_LuUZDaS0flwtZJnFz39MZs7AWXIe1CJUBxv--M7hbetEnb8_7JKdnaCAiDtTZEW_PgUJJiKCYiCCQLJd0JsGB7CAw7ENElVoc9MMZJyxkHN_acgi4R0KfUVRpDDYbIILGpxtzvXwNdl3_rFijed0_vS2o3skXQR7j4PR-f7VYdw8wtAidlgZPO1UatlsH2tyOqmSdzOvG85mpV9XEfDYfdJlyrpPm9ju-S8mxUGWV6NVXMYexxv6pDjZHE0KV7dNuRCWyEUqzh-gMqShwS5Pn6ND18C3qByLKXRd7BoM_sBaHucsC171cfgF7kF68.GFrGbniGWc1DCsfs_DKfuDe1Lkinv-3Df0XeuKXrlVv7U_fmTVuI3HL8FX2SH8nz1jblA02eGBAIHWwRJVg_BA"

/**
 * Why the ceiling matters more here than anywhere else in the suite: the full frame is 730 characters, and the
 * signalling kinds this app also carries refuse anything over their own payload ceiling. A fixture that came in
 * under the limit would not have proven the two ceilings are different rules.
 */
internal const val FULL_FRAME_CHARACTERS = 730

/**
 * The addresses the handler builds from those bodies: the signature carries the unpadded 43-character
 * fingerprint, and `padded` offers the 44-character spelling first, which is what the shipped presets and iOS
 * both use. Quoted here rather than re-derived so a test that asserts a row was installed names the row.
 */
internal const val SMP11_URI = "smp://QqYUUR-FYesxbsSt3w2zhmKHHbxSkmwLtuX0T3gATmI=@smp11.popopx.im"
internal const val SMP12_URI = "smp://1c3DuHoFOV8gyzTi4vm6szSWL3mgdUc1RD8uZPBLYyQ=@smp12.popopx.im"
internal const val SMP13_URI = "smp://1c3DuHoFOV8gyzTi4vm6szSWL3mgdUc1RD8uZPBLYyQ=@smp13.popopx.im"

internal const val FULL_BODY_HASH = "06a413cfe750c6e2"
internal const val FULL_ACK = "::popopx_sys::SERVER_CFG_ACK::7::$FULL_BODY_HASH"

// MARK: - Test doubles

/** A settings bag that touches nothing outside the process; see `PopopxEcoFixtures` for why. */
internal fun cfgSettings(): Settings = PropertiesSettings(Properties()) { }

internal fun cfgStore(defaults: Settings = cfgSettings()): PopopxServerConfigStore =
  PopopxServerConfigStore(defaults)

/**
 * A handler whose every outside effect is recorded, and whose two unreachable dependencies are replaced: the
 * decoder trusts the fixture key instead of the pinned root, and the placement answer stands in for the core's
 * `chatParseServer`. Both are the shapes production takes — the key list is the only difference a fixture can
 * legitimately have, and the placement here is what the core returns for a self-hosted address in a table that
 * has no operator.
 */
internal fun cfgHandler(
  store: PopopxServerConfigStore,
  transport: CfgTransportDouble,
  /** Both clocks are pinned so a window's two looks and an install-window timeout are all reachable. */
  now: () -> Long = { NOW },
  keys: List<ByteArray> = FIXTURE_KEYS,
  placement: (String, List<UserOperatorServers>) -> Pair<ServerProtocol, ServerOperator?>? =
    { _, _ -> ServerProtocol.SMP to null },
  log: (String) -> Unit = { },
): PopopxServerConfigSignalHandler =
  PopopxServerConfigSignalHandler(
    store = store,
    transport = transport,
    decode = { text, at -> PopopxServerConfigWire.decodeConfigFrame(text, at, keys) },
    placement = placement,
    now = now,
    wait = { _ -> delay(0) },
    applicationActive = { transport.applicationActive },
    log = log,
  )

/** One row of a server table, in the shape the core returns. */
internal fun cfgUserServer(uri: String, preset: Boolean = false, tested: Boolean? = null): UserServer =
  UserServer(
    remoteHostId = null,
    serverId = null,
    server = uri,
    preset = preset,
    tested = tested,
    enabled = true,
    deleted = false,
  )

/**
 * A table with no operator, which is what `UserOperatorServers.operator` being nullable allows and what the
 * merge rule needs: `mergedServers` places a row in the group whose operator id matches the parsed one, and a
 * null operator is the group a self-hosted address lands in.
 */
internal fun cfgTable(vararg smpUris: String): List<UserOperatorServers> =
  listOf(
    UserOperatorServers(
      operator = null,
      smpServers = smpUris.map { cfgUserServer(it) },
      xftpServers = emptyList(),
    )
  )

/** A session row, since `judge` reads the counters rather than the wrapper. */
internal fun cfgSummary(server: String, connected: Int = 0, errors: Int = 0): SMPServerSummary =
  SMPServerSummary(
    smpServer = server,
    known = true,
    sessions = ServerSessions(ssConnected = connected, ssErrors = errors, ssConnecting = 0),
  )

/**
 * Every effect the handler is allowed to have, recorded instead of performed.
 *
 * The knobs are per-test rather than a scripted program because the interesting assertions are all of the form
 * "given this answer, nothing else happened": a refused snapshot write, a rejected replacement, a silent receipt.
 */
internal class CfgTransportDouble(
  var userId: Long? = 1L,
  var table: List<UserOperatorServers> = cfgTable("smp://aaaa@legacy.popopx.im"),
  var validationErrors: Int = 0,
  var replaces: Boolean = true,
  var resetsStats: Boolean = true,
  var sends: Boolean = true,
  var deletes: Boolean = true,
  var silences: Boolean = true,
  var rows: List<SMPServerSummary> = emptyList(),
  /** Null is "the test did not run", which is a different answer from "it failed". */
  var directTest: Boolean? = null,
  var applicationActive: Boolean = true,
  var joins: List<PopopxOfficialJoinOutcome> = emptyList(),
) : PopopxServerConfigTransport {
  val replacedTables = mutableListOf<List<UserOperatorServers>>()
  val sentTexts = mutableListOf<String>()
  val deletedRows = mutableListOf<Triple<ChatType, Long, Long>>()
  val silencedChats = mutableListOf<Pair<ChatType, Long>>()
  val joinedURIs = mutableListOf<String>()
  var serverTableReads = 0
  var statsResets = 0

  /** Only used by the address-building tests; the URI grammar is what is under test, not the core's parser. */
  var acceptServerUri: (String) -> Boolean = { uri ->
    uri.startsWith("${ServerProtocol.SMP.name.lowercase()}://") && uri.contains("@") && uri.length > 12
  }

  override suspend fun signedInUserId(): Long? = userId

  override suspend fun serverTable(): List<UserOperatorServers>? {
    serverTableReads += 1
    return table
  }

  override suspend fun replaceTable(servers: List<UserOperatorServers>): Boolean {
    replacedTables.add(servers)
    if (replaces) table = servers
    return replaces
  }

  override suspend fun validationErrorCount(servers: List<UserOperatorServers>): Int = validationErrors

  override suspend fun resetSessionStats(): Boolean {
    if (resetsStats) statsResets += 1
    return resetsStats
  }

  override suspend fun serverRows(): List<SMPServerSummary> = rows

  override suspend fun directTest(uri: String): Boolean? = directTest

  override fun acceptsServerUri(uri: String): Boolean = acceptServerUri(uri)

  override suspend fun sendText(chatType: ChatType, chatApiId: Long, text: String): Boolean {
    if (sends) sentTexts.add(text)
    return sends
  }

  override suspend fun deleteRow(chatType: ChatType, chatApiId: Long, itemId: Long): Boolean {
    if (deletes) deletedRows.add(Triple(chatType, chatApiId, itemId))
    return deletes
  }

  override suspend fun silenceChat(chatType: ChatType, chatApiId: Long): Boolean {
    // Recorded whatever the answer is, so a test can tell "never attempted" from "attempted and refused" — the
    // distinction the seeding rule depends on.
    silencedChats.add(chatType to chatApiId)
    return silences
  }

  override suspend fun joinOfficial(uri: String): PopopxOfficialJoin? {
    joinedURIs.add(uri)
    val outcome = joins.firstOrNull { it.uri == uri } ?: return null
    return PopopxOfficialJoin(outcome.chatType, outcome.chatApiId)
  }
}

/** What the transport answers for one official address. */
internal class PopopxOfficialJoinOutcome(val uri: String, val chatType: ChatType, val chatApiId: Long)

/**
 * Both conversations the seeding flow asks for: the channel is a group link (`/g#`) and the service account is a
 * direct one (`/a#`), which is the distinction that decides whether a receipt is ever owed.
 */
internal fun cfgJoin(channelApiId: Long = 11L, botApiId: Long = 12L): List<PopopxOfficialJoinOutcome> = listOf(
  PopopxOfficialJoinOutcome(PopopxOfficialConfigLinks.CHANNEL_URI, ChatType.Group, channelApiId),
  PopopxOfficialJoinOutcome(PopopxOfficialConfigLinks.BOT_URI, ChatType.Direct, botApiId),
)
