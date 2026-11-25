package chat.popopx.app.eco

import chat.popopx.common.crypto.base64UrlEncode
import chat.popopx.common.eco.PopopxEcoAction
import chat.popopx.common.eco.PopopxEcoApplyOutcome
import chat.popopx.common.eco.PopopxEcoFrame
import chat.popopx.common.eco.PopopxEcoKeychain
import chat.popopx.common.eco.PopopxEcoKeys
import chat.popopx.common.eco.PopopxEcoLimits
import chat.popopx.common.eco.PopopxEcoMenu
import chat.popopx.common.eco.PopopxChannelKeyRotation
import chat.popopx.common.eco.PopopxEcoMarker
import chat.popopx.common.eco.PopopxEcoSecrets
import chat.popopx.common.eco.PopopxEcoSession
import chat.popopx.common.eco.PopopxEcoSessionStore
import chat.popopx.common.eco.PopopxEcoStore
import chat.popopx.common.eco.PopopxEcoUplink
import chat.popopx.common.eco.PopopxChannelPublicURI
import chat.popopx.common.eco.PopopxServiceCard
import chat.popopx.common.eco.ecoTokens
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// The parser and the store, rule by rule, against PopopxEcoModels.swift / PopopxEcoRouterAndDeepLink.swift.
// Every case here is a frame a server could actually send, because the discards are the security model: a
// half-accepted menu or card is a button the user tapped without anyone validating it.

private const val LINK_RELAY = "smp1.popopx.test"

private fun menuFrame(items: List<String>, rev: Int? = null): String {
  val revision = if (rev == null) "" else ""","rev":$rev"""
  return """{"t":"mc","menu":{"items":[${items.joinToString(",")}]$revision}}"""
}

private fun item(
  title: String,
  kind: String? = null,
  action: String? = null,
  payload: String? = null,
  url: String? = null,
  sub: List<String> = emptyList(),
): String {
  val parts = ArrayList<String>()
  parts.add(""""title":"$title"""")
  if (kind != null) parts.add(""""kind":"$kind"""")
  if (action != null) parts.add(""""action":"$action"""")
  if (payload != null) parts.add(""""payload":"$payload"""")
  if (url != null) parts.add(""""url":"$url"""")
  parts.add(""""sub":[${sub.joinToString(",")}]""")
  return "{" + parts.joinToString(",") + "}"
}

private val clickable = item("Buy", action = "callback", payload = "buy")
private val linkable = item("Site", kind = "view", url = "https://eco.test/x")

private fun cardFrame(
  id: String = "card.1",
  style: String = "standard",
  title: String = "Title",
  body: String? = null,
  fields: List<String>? = null,
  progress: String? = null,
  actions: List<String>? = null,
  ut: Long = 1000L,
  et: Long? = null,
  mode: String = "c",
): String {
  val parts = ArrayList<String>()
  parts.add(""""id":"$id"""")
  parts.add(""""v":"$style"""")
  parts.add(""""title":"$title"""")
  if (body != null) parts.add(""""body":"$body"""")
  if (fields != null) parts.add(""""fields":[${fields.joinToString(",")}]""")
  if (progress != null) parts.add(""""progress":$progress""")
  if (actions != null) parts.add(""""actions":[${actions.joinToString(",")}]""")
  parts.add(""""ut":$ut""")
  if (et != null) parts.add(""""et":$et""")
  return """{"t":"sc","m":"$mode","card":{${parts.joinToString(",")}}}"""
}

private fun action(id: String, kind: String = "callback", payload: String? = "go", title: String = "Go"): String {
  val parts = ArrayList<String>()
  parts.add(""""id":"$id"""")
  parts.add(""""title":"$title"""")
  parts.add(""""m":"$kind"""")
  if (payload != null) parts.add(""""payload":"$payload"""")
  return "{" + parts.joinToString(",") + "}"
}

private fun field(label: String, value: String): String = """{"k":"$label","v":"$value"}"""

class PopopxEcoProtocolTest {
  private fun decode(text: String): PopopxEcoFrame? = PopopxEcoMarker.parseControlText(ecoFrameText(text))

  // MARK: - The two entry points

  @Test
  fun aControlFrameIsRecognisedOnlyWhenTheWholeTextIsOneFrame() {
    assertNotNull(decode(cardFrame()))
    // A frame inside a longer message returns null *by design*: it would decode fine as JSON and silently
    // execute while the user reads their own sentence.
    assertNull(PopopxEcoMarker.parseControlText(ecoFrameText(cardFrame()) + " delivered"))
    assertNull(PopopxEcoMarker.parseControlText("look: " + ecoFrameText(cardFrame())))
    assertNull(PopopxEcoMarker.parseControlText(ecoFrameText(cardFrame()) + "\ntrailing"))
    assertFalse(PopopxEcoMarker.isControlText("hello"))
  }

  @Test
  fun aVisibleCardIsScannedFromTheEndAndOnlyACreateCardSurvives() {
    val json = cardFrame(title = "Order9")
    val card = PopopxEcoMarker.parseVisibleCard("Your order is confirmed " + ecoFrameText(json))
    assertNotNull(card)
    assertEquals("Order9", card.title)
    // The scan splits on whitespace, which is iOS's rule too (PopopxEcoModels.swift:124-133), and it has a
    // consequence worth naming: a card whose own text contains a space cannot be recovered from a mixed
    // message. A card sent alone still works, because the control path reads the whole string.
    assertNull(PopopxEcoMarker.parseVisibleCard("note " + ecoFrameText(cardFrame(title = "Two Words"))))
    assertNotNull(PopopxEcoMarker.parseControlText(ecoFrameText(cardFrame(title = "Two Words"))))
    assertEquals(PopopxServiceCard.Mode.CREATE, card.mode)
    // An update mutates a card that is already on screen; on its own it is nothing to render.
    assertNull(PopopxEcoMarker.parseVisibleCard("status " + ecoFrameText(cardFrame(mode = "u"))))
    // The last candidate wins, which is why a place name shaped like a payload cannot take the frame's place.
    val two = ecoFrameText(cardFrame(id = "first")) + " " + ecoFrameText(cardFrame(id = "second"))
    assertEquals("second", PopopxEcoMarker.parseVisibleCard(two)?.cardId)
  }

  @Test
  fun everyFrameButAVisibleCardIsSuppressedInUi() {
    assertTrue(PopopxEcoMarker.isControlText(ecoFrameText("""{"t":"sh","uid":"u","sec":"00"}""")))
    assertTrue(PopopxEcoMarker.isControlText(ecoFrameText(menuFrame(listOf(clickable)))))
    assertTrue(PopopxEcoMarker.isControlText(ecoFrameText(cardFrame(mode = "u"))))
    assertFalse(PopopxEcoMarker.isControlText(ecoFrameText(cardFrame())))
  }

  @Test
  fun aFrameOverTheCharacterCapIsDroppedWhole() {
    val body = "x".repeat(PopopxEcoLimits.MAXIMUM_FRAME_CHARACTERS)
    assertNull(decode(cardFrame(id = body, title = body)))
    assertNotNull(decode(cardFrame()))
  }

  @Test
  fun anUnknownTypeOrAMissingPayloadSectionDecodesToNothing() {
    assertNull(decode("""{"t":"zz","card":{}}"""))
    assertNull(decode("""{"t":"sc","m":"c"}"""))
    assertNull(decode("""{"t":"sc","m":"x","card":{"id":"a","v":"standard","title":"t","ut":1}}"""))
    assertNull(decode("""{"t":"mc"}"""))
    assertNull(decode("""not json"""))
    assertNull(decode("""[1,2]"""))
  }

  @Test
  fun aFrameSurvivesARoundTripThroughItsOwnWireForm() {
    val decoded = decode(cardFrame(fields = listOf(field("a", "b")), actions = listOf(action("x")), ut = 4242L, et = 9000L))
    assertNotNull(decoded)
    val again = PopopxEcoMarker.parseControlText(PopopxEcoMarker.wireString(decoded))
    assertEquals(decoded, again)
  }

  // MARK: - The menu, where every violation is a whole-menu discard

  private fun menu(items: List<String>, rev: Int? = null): PopopxEcoMenu? =
    (decode(menuFrame(items, rev)) as? PopopxEcoFrame.MenuConfig)?.menu

  @Test
  fun aFourthTopLevelItemDiscardsTheWholeMenu() {
    assertNull(menu(List(PopopxEcoLimits.MAXIMUM_MENU_ITEMS + 1) { item("b$it", action = "callback", payload = "p$it") }))
    assertEquals(3, menu(List(3) { item("b$it", action = "callback", payload = "p$it") })?.items?.size)
  }

  @Test
  fun aSixthSubItemDiscardsTheWholeMenuRatherThanRenderingFiveOfSix() {
    val over = List(PopopxEcoLimits.MAXIMUM_SUB_ITEMS + 1) { item("s$it", action = "callback", payload = "p$it") }
    assertNull(menu(listOf(item("More", action = "callback", payload = "m", sub = over))))
    val five = List(5) { item("s$it", action = "callback", payload = "p$it") }
    assertEquals(5, menu(listOf(item("More", action = "callback", payload = "m", sub = five)))?.items?.first()?.subItems?.size)
    // A submenu parent is still a button: iOS requires its own action even when its children are the point,
    // so a bare expander discards the menu rather than rendering a control that cannot fire.
    assertNull(menu(listOf(item("More", sub = five))))
  }

  /**
   * A `view` button is a link; children under it could never be reached, so the server that sent them has a
   * different menu in mind than the one that could be drawn. Half a menu is worse than none.
   */
  @Test
  fun aViewButtonCarryingSubItemsOrMissingItsUrlDiscardsTheWholeMenu() {
    assertNull(menu(listOf(item("Site", kind = "view", url = "https://eco.test/x", sub = listOf(clickable)))))
    assertNull(menu(listOf(item("Site", kind = "view"))))
    assertNotNull(menu(listOf(linkable)))
  }

  @Test
  fun aClickButtonWithoutAValidActionDiscardsTheWholeMenu() {
    assertNull(menu(listOf(item("Nothing"))))
    assertNull(menu(listOf(item("Opens", action = "open_url"))))
    assertNull(menu(listOf(item("Sends", action = "send_cmd"))))
    assertNotNull(menu(listOf(clickable)))
    // `scancode` and `location` carry no action at all, and are the two kinds that must NOT have one.
    assertNotNull(menu(listOf(item("Scan", kind = "scancode"))))
    assertNull(menu(listOf(item("Scan", kind = "scancode", action = "callback", payload = "p"))))
  }

  @Test
  fun aDuplicatedTopLevelTitleDiscardsTheWholeMenuBecauseTitlesAreTheIds() {
    assertNull(menu(listOf(clickable, clickable)))
    assertNotNull(menu(listOf(clickable, item("Other", action = "callback", payload = "p"))))
  }

  @Test
  fun anUnknownKindOrActionWordDiscardsTheWholeMenu() {
    assertNull(menu(listOf(item("x", kind = "teleport"))))
    assertNull(menu(listOf(item("x", action = "teleport", payload = "p"))))
  }

  @Test
  fun anEmptyMenuOrAnOverlongLabelDiscardsIt() {
    assertNull(menu(emptyList()))
    assertNull(menu(listOf(item("t".repeat(PopopxEcoLimits.MAXIMUM_LABEL_CHARACTERS + 1), action = "callback", payload = "p"))))
  }

  /** Third level: iOS does not validate sub-items recursively, so they ride along and the menu bar ignores them. */
  @Test
  fun aThirdLevelItemIsKeptInDataBecauseTheMenuBarOnlyRendersTwoLevels() {
    val deep = menu(listOf(item("More", action = "callback", payload = "m", sub = listOf(item("Nested", action = "callback", payload = "p", sub = listOf(clickable))))))
    assertNotNull(deep)
    assertEquals(1, deep.items.first().subItems.first().subItems.size)
  }

  // MARK: - The store

  @Test
  fun menuConflictIsDecidedByRevisionAloneAndOnlyWhenBothSidesCarryOne() {
    val store = PopopxEcoStore(ecoSettings(), PopopxChannelKeyRotation())
    val contact = 5L
    assertEquals(PopopxEcoApplyOutcome.STORED_MENU, store.apply(decode(menuFrame(listOf(clickable), rev = 5))!!, contact))
    assertEquals(PopopxEcoApplyOutcome.IGNORED_STALE, store.apply(decode(menuFrame(listOf(linkable), rev = 4))!!, contact))
    assertEquals(PopopxEcoApplyOutcome.STORED_MENU, store.apply(decode(menuFrame(listOf(linkable), rev = 6))!!, contact))
    assertEquals("Site", store.liveMenu(contact)!!.items.first().title)
    // An absent revision is not zero: unversioned replaces, and it does not poison the next comparison.
    assertEquals(PopopxEcoApplyOutcome.STORED_MENU, store.apply(decode(menuFrame(listOf(clickable)))!!, contact))
    assertEquals("Buy", store.liveMenu(contact)!!.items.first().title)
  }

  /** Menus are keyed by `ChatInfo.apiId`, a row number in this device's database, so they are never restored. */
  @Test
  fun menusAreLiveOnlyAndNeverRestoredFromDisk() {
    val defaults = ecoSettings()
    val store = PopopxEcoStore(defaults, PopopxChannelKeyRotation())
    store.apply(decode(menuFrame(listOf(clickable)))!!, 11L)
    assertNotNull(store.liveMenu(11L))
    val reloaded = PopopxEcoStore(defaults, PopopxChannelKeyRotation())
    assertNull(reloaded.liveMenu(11L))
    // …while a card, keyed by a server-minted id, does come back.
    store.apply(decode(cardFrame(id = "persist.me"))!!, 11L)
    assertEquals("persist.me", PopopxEcoStore(defaults, PopopxChannelKeyRotation()).card("persist.me")?.cardId)
  }

  @Test
  fun aCorruptStoredCardDoesNotStopTheRestOfTheListLoading() {
    val defaults = ecoSettings()
    val store = PopopxEcoStore(defaults, PopopxChannelKeyRotation())
    store.apply(decode(cardFrame(id = "good"))!!, 1L)
    defaults.putString(PopopxEcoKeys.CARDS, "[{\"id\":\"broken\"},{\"id\":\"good\",\"v\":\"standard\",\"title\":\"T\",\"ut\":5}]")
    val reloaded = PopopxEcoStore(defaults, PopopxChannelKeyRotation())
    assertEquals(listOf("good"), reloaded.storedCards.map { it.cardId })
    defaults.putString(PopopxEcoKeys.CARDS, "not json at all")
    assertEquals(emptyList(), PopopxEcoStore(defaults, PopopxChannelKeyRotation()).storedCards)
  }

  @Test
  fun mergeLeavesAbsentSectionsAloneAndTakesTheOnesThatArrive() {
    val store = PopopxEcoStore(ecoSettings(), PopopxChannelKeyRotation())
    store.apply(
      decode(
        cardFrame(
          body = "paid 3 credits",
          fields = listOf(field("order", "A1")),
          progress = """{"l":"ship","p":10,"d":"soon"}""",
          actions = listOf(action("x")),
          ut = 1000L,
          et = 9000L,
        ),
      )!!,
      1L,
    )
    // A frame carrying only progress must not wipe the title, the rows or the buttons.
    val patched = decode(cardFrame(style = "receipt", progress = """{"l":"ship","p":80}""", ut = 1100L, mode = "u"))!!
    assertEquals(PopopxEcoApplyOutcome.UPDATED_CARD, store.apply(patched, 1L))
    val card = store.card("card.1")!!
    assertEquals("Title", card.title)
    assertEquals("paid 3 credits", card.body)
    assertEquals(listOf("order"), card.fields.map { it.label })
    assertEquals(listOf("x"), card.actions.map { it.id })
    assertEquals(80, card.progress?.percent)
    assertEquals("ship", card.progress?.label)
    assertNull(card.progress?.detail)
    assertEquals(9000L, card.expiresAtMs)
    assertEquals(PopopxServiceCard.Style.RECEIPT, card.style)
    assertEquals(1100L, card.updatedAtMs)
    // An update never stays an update: whatever renders the stored card must not re-send a confirmation.
    assertEquals(PopopxServiceCard.Mode.CREATE, card.mode)
    // An empty string clears the body; an absent one leaves it. Both are distinguishable on the wire.
    store.apply(decode(cardFrame(body = "", ut = 1200L, mode = "u"))!!, 1L)
    assertEquals("", store.card("card.1")!!.body)
  }

  /** The two operators are the answer to two different questions, so the tie is decided differently on each side. */
  @Test
  fun writeRefusesAnOlderFrameWhileReadPrefersTheStoredCardOnATie() {
    val store = PopopxEcoStore(ecoSettings(), PopopxChannelKeyRotation())
    store.apply(decode(cardFrame(title = "New", ut = 2000L))!!, 1L)
    assertEquals(PopopxEcoApplyOutcome.IGNORED_STALE, store.apply(decode(cardFrame(title = "Old", ut = 1000L, mode = "u"))!!, 1L))
    assertEquals("New", store.card("card.1")!!.title)
    // Equal timestamps: the incoming frame wins on the write.
    assertEquals(PopopxEcoApplyOutcome.UPDATED_CARD, store.apply(decode(cardFrame(title = "Tie", ut = 2000L, mode = "u"))!!, 1L))
    assertEquals("Tie", store.card("card.1")!!.title)
    // …and a bubble built from an OLDER message of the same card is still rendered from what is stored.
    val older = decode(cardFrame(title = "From the message", ut = 500L))!!
    val rendered = store.rendered((older as PopopxEcoFrame.ServiceCard).card)
    assertEquals("Tie", rendered.title)
    // On a tie the stored card wins for reading too, which is the `>=` in `rendered`.
    assertEquals("Tie", store.rendered((decode(cardFrame(title = "Same time", ut = 2000L))!! as PopopxEcoFrame.ServiceCard).card).title)
    // A card the store has never seen renders as itself.
    val unseen = (decode(cardFrame(id = "other", title = "Fresh", ut = 1L))!! as PopopxEcoFrame.ServiceCard).card
    assertEquals("Fresh", store.rendered(unseen).title)
  }

  @Test
  fun anUnsaneCardIsNeverStoredAndEveryLimitThatBreaksItDiscardsTheWholeFrame() {
    val store = PopopxEcoStore(ecoSettings(), PopopxChannelKeyRotation())
    assertNull(decode(cardFrame(title = "")))
    assertNull(decode(cardFrame(ut = 0L)))
    assertNull(decode(cardFrame(et = 0L)))
    assertNull(decode(cardFrame(progress = """{"l":"p","p":101}""")))
    assertNull(decode(cardFrame(progress = """{"l":"p","p":-1}""")))
    assertNull(decode(cardFrame(fields = List(PopopxEcoLimits.MAXIMUM_FIELDS + 1) { field("f$it", "v") })))
    assertNull(decode(cardFrame(actions = List(PopopxEcoLimits.MAXIMUM_ACTIONS + 1) { action("a$it") })))
    assertNull(decode(cardFrame(actions = listOf(action("dup"), action("dup")))))
    assertNull(decode(cardFrame(id = "i".repeat(PopopxEcoLimits.MAXIMUM_CARD_ID_CHARACTERS + 1))))
    assertNull(decode(cardFrame(actions = listOf(action("p", kind = "pay_credits", payload = null)))))
    assertNull(decode(cardFrame(actions = listOf("""{"id":"u","title":"t","m":"open_url","url":"javascript:alert(1)"}"""))))
    assertEquals(emptyList(), store.storedCards)
  }

  @Test
  fun storedCardsAreCappedAtTwoHundredOldestTimestampFirstAndTheMapIsRebuilt() {
    val defaults = ecoSettings()
    val store = PopopxEcoStore(defaults, PopopxChannelKeyRotation())
    for (i in 1..(PopopxEcoLimits.MAXIMUM_STORED_CARDS + 5)) {
      store.apply(decode(cardFrame(id = "c$i", ut = i.toLong()))!!, 1L)
    }
    val stored = store.storedCards
    assertEquals(PopopxEcoLimits.MAXIMUM_STORED_CARDS, stored.size)
    // Newest first for the view, and the six oldest card ids are gone rather than merely hidden.
    assertEquals("c205", stored.first().cardId)
    assertFalse(stored.any { it.cardId == "c1" })
    assertNull(store.card("c1"))
    assertNotNull(store.card("c6"))
    val json = defaults.getStringOrNull(PopopxEcoKeys.CARDS)!!
    assertFalse(json.contains("\"c1\""))
    assertEquals(PopopxEcoLimits.MAXIMUM_STORED_CARDS, PopopxEcoStore(defaults, PopopxChannelKeyRotation()).storedCards.size)
  }

  /** The lockout key joins with U+0001 because both halves are server-supplied and neither is punctuation-free. */
  @Test
  fun theLockoutKeyCannotBeCollidedOntoByPunctuationInEitherHalf() {
    val store = PopopxEcoStore(ecoSettings(), PopopxChannelKeyRotation())
    store.lock("a-", "b")
    assertTrue(store.isActionLocked("a-", "b"))
    assertFalse(store.isActionLocked("a", "-b"))
    store.lock("a", "-b")
    assertTrue(store.isActionLocked("a", "-b"))
  }

  @Test
  fun aCardChangeLiftsOnlyThatCardsLockoutsAndTheSetIsBounded() {
    val store = PopopxEcoStore(ecoSettings(), PopopxChannelKeyRotation())
    store.apply(decode(cardFrame(id = "A"))!!, 1L)
    store.apply(decode(cardFrame(id = "B"))!!, 1L)
    store.lock("A", "pay")
    store.lock("B", "pay")
    store.apply(decode(cardFrame(id = "A", ut = 2000L, mode = "u"))!!, 1L)
    assertFalse(store.isActionLocked("A", "pay"))
    assertTrue(store.isActionLocked("B", "pay"))
    for (i in 1..300) store.lock("bulk", "a$i")
    // Past the ceiling the whole set is dropped rather than growing, so a tap after a wipe can still fire.
    assertFalse(store.isActionLocked("bulk", "a1"))
    store.lock("bulk", "after")
    assertTrue(store.isActionLocked("bulk", "after"))
  }

  // MARK: - Session handshake, and the two halves of storage

  @Test
  fun aHandshakeStoresTheSecretInTheKeystoreAndTheUidBesideIt() {
    val defaults = ecoSettings()
    val store = PopopxEcoStore(defaults, PopopxChannelKeyRotation())
    val json = """{"t":"sh","uid":"popopx1abcdef","sec":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","svc":"svc.9"}"""
    assertEquals(PopopxEcoApplyOutcome.STORED_SESSION, store.apply(decode(json)!!, 3L))
    val session = PopopxEcoSessionStore.session(3L, defaults)
    assertNotNull(session)
    assertEquals("popopx1abcdef", session.pairwiseUid)
    assertEquals("svc.9", session.serviceId)
    assertEquals(32, session.secretBytes?.size)
    // The uid is not a secret and the open_url path needs it without touching the secret.
    assertEquals("popopx1abcdef", defaults.getStringOrNull(PopopxEcoKeys.SESSION_UID_PREFIX + 3L))
    assertTrue(PopopxEcoSecrets.contains(PopopxEcoKeychain.sessionAccount(3L), defaults))
    // The ciphertext slot must not carry the key in the clear.
    assertFalse(defaults.getStringOrNull(PopopxEcoKeys.SESSION_UID_PREFIX + 3L)!!.contains("00112233"))
    assertContentEquals(session.secretBytes, PopopxEcoSecrets.read(PopopxEcoKeychain.sessionAccount(3L), defaults))

    // The anti-theft wipe takes both halves.
    PopopxEcoKeys.wipe(listOf(3L), emptyList(), defaults)
    assertNull(PopopxEcoSessionStore.session(3L, defaults))
    assertFalse(PopopxEcoSecrets.contains(PopopxEcoKeychain.sessionAccount(3L), defaults))
  }

  @Test
  fun aHandshakeWithoutUsableKeyMaterialIsRejectedAndLeavesNothingBehind() {
    val defaults = ecoSettings()
    val store = PopopxEcoStore(defaults, PopopxChannelKeyRotation())
    // An unsane handshake never reaches the store at all: `decode` validates, so the parser is the gate.
    for (sec in listOf("", "zz", "00".repeat(33))) {
      assertNull(decode("""{"t":"sh","uid":"u","sec":"$sec"}"""), sec)
      // The store keeps its own check for a frame built in-process, which is the only way to reach it.
      assertEquals(
        PopopxEcoApplyOutcome.REJECTED,
        store.apply(PopopxEcoFrame.SessionHandshake(PopopxEcoSession("u", sec, null)), 4L),
        sec,
      )
    }
    // 32 bytes is the cap because HMAC truncates rather than rejects, which would mean a key the server does not hold.
    assertNull(PopopxEcoSessionStore.session(4L, defaults))
    assertFalse(PopopxEcoSecrets.contains(PopopxEcoKeychain.sessionAccount(4L), defaults))
    assertNull(decode("""{"t":"sh","uid":"","sec":"00"}"""))
    assertNull(decode("""{"t":"sh","uid":"u"}"""))
  }

  // MARK: - The three uplink lines

  @Test
  fun anUplinkLineRefusesAnythingThatCouldCarryASecondCommand() {
    for (prefix in listOf(PopopxEcoUplink.CALLBACK_PREFIX, PopopxEcoUplink.REFERENCE_PREFIX, PopopxEcoUplink.SSO_SCAN_PREFIX)) {
      assertNotNull(PopopxEcoUplink.wireString(prefix, "order.1"))
      assertNull(PopopxEcoUplink.wireString(prefix, ""))
      assertNull(PopopxEcoUplink.wireString(prefix, "a b"))
      assertNull(PopopxEcoUplink.wireString(prefix, "a::b"))
      assertNull(PopopxEcoUplink.wireString(prefix, "x".repeat(PopopxEcoLimits.MAXIMUM_PAYLOAD_CHARACTERS + 1)))
      assertTrue(PopopxEcoUplink.isUplinkText(prefix + "order.1"))
    }
    assertNull(PopopxEcoUplink.wireString("::FORGED::", "order.1"))
    // A sentence that merely quotes one of these lines is a message the user wrote.
    assertFalse(PopopxEcoUplink.isUplinkText("the server said ${PopopxEcoUplink.CALLBACK_PREFIX} but not really"))
    assertTrue(PopopxEcoUplink.isSendablePayload("x".repeat(PopopxEcoLimits.MAXIMUM_PAYLOAD_CHARACTERS)))
  }

  // MARK: - Links and URLs

  @Test
  fun aChannelLinkNeedsTwoSegmentsAndBothHalvesOfTheKey() {
    val key = base64UrlEncode(ByteArray(32) { (it + 1).toByte() })
    val pub = base64UrlEncode(ByteArray(32) { (it + 90).toByte() })
    val uri = PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/chan.1#key=$key&pub=$pub")
    assertNotNull(uri)
    assertEquals(LINK_RELAY, uri.relay)
    assertEquals("chan.1", uri.channelId)
    // The fragment is never part of the form that may leave the device.
    assertEquals("popopx://channel/$LINK_RELAY/chan.1", uri.connectionUri)
    assertFalse(uri.connectionUri.contains("key="))

    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY#key=$key&pub=$pub"))
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/a/b#key=$key&pub=$pub"))
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/chan.1"))
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/chan.1#key=$key"))
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/chan.1#key=$key&pub=$pub&key=$key"))
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/chan.1#key=$key&pub=$pub&extra=1"))
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/chan.1?key=$key&pub=$pub"))
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/chan%2E1#key=$key&pub=$pub"))
    // A key that is not 32 bytes is a link to nothing, whichever half is short.
    val short = base64UrlEncode(ByteArray(31))
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/chan.1#key=$short&pub=$pub"))
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/chan.1#key=$key&pub=$short"))
  }

  /**
   * MEASURED FINDING, not a preference. iOS's comment on its own segment guard claims a `..` is refused, but
   * the guard is a character set (`alphanumerics` ∪ `-_ .`) and `..` is inside it, so such a link parses —
   * here too. Ported as it is: tightening it would refuse links iOS accepts, and the value is only ever a
   * keystore account suffix, never a path that gets traversed.
   */
  @Test
  fun aDotDotChannelIdParsesBecauseTheGuardIsACharacterSetNotAPathRule() {
    val key = base64UrlEncode(ByteArray(32) { (it + 1).toByte() })
    val pub = base64UrlEncode(ByteArray(32) { (it + 90).toByte() })
    assertEquals("..", PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/..#key=$key&pub=$pub")?.channelId)
    // What the character set DOES refuse is anything outside it: an encoded separator, a colon.
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/a%2Fb#key=$key&pub=$pub"))
    assertNull(PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/a:b#key=$key&pub=$pub"))
  }

  /**
   * Regression for the one port bug the cross-vector gate found: the URL-safe alphabet's own characters.
   * `0xFF 0xFF 0xFF` is `____` in base64url, so a key whose first three bytes are set used to decode to
   * nothing and every rotation for that channel was silently refused.
   */
  @Test
  fun aKeyWrittenWithTheUrlSafeAlphabetsOwnCharactersDecodes() {
    val alphabet = base64UrlEncode(ByteArray(32) { if (it < 3) 0xFF.toByte() else 0x00 })
    assertTrue(alphabet.contains('_'), alphabet)
    assertEquals(32, PopopxChannelPublicURI.parse("popopx://channel/$LINK_RELAY/chan.1#key=$alphabet&pub=$alphabet")?.let { 32 })
    assertContentEquals(ByteArray(32) { if (it < 3) 0xFF.toByte() else 0x00 }, chat.popopx.common.crypto.base64UrlDecode(alphabet))
  }

  /**
   * Regression for the one character-set bug this pass found: the punctuation was silently left out of the
   * allowed set, which rejected every dotted relay and every dotted channel id, i.e. all of them.
   */
  @Test
  fun aDottedOrHyphenatedSegmentIsAnOpaqueIdAndNotAPath() {
    val key = base64UrlEncode(ByteArray(32) { (it + 1).toByte() })
    for (segment in listOf("smp1.popopx.test", "chan-1_2", "x", "SMP9.a-B_c")) {
      assertNotNull(PopopxChannelPublicURI.parse("popopx://channel/$segment/chan.1#key=$key&pub=$key"), segment)
    }
    for (bad in listOf("relay:8443", "relay/x", "relay%2Fx", "re lay", "")) {
      assertNull(PopopxChannelPublicURI.parse("popopx://channel/$bad/chan.1#key=$key&pub=$key"), bad)
    }
  }

  @Test
  fun onlyHttpAndHttpsWithAHostAreOpenableFromACard() {
    assertTrue(PopopxEcoAction.isHttpUrl("https://eco.test/a?b=1#f"))
    assertTrue(PopopxEcoAction.isHttpUrl("http://127.0.0.1:8080"))
    assertFalse(PopopxEcoAction.isHttpUrl("javascript:alert(1)"))
    assertFalse(PopopxEcoAction.isHttpUrl("popopx://channel/x/y"))
    assertFalse(PopopxEcoAction.isHttpUrl("https://"))
    assertFalse(PopopxEcoAction.isHttpUrl("HTTPS ECO TEST"))
    assertFalse(PopopxEcoAction.isHttpUrl("https://eco.test:notaport"))
    assertFalse(PopopxEcoAction.isHttpUrl("https://[::1]"))
    assertFalse(PopopxEcoAction.isHttpUrl("https://eco.test/" + "a".repeat(PopopxEcoLimits.MAXIMUM_URL_CHARACTERS)))
    // Userinfo is dropped, not validated: same destination, credential never reaches the address bar.
    assertTrue(PopopxEcoAction.isHttpUrl("https://u:p@eco.test/x"))
  }

  @Test
  fun anActionIsSaneOnlyForItsOwnKindOfArgument() {
    fun sane(kind: PopopxEcoAction.Kind, payload: String? = null, url: String? = null, amount: Int? = null, target: String? = null) =
      PopopxEcoAction("a", "Go", kind, PopopxEcoAction.Visual.PRIMARY, payload, url, target, amount, false).isSane
    assertFalse(sane(PopopxEcoAction.Kind.NONE))
    assertFalse(sane(PopopxEcoAction.Kind.CALLBACK))
    assertTrue(sane(PopopxEcoAction.Kind.CALLBACK, payload = "p"))
    assertFalse(sane(PopopxEcoAction.Kind.CALLBACK, payload = ""))
    assertTrue(sane(PopopxEcoAction.Kind.OPEN_URL, url = "https://eco.test"))
    assertFalse(sane(PopopxEcoAction.Kind.OPEN_URL, url = "ftp://eco.test"))
    assertTrue(sane(PopopxEcoAction.Kind.PAY_CREDITS, amount = PopopxEcoLimits.MINIMUM_AMOUNT))
    assertFalse(sane(PopopxEcoAction.Kind.PAY_CREDITS, amount = 0))
    assertFalse(sane(PopopxEcoAction.Kind.PAY_CREDITS, amount = PopopxEcoLimits.MAXIMUM_CREDIT_AMOUNT + 1))
    assertFalse(sane(PopopxEcoAction.Kind.OPEN_CHANNEL, payload = "popopx://channel/onlyone"))
  }

  @Test
  fun aCardBubbleIsLiveUntilItsOwnExpiryOnTheCallersClock() {
    val card = (decode(cardFrame(et = 5000L))!! as PopopxEcoFrame.ServiceCard).card
    assertTrue(card.isLive(4999L))
    assertFalse(card.isLive(5000L))
    assertTrue((decode(cardFrame())!! as PopopxEcoFrame.ServiceCard).card.isLive(Long.MAX_VALUE))
  }

  @Test
  fun theStoreRefusesAHandshakeWithoutASecretButAcceptsOneWithAShorterKey() {
    val defaults = ecoSettings()
    val store = PopopxEcoStore(defaults, PopopxChannelKeyRotation())
    assertEquals(PopopxEcoApplyOutcome.STORED_SESSION, store.apply(decode("""{"t":"sh","uid":"u","sec":"00112233"}""")!!, 8L))
    assertEquals(4, PopopxEcoSessionStore.session(8L, defaults)?.secretBytes?.size)
    assertFalse(PopopxEcoSession("u", "00".repeat(33), null).isSane)
    assertFalse(PopopxEcoSession("", "00", null).isSane)
    assertFalse(PopopxEcoSession("u", "00", "").isSane)
  }


}
