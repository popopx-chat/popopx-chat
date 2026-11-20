//
//  PopopxAntiPhotoRenderView.swift
//  POPOPX (iOS)
//
//  [Top-secret view-once - module four, shutter side] The route taken by photographing the screen; this provides three things:
//  1. `PopopxAntiPhotoRenderView`: a time-division-multiplexed dot-matrix overlay, aimed at the camera shutter's integration time / rolling shutter;
//  2. `PopopxSpotlightTextView` / `PopopxTeleprompterTextView`: two reading modes that "read clearly only while held",
//     aimed at the action of "holding the phone up while another device casually photographs a whole page";
//  3. `PopopxBlindWatermarkOverlay`: a blind watermark invisible to the naked eye; it defends against nobody and only makes it possible to find out afterwards who leaked.
//
//  ### The dot-matrix overlay's physical claims (written to the point of being refutable, never "absolutely uncapturable")
//  What it does: each frame switches between two binary grayscale dot matrices that are **pixel-by-pixel complementary** (`PopopxShutterPattern`), driven by
//  `PopopxFrameTicker` alternating at 60Hz; the same tile is generated only once and cached, and each frame swaps nothing but a reference.
//  Why the eye still reads it while photos break:
//  - The eye: a single frame's spatial frequency is at the 1-pixel level (beyond resolution at a normal reading distance), and the 60Hz temporal alternation is averaged
//    by persistence of vision into a gray haze of about 5%; average brightness does not vary with phase, so no "flash" is seen, only "a layer smeared over".
//  - The camera: CMOS is a **rolling shutter** - every row of pixels exposes at a different moment, so in one frame the upper rows sample phase A, the lower rows
//    sample phase B, and the rows crossing the boundary integrate A+B together. The three kinds of rows each get a different dot matrix, so the output is horizontal banding + low-frequency
//    moire patterns slapped onto the text; add the lens MTFO low-pass, Bayer demosaicing and JPEG 4:2:0 - because the dot matrix is a **pure luminance**
//    signal (grayscale, no color), chroma subsampling cannot separate it from the image's own luminance, so denoising cannot throw it away as noise either.
//  Conditions under which it does not hold (these really can be bypassed; the UI copy must not overstate them):
//  - A global shutter / machine-vision camera squeezes the whole frame's exposure into one display frame -> only one phase is sampled, and the alternation leg fails outright
//    (the spatial-aliasing leg remains, but with a much smaller amplitude);
//  - A slow shutter (>= 2 display periods) integrates both phases completely -> the dot matrix cancels itself, leaving only a uniform haze;
//  - Clipping on one side over a pure-black or pure-white surface: 0-valued pixels do nothing on a pure-black background, 255-valued pixels do nothing on a pure-white background,
//    so only half of the complementarity is left - which is why this layer's best working range is **mid-tone** surfaces;
//  - Long-distance zoom + low resolution, or simply feeding the photo into multi-frame averaging / deep-learning restoration -> both help considerably.
//  So this layer's positioning is "make the few lines of small print in a casually taken photo unreadable / untrustworthy", not "impossible to photograph".
//
//  ### Photosensitivity and readability (this is not an optional moral statement, it is a design parameter)
//  Full-screen 60Hz alternation is **flicker**. The mitigations here are four: opacity is only 0.05; the bright/dark cell counts of the two dot matrices are guaranteed by construction
//  to be strictly 32/32 (the centre-symmetric pairing of `PopopxShutterPattern.baseBit`), so the alternation **does not change average brightness**,
//  there is no 30Hz low-frequency luminance component on the screen and the flicker lands only in the spatial-temporal channel; the single-frame bright/dark jump at the 1-pixel scale covers only
//  half the area; and when `accessibilityReduceMotion` is true the **alternation stops**, degrading to one static dot matrix (keeping the spatial-aliasing leg,
//  giving up the temporal one). Also this screen exists for at most `ttlSeconds` seconds. Even so, "rechecked on device against WCAG 2.3.1"
//  must still be a manual step before release - this file cannot supply that proof.
//
//  ### The two reading modes attack the action, not the pixels
//  Spotlight: the whole screen is blurred by default and only the circle being held is sharp; line-by-line: one logical line at a time, which advances only while held and dragged vertically.
//  What they share is "the hand cannot leave the screen, and only a small patch is looked at each time" - so casually photographing a whole page with another device
//  becomes impossible (what you capture is only a small sharp region, the rest blurred / other lines). These two modes do **not** defend against handing the phone to someone else,
//  nor against holding still so the sharp window parks on one line and photographing that - that is the job of the physical privacy screen and camera-detection routes.
//
//  ### What the blind watermark defends against, at a glance
//  Nothing. It is **forensics**: the device's `identifierForVendor` + the session id (truncated past 64 grapheme clusters / 128 UTF-8 bytes,
//  which is one lossy spot stated openly) + a millisecond timestamp encoded into a dot matrix; the contrast between the two colors is 1/255, invisible to the eye, surfacing only after a frame
//  has been photographed or screenshotted by the system and pushed through an editor for brightness/contrast. It offers attribution only after something has already happened (the image
//  leaked), therefore: never write "watermarked" into any "anti-photo" copy.
//
//  ### Threading and ownership contract
//  - All three views only read the values the caller passes in, subscribe to nothing, and hold no reference to the other party's objects;
//  - The dot-matrix driver `PopopxRollingShutterDriver` exists only when `isEnabled` is true and this layer has entered the view tree,
//    and it must be stopped in `onDisappear` (when `PopopxAntiPhotoRenderView` is off it is **truly zero overhead**: no ticker built, no drawing entered);
//  - The two caches (tile / watermark matrix) are process-level mutable dictionaries accessed only on the main thread (evaluating a view body is the main thread).
//    The keys are `sessionIdentifier` / zoom level, capacities are bounded, and no plaintext's lifetime is extended because of caching.
//
//  ### The verifiable pure-logic region
//  The section between `POPUPX_PURE_CORE_BEGIN`/`END` below **references no UIKit/SwiftUI symbol at all**, so that the whole block can be
//  cut out and run through round-trip tests with the host compiler (bit encoding <-> decoding, the two phases pixel-by-pixel complementary and each 32/32, screen visual row/column <-> bit
//  index being mutually inverse, the splitting neither exceeding its budget nor dropping characters). Any change to this section must rerun those assertions; and precisely because it can only be validated this way,
//  keeping it in one contiguous range is a hard requirement, not a typesetting preference.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import SwiftUI
import UIKit

// ================ POPUPX_PURE_CORE_BEGIN (no UIKit/SwiftUI symbol may appear in this section) ================

// MARK: - Reading modes

/// The two ways of reading in the top-secret dialog that "read clearly only while held".
enum PopopxSecureReadMode: String, CaseIterable, Identifiable, Sendable {
    /// Spotlight: heavy blur over the whole screen, only the circle being held is sharp.
    case spotlight
    /// Line-by-line: a single-line window that advances only while held and dragged.
    case teleprompter

    /// `Identifiable` has to be supplied explicitly: `CaseIterable` guarantees only `allCases`, not id.
    var id: String { rawValue }

    /// The short label for `PopopxSegmentedControl`.
    var title: String {
        switch self {
        case .spotlight: return NSLocalizedString("Spotlight", comment: "secure read mode")
        case .teleprompter: return NSLocalizedString("Line by line", comment: "secure read mode")
        }
    }

    /// The one-line note for `PopopxSectionCard(footnote:)`: it explains the "must hold" action, it makes no guarantee.
    var note: String {
        switch self {
        case .spotlight:
            return NSLocalizedString("The whole screen is heavily blurred; only the circle under your finger stays sharp. Let go and it all blurs back.", comment: "secure read mode")
        case .teleprompter:
            return NSLocalizedString("One logical line at a time: hold and drag up to move down, release to stop where you are.", comment: "secure read mode")
        }
    }
}

// MARK: - Time-division-multiplexed dot matrix (pure logic)

/// The two binary dot matrices that are complementary pixel by pixel. Between tile and tile they are opposite at **every single pixel**, and that is the origin of
/// the "integrals cancel each other out" criterion; a single tile is only 64 bytes, so both matrices are generated only once.
/// The bright-cell count of each is guaranteed equal by construction (see `baseBit`), so the overlay's average brightness is independent of phase - no flicker is introduced.
enum PopopxShutterPattern {
    /// The tile side length (device pixels). 8 is a deliberately chosen power of 2 smaller than common screen widths: tiling produces no visible large period,
    /// so the moire is broadband rather than a few fixed bands (fixed bands would be handled away as regular noise by the camera's denoising).
    static let tilePixels = 8

    /// The dot matrix uses only these two levels: only with two possible values can one claim "highest spatial frequency + maximum amplitude".
    static let darkValue: UInt8 = 0
    static let lightValue: UInt8 = 255

    /// Whether (x, y) is a bright cell or a dark cell under a given phase. The phase does nothing but one inversion, nothing else at all.
    static func bit(x: Int, y: Int, phase: Int) -> Bool {
        let raw = baseBit(x: x, y: y)
        return phase & 1 == 0 ? raw : !raw
    }

    /// One phase's grayscale plane (row-major, `tilePixels * tilePixels` bytes, each byte only ever dark or light).
    static func grayPlane(phase: Int) -> [UInt8] {
        var plane = [UInt8](repeating: darkValue, count: tilePixels * tilePixels)
        for y in 0 ..< tilePixels {
            for x in 0 ..< tilePixels {
                plane[y * tilePixels + x] = bit(x: x, y: y, phase: phase) ? lightValue : darkValue
            }
        }
        return plane
    }

    /// The base bit: decided by (x, y) alone, with no phase in it - the phase only inverts, so complementarity is a structural guarantee, not a coincidence.
    ///
    /// **The balance is built by construction**: each pixel is paired with its centre-symmetric pixel, and each pair must yield one bright and one dark
    /// (`tilePixels` is even, so no pixel pairs with itself). Thus both phases have exactly 32 bright and 32 dark cells inside the tile,
    /// the overlay's average brightness is independent of phase - there is no low-frequency flicker of any kind on the screen, and the flicker exists only in the spatial-temporal channel.
    /// Relying on the hash alone without guaranteeing count balance measurably gives deviations like 26/38, which = an extra roughly 18.8% ×
    /// opacity worth of 30Hz luminance component between the two phases; it neither helps nor hinders "camera integration cancellation", but there is no reason to keep it.
    private static func baseBit(x: Int, y: Int) -> Bool {
        let mirrorX = tilePixels - 1 - x
        let mirrorY = tilePixels - 1 - y
        let here = y * tilePixels + x
        let there = mirrorY * tilePixels + mirrorX
        if here <= there {
            return rawBit(x: x, y: y)
        }
        return rawBit(x: mirrorX, y: mirrorY) == false
    }

    /// Take bit 13: the low bits are polluted by the arithmetic structure of the `x &* 31 &+ y` step, and measurements show runs of equal values within one row;
    /// after switching to the middle bit the adjacent-pixel flip rate is close to 50% and the number of all-identical 2×2 windows drops to single digits (the `/tmp` test bench has the measured numbers).
    private static func rawBit(x: Int, y: Int) -> Bool {
        (mix(x: x, y: y) >> 13) & 1 == 1
    }

    /// A process-stable deterministic hash (an FNV-1a variant), not `Int.hashValue`: the latter's seed differs at every process launch,
    /// so "the two tiles are complementary" would still hold, but the same device would generate a different pattern each time, and neither forensics nor on-device reproduction could compare them.
    private static func mix(x: Int, y: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in [UInt64(x & 0xFF), UInt64(y & 0xFF), UInt64((x &* 31 &+ y) & 0xFF)] {
            hash = (hash ^ value) &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

// MARK: - Splitting for line-by-line reading (pure logic)

/// Cut a piece of body text into the logical lines of "line-by-line mode".
///
/// Why it cannot be left to SwiftUI's own typesetting: this mode wants **one line appearing at a time**, and the typesetting result depends on width,
/// font size class and copy, so the same sentence is one line in the SE class and three lines in the AX class. Taking the typesetting result as "a line" means one drag
/// jumps two or three lines, and the amount jumped differs between devices - this interaction must be predictable, so we cut the lines ourselves.
enum PopopxReadingLines {
    /// The character budget of one logical line (counted in grapheme clusters, CJK and Latin both counted as "one character / one letter").
    /// 24 is a conservative estimate of what fits on one line for "a 375pt narrow screen + body font size + no scaling"; better to cut a few extra lines
    /// than to let one line wrap into two on a narrow screen - that would expose two lines in the window at the same time.
    static let charactersPerLine = 24

    /// Paragraphs first (the newline test uses `Character.isNewline`, see below), and inside a paragraph cut greedily by the character budget:
    /// cut at a space if one is found in the second half of the window (English words are not bisected), otherwise cut hard (the right answer for spaceless CJK).
    /// All-whitespace paragraphs are discarded: one press buying an empty line tells the user "this gesture does nothing".
    ///
    /// Any input must return a **terminating, bounded** result: `limit < 1` does not recurse, and a single 4000-character spaceless "word"
    /// just produces a few more pieces; it can never become an O(n²) scan or an infinite loop.
    static func lines(from text: String, maxCharactersPerLine limit: Int = charactersPerLine) -> [String] {
        guard limit > 0 else { return text.isEmpty ? [] : [text] }
        let characters = Array(text)
        var result: [String] = []
        var start = 0
        var index = 0
        while index <= characters.count {
            // This **cannot** be written as `characters[index] == "\n"`: Swift's `Character` is a grapheme cluster,
            // and in a cross-platform "firstPart\r\nsecondPart" the CRLF is **one** whole grapheme "\r\n", which is not equal to "\n",
            // so the whole message would be hard-cut as a single paragraph and the resulting "lines" would still carry invisible graphemes like CR/CRLF -
            // once handed to Text for typesetting that is a line suddenly wrapping inside itself, and "show only one line at a time" fails on the spot.
            // `isNewline` recognizes \n, \r, \r\n and U+000B/U+000C/U+0085/U+2028/U+2029, covering every spelling in one go.
            if index == characters.count || characters[index].isNewline {
                appendWrapped(characters: characters, start: start, end: index, limit: limit, into: &result)
                start = index + 1
            }
            index += 1
        }
        return result
    }

    /// The identity (the one the assertions cover): strip the whitespace and join the result back, and it equals the original with all whitespace removed.
    /// That is, the splitting only **adds** newlines and only **deletes** whitespace; it never loses a character and never changes one.
    static func isLossless(original: String, lines: [String]) -> Bool {
        withoutWhitespace(original) == withoutWhitespace(lines.joined())
    }

    static func withoutWhitespace(_ value: String) -> String {
        value.filter { $0.isWhitespace == false }
    }

    private static func appendWrapped(
        characters: [Character],
        start: Int,
        end: Int,
        limit: Int,
        into result: inout [String]
    ) {
        // Whitespace is trimmed off both ends of the paragraph first: the leading run would make the first cut line start with a space (an illusion of indentation),
        // the trailing run would leave the last line an invisible tail eating into the character budget. Whitespace in the middle is kept exactly as it is.
        var cursor = start
        while cursor < end, characters[cursor].isWhitespace { cursor += 1 }
        var paragraphEnd = end
        while paragraphEnd > cursor, characters[paragraphEnd - 1].isWhitespace { paragraphEnd -= 1 }
        while cursor < paragraphEnd {
            let windowEnd = min(cursor + limit, paragraphEnd)
            var cut = windowEnd
            // A cut is needed only when "the window cannot hold it"; a paragraph that fits is never split into two lines just because there is a space inside it
            // (that would turn one short sentence into three presses, and the entire point of this mode is "one line at a time").
            if windowEnd < paragraphEnd {
                var probe = windowEnd - 1
                // Look back from the end of the window for the first space, and accept only a space falling in the window's **second half**:
                // cutting in the first half would drop the line width suddenly to half the budget, which is uglier than bisecting a long word.
                // It must not fall on cursor, otherwise this round makes no progress.
                let floor = cursor + (windowEnd - cursor) / 2
                while probe > cursor {
                    if characters[probe].isWhitespace, probe >= floor {
                        cut = probe
                        break
                    }
                    probe -= 1
                }
            }
            let piece = String(characters[cursor ..< cut])
            if piece.isEmpty == false {
                result.append(piece)
            }
            cursor = cut
            while cursor < paragraphEnd, characters[cursor].isWhitespace { cursor += 1 }
        }
    }
}

// MARK: - Blind watermark encoding (pure logic)

/// The decodable content of one blind watermark.
struct PopopxWatermarkBits: Equatable, Sendable {
    let deviceIdentifier: String
    let sessionIdentifier: String
    let epochMillis: Int64
}

/// The cell count of the dot matrix, the scatter stride, the two colors and the encode/decode. All of it is integer arithmetic - the Canvas on screen is only responsible
/// for drawing the cells according to the `onCells` given here, and any change to the geometry or the encoding makes the images already sent out fail to line up.
enum PopopxBlindWatermarkCodec {
    /// A fixed 40×40 grid. The column count is **not** computed from the screen size: in forensics the analyst must be able to count the cells out of the image to know how to read it,
    /// while a geometry-dependent layout decodes a different bit order at each size, which amounts to writing the watermark so that "only the same device can solve it".
    static let gridColumns = 40
    static let gridRows = 40
    static let cellCount = gridColumns * gridRows

    /// Bit i goes to cell `(i * stride) % cellCount`. Stride and cell count must be coprime, otherwise the scatter cycles early
    /// and the second half of the bits are all overwritten (40×40 = 1600 = 2^5 × 5^2, and 31 is coprime with it ✓).
    /// The point of scattering: the payload is only on the order of a thousand bits, and laying it out in cell order would leave a high-density band in one corner of the screen,
    /// easy to notice as "texture" and easy to lose wholesale in a cropped image.
    static let scatterStride = 31

    /// The payload byte cap = cell count / 8. Going over it is an encoding-side error, and `encode` returns nil outright instead of truncating quietly.
    static let maximumPayloadBytes = cellCount / 8

    /// The **character** cap of the session id. Past it the value is truncated - this is **known information loss**, stated here rather than hidden in the code:
    /// the payload additionally keeps the full timestamp and the device id, so truncation only affects "this view" and the precision of lining it up with the session table.
    static let maximumSessionCharacters = 64

    /// The **UTF-8 byte** cap of the session id, which applies **together** with the one above and is the one that actually bites for Chinese ids:
    /// one CJK grapheme occupies 3 bytes, so cutting by characters alone gives 64 characters = 192 bytes, a whole-frame payload of 247 > 200,
    /// and `encode` returns nil - the result is that **the watermark never appears at all**, which is exactly the hardest kind of failure to spot.
    /// How 128 is arrived at: 4(magic) + 1 + 36(device UUID) + 1 + 128 + 13 = 183 <= 200, leaving room for the longest realistic device id.
    static let maximumSessionBytes = 128

    /// The two near-black colors the specification requires. Apart from these two values the whole dot matrix never shows a third one (`rgb(isOn:)` is the only outlet).
    static let offColorRGB: UInt32 = 0x0000_00
    static let onColorRGB: UInt32 = 0x0101_01

    /// magic(4) | deviceLen(1) | device | sessionLen(1) | session | millis(13 ASCII digits)
    static let magicBytes: [UInt8] = [0x50, 0x58, 0x53, 0x31] // "PXS1"
    static let millisDigits = 13

    /// Encoded into one frame's payload. `deviceIdentifier` is supplied by the caller (pass "" when it cannot be obtained; see the nil handling on the view side).
    static func encode(_ record: PopopxWatermarkBits) -> [UInt8]? {
        let device = Array(record.deviceIdentifier.utf8)
        let session = Array(clamp(record.sessionIdentifier).utf8)
        let millis = millisecondDigits(record.epochMillis)
        var bytes: [UInt8] = magicBytes
        bytes.append(UInt8(min(device.count, 255)))
        bytes.append(contentsOf: device.prefix(255))
        bytes.append(UInt8(min(session.count, 255)))
        bytes.append(contentsOf: session.prefix(255))
        bytes.append(contentsOf: millis)
        guard bytes.count <= maximumPayloadBytes else { return nil }
        return bytes
    }

    static func decode(_ bytes: [UInt8]) -> PopopxWatermarkBits? {
        let header = magicBytes.count
        guard bytes.count >= header + 2 else { return nil }
        guard Array(bytes[0 ..< header]) == magicBytes else { return nil }
        let deviceLength = Int(bytes[header])
        let deviceStart = header + 1
        guard bytes.count >= deviceStart + deviceLength + 1 else { return nil }
        let sessionLength = Int(bytes[deviceStart + deviceLength])
        let sessionStart = deviceStart + deviceLength + 1
        guard bytes.count >= sessionStart + sessionLength + millisDigits else { return nil }
        let device = String(decoding: bytes[deviceStart ..< deviceStart + deviceLength], as: UTF8.self)
        let session = String(decoding: bytes[sessionStart ..< sessionStart + sessionLength], as: UTF8.self)
        let millisRange = sessionStart + sessionLength ..< sessionStart + sessionLength + millisDigits
        let millisText = String(decoding: bytes[millisRange], as: UTF8.self)
        // The timestamp field accepts digits only: a single non-digit anywhere in the string means this image is not a dot matrix we drew.
        guard millisText.allSatisfy(\.isNumber), let millis = Int64(millisText) else { return nil }
        return PopopxWatermarkBits(deviceIdentifier: device, sessionIdentifier: session, epochMillis: millis)
    }

    /// Payload -> cells. The returned length is always `cellCount`, and the cells beyond the payload are false.
    static func cells(from bytes: [UInt8]) -> [Bool] {
        var cells = [Bool](repeating: false, count: cellCount)
        guard bytes.count <= maximumPayloadBytes else { return cells }
        var bitIndex = 0
        for byte in bytes {
            var mask: UInt8 = 0x80
            while mask != 0 {
                if byte & mask != 0 {
                    cells[bitIndex] = true
                }
                mask >>= 1
                bitIndex += 1
            }
        }
        return cells
    }

    /// Scatter: bit i lands on cell `(i * stride) % cellCount`.
    ///
    /// Moving only the bits that are 1 is enough: the target is a fresh all-false array, and `(i * stride) % cellCount`, under the coprime
    /// premise, is a permutation (no two bits fight over the same cell), so "write only the 1s" and "assign the whole range" give the same result,
    /// and the former does half as many writes.
    static func scatter(_ cells: [Bool]) -> [Bool] {
        precondition(cells.count == cellCount, "scatter input must be \(cellCount) cells, got \(cells.count)")
        var scattered = [Bool](repeating: false, count: cellCount)
        for (bitIndex, isOn) in cells.enumerated() where isOn {
            scattered[(bitIndex * scatterStride) % cellCount] = true
        }
        return scattered
    }

    /// Reverse scatter: bit i of `gather` is exactly the bit `scatter` placed on cell `(i * stride) % cellCount`.
    /// that is, walking the same formula forward once - the inverse function relies on coprimality, not on a lookup table, so the forensic side needs no extra data.
    static func gather(_ scattered: [Bool]) -> [Bool] {
        precondition(scattered.count == cellCount, "gather input must be \(cellCount) cells, got \(scattered.count)")
        var cells = [Bool](repeating: false, count: cellCount)
        for bitIndex in 0 ..< cellCount {
            cells[bitIndex] = scattered[(bitIndex * scatterStride) % cellCount]
        }
        return cells
    }

    /// The only color outlet: any cell can only be one of the two near-black colors.
    static func rgb(isOn: Bool) -> UInt32 {
        isOn ? onColorRGB : offColorRGB
    }

    /// The whole chain: payload -> cells before scattering -> the scattered dot matrix.
    static func matrix(for record: PopopxWatermarkBits) -> PopopxWatermarkMatrix? {
        guard let bytes = encode(record) else { return nil }
        let scattered = scatter(cells(from: bytes))
        let onCells = scattered.enumerated().compactMap { $0.element ? $0.offset : nil }
        return PopopxWatermarkMatrix(record: record, cells: scattered, onCells: onCells)
    }

    /// Read back from the dot matrix (for forensics / self-tests; the parameter is the **scattered** cells).
    static func record(from cells: [Bool]) -> PopopxWatermarkBits? {
        let gathered = gather(cells)
        var bytes: [UInt8] = []
        var bitIndex = 0
        while bitIndex + 8 <= gathered.count {
            var byte: UInt8 = 0
            for bit in 0 ..< 8 {
                if gathered[bitIndex + bit] {
                    byte |= UInt8(0x80 >> bit)
                }
            }
            bytes.append(byte)
            bitIndex += 8
        }
        return decode(bytes)
    }

    /// Both measures narrow unconditionally (character count -> `maximumSessionCharacters`, UTF-8 byte count -> `maximumSessionBytes`).
    /// No shortcut of "return the original string when it is short enough": that shortcut is exactly what let 64 Chinese characters (192 bytes) slip past the byte cap.
    /// `removeLast` one character at a time removes a **whole grapheme**, so the result is always valid UTF-8 and the `decode` side never reads a broken sequence.
    static func clamp(_ session: String) -> String {
        var candidate = session
        if candidate.count > maximumSessionCharacters {
            candidate = String(candidate.prefix(maximumSessionCharacters))
        }
        while candidate.utf8.count > maximumSessionBytes, candidate.isEmpty == false {
            candidate.removeLast()
        }
        return candidate
    }

    private static func millisecondDigits(_ millis: Int64) -> [UInt8] {
        // The cap is 13 digits (≈ year 2286 AD): past it the value is pinned to the maximum rather than truncated to the first 13 digits -
        // truncating would make `decode` read back a moment completely different from the one written in, and round-trip reversibility is this layer's only correctness criterion.
        let clamped = min(max(0, millis), 9_999_999_999_999)
        let text = String(clamped)
        let padded = String(repeating: "0", count: millisDigits - text.count) + text
        return Array(padded.utf8)
    }
}

/// One frame's finished watermark dot matrix. Immutable - the timestamp must be taken only once per viewing session, otherwise every redraw would swap in a new set
/// of bits, the cells on screen would crawl (visible to the naked eye), and the timestamp read back in forensics would no longer stand for "this view".
///
/// Cell index -> screen position uses a **per-row offset** mapping (not a plain row-major tiling). The reason was measured in the self-tests:
/// the payload is mostly ASCII/UUID, the distribution of bit indices mod 8 is very uneven, and 1600 = 40 × 40, 40 = 8 × 5,
/// so a purely row-major `column = i % 40` squeezes all the bright cells of "the same mod-8 residue class" into a fixed 5 columns -
/// measurements on a typical payload give 244 bright cells covering only 34/40 columns. When whole columns are cropped away the bright cells vanish in blocks,
/// and after offsetting, the same payload covers all 40 columns (see the numbers in the /tmp self-test report).
struct PopopxWatermarkMatrix: Equatable, Sendable {
    let record: PopopxWatermarkBits
    /// The scattered cells, whose length is always `PopopxBlindWatermarkCodec.cellCount`.
    let cells: [Bool]
    /// The indices of the cells that need coloring (cheaper than walking 1600 cells and testing, and the only drawing list on the Canvas side).
    let onCells: [Int]

    /// For each row down, the whole row shifts right by this many cells. Having no common factor with `gridColumns` is enough (here 7 and 40 are coprime).
    static let rowStagger = 7

    func column(of index: Int) -> Int {
        let columns = PopopxBlindWatermarkCodec.gridColumns
        let shifted = index % columns + Self.rowStagger * row(of: index)
        return ((shifted % columns) + columns) % columns
    }

    func row(of index: Int) -> Int {
        index / PopopxBlindWatermarkCodec.gridColumns
    }

    /// Screen position -> cell index: the inverse of `column(of:)`; after counting rows and columns off a photo, the forensic side calls it to get the bit position back.
    /// This pair of functions is the watermark's only geometry contract: changing either one must change the other at the same time.
    static func cellIndex(row: Int, column: Int) -> Int {
        let columns = PopopxBlindWatermarkCodec.gridColumns
        let unshifted = ((column - rowStagger * row) % columns + columns) % columns
        return row * columns + unshifted
    }

    /// The 1600 cells read back off a photo (laid out by **visual** rows and columns, row-major) -> payload.
    /// The only difference from `PopopxBlindWatermarkCodec.record(from:)` is that the input here is the cells counted on the screen,
    /// while there the input is an array in the scatter domain.
    static func record(visualCells: [Bool]) -> PopopxWatermarkBits? {
        let columns = PopopxBlindWatermarkCodec.gridColumns
        guard visualCells.count == columns * PopopxBlindWatermarkCodec.gridRows else { return nil }
        var scattered = [Bool](repeating: false, count: visualCells.count)
        // The input index = the (row, column) counted on the screen; `cellIndex` sends it back to an index in the scatter domain.
        // The direction must not be reversed: `column(of:)` is "index -> screen", while what is wanted here is "screen -> index".
        for visualIndex in visualCells.indices {
            scattered[cellIndex(row: visualIndex / columns, column: visualIndex % columns)] = visualCells[visualIndex]
        }
        return PopopxBlindWatermarkCodec.record(from: scattered)
    }
}

// ================ POPUPX_PURE_CORE_END ================

// MARK: - Time-division-multiplexed dot-matrix overlay

/// The anti-shutter time-division-multiplexed dot-matrix overlay. When `isEnabled` is false it must be genuinely zero overhead (no ticker built, no drawing entered).
struct PopopxAntiPhotoRenderView: View {
    private let isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    var body: some View {
        // `if` rather than `.opacity(0)`: when it is off this branch does not exist at all - no driver built, no ticker built,
        // no entering the tile cache, no participating in a single draw. Opacity or `hidden()` both still pay inside layout and compositing.
        Group {
            if isEnabled {
                PopopxRollingShutterLayer()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The layer that actually does the work. The phase is written into `@State` by the driver's callback, so body recomputes once per frame - and what it recomputes is only
/// picking one reference between the two already cached `UIImage`s, with no allocation and no rasterization.
private struct PopopxRollingShutterLayer: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var driver: PopopxRollingShutterDriver?
    @State private var phase = 0

    var body: some View {
        Image(uiImage: PopopxShutterPatternAtlas.tile(forPhase: phase, displayScale: displayScale))
            .resizable(resizingMode: .tile)
            .opacity(PopopxShutterPatternAtlas.overlayOpacity)
            // No `.drawingGroup()`: this layer is already a single pattern fill, and wrapping it would rasterize the whole subtree
            // every frame into an offscreen MTLTexture - which is exactly what we are trying to save. Add it when merging several layers, and there are none here.
            .onAppear { installDriver() }
            .onDisappear { removeDriver() }
            .onChange(of: reduceMotion) { _, _ in installDriver() }
            .onChange(of: displayScale) { _, _ in installDriver() }
    }

    private func installDriver() {
        if driver == nil {
            driver = PopopxRollingShutterDriver()
        }
        // `@State`'s setter is nonmutating, so writing `phase` from an escaping closure here needs no mutable self.
        driver?.onPhaseChange = { nextPhase in phase = nextPhase }
        driver?.start(alternating: reduceMotion == false)
    }

    private func removeDriver() {
        driver?.stop()
        driver = nil
        phase = 0
    }
}

/// The 60Hz phase driver. The only user of `PopopxFrameTicker`, and the only object in this layer that hangs a CADisplayLink.
///
/// The main-thread convention comes from `PopopxFrameTicker` itself (it is attached to the main runloop), so this class does not add `@MainActor`:
/// adding it would only give the three lifecycle callbacks in the view one extra cross-actor hop each, and the destination of that hop is still the same main thread.
private final class PopopxRollingShutterDriver {
    var onPhaseChange: ((Int) -> Void)?

    private let ticker = PopopxFrameTicker(framesPerSecond: 60)
    private var frameIndex = 0

    /// Idempotent. With `alternating == false` (Reduce Motion) the link is not started and the phase stays at 0:
    /// the spatial-aliasing leg is kept and the temporal leg is given up - this trade-off is one of the few places in this file where safety yields to accessibility.
    func start(alternating: Bool) {
        guard alternating else {
            stop()
            return
        }
        if ticker.isRunning == false {
            ticker.onFrame = { [weak self] _ in
                self?.advance()
            }
            ticker.start()
        }
    }

    func stop() {
        ticker.stop()
        onPhaseChange = nil
    }

    deinit {
        // This class is not actor-isolated, so deinit can clean up directly; `ticker.stop()` will invalidate the link
        // and break onFrame, and it is a no-op when `link` is already nil, so calling it repeatedly together with `stop()` is safe.
        ticker.stop()
    }

    private func advance() {
        // Keep only the lowest digit: two tiles means two phases, so the index does not need (and should not) grow without bound.
        frameIndex = (frameIndex + 1) & 1
        onPhaseChange?(frameIndex)
    }
}

/// Cache for the two tiles. Generated once, reused for the lifetime of the process.
enum PopopxShutterPatternAtlas {
    /// Opacity of the overlay. The trade-off at 0.05: any higher and it clearly reads as "snow" and tires the eyes on long text; any lower and it barely affects the photo.
    /// This curve can only be tuned on a real device; this file cannot offer a safe value across devices, so it is a **parameter** rather than a constant.
    static let overlayOpacity: Double = 0.05

    /// key = device pixel ratio (rounded to an integer); value = [phase 0, phase 1]. Both tiles are generated together, so the fact that they are "generated only once"
    /// is guaranteed by the shape of this array and does not depend on call order.
    private static var cache: [Int: [UIImage]] = [:]

    static func tile(forPhase phase: Int, displayScale: CGFloat) -> UIImage {
        let steps = max(1, Int(displayScale.rounded()))
        if let built = cache[steps] {
            return built[phase & 1]
        }
        let built = (0 ... 1).map { rasterize(phase: $0, pixelRatio: steps) }
        // Cap: the pixel ratio only ever takes the real values 1/2/3, so the eviction rule is hardcoded merely to keep this dictionary from
        // growing alongside something odd over an extremely long process lifetime.
        if cache.count > 4 {
            cache.removeAll()
        }
        cache[steps] = built
        return built[phase & 1]
    }

    private static func rasterize(phase: Int, pixelRatio: Int) -> UIImage {
        let edge = PopopxShutterPattern.tilePixels
        let plane = PopopxShutterPattern.grayPlane(phase: phase)
        guard let provider = CGDataProvider(data: Data(plane) as CFData),
              let image = CGImage(
                  width: edge,
                  height: edge,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: edge,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            // Failing to build an 8x8 grayscale image = the CoreGraphics path is already dead. Return an empty image: the overlay stops working,
            // and not a single character of the message body is affected.
            return UIImage()
        }
        // scale = pixel ratio, so the tile's point size equals exactly its pixel size: when tiled, 1 image pixel = 1 device pixel.
        // This is not an aesthetic question: as soon as it is not 1:1 the system interpolates, and interpolation is itself a low pass, and the very thing
        // we are fighting is that low pass, so wiping our own high frequencies first would be self-disarmament.
        return UIImage(cgImage: image, scale: CGFloat(pixelRatio), orientation: .up)
    }
}

// MARK: - Spotlight reading mode

/// Spotlight reading mode: everything is blurred by default, and inside the `radius` circle under the finger it is sharp.
struct PopopxSpotlightTextView: View {
    private let text: String
    private let radius: CGFloat

    /// Blurred to this radius, the body text is unusable beyond 4pt, with not one character left to piece together; going larger brings no extra benefit
    /// and only spends more CoreImage blur radius.
    private static let blurRadius: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spotlightCenter = CGPoint.zero
    @State private var isFingerDown = false

    init(text: String, radius: CGFloat = 45) {
        self.text = text
        self.radius = radius
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            textLayer
                .blur(radius: PopopxSpotlightTextView.blurRadius)
            textLayer
                .mask { spotlightWindow }
        }
        .contentShape(Rectangle())
        // `simultaneousGesture` rather than `gesture`: the caller will very likely put this layer inside a ScrollView (long message body),
        // and an exclusive gesture would swallow scrolling, while the spotlight never advances by swiping anyway, so both must hold at once.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    spotlightCenter = value.location
                    isFingerDown = true
                }
                .onEnded { _ in isFingerDown = false }
        )
        // Visually this screen is one blur, but in accessibility it must be the entire message body: otherwise VoiceOver users would get a
        // deliberately ruined substitute.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// The clear window. The radius returns to 0 when the finger lifts, and a mask with radius 0 draws nothing, so the sharp copy on top
    /// vanishes as a whole, leaving only the blurred copy on screen ("restoring to full blur" lands here, rather than conditionally inserting views,
    /// which would rebuild the entire text subtree on every press).
    ///
    /// The animation hangs only off the **radius**, and off it before `.position`: the position that follows the finger must be immediate,
    /// and springing the position would give a halo lagging half a step behind the finger, exactly the most glaring failure shape of this mode.
    /// Reduce Motion takes this whole stretch of animation away (the radius opens and closes instantly); the dot matrix and the blur itself are unaffected.
    @ViewBuilder private var spotlightWindow: some View {
        let activeRadius = isFingerDown ? radius : 0
        Circle()
            .fill(
                RadialGradient(
                    colors: [.black, .black, .clear],
                    center: .center,
                    startRadius: activeRadius * 0.55,
                    endRadius: activeRadius
                )
            )
            .frame(width: activeRadius * 2, height: activeRadius * 2)
            .animation(PopopxMotion.animation(PopopxSpring.fluid, reduceMotion: reduceMotion), value: activeRadius)
            .position(spotlightCenter)
    }

    /// Two **exactly identical** text layers. The blurred draft and the clear copy must coincide word for word, so this function must not carry
    /// any modifier that appears on only one of the two paths; the difference between the two call sites is decided only by the outer layers (`.blur` / `.mask`).
    private var textLayer: some View {
        Text(text)
            .font(PopopxType.body)
            .foregroundStyle(PopopxPalette.label)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Line-by-line reading mode

/// Line-by-line reading mode against framing the shot: one line shows at a time, and it advances only while held down and dragged vertically.
struct PopopxTeleprompterTextView: View {
    private let text: String
    private let lines: [String]

    /// The drag distance for one step of advance. Using the `minHitTarget` token instead of making up a number: 44pt is the smallest displacement
    /// a finger can reliably make in one go, and also the HIG's lower bound on the distance of one clearly intended action.
    private static let pointsPerLine: CGFloat = PopopxMetrics.minHitTarget

    @State private var committedLine = 0
    @GestureState private var dragTranslation: CGFloat = 0

    init(text: String) {
        self.text = text
        self.lines = PopopxReadingLines.lines(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopopxMetrics.spaceS) {
            Text(currentLine)
                .font(PopopxType.body)
                .foregroundStyle(PopopxPalette.label)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: PopopxMetrics.space2XS) {
                ProgressView(value: progressValue, total: 1)
                    .tint(PopopxPalette.brand)
                HStack {
                    Text(hintText)
                        .font(PopopxType.microTag)
                    Spacer(minLength: PopopxMetrics.spaceXS)
                    Text(positionText)
                        .font(PopopxType.metricSmall)
                }
                .foregroundStyle(PopopxPalette.labelHint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { _ in
                    // Releasing rests on the current line: the position computed during the gesture is frozen, `@GestureState` returns to zero at the same moment,
                    // and the two cancel each other out, so there is neither a snap back nor an extra step.
                    committedLine = displayedIndex
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var currentLine: String {
        guard lines.isEmpty == false else { return text }
        return lines[displayedIndex]
    }

    /// Line advance is decided only by held-down plus vertical drag, and symmetrically: drag up one full step to move forward one, drag down one full step to move back one,
    /// and half a step never counts (`towardZero`), so there is no misreading where a light touch skips a line.
    private var displayedIndex: Int {
        guard lines.isEmpty == false else { return 0 }
        let steps = Int((dragTranslation / Self.pointsPerLine).rounded(.towardZero))
        return min(max(committedLine - steps, 0), lines.count - 1)
    }

    private var progressValue: Double {
        guard lines.count > 1 else { return lines.isEmpty ? 0 : 1 }
        return Double(displayedIndex) / Double(lines.count - 1)
    }

    private var positionText: String {
        guard lines.isEmpty == false else { return "0 / 0" }
        return "\(displayedIndex + 1) / \(lines.count)"
    }

    /// With an empty body this hint is more honest than "hold and drag up": the gesture is not broken, this message simply has no content.
    private var hintText: String {
        lines.count > 1 ? NSLocalizedString("Hold and drag up · release stops at the current line", comment: "secure reading") : NSLocalizedString("This message has no more content", comment: "secure reading")
    }
}

// MARK: - Blind watermark

/// Invisible blind watermark: device UUID + session id + millisecond timestamp encoded into a very low contrast dot matrix covering the whole screen.
///
/// It is a **surface**, not an overlay filter: every cell gets filled with one of the two near-black colours, so it must be drawn **under** the message body
/// (used as the background layer by the window manager / `PopopxSecureSheetView`). Drawing it above the body would wash the whole screen into near black,
/// which is not conservatism, that is hiding the message so nobody can see it.
struct PopopxBlindWatermarkOverlay: View {
    private let matrix: PopopxWatermarkMatrix?

    init(sessionIdentifier: String) {
        self.matrix = PopopxBlindWatermarkCache.matrix(
            forSession: sessionIdentifier,
            deviceIdentifier: UIDevice.current.identifierForVendor?.uuidString
        )
    }

    var body: some View {
        Canvas { context, size in
            let columns = CGFloat(PopopxBlindWatermarkCodec.gridColumns)
            let rows = CGFloat(PopopxBlindWatermarkCodec.gridRows)
            let cellWidth = size.width / columns
            let cellHeight = size.height / rows
            // Whole background = colour 0, one fill; below only the cells of colour 1 are added.
            // The background does **not** depend on whether matrix exists: this layer's contract is "an opaque near-black surface",
            // so when matrix is nil (payload over capacity, a fault on the encoding side) it should degrade to "a background without the watermark",
            // not degrade to transparent, because transparency would let the window background show straight through under the body, a harder failure to notice.
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(PopopxBlindWatermarkPalette.color(forRGB: PopopxBlindWatermarkCodec.rgb(isOn: false)))
            )
            guard let matrix else { return }
            for index in matrix.onCells {
                let rect = CGRect(
                    x: CGFloat(matrix.column(of: index)) * cellWidth,
                    y: CGFloat(matrix.row(of: index)) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                // Expand outward by half a pixel: Canvas fills are antialiased, so between adjacent cells a seam remains that is neither 0x010101
                // nor 0x000000, and that seam would make the claim "the whole matrix uses only two colours" untrue at the pixel level
                // and would add another layer of noise to a forensic reading. Overlapping the same colour changes no colour and only removes the seam.
                context.fill(
                    Path(rect.insetBy(dx: -0.5, dy: -0.5)),
                    with: .color(PopopxBlindWatermarkPalette.color(forRGB: PopopxBlindWatermarkCodec.rgb(isOn: true)))
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The mapping from the two near-black values to `Color`. Kept in one place so the drawing code and the numbers quoted in the docs cannot disagree.
enum PopopxBlindWatermarkPalette {
    static func color(forRGB rgb: UInt32) -> Color {
        Color.popopx(rgb)
    }
}

/// One-shot cache from session to dot matrix. Its only reason to exist is that the timestamp is taken **once per session**:
/// the view value is rebuilt repeatedly by its parent (the countdown fires once per second), and without this cache that means a new set of bits every second,
/// the cells on screen would crawl (visible to the eye, so the watermark is no longer invisible), and the decoded timestamp would no longer point at "this viewing".
enum PopopxBlindWatermarkCache {
    private static var matrices: [String: PopopxWatermarkMatrix] = [:]

    static func matrix(forSession sessionIdentifier: String, deviceIdentifier: String?) -> PopopxWatermarkMatrix? {
        if let cached = matrices[sessionIdentifier] {
            return cached
        }
        let record = PopopxWatermarkBits(
            deviceIdentifier: deviceIdentifier ?? "",
            sessionIdentifier: sessionIdentifier,
            // Milliseconds: the only "when" inside the watermark, and the only quantity that can be lined up against server time during post-hoc attribution.
            epochMillis: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        guard let built = PopopxBlindWatermarkCodec.matrix(for: record) else { return nil }
        if matrices.count > 8 {
            matrices.removeAll()
        }
        matrices[sessionIdentifier] = built
        return built
    }
}

#if DEBUG
private struct PopopxAntiPhotoGallery: View {
    @State private var mode = PopopxSecureReadMode.spotlight
    @State private var overlayOn = true

    private let sample = """
    Shenzhen North Station · Platform 3 · the 18:42 service
    The contact is the one in the grey coat; he holds a sheet of paper and what you need is on it.
    Leave no copy of this text on any device, and do not forward it.
    """

    var body: some View {
        PopopxSheetContainer(NSLocalizedString("Anti-photo reading preview", comment: "secure reading preview"), subtitle: "PopopxAntiPhotoRenderView") {
            PopopxSectionCard(NSLocalizedString("Reading mode", comment: "secure reading preview"), footnote: mode.note) {
                PopopxSegmentedControl(
                    PopopxSecureReadMode.allCases.map { .init(selection: $0, title: $0.title) },
                    title: \.title,
                    selection: $mode
                )
                PopopxDividerRow()
                PopopxToggleRow(NSLocalizedString("Dot-matrix overlay", comment: "secure reading preview"), note: NSLocalizedString("When it is off, no ticker is created and nothing is drawn", comment: "secure reading preview"), isOn: $overlayOn)
            }
            PopopxSectionCard(NSLocalizedString("Message body", comment: "secure reading preview")) {
                ZStack {
                    PopopxBlindWatermarkOverlay(sessionIdentifier: "preview-session")
                    Group {
                        switch mode {
                        case .spotlight: PopopxSpotlightTextView(text: sample)
                        case .teleprompter: PopopxTeleprompterTextView(text: sample)
                        }
                    }
                    .frame(minHeight: 220, alignment: .topLeading)
                    PopopxAntiPhotoRenderView(isEnabled: overlayOn)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(PopopxPalette.card, in: .rect(cornerRadius: PopopxMetrics.radiusCard))
            }
        }
        .background(PopopxPalette.base)
    }
}

private struct PopopxDividerRow: View {
    var body: some View {
        Rectangle()
            .fill(PopopxPalette.separator)
            .frame(height: PopopxMetrics.divider)
            .padding(.vertical, PopopxMetrics.spaceXS)
    }
}

struct PopopxAntiPhotoGallery_Previews: PreviewProvider {
    static var previews: some View {
        PopopxAntiPhotoGallery()
    }
}
#endif
