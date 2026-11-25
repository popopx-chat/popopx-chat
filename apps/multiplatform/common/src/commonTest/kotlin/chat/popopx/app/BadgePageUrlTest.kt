package com.popopxchat.popopx

import chat.popopx.common.views.badges.ANDROID_FOSS_PAYMENT_URL
import chat.popopx.common.views.badges.androidFossPaymentLane
import chat.popopx.common.views.badges.badgePageUrl
import chat.popopx.common.views.badges.badgePaymentUrl
import chat.popopx.common.views.badges.badgeSiteUrl
import chat.popopx.common.views.badges.fossPaymentIsCheckout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BadgePageUrlTest {
  // The flag has to be a query parameter: a fragment is never sent to the host, so a page that ends in
  // `#/tier?app=…` cannot read which installation asked for it.
  @Test
  fun pageEndsWithALinkBackWhenTheLinkReturnsToTheApp() {
    val url = badgePageUrl(linkReturns = true)
    assertTrue(url.endsWith("?app=true") && !url.contains("#"), "url: $url")
  }

  @Test
  fun pageEndsWithACodeToPasteWhenNoLinkReturns() {
    val url = badgePageUrl(linkReturns = false)
    assertTrue(url.endsWith("?app=desktop") && !url.contains("#"), "url: $url")
  }

  // The foss exit is one configured address, so it carries no app flag and reads the same either way.

  @Test
  fun fossExitIsTheConfiguredAddressAndCarriesNoFragment() {
    val url = badgePaymentUrl(linkReturns = true, androidFoss = true)
    assertEquals(ANDROID_FOSS_PAYMENT_URL, url)
    assertEquals(url, badgePaymentUrl(linkReturns = false, androidFoss = true))
    assertTrue(!url.contains("#"), "url: $url")
  }

  // Written to hold both now and once the address is swapped for the bot, which is what the flag is for.
  @Test
  fun fossExitCountsAsACheckoutOnlyOnceItLeavesTheSitePage() {
    assertEquals(fossPaymentIsCheckout(), badgePaymentUrl(true, androidFoss = true) != badgeSiteUrl)
  }

  // This target is desktop, so it stands for every build without Play Billing on Android: it must never
  // take the foss lane, and therefore keeps the flagged site page. iOS is not in this suite at all — it
  // opens apps/ios/Shared/Views/Badges/BadgeStore.swift, whose badgePageUrl is a separate literal.
  @Test
  fun desktopNeverTakesTheFossPaymentLane() {
    assertFalse(androidFossPaymentLane())
    assertEquals(badgePageUrl(linkReturns = false), badgePaymentUrl(linkReturns = false))
  }
}
