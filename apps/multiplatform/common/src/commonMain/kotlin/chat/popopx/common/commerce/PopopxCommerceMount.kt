package chat.popopx.common.commerce

import chat.popopx.common.discover.PopopxSubscriptionEngine
import chat.popopx.common.eco.PopopxChannelKeyRotation
import chat.popopx.common.eco.PopopxEcoRuntime

/**
 * The one place the ledger is handed to the packages that ask for money.
 *
 * Neither eco nor discover imports this module — each declares a seam instead ([PopopxEcoRuntime.credits],
 * [PopopxSubscriptionEngine.ledger], the two hooks on [PopopxChannelKeyRotation]) and every one of them defaults to
 * "no wallet", which is the honest behaviour of a build that never installed one: a card button answers LEDGER and
 * a Discover renewal answers unpaid. iOS reaches `PopopxCreditsManager.shared` from all four sites directly; the
 * seams exist so the three packages can be compiled and tested without each other, and this function is where that
 * indirection collapses back into one object.
 *
 * Called once, from the app entry, after the platform context exists — every singleton touched here reads the
 * platform settings at construction, and a keystore without a context is an exception during `Application.onCreate`.
 * Desktop never calls it, so the desktop app keeps its pre-port behaviour of running no service-account ecosystem
 * at all, which is what its 376 snapshot baselines were taken against.
 */
fun popopxInstallCommerceLedger(manager: PopopxCreditsManager = PopopxCreditsManager.shared) {
  PopopxEcoRuntime.credits = manager
  PopopxSubscriptionEngine.shared.ledger = manager.discoverLedger()
  // The channel handover asks the same two questions the subscription sheet asks, and must get the same answers the
  // ledger gave when the ticket was written (`PopopxChannelKeyRotation.kt:119-127`).
  PopopxChannelKeyRotation.shared.channelIssuerConflict = { channelId, issuer -> manager.channelIssuerConflict(channelId, issuer) }
  PopopxChannelKeyRotation.shared.channelTicketExists = { channelId -> manager.validTicket(channelId) != null }
}
