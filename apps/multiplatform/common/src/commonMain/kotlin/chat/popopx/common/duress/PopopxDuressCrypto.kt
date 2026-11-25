package chat.popopx.common.duress

import java.security.SecureRandom
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * The password-derivation area of the duress engine: PBKDF2-HMAC-SHA256, constant-time comparison, and random
 * bytes. Mirrors `PopopxDuressCrypto` (apps/ios/Shared/Features/AntiTheftDuress/PopopxDuressAuthManager.swift:307-386).
 *
 * iOS hand-rolls the loop over CryptoKit's `HMAC<SHA256>`; this uses `SecretKeyFactory("PBKDF2WithHmacSHA256")`,
 * which is the same algorithm by specification (RFC 8018, PRF = HMAC-SHA-256, block salt = `salt ‖ i2be(i)`,
 * XOR of the `c` u-values, concatenation truncated to `dkLen`). The agreement is not assumed: the vectors below
 * are asserted against iOS's own function, run on this machine, in `PopopxDuressCryptoTest`.
 *
 * Nothing here is `@MainActor`-equivalent on either platform, for iOS's reason (the same file, line 304): 100,000
 * HMACs measure in the low hundreds of milliseconds, and that cost has to be movable off the UI thread — on
 * Android that means the caller wraps it in `Dispatchers.Default`, which is why none of these functions touch a
 * handler or a context.
 */
object PopopxDuressCrypto {
  /** Matches `PopopxDuressCrypto.saltBytes`. */
  const val SALT_BYTES: Int = 32

  /** Matches `hashBytes`: the stored verification hash is 32 bytes, never a hex string of another length. */
  const val HASH_BYTES: Int = 32

  /** Matches `iterations`. Stored per record, because verification reads the record's own count. */
  const val ITERATIONS: Int = 100_000

  /**
   * PBKDF2-HMAC-SHA256, or an empty array when the inputs are not derivable.
   *
   * iOS returns `Data()` for `iterations <= 0` or `outputCount <= 0` (line 330) rather than throwing, and every
   * caller treats an empty result as "no write". That is kept, because an exception escaping here would surface
   * as a crash in a screen whose whole job is to stay quiet.
   */
  fun pbkdf2Sha256(
    password: ByteArray,
    salt: ByteArray,
    iterations: Int,
    outputCount: Int,
  ): ByteArray {
    if (iterations <= 0 || outputCount <= 0) return ByteArray(0)
    return try {
      // `PBEKeySpec` takes chars, not bytes, so the UTF-8 password is decoded back to the string it came from at
      // the call site. iOS derives over `Data(secret.utf8)`; the round trip is identity for any password that was
      // itself decoded from UTF-8, which is what the text field produces.
      val spec = PBEKeySpec(String(password, Charsets.UTF_8).toCharArray(), salt, iterations, outputCount * 8)
      SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded.copyOf(outputCount)
    } catch (e: Exception) {
      ByteArray(0)
    }
  }

  fun pbkdf2Sha256(password: String, salt: ByteArray, iterations: Int, outputCount: Int): ByteArray =
    pbkdf2Sha256(password.toByteArray(Charsets.UTF_8), salt, iterations, outputCount)

  /**
   * Length-equal, non-empty, XOR-accumulated comparison — iOS `matchesInConstantTime` (line 358-365), including
   * its two guards: unequal length returns false immediately ("length is not a secret, and this module's two
   * records always have the same length"), and an empty pair returns false rather than true.
   *
   * The second guard is the one that matters for a port: a comparison that reads "no stored hash" as a match
   * would unlock on an absent record.
   */
  fun matchesInConstantTime(candidate: ByteArray, stored: ByteArray): Boolean {
    if (candidate.size != stored.size || candidate.isEmpty()) return false
    var difference: Int = 0
    for (offset in candidate.indices) {
      difference = difference or (candidate[offset].toInt() xor stored[offset].toInt())
    }
    return difference == 0
  }

  /** 32 system-random bytes; empty on failure, meaning "do not write this time". */
  fun randomSalt(): ByteArray = randomBytes(SALT_BYTES)

  /**
   * System random bytes of any length.
   *
   * iOS returns empty `Data` on a failing `SecRandomCopyBytes` and states the reason twice (lines 373-382): a
   * timestamp or counter fallback would make the salt predictable, which is the exact problem a salt exists to
   * solve, so "better to write nothing than to write a false sense of security". `SecureRandom` here has no
   * error channel to check, so the guard is an exception one — and it is kept rather than dropped, because an
   * empty return is a *contract* the caller must honour, not a curiosity of Apple's API.
   */
  fun randomBytes(count: Int): ByteArray {
    if (count <= 0) return ByteArray(0)
    return try {
      ByteArray(count).also { SecureRandom().nextBytes(it) }
    } catch (e: Exception) {
      ByteArray(0)
    }
  }

  /** Lowercase hex, the spelling every stored value and every vector in the tests uses. */
  fun toHex(bytes: ByteArray): String {
    val out = StringBuilder(bytes.size * 2)
    for (byte in bytes) {
      val v = byte.toInt() and 0xFF
      if (v < 0x10) out.append('0')
      out.append(v.toString(16))
    }
    return out.toString()
  }

  /** Null for anything that is not even-length valid hex — never a partial decode. */
  fun fromHex(hex: String): ByteArray? {
    if (hex.isEmpty() || hex.length % 2 != 0) return null
    val out = ByteArray(hex.length / 2)
    for (index in out.indices) {
      val high = Character.digit(hex[index * 2], 16)
      val low = Character.digit(hex[index * 2 + 1], 16)
      if (high < 0 || low < 0) return null
      out[index] = ((high shl 4) or low).toByte()
    }
    return out
  }

  /**
   * The vectors, each of them measured rather than quoted from a book.
   *
   * The first two are the pair iOS's own doc comment names (lines 318-320). The third is a two-block output:
   * `dkLen = 48` forces `blockCount = 2`, which is the only way a wrong endianness in the counter or a broken
   * concatenation boundary becomes visible — iOS says exactly that at line 336 ("a single-block implementation
   * cannot reveal a wrong endianness; only multi-block does"), and the value begins with the single-block answer
   * for the same inputs, so the boundary is visible in the string itself. The last two are production-shaped:
   * 100,000 iterations and a 32-byte salt.
   *
   * Deviation worth naming in the commit: the plan cited `3d22d31d46da…` as "the c=2 multi-block vector". It is
   * not. iOS's file lists that fragment among "8 groups … two of them multi-block outputs (dkLen=48 and 6)"
   * without stating its inputs, and the real c=2 answer is `ae4d0c95…`. Every hex below was produced on this
   * machine by the iOS function and independently by `hashlib.pbkdf2_hmac`, and the two agreed on all five.
   */
  object KnownAnswers {
    const val PASSWORD = "password"
    const val SALT_HEX = "73616c74"

    const val C1_DK32 = "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
    const val C2_DK32 = "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
    const val C1_DK48 = "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b4dbf3a2f3dad3377264bb7b8e8330d4e"

    const val PRODUCTION_PASSWORD = "correct horse battery staple"
    const val PRODUCTION_SALT_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    const val PRODUCTION_C100_000 = "ef8970894e11c302383e9d31b220979179c2e8964100f3a99a52cdc7ce6f9f77"

    const val SECOND_PASSWORD = "po-popx-duress-check"
    const val SECOND_SALT_HEX = "a0a1a2a3a4a5a6a7a8a9aaabacadaeafa0a1a2a3a4a5a6a7a8a9aaabacadaeaf"

    // Re-derived, not copied: the iOS comment's own two multi-block literals (A:315-316) cannot be reproduced from
    // this password/salt at any (c, dkLen) that comment names, and the second has an odd number of hex digits, so it
    // cannot be decoded at all. Every value below is the output of three instruments that agree — this function, the
    // `pbkdf2SHA256` extracted verbatim from A:324-354 run under `xcrun swift`, and
    // `hashlib.pbkdf2_hmac("sha256", pw, salt, c, dklen=dk)`.
    const val SECOND_C100_000 = "86589ed7baac9541b29851cbc94e7e4c0d8c544e446fbf83cb69821a551b7d4b"
  }
}
