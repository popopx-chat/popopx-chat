package chat.popopx.common.eco

import chat.popopx.common.model.ChatType
import chat.popopx.common.platform.appPlatform
import chat.popopx.common.signal.PopopxRenderSuppression
import chat.popopx.common.signal.PopopxSignalChatKind
import chat.popopx.common.signal.PopopxSilentSignalingRouter
import chat.popopx.common.signal.popopxSysSignalSuppression
import chat.popopx.common.views.chatlist.openDirectChat
import chat.popopx.common.views.helpers.ModalManager
import chat.popopx.common.views.helpers.withBGApi
import chat.popopx.common.views.newchat.planAndConnect

// The host side of the two machine-line routers: the singletons, the inbound mount, and the link mount.
// Everything above this file is platform-free arithmetic; everything here touches ChatModel, SMP and the
// navigation stack, which is why it is a seam rather than part of the router.
//
// Mounted only on Android. Desktop has never had the service-account ecosystem, and the desktop app's
// behaviour — and therefore its 376 snapshot baselines — must not move as a side effect of this port.

/**
 * The one instance of each router. Both hold mutable state that is wrong if duplicated: the eco router owns
 * the single pending deep-link intent, the single spent H5 signature and the single credit-top-up prompt, and
 * the signalling router owns the initiation rows an ACK is matched against.
 */
object PopopxEcoRuntime {
  /**
   * The wallet, installed by the commerce layer when its encrypted ledger exists. Read per payment rather
   * than captured, because this object is built on first use, which can be before the ledger has been
   * created; a payment with no ledger fails as `LEDGER`, which is the truthful message when the wallet is
   * genuinely absent.
   */
  var credits: PopopxCreditSource? = null

  val router: PopopxEcoRouter by lazy {
    PopopxEcoRouter(sender = PopopxEcoHostSender(), creditsSource = { credits })
  }

  /**
   * Delegated to [PopopxSilentSignalingRouter.shared] rather than constructed here: the same router must serve
   * the inbound mount below and the commerce cards' `outcomesByVoucher` read, or a card would watch an empty
   * table while the ACK settled in another instance.
   */
  val signaling: PopopxSilentSignalingRouter get() = PopopxSilentSignalingRouter.shared
}

/**
 * Mount point of both machine-line protocols on one received line, hung beside each other exactly as iOS
 * hangs them in the same block (POPOPXAPI.swift:2775-2796): one site owns the text read and the hop onto the
 * serialized dispatcher, so the two routers cannot disagree about the order they saw the same message in.
 * They answer different markers, so a given line is handled by at most one of them.
 *
 * The third observer iOS has here — the signed server-cluster update — is deliberately not mounted: those
 * chats are hidden from the interface on iOS as of 2026-11-24, and Android has no receiving UI for them.
 */
fun popopxEcoObserveIncoming(chatType: ChatType, chatId: Long, itemId: Long, memberId: Long?, text: String) {
  if (!appPlatform.isAndroid) return
  val kind = when (chatType) {
    ChatType.Direct -> PopopxSignalChatKind.DIRECT
    ChatType.Group -> PopopxSignalChatKind.GROUP
    else -> PopopxSignalChatKind.OTHER
  }
  withBGApi {
    PopopxEcoRuntime.signaling.observeIncoming(kind, chatId, itemId, text, memberId)
    PopopxEcoRuntime.router.observeIncoming(chatType, chatId, itemId, text)
  }
}

/**
 * The one suppression criterion the three render sites consult — the conversation row, the chat-list preview
 * and the notification banner — composed exactly as iOS composes it (`PopopxSysMarker.isSignalText`,
 * PopopxBadgeCreditsModels.swift:1201-1204): this package's signalling marker, the eco control frame, and the
 * eco uplink lines. One site carrying all terms is the only shape that cannot drift, which is why the UI
 * never asks the two packages separately.
 *
 * iOS ORs a fourth term, the signed server-cluster frame; it is not ported because Android has no receiver
 * for it and the frame is not sent from this app.
 */
private val popopxEcoSuppression: PopopxRenderSuppression = popopxSysSignalSuppression {
  PopopxEcoMarker.isControlText(it) || PopopxEcoUplink.isUplinkText(it)
}

/**
 * Whether a line must never be drawn. Android only: the desktop app has never run the service-account
 * ecosystem, and hiding a peer's machine line there would be a behaviour change this port did not earn.
 */
fun popopxEcoSuppressesText(text: String?): Boolean =
  appPlatform.isAndroid && text != null && popopxEcoSuppression.suppresses(text)

/**
 * The app's eco deep-link entry, for both `popopx://service?uri=…&ref=…` and `popopx://sso?uri=…&session=…`.
 * Returns true when this module took the link, so the caller stops its own connection handling: an eco link
 * is a `popopx:`-scheme URI, which the app otherwise hands straight to `planAndConnect` as a plain connection
 * address — that would connect to the service account and silently discard the payload the scan carried.
 *
 * Synchronous for the same reason iOS's `handle(text:)` is: the intent is recorded before the connection
 * starts, so a connection that reports its contact synchronously cannot miss it.
 */
fun popopxEcoOpenLink(rhId: Long?, text: String): Boolean {
  if (!appPlatform.isAndroid) return false
  val handler = PopopxEcoDeepLinkHandler(
    router = PopopxEcoRuntime.router,
    connect = { serviceURI, onCleanup, onKnownContact ->
      withBGApi {
        planAndConnect(
          rhId,
          serviceURI,
          close = { ModalManager.closeAllModalsEverywhere() },
          // `cleanup` fires on cancel, on a refused link AND after a chat opened; only
          // `discardPendingIntentIfConnectionAborted` can tell those apart, because it consults
          // `ConnectProgressManager.isInProgress`, which the plain `cleanup` timer cannot see.
          cleanup = onCleanup,
          filterKnownContact = { contact -> withBGApi { onKnownContact(contact.contactId) } },
        )
      }
    },
    openKnownChat = { contactId -> openDirectChat(rhId, contactId) },
  )
  return handler.handle(text)
}
