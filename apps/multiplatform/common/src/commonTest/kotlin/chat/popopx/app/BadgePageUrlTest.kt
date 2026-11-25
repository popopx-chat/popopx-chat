package com.popopxchat.popopx

import chat.popopx.common.views.badges.badgePageUrl
import kotlin.test.Test
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
}
