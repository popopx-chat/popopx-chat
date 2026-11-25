package chat.popopx.common.commerce

import chat.popopx.common.crypto.base64UrlDecode
import chat.popopx.common.crypto.base64UrlEncode

// The four conversation-stream payloads: `popopx://gift`, `popopx://creditgift`, `popopx://redpacket`,
// `popopx://channel`. Ported from `PopopxBadgeCreditsModels.swift:619-1086`.
//
// Every one of them is minted by signing once and encoding once ([PopopxCommerceSignature.canonical] over the
// canonical bytes, then the wire string), and every one of them is parsed with the same criteria: split the text on
// whitespace, try the LAST token first, check scheme and host together, allow-list the field names, require the
// fields that must be there, cap every length. A field that fails a cap rejects the whole token rather than being
// truncated into a smaller number — silently accepting `amount=999999999999` because it "fits in an Int" is how a
// forged card becomes a ledger row.

/**
 * A token's field map, the Kotlin form of Swift's `URLComponents.percentEncodedQuery` walk
 * (`:686-693`, and identically in the other three parsers).
 *
 * It returns the fields in the order they appeared, first occurrence of a name wins, and a piece without `=` is
 * skipped rather than rejected. `null` means the token is not this scheme/host at all. The allow-list each payload
 * publishes as `FIELD_NAMES` is enforced by the readers below, which only ever look up whitelisted names: an extra
 * `evil=` lands in this map and is never consulted, which is the same observable answer Swift gets by `continue`-ing
 * past it, and it is why a second `v=` cannot displace the first.
 *
 * ### What is NOT reproduced, and why that is safe here
 * `URLComponents` percent-encodes characters that are illegal in a query (` ` → `%20`, `{` → `%7B`, a non-ASCII
 * letter → its UTF-8 bytes, a stray `%` → `%25`) before handing `percentEncodedQuery` over, and the parsers above
 * read that normalised text. This helper passes the raw substring. The two differ only for values that contain
 * those characters, and every field these payloads accept is drawn from a closed set — base64url, ASCII digits, a
 * UUID, a period letter — for which the normalisation is the identity. A token carrying anything else fails the
 * same gate on both platforms: here the value keeps its space and dies at the base64url alphabet check, there it
 * becomes `%20` and dies at exactly the same check.
 */
internal fun commerceTokenFields(token: String, scheme: String, host: String): Map<String, String>? {
  if (!token.startsWith("$scheme://")) return null
  val afterAuthority = token.substring("$scheme://".length)
  // Authority ends at the first `:` (a port, which we do not validate, exactly as `components.host` ignores it),
  // `/`, `?` or `#`.
  var authorityEnd = 0
  while (authorityEnd < afterAuthority.length) {
    val character = afterAuthority[authorityEnd]
    if (character == ':' || character == '/' || character == '?' || character == '#') break
    authorityEnd++
  }
  if (afterAuthority.substring(0, authorityEnd) != host) return null
  val queryStart = afterAuthority.indexOf('?')
  if (queryStart < 0) return null
  var query = afterAuthority.substring(queryStart + 1)
  // The query stops at the first `#` — measured on Swift's `URLComponents`, and the reason a fragment cannot
  // smuggle an extra field into a card.
  val fragment = query.indexOf('#')
  if (fragment >= 0) query = query.substring(0, fragment)
  val fields = LinkedHashMap<String, String>()
  for (pair in query.split('&')) {
    if (pair.isEmpty()) continue
    val separator = pair.indexOf('=')
    if (separator < 0) continue
    val key = pair.substring(0, separator)
    // `key=` records an empty value, exactly as Swift's `split(separator: "=", maxSplits: 1,
    // omittingEmptySubsequences: false)` does; the per-field `!isEmpty` gate decides what that means.
    if (!fields.containsKey(key)) fields[key] = pair.substring(separator + 1)
  }
  return fields
}

/** The digits gate Swift writes as `allSatisfy(\.isNumber)` + `Int64(…)`: a non-ASCII digit passes the first test and fails the parse, which is the same answer as ours. */
internal fun commerceDigits(raw: String, maximumDigits: Int): Long? {
  if (raw.isEmpty()) return null
  if (!raw.all { it.isDigit() }) return null
  if (raw.commerceLength() > maximumDigits) return null
  return raw.toLongOrNull()
}

/**
 * The gift-card bubble's payload (`:621-726`): `popopx://gift?v=<voucher>&p=<m|y>&n=<note>&t=<ms>&s=<sig>`.
 *
 * The note travels as base64url, not percent-encoding, because it may contain any character and the parsing side
 * must always be able to split on `&` and divide at the first `=` — the same premise as the module's other URI
 * branches. The signature covers the canonical bytes, which end with the RAW note text appended after the last
 * `|` (see [PopopxCommerceSignature.canonicalGift]): free text never enters `parts` because it may contain `|`, and
 * appended after the final part it cannot shift any earlier field out of position.
 */
data class PopopxGiftCardPayload(
  val voucherId: String,
  val period: PopopxNodeBadgePeriod,
  val note: String,
  val mintedAtMs: Long,
  val signature: String,
) {
  fun canonicalBytes(): ByteArray = PopopxCommerceSignature.canonicalGift(voucherId, period, mintedAtMs, note)

  /**
   * The card carries no public key — in a conversation stream a public key belongs to the privacy face — so this is
   * only decidable when this side IS the giver. Authenticity on the receiving side is judged on the
   * `PopopxBadgeGrant` that comes back in the ACK, never here (`:645-649`).
   */
  val isSignatureValid: Boolean
    get() = PopopxCommerceSignature.shared.verifySelfIssued(signature, canonicalBytes())

  fun wireString(): String =
    "$SCHEME://$HOST?v=$voucherId&p=${period.wireValue}&n=${noteField()}&t=$mintedAtMs&s=$signature"

  private fun noteField(): String = base64UrlEncode(note.encodeToByteArray())

  companion object {
    const val SCHEME = "popopx"
    const val HOST = "gift"

    /** The allow-list (`:629`): a field name outside it is skipped, which is how an added field cannot become a second `v`. */
    val FIELD_NAMES = setOf("v", "p", "n", "t", "s")

    /**
     * Mint: sign once, encode once (`:659-665`). Null means this device's identity key could not be fetched, and the
     * caller must give visible feedback rather than send an unsigned card.
     */
    fun make(voucherId: String, period: PopopxNodeBadgePeriod, note: String, mintedAtMs: Long): PopopxGiftCardPayload? {
      val trimmed = note.commercePrefix(PopopxCommerceLimits.MAXIMUM_NOTE_CHARACTERS)
      val signature = PopopxCommerceSignature.shared.signatureBase64URL(
        PopopxCommerceSignature.canonicalGift(voucherId, period, mintedAtMs, trimmed),
      ) ?: return null
      return PopopxGiftCardPayload(voucherId, period, trimmed, mintedAtMs, signature)
    }

    /** Split on whitespace, try from the LAST token backwards: the newest card in a forwarded line wins (`:672-679`). */
    fun parse(text: String): PopopxGiftCardPayload? {
      val tokens = text.commerceTokens()
      for (index in tokens.indices.reversed()) {
        parseToken(tokens[index])?.let { return it }
      }
      return null
    }

    fun parseToken(token: String): PopopxGiftCardPayload? {
      val fields = commerceTokenFields(token, SCHEME, HOST) ?: return null
      val voucherId = fields["v"] ?: return null
      if (voucherId.isEmpty() || voucherId.commerceLength() > PopopxCommerceLimits.MAXIMUM_VOUCHER_ID_CHARACTERS) return null
      val period = PopopxNodeBadgePeriod.fromWire(fields["p"]) ?: return null
      val mintedAtMs = commerceDigits(fields["t"] ?: return null, PopopxCommerceLimits.MAXIMUM_TIME_DIGITS) ?: return null
      val signature = fields["s"] ?: return null
      if (signature.isEmpty() || signature.commerceLength() > PopopxCommerceLimits.MAXIMUM_SIGNATURE_CHARACTERS) return null
      val noteField = fields["n"] ?: ""
      val note = if (noteField.isEmpty()) {
        ""
      } else {
        // An undecodable note rejects the card outright: a card whose message could not be read is not the card
        // that was signed, and the signature below covers the note bytes (`:709-717`).
        val decoded = base64UrlDecode(noteField)?.decodeToString() ?: return null
        decoded.commercePrefix(PopopxCommerceLimits.MAXIMUM_NOTE_CHARACTERS)
      }
      return PopopxGiftCardPayload(voucherId, period, note, mintedAtMs, signature)
    }
  }
}

/**
 * The compute-credit gift-card bubble (`:728-839`), on its **own host** `creditgift` rather than a field on `gift`:
 * the two cards grant different things and a recipient must be able to tell which it holds *before* parsing a value
 * — one host with an optional amount would make "badge or credits" a runtime question, and mis-answering it is a
 * voucher redeemed against the wrong ledger.
 *
 * The amount in this card is **display only**: what gets credited comes from the signed `PopopxCreditsGrant` in the
 * ACK, so a hand-edited `a=` can lie on screen but cannot mint a single credit (`:734-736`).
 */
data class PopopxCreditGiftPayload(
  val voucherId: String,
  val creditsAmount: Int,
  val note: String,
  val mintedAtMs: Long,
  val signature: String,
) {
  fun canonicalBytes(): ByteArray =
    PopopxCommerceSignature.canonicalCreditGift(voucherId, creditsAmount, mintedAtMs, note)

  val isSignatureValid: Boolean
    get() = PopopxCommerceSignature.shared.verifySelfIssued(signature, canonicalBytes())

  fun wireString(): String =
    "$SCHEME://$HOST?v=$voucherId&a=$creditsAmount&n=${base64UrlEncode(note.encodeToByteArray())}&t=$mintedAtMs&s=$signature"

  companion object {
    const val SCHEME = "popopx"
    const val HOST = "creditgift"
    val FIELD_NAMES = setOf("v", "a", "n", "t", "s")

    /**
     * `creditsAmount > 0` is checked BEFORE signing (`:771`): a zero-credit card would be a signed instruction to
     * move nothing, and the receiver's ledger would carry a row for it.
     */
    fun make(voucherId: String, creditsAmount: Int, note: String, mintedAtMs: Long): PopopxCreditGiftPayload? {
      if (creditsAmount <= 0) return null
      val trimmed = note.commercePrefix(PopopxCommerceLimits.MAXIMUM_NOTE_CHARACTERS)
      val signature = PopopxCommerceSignature.shared.signatureBase64URL(
        PopopxCommerceSignature.canonicalCreditGift(voucherId, creditsAmount, mintedAtMs, trimmed),
      ) ?: return null
      return PopopxCreditGiftPayload(voucherId, creditsAmount, trimmed, mintedAtMs, signature)
    }

    fun parse(text: String): PopopxCreditGiftPayload? {
      val tokens = text.commerceTokens()
      for (index in tokens.indices.reversed()) {
        parseToken(tokens[index])?.let { return it }
      }
      return null
    }

    fun parseToken(token: String): PopopxCreditGiftPayload? {
      val fields = commerceTokenFields(token, SCHEME, HOST) ?: return null
      val voucherId = fields["v"] ?: return null
      if (voucherId.isEmpty() || voucherId.commerceLength() > PopopxCommerceLimits.MAXIMUM_VOUCHER_ID_CHARACTERS) return null
      val rawAmount = commerceDigits(fields["a"] ?: return null, PopopxCommerceLimits.MAXIMUM_AMOUNT_DIGITS) ?: return null
      if (rawAmount <= 0 || rawAmount > Int.MAX_VALUE.toLong()) return null
      val creditsAmount = rawAmount.toInt()
      val mintedAtMs = commerceDigits(fields["t"] ?: return null, PopopxCommerceLimits.MAXIMUM_TIME_DIGITS) ?: return null
      val signature = fields["s"] ?: return null
      if (signature.isEmpty() || signature.commerceLength() > PopopxCommerceLimits.MAXIMUM_SIGNATURE_CHARACTERS) return null
      val note = commerceNoteField(fields["n"] ?: "") ?: return null
      return PopopxCreditGiftPayload(voucherId, creditsAmount, note, mintedAtMs, signature)
    }
  }
}

/**
 * The compute-credit red-packet bubble (`:841-960`). The spec's fields `id`/`amount`/`note`/`sig` plus exactly ONE
 * extra, `n`, the share count: in an even group split the claiming side has to know how large its own share is, and
 * without `n` either the recipient divides by a headcount somebody else can change, or the share count goes into
 * `note`, which is user text rather than an accounting entry. So `n` is inside the signed bytes and altering it is
 * just as much a verification failure as altering the amount (`:841-844`).
 */
data class PopopxRedPacketPayload(
  val packetId: String,
  val amount: Int,
  val recipients: Int,
  val note: String,
  val signature: String,
) {
  fun canonicalBytes(): ByteArray = PopopxCommerceSignature.canonicalRedPacket(packetId, amount, recipients, note)

  /** Self-signature only, for the sender's own re-check; the receiver's answer is the ACK (`:866-868`). */
  val isSelfSignatureValid: Boolean
    get() = PopopxCommerceSignature.shared.verifySelfIssued(signature, canonicalBytes())

  /**
   * The amount must land on one of the calibrated tiers (`:870-874`). The UI only offers fixed tiers, but the
   * criterion cannot live only in the UI: a red-packet text with an altered amount can perfectly well be pasted
   * into a conversation, and this layer must refuse it. Apple's 3.1.1 red line "no random amounts" is what the
   * whitelist is for.
   */
  val isAmountAuthorized: Boolean get() = PopopxCommerceLimits.RED_PACKET_AMOUNTS.contains(amount)

  /**
   * What one person is owed (`:876-881`). A payload that does not divide evenly is ALWAYS treated as forged: it
   * cannot be an "equal split", and crediting it rounded down silently swallows the difference — money nobody can
   * reconcile. This is the reason `amountPerRecipient` is a gate rather than a computation the caller may skip.
   */
  val amountPerRecipient: Int?
    get() {
      if (recipients < 1) return null
      if (amount % recipients != 0) return null
      return amount / recipients
    }

  fun wireString(): String =
    "$SCHEME://$HOST?id=$packetId&amount=$amount&n=$recipients&note=${base64UrlEncode(note.encodeToByteArray())}&sig=$signature"

  companion object {
    const val SCHEME = "popopx"
    const val HOST = "redpacket"
    val FIELD_NAMES = setOf("id", "amount", "note", "sig", "n")

    /** Construction refuses anything the receiver would have to round (`:891-901`). */
    fun make(packetId: String, amount: Int, recipients: Int, note: String): PopopxRedPacketPayload? {
      if (!PopopxCommerceLimits.RED_PACKET_AMOUNTS.contains(amount)) return null
      if (recipients < 1 || recipients > PopopxCommerceLimits.MAXIMUM_PACKET_RECIPIENTS) return null
      if (amount % recipients != 0) return null
      val trimmed = note.commercePrefix(PopopxCommerceLimits.MAXIMUM_NOTE_CHARACTERS)
      val signature = PopopxCommerceSignature.shared.signatureBase64URL(
        PopopxCommerceSignature.canonicalRedPacket(packetId, amount, recipients, trimmed),
      ) ?: return null
      return PopopxRedPacketPayload(packetId, amount, recipients, trimmed, signature)
    }

    fun parse(text: String): PopopxRedPacketPayload? {
      val tokens = text.commerceTokens()
      for (index in tokens.indices.reversed()) {
        parseToken(tokens[index])?.let { return it }
      }
      return null
    }

    fun parseToken(token: String): PopopxRedPacketPayload? {
      val fields = commerceTokenFields(token, SCHEME, HOST) ?: return null
      val packetId = fields["id"] ?: return null
      if (packetId.isEmpty() || packetId.commerceLength() > PopopxCommerceLimits.MAXIMUM_PACKET_ID_CHARACTERS) return null
      val rawAmount = commerceDigits(fields["amount"] ?: return null, PopopxCommerceLimits.MAXIMUM_AMOUNT_DIGITS) ?: return null
      if (rawAmount <= 0 || rawAmount > Int.MAX_VALUE.toLong()) return null
      val amount = rawAmount.toInt()
      val signature = fields["sig"] ?: return null
      if (signature.isEmpty() || signature.commerceLength() > PopopxCommerceLimits.MAXIMUM_SIGNATURE_CHARACTERS) return null
      // The share count defaults to 1 (`:942-948`): the only legal value for a 1:1 packet, and also what a payload
      // minted before `n` existed must look like.
      val rawRecipients = commerceDigits(fields["n"] ?: "1", PopopxCommerceLimits.MAXIMUM_RECIPIENTS_DIGITS) ?: return null
      if (rawRecipients < 1 || rawRecipients > PopopxCommerceLimits.MAXIMUM_PACKET_RECIPIENTS) return null
      val recipients = rawRecipients.toInt()
      val note = commerceNoteField(fields["note"] ?: "") ?: return null
      return PopopxRedPacketPayload(packetId, amount, recipients, note, signature)
    }
  }
}

/**
 * The channel subscription threshold card (`:962-1086`). It is a **visible** message, not silent signalling: the
 * threshold is the price the channel owner wants members to know, and hiding it would mean making members pay for a
 * number they cannot see.
 *
 * There is no server and no address book of the owner's, so publishing = sending this message and the subscription
 * panel's price = the `p` decoded out of it; neither side invents a number. The channel itself does NOT enter the
 * payload: the credential key on a member's side is the local conversation id, stable on one device and never
 * portable across devices — signing it in would only create a key that does not exist on the other side's device
 * (`:962-975`).
 */
data class PopopxChannelAccessPayload(
  val price: Int,
  val publishedAtMs: Long,
  val issuerPublicKeyBase64URL: String,
  val signature: String,
) {
  fun canonicalBytes(): ByteArray =
    PopopxCommerceSignature.canonicalChannel(price, publishedAtMs, issuerPublicKeyBase64URL)

  /** The re-check on the issuing device itself (`:993-996`). */
  val isSelfSignatureValid: Boolean
    get() = PopopxCommerceSignature.shared.verifySelfIssued(signature, canonicalBytes())

  /**
   * Authenticity on the member's side (`:998-1006`): the public key is right here in this message, so this does NOT
   * need the two sides to be contacts and does not depend on a local key. Not decoration — altering `p` once is one
   * failed verification, and the threshold directly decides how much money is deducted.
   */
  val isIssuerSignatureValid: Boolean
    get() = PopopxCommerceSignature.shared.verify(signature, canonicalBytes(), issuerPublicKeyBase64URL)

  /** `0` is legal (a free channel); negatives and anything above the ceiling are not (`:1008-1012`). */
  val isPriceAuthorized: Boolean
    get() = price >= 0 && price <= PopopxCommerceLimits.MAXIMUM_CREDITS_THRESHOLD

  fun wireString(): String =
    "$SCHEME://$HOST?p=$price&t=$publishedAtMs&e=$issuerPublicKeyBase64URL&s=$signature"

  companion object {
    const val SCHEME = "popopx"
    const val HOST = "channel"
    val FIELD_NAMES = setOf("p", "t", "e", "s")

    /**
     * Publish (`:1021-1032`). Two gates before any signing happens:
     *
     *  - `price >= 1`: a 0-price tile neither deducts credits nor leaves a ledger row, so sending it is only noise
     *    (the panel already explained this to the user);
     *  - an empty public key means this device's key could not be fetched. Screening empties BEFORE signing matters
     *    because a card signed with a key that does not exist only gives the member "verification failed" while the
     *    real reason is "this device has no key".
     */
    fun make(price: Int, publishedAtMs: Long): PopopxChannelAccessPayload? {
      if (price < 1 || price > PopopxCommerceLimits.MAXIMUM_CREDITS_THRESHOLD) return null
      val publicKey = PopopxCommerceSignature.shared.localPublicKeyBase64URL()
      if (publicKey.isEmpty()) return null
      val signature = PopopxCommerceSignature.shared.signatureBase64URL(
        PopopxCommerceSignature.canonicalChannel(price, publishedAtMs, publicKey),
      ) ?: return null
      return PopopxChannelAccessPayload(price, publishedAtMs, publicKey, signature)
    }

    /** Publication publishes: a zero price is refused here as well as in [make], and `isPriceAuthorized` stays the member-side gate. */
    fun parse(text: String): PopopxChannelAccessPayload? {
      val tokens = text.commerceTokens()
      for (index in tokens.indices.reversed()) {
        parseToken(tokens[index])?.let { return it }
      }
      return null
    }

    fun parseToken(token: String): PopopxChannelAccessPayload? {
      val fields = commerceTokenFields(token, SCHEME, HOST) ?: return null
      val rawPrice = commerceDigits(fields["p"] ?: return null, PopopxCommerceLimits.MAXIMUM_PRICE_DIGITS) ?: return null
      if (rawPrice > PopopxCommerceLimits.MAXIMUM_CREDITS_THRESHOLD) return null
      val price = rawPrice.toInt()
      val publishedAtMs = commerceDigits(fields["t"] ?: return null, PopopxCommerceLimits.MAXIMUM_TIME_DIGITS) ?: return null
      val publicKey = fields["e"] ?: return null
      if (publicKey.isEmpty() || publicKey.commerceLength() > PopopxCommerceLimits.MAXIMUM_PUBLIC_KEY_CHARACTERS) return null
      val signature = fields["s"] ?: return null
      if (signature.isEmpty() || signature.commerceLength() > PopopxCommerceLimits.MAXIMUM_SIGNATURE_CHARACTERS) return null
      return PopopxChannelAccessPayload(price, publishedAtMs, publicKey, signature)
    }
  }
}

/**
 * The shared `n` / `note` decoding: an absent or empty field is an empty message, anything else must base64url-decode
 * and UTF-8-decode whole or the card is refused, and only then is the text truncated to the cap (`:709-717`) —
 * decoding first and truncating after is what keeps a truncated note inside the signed bytes rather than outside them.
 */
private fun commerceNoteField(field: String): String? {
  if (field.isEmpty()) return ""
  val decoded = base64UrlDecode(field)?.decodeToString() ?: return null
  return decoded.commercePrefix(PopopxCommerceLimits.MAXIMUM_NOTE_CHARACTERS)
}

/**
 * Swift's `text.split(whereSeparator: \.isWhitespace)` without a regex (`:675`, `:784`, `:909`, `:1041`).
 *
 * Written out because `\s` and `Char.isWhitespace()` are not the same class and a token split differently on the two
 * platforms parses as two different things; the class used here is the one the eco frames already share.
 */
internal fun String.commerceTokens(): List<String> {
  val out = ArrayList<String>()
  var index = 0
  while (index < length) {
    if (this[index].isWhitespace()) {
      index++
      continue
    }
    val start = index
    while (index < length && !this[index].isWhitespace()) index++
    out.add(substring(start, index))
  }
  return out
}
