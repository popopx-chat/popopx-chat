package chat.popopx.app.signal

import chat.popopx.common.signal.PopopxSignalDisposition
import chat.popopx.common.signal.PopopxSignalInbound
import chat.popopx.common.signal.PopopxSignalInvite
import chat.popopx.common.signal.PopopxSignalKind
import chat.popopx.common.signal.PopopxSignalPayloadGate
import chat.popopx.common.signal.PopopxSilentDeleteMode
import chat.popopx.common.signal.PopopxSilentTransport
import chat.popopx.common.signal.PopopxSysMarker
import com.russhwolf.settings.PropertiesSettings
import com.russhwolf.settings.Settings
import java.util.Properties

// Shared fixtures for the silent-signalling tests.
//
// `PropertiesSettings(Properties()) { }` and not the app's own `settings`, for the reason recorded in
// `../eco/PopopxEcoFixtures.kt`: the desktop actual flushes to ~/Library/Preferences on every put,
// so a test that touched it would edit the developer's real preferences.

internal fun signalSettings(): Settings = PropertiesSettings(Properties()) { }

/** The wire spelled out here rather than via the codec, so the codec's output is a tested claim. */
internal fun signalWire(kind: PopopxSignalKind, payload: String): String =
  PopopxSysMarker.MARKER + kind.raw + PopopxSysMarker.BODY_SEPARATOR + payload

/** Records every host call the router makes, and answers with switches the test sets. */
internal class RecordingTransport(
  var delivers: Boolean = true,
  var deletesOk: Boolean = true,
  var invite: PopopxSignalInvite? = PopopxSignalInvite("popopx://invite/one-time-link", 88L),
  var connectionId: Long? = 88L,
) : PopopxSilentTransport {
  data class Sent(val chatId: Long, val isGroup: Boolean, val text: String, val live: Boolean, val ttlSeconds: Int?)
  data class Deleted(val chatId: Long, val itemIds: List<Long>, val mode: PopopxSilentDeleteMode)
  data class ContactDeleted(val contactId: Long, val notifyPeer: Boolean)
  data class Connected(val incognito: Boolean, val connFullLink: String)

  val sent = mutableListOf<Sent>()
  val deleted = mutableListOf<Deleted>()
  val contactsDeleted = mutableListOf<ContactDeleted>()
  val connected = mutableListOf<Connected>()
  val addContactIncognito = mutableListOf<Boolean>()

  override suspend fun send(chatId: Long, isGroup: Boolean, text: String, live: Boolean, ttlSeconds: Int?): Boolean {
    sent += Sent(chatId, isGroup, text, live, ttlSeconds)
    return delivers
  }

  override suspend fun delete(chatId: Long, itemIds: List<Long>, mode: PopopxSilentDeleteMode): Boolean {
    deleted += Deleted(chatId, itemIds, mode)
    return deletesOk
  }

  override suspend fun addContact(incognito: Boolean): PopopxSignalInvite? {
    addContactIncognito += incognito
    return invite
  }

  override suspend fun connect(incognito: Boolean, connFullLink: String): Long? {
    connected += Connected(incognito, connFullLink)
    return connectionId
  }

  override suspend fun deleteContact(contactId: Long, notifyPeer: Boolean): Boolean {
    contactsDeleted += ContactDeleted(contactId, notifyPeer)
    return true
  }
}

/** A payload gate whose dispositions the test scripts, keeping every inbound it was shown. */
internal class ScriptedGate(
  var disposition: (PopopxSignalInbound) -> PopopxSignalDisposition = { PopopxSignalDisposition.DeleteRow },
) : PopopxSignalPayloadGate {
  val inbounds = mutableListOf<PopopxSignalInbound>()

  override fun consume(inbound: PopopxSignalInbound): PopopxSignalDisposition {
    inbounds += inbound
    return disposition(inbound)
  }
}
