//
//  PopopxDuressAuthManager.swift
//  POPOPX (iOS)
//
//  [dual-password duress self-destruct · module 3] two 6-digit codes (regular + duress), PBKDF2-HMAC-SHA256 verifiers,
//  Keychain stores only derived values, Face ID/Touch ID quick unlock with consecutive-failure downgrade, a 12-word BIP-39 recovery phrase,
//  progressive cooldown modelled on the native iOS lock screen (with an optional wipe at the 10th attempt), and the **only copy in the whole app**
//  of the "wipe the storage and rebuild" routine `PopopxStorageWipe`.
//
//  ### Why the verifier goes through PBKDF2 while the upstream self-destruct code compares plaintext
//  Upstream stores the self-destruct code itself in the Keychain (`kcSelfDestructPassword`, POPOPXChat/KeyChain.swift:23),
//  and verification is `password == sdPassword` (LocalAuthView.swift:23). The Keychain is itself encrypted, so this is not
//  an obvious hole, but it has two consequences: first, getting hold of a Keychain dump (jailbroken device + iKeyDB) means getting the code itself,
//  second, there is no room to price it up — making it costlier means replacing the representation wholesale. This module, as the task requires, switches to
//  salt + PBKDF2-HMAC-SHA256(100_000), so from now on **no passphrase exists on disk**, only derived values.
//  ⚠️ This does not mean "those two upstream Keychain entries have disappeared": `kcAppPassword`/`kcSelfDestructPassword`
//  are still independent credentials stored in plaintext, still used by the upstream LA gate. `kcSelfDestructPassword` has four deletion points
//  （`PopopxStorageWipe.wipe`、`scrubCredentialHistory`、`migrateNativeEntryPassword`、
//  `retireGhostSelfDestructCode`）: once each on the full and the preserving self-destruct paths, once each on the two migration branches.
//  The reason migration deletes it in passing is that its only entry point
//  (`LocalAuthView`) went away together with `kcAppPassword`, so keeping it leaves a credential nobody can press and still makes the privacy settings
//  cell show "enabled" (that cell only reads the UserDefaults bool, not the Keychain). If the entry code was the first to go and
//  only this self-destruct code was left, that step becomes **having the owner type it once first** before deleting (`retireGhostSelfDestructCode`):
//  it is the only path in the whole migration where nothing else on hand can prove identity.
//  `kcAppPassword` gets one more route: it is only the entry code that, in `.passcode` mode,
//  `authenticate` compares verbatim (LocalAuthenticationUtils.swift:45, **not** the SQLCipher
//  library key — the library key is `kcDatabasePassword`, see POPOPXChat/API.swift:43); this module, when enabling/changing the
//  POPOPX entry password, verifies it first and then migrates it away, making the dual-password lock the only front-end authentication entry
//  (see `migrateNativeEntryPassword`). This item is written into the acceptance report; nothing is papered over.
//
//  ### Why the derivation is always done twice
//  If verifying the regular code and the duress code took different times (1 vs 2 derivations), a coercer with a stopwatch could tell which of the two he had
//  pressed. So `verify` unconditionally runs PBKDF2 **once on each of the two records** (if one is missing, an equivalent fixed salt supplies one extra
//  meaningless derivation), compute first, branch afterwards. This is the half of "zero anomalies" that lives in the time dimension — the 1.2 s floor in the UI
//  (`minimumFlowSeconds`) is the other half; both are written into the code rather than left to the UI's self-discipline.
//
//  ### The mnemonic phrase is this module's only "recoverable in plaintext" store, and that is what the view feature cost
//  The brief asked for two things at once: "viewable any time from the settings page" and "after normalization, derived through PBKDF2 into a hash stored in the Keychain".
//  A hash is one-way and cannot be viewed. So **two** records are stored here: `mnemonicAccount` holds the derived hash — the only one that takes part in the
//  comparison at reset time, in constant time, exactly isomorphic to the two codes; `mnemonicPhraseAccount` holds the normalized
//  plaintext and exists only for the single purpose of "view/backup". The price is stated plainly, not papered over: anyone with a Keychain dump can read the phrase back,
//  while the two codes remain only hashes. This is not a newly introduced attack surface — upstream's `kcAppPassword`/`kcSelfDestructPassword`
//  together with `kcDatabasePassword`, which holds the library key, are all stored in plaintext (POPOPXChat/KeyChain.swift:21-23),
//  and the first thing lost to such a dump was always the whole database anyway. Three compensations: viewing requires passing an identity gate first
//  (`verifyEntryPin` or `verifyIdentityWithBiometrics`; the emergency code does not count as passing; the same pair of gates also governs
//  the "regenerate a new set" question), both records carry `WhenUnlockedThisDeviceOnly`
//  (unreadable while locked, never travels with a device backup), and the self-destruct/reset/disarm paths all delete the two together.
//
//  ### Why the cooldown counter is not kept in UserDefaults
//  `failedAttemptCount` and the unfreeze moment live in the `lockoutAccount` Keychain record. Stored in UserDefaults,
//  "kill the app process and relaunch" would be a free reset — and kill-and-relaunch is precisely the first thing a coercer tries.
//  When it cannot be read, the **in-memory value is kept** rather than treated as zero (see `PopopxDuressKeychain.readLockout`).
//
//  ### Why PBKDF2 is implemented by hand here
//  The repository has no CommonCrypto bridge and no third-party option available (`git grep -i pbkdf2` finds only this task's prompt).
//  `CryptoKit` provides `HMAC<SHA256>`, and PBKDF2 is just 100_000 chained uses of it, ten lines. This is a deliberate trade:
//  a few more HMACs in exchange for zero new dependencies and zero build-setting changes (red line: no linker flags added to the target).
//  The implementation aligns itself with RFC 6070/7914; the known-answer pairs (`python3 -c "import hashlib; ..."`) are written in
//  the comments of `PopopxDuressCrypto`, and before submitting the code they were run to agreement with a standalone swift script — not speculation.
//
//  ### What is never allowed
//  1. No `exit(0)`/`abort()`: the process must stay alive, and an in-memory overlay blocks the interface (task red line + App Store 4.2.x).
//     The ready-made `PopopxPanicWipeManager` on the mesh side calls `exit` at the end by default, so this passes
//     `termination: nil` explicitly (the parameter accepts nil, see the comment at PanicWipeManager.swift:477), and admits in the report
//     that "the key is burned, the process is still alive".
//  2. Never `print`/`logger` any passphrase, salt, or derived value. Logs record only the stage name.
//  3. Sensor criteria do not lead here (see the module 1 header note). The only road here is keyboard entry.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SwiftUI
import POPOPXChat
import PopopxMeshUI

// MARK: - Account presentation strategy after an emergency wipe (choose one of three)

/// What kind of account is handed over after the wipe. The owner picks it on the settings page with `PopopxSegmentedControl`,
/// persisted in UserDefaults (JSON, because it carries associated values); **the duress flow reads it exactly once**
/// (see step A of `PopopxDuressAuthManager.submit`), and from then on only that in-memory copy is used,
/// because the wipe clears this key along with every trace of the whole module.
///
/// Default `.emptyProfile`: a freshly installed empty app explains itself without any fabricated content,
/// while three contacts that appeared out of nothing are something that **needs to be explained**. The other two take effect only if the owner explicitly chose them.
///
/// This type replaces the first round's `PopopxDuressRebuildMode` (choose one of two). With associated values it can no longer be
/// expressed as `CaseIterable`/`RawRepresentable`, so persistence became `Codable` JSON,
/// and the segmented control is assembled by the interface in the order of `segmentTitles` (`segmentIndex` is the only mapping rule).
enum PopopxDuressRetentionStrategy: Codable, Hashable, Sendable {
    /// Keep one chosen existing anonymous identity: physically delete every other identity and Cabin mapping, switch to `profileId`.
    /// `profileId` = `User.userId`（`POPOPXChat/ChatTypes.swift:31`，Int64），
    /// `displayName` is only a snapshot for people to read — the real criterion is always the id.
    case retainExistingProfile(profileId: Int64, displayName: String)
    /// Simulated smokescreen account: a random lifelike nickname + 2–3 fake contacts + harmless Chinese conversation inside the past 24 hours.
    case simulatedDecoy
    /// Brand-new blank account: creates one new profile only, zero contacts, zero messages, equivalent to just downloaded and installed.
    case emptyProfile

    /// The three segment titles of the segmented control; their order is the definition of `segmentIndex`. At most 5 characters per segment
    /// (`PopopxSegmentedControl` gives only one line, and anything longer is truncated).
    static let segmentTitles: [String] = [NSLocalizedString("Keep one profile", comment: ""), NSLocalizedString("Simulated decoy", comment: ""), NSLocalizedString("Empty account", comment: "")]

    static let defaultValue = PopopxDuressRetentionStrategy.emptyProfile

    var segmentIndex: Int {
        switch self {
        case .retainExistingProfile: return 0
        case .simulatedDecoy: return 1
        case .emptyProfile: return 2
        }
    }

    /// The index the segmented control taps back. **Out of range always falls back to the default**, no crash and no guessing: picking the wrong segment
    /// means handing over an account that does not look like his after the owner's data was wiped.
    static func fromSegmentIndex(_ index: Int) -> PopopxDuressRetentionStrategy {
        switch index {
        case 0: return .retainExistingProfile(profileId: 0, displayName: "")
        case 1: return .simulatedDecoy
        default: return .emptyProfile
        }
    }

    var label: String { Self.segmentTitles[segmentIndex] }

    var isRetainExisting: Bool {
        if case .retainExistingProfile = self { return true }
        return false
    }

    /// The identity id to be picked in the keep strategy; the other two have no such concept.
    var retainedProfileId: Int64? {
        if case let .retainExistingProfile(profileId, _) = self { return profileId }
        return nil
    }

    var note: String {
        switch self {
        case .retainExistingProfile:
            return NSLocalizedString("Keeps only the anonymous profile you chose; every other profile, the offline mesh Bluetooth mappings and every chat trace are physically deleted.", comment: "")
        case .simulatedDecoy:
            return NSLocalizedString("Rebuilds a lifelike account with an everyday nickname, a few familiar contacts and routine conversations from the last 24 hours.", comment: "")
        case .emptyProfile:
            return NSLocalizedString("Opens an app as if it had just been installed, with nothing fabricated in it.", comment: "")
        }
    }

    /// Reads the owner's preset back. **If it cannot be decoded, fall back to the default**: this data only affects "what account is handed over after the wipe",
    /// and rebuilding with a guessed strategy is worse than using the default; the default (blank account) happens to be the one least likely
    /// to produce anything extra.
    static func load(from defaults: UserDefaults = .standard) -> PopopxDuressRetentionStrategy {
        guard let data = defaults.data(forKey: DEFAULT_ANTI_THEFT_RETENTION_STRATEGY),
              let strategy = try? JSONDecoder().decode(PopopxDuressRetentionStrategy.self, from: data)
        else { return .defaultValue }
        return strategy
    }

    /// Writes to disk. On encoding failure the **key is deleted** rather than keeping the old value: keeping it means the interface shows A while the wipe runs B.
    /// Once deleted, `load` returns to the default, which matches the interface's "never chosen" behaviour.
    func store(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else {
            defaults.removeObject(forKey: DEFAULT_ANTI_THEFT_RETENTION_STRATEGY)
            return
        }
        defaults.set(data, forKey: DEFAULT_ANTI_THEFT_RETENTION_STRATEGY)
    }
}

// MARK: - Verdicts and errors

/// The verdict of one keyboard submission or biometric check.
///
/// For the **interface**, `.unlocked` and `.duress` must take the same branch: the two branches the overlay receives do the same thing
/// (`PopopxAppLockState.unlock()`), and `.duress` must not cause anything to be shown or hidden.
/// The reason it is still split into two cases is to leave a trace of this path in the type system, which makes auditing easier.
enum PopopxDuressAuthOutcome: Hashable, Sendable {
    case unlocked
    case duress
    case wrong
    case notConfigured
    /// Cooling down: `remaining` = how many seconds are left. **This branch must return before any derivation**,
    /// otherwise every press inside the lockout still pays 0.71 seconds and the interface looks as if it still accepted input.
    case lockedOut(remaining: TimeInterval)
}

/// Why configuring the two codes on the settings page can fail. All local validation, nothing to do with the network.
enum PopopxDuressSetupError: Error, Equatable, LocalizedError {
    /// Not exactly 6 ASCII digits.
    case malformedPin
    /// The two codes are identical — task red line: the regular code and the duress code must differ, otherwise "handing over the regular code" and "handing over the duress code"
    /// are the same action and the whole design fails.
    case pinsMustDiffer
    /// Setting the duress code before any regular code exists.
    case normalPinRequiredFirst
    /// The Keychain write was refused (device not unlocked, or the item is not writable).
    case keychainWriteFailed
    /// The native entry code (`kcAppPassword`) is still on, but the interface did not collect the one input used to confirm the migration.
    /// This branch is not "something was done wrong" but "one step still missing": before writing the new code, the old front door has to be closed properly.
    case nativePasscodeRequired
    /// Collected, but it does not match the one in `kcAppPassword`. **Nothing was changed** here — the old front door is still where it was,
    /// and the new front door was not installed either.
    case nativePasscodeIncorrect
    /// This device no longer has a native entry code, yet that self-destruct code (or the switch belonging to it) is still there: its only entry point was
    /// the entry-code keyboard, the keyboard went first, so it became a ghost credential nobody can press. Clearing it requires proving identity first;
    /// the reason and the full derivation are written in the "ghost self-destruct code" section of `migrateNativeEntryPassword`.
    case nativeSelfDestructCodeRequired
    /// Collected, but it does not match the plaintext one in `kcSelfDestructPassword`. **Nothing was changed**,
    /// the ghost state is left exactly as it was — it cannot be pressed, so keeping it is no more dangerous than deleting it, and a wrong deletion is irreversible.
    case nativeSelfDestructCodeIncorrect
    /// No mnemonic phrase has ever been generated, yet it is being viewed or used to reset. Keeping this apart from "wrong mnemonic" is necessary: the former is
    /// the owner having skipped a setup step (he should be told to do it), the latter is a real failure (it should enter the cooldown count).
    case mnemonicMissing
    /// The format itself is wrong: not 12 words, some word is not in the BIP-39 table, or the checksum does not recompute back.
    /// **This branch does not consume cooldown counts**, because it never even reached the "compare passphrase" step — a slip of the hand
    /// that can be decided locally (copying `watch` as `wach`) would also cost an attempt; the owner mistyping three times would be locked for 15 minutes,
    /// and that penalty is meant for "someone guessing", not for "someone transcribing".
    case mnemonicMalformed
    /// All 12 words are valid, but they do not match the stored one. This is a real failed attempt and consumes a count.
    case mnemonicIncorrect
    /// The gate that verifies the entry password (`verifyEntryPin`) was handed no password. That gate governs both "view the mnemonic phrase" and
    /// "regenerate a new set", so "no password was handed over" holds for both questions.
    case entryPinRequired
    /// The gate that verifies the entry password (`verifyEntryPin`) received something other than the current entry password (the emergency code also counts as wrong; see that method for the reason).
    case entryPinIncorrect
    /// The Face ID gate (`verifyIdentityWithBiometrics`) did not pass: the system cannot tell that it is usable, the switch is off,
    /// it has been downgraded to the keyboard, or the owner was not recognised. This sentence likewise applies to both the "view" and "regenerate" questions.
    /// The four cases are merged into one sentence because, for whoever is holding the phone, the difference between them has no meaning — the phrase was not shown
    /// and the phrase was not replaced; and for the owner, telling "Face ID is broken" from "Face ID did not recognise me" is done on the system settings side, not in this cell.
    case biometricDenied
    /// An attempt to verify during the cooldown: does nothing and returns the remaining seconds to the interface.
    case lockedOut(remaining: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .malformedPin: return NSLocalizedString("Enter exactly 6 digits", comment: "")
        case .pinsMustDiffer: return NSLocalizedString("The duress code cannot be the same as the normal code", comment: "")
        case .normalPinRequiredFirst: return NSLocalizedString("Set the normal code first", comment: "")
        case .keychainWriteFailed: return NSLocalizedString("Cannot write to secure storage, please try again later", comment: "")
        case .nativePasscodeRequired: return NSLocalizedString("Enter the entry passcode this device already uses, so the duplicate unlock keyboard can be removed", comment: "")
        case .nativePasscodeIncorrect: return NSLocalizedString("The existing entry passcode is incorrect; nothing was changed", comment: "")
        case .nativeSelfDestructCodeRequired: return NSLocalizedString("Enter the self-destruct code this device already uses, so it can be removed as well", comment: "")
        case .nativeSelfDestructCodeIncorrect: return NSLocalizedString("The existing self-destruct code is incorrect; nothing was changed", comment: "")
        case .mnemonicMissing: return NSLocalizedString("No recovery phrase has been generated yet; create one and write it down first", comment: "")
        case .mnemonicMalformed: return NSLocalizedString("The recovery phrase needs 12 standard English words; check them word by word and try again", comment: "")
        case .mnemonicIncorrect: return NSLocalizedString("The recovery phrase is incorrect", comment: "")
        case .entryPinRequired: return NSLocalizedString("Enter the current entry code first", comment: "")
        case .entryPinIncorrect: return NSLocalizedString("The entry code is incorrect; the recovery phrase was not shown", comment: "")
        case .biometricDenied: return NSLocalizedString("Face ID did not pass; the recovery phrase was not shown", comment: "")
        case let .lockedOut(remaining): return String(format: NSLocalizedString("Too many attempts, try again in %@", comment: ""), PopopxLockoutSchedule.phrase(remaining))
        }
    }
}

/// The result of one wipe. `failure` carries the stage name and no trace of any passphrase.
enum PopopxWipeOutcome: Equatable, Sendable {
    case success
    case failure(stage: String)
}

// MARK: - Verifier record

/// The record stored into the Keychain: **only** the salt and the derived value.
///
/// `iterations` is stored along with the record instead of referencing the constant, so that when the cost rises later (200_000, 400_000) old records
/// remain verifiable: changing the constant only affects newly generated records, so nobody ends up with "after the upgrade all codes are invalid".
struct PopopxDuressVerifier: Codable, Equatable {
    var version: Int
    var iterations: Int
    var salt: Data
    var hash: Data

    init(salt: Data, hash: Data, iterations: Int) {
        self.version = 1
        self.iterations = iterations
        self.salt = salt
        self.hash = hash
    }

    /// The record used to hold a place and even out the work: never written to disk, it only takes part in one real derivation.
    static func workloadPad(salt: Data) -> PopopxDuressVerifier {
        PopopxDuressVerifier(
            salt: salt,
            hash: Data(repeating: 0, count: PopopxDuressCrypto.hashBytes),
            iterations: PopopxDuressCrypto.iterations
        )
    }

    var encoded: Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> PopopxDuressVerifier? {
        try? JSONDecoder().decode(PopopxDuressVerifier.self, from: data)
    }
}

// MARK: - Passphrase derivation

/// Pure-function area: PBKDF2-HMAC-SHA256 and constant-time comparison.
///
/// This enum carries no `@MainActor`, so the derivation can be moved wholesale into `Task.detached`; 100_000
/// HMACs measure in the low hundreds of milliseconds on an A-series chip, and pressed against a 60Hz breathing animation that is one visible stutter,
/// and "stutter" is itself the only risk this interface is allowed to carry, so it must not be computed on the main thread.
enum PopopxDuressCrypto {
    static let saltBytes = 32
    static let hashBytes = 32
    static let iterations = 100_000

    /// Known-answer pairs: the implementation in this file was **extracted verbatim** and fed to
    /// `python3 -c "import hashlib; print(hashlib.pbkdf2_hmac('sha256', pw, salt, c, dk).hex())"`
    /// comparison, 8 groups all correct, two of them multi-block outputs (dkLen=48 and 6) meant to pin down the i2be counter and the concatenation boundary
    /// （`03ee63fb94ef677d779f4654f03a90103c4db92872578740f62727a0ab02cffb` /
    /// `3d22d31d46da4f54404f3b0f7ca2710ff49d4a9eb2fc44b68c6ef0050b13`），
    /// A single-block implementation cannot reveal a wrong endianness; only multi-block does. Equivalent standard vectors are in RFC 7914 §12
    /// （PBKDF2-HMAC-SHA256：P="password" S="salt" c=1 dkLen=32 →
    /// `120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b`，
    /// c=2 → `ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43`）。
    /// One measured derivation with c=100_000, dkLen=32 took **355ms** (this machine, arm64, run directly with `xcrun swift`),
    /// so the fixed two derivations of `verify` take about 0.7 seconds — this number directly decides whether the UI's 1.2 s floor is
    /// a budget that real work will punch through; see `PopopxDuressAuthManager.minimumFlowSeconds`.
    static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        outputCount: Int
    ) -> Data {
        guard iterations > 0, outputCount > 0 else { return Data() }
        let key = SymmetricKey(data: password)
        let blockCount = (outputCount + Int(SHA256.byteCount) - 1) / SHA256.byteCount
        var output = Data(capacity: blockCount * SHA256.byteCount)
        for index in 1...blockCount {
            // i2be(OctetCount) — in RFC 8018 the `i` of PBKDF2 must be 4 big-endian bytes,
            // writing it little-endian computes a different number, and it only shows up when blockCount > 1. Here only 1 block is produced,
            // but it is written to the specification so that a later increase of dkLen cannot silently change the algorithm.
            let counter = UInt32(index).bigEndian
            var blockSalt = salt
            blockSalt.append(contentsOf: withUnsafeBytes(of: counter) { Array($0) })
            var u = Data(HMAC<SHA256>.authenticationCode(for: blockSalt, using: key))
            var accumulator = u
            var round = 1
            while round < iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for byte in accumulator.startIndex..<accumulator.endIndex {
                    accumulator[byte] ^= u[byte]
                }
                round += 1
            }
            output.append(accumulator)
        }
        return output.prefix(outputCount)
    }

    /// Constant-time comparison: differences are accumulated into a bitwise operation, and in the end only the total is looked at.
    /// Unequal length fails outright — length is not a secret, and this module's two records always have the same length.
    static func matchesInConstantTime(_ candidate: Data, _ stored: Data) -> Bool {
        guard candidate.count == stored.count, !candidate.isEmpty else { return false }
        var difference: UInt8 = 0
        for offset in 0..<candidate.count {
            difference |= candidate[candidate.startIndex + offset] ^ stored[stored.startIndex + offset]
        }
        return difference == 0
    }

    /// 32-byte system random salt. `SecRandomCopyBytes` is the same source upstream uses to generate the database key
    /// (POPOPXChat/KeyChain.swift:42-45); no second convention such as `arc4random` is introduced.
    static func randomSalt() -> Data {
        randomBytes(count: saltBytes)
    }

    /// System random bytes of any length. On failure it returns **empty Data** instead of falling back to a timestamp: that would make the random value predictable,
    /// and a predictable salt is the same mistake as a predictable mnemonic entropy source. Callers must treat the empty value as "do not write to disk this time".
    static func randomBytes(count: Int) -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // When the system random source fails it must **not** fall back to a timestamp: that would make the salt predictable, which is exactly the problem salt exists to solve.
            // Better to write nothing than to write a false sense of security.
            return Data()
        }
        return Data(bytes)
    }
}

// MARK: - BIP-39 mnemonic phrase

/// The standard BIP-39 English wordlist and the generation/validation of 12-word mnemonic phrases.
///
/// ### Why a real wordlist and a real checksum, rather than "any 12 English words"
/// The brief asked for "12 standard English mnemonic words". "Standard" is not decoration: the wordlist pins every word to an 11 bit index,
/// 12 words are exactly 132 bit = 128 bit of entropy + 4 bit SHA-256 checksum. The checksum lets "one word copied wrong" be decided
/// **locally** (`validate` returns false) instead of waiting until PBKDF2 has finished comparing to find the whole string wrong —
/// the latter would count one slip of the hand against the ten attempts of the lock screen.
///
/// ### Wordlist source and recomputability
/// The wordlist is taken verbatim from bitcoin/bips' `bip-0039/english.txt`: 2048 lines, lexicographic order, unique, `[a-z]{3,8}`,
/// source file sha256 = `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
/// The literal below was cut by a script at 16 words per line (not hand-copied) and, read back, equals the source file item by item —
/// index = position in the wordlist, so one word out of order misnumbers every word after it; this must be recomputable.
enum PopopxBIP39 {
    /// 12 words = 128 bit entropy + 4 bit checksum = 132 bit = 12 × 11 bit.
    static let wordCount = 12
    /// Bytes of entropy: 128 bit. That is exactly the 12-word tier in BIP-39, not "just take 16 bytes".
    static let entropyBytes = 16

    static let englishWords: [String] = {
        let packed = """
        abandon ability able about above absent absorb abstract absurd abuse access accident account accuse achieve acid
        acoustic acquire across act action actor actress actual adapt add addict address adjust admit adult advance
        advice aerobic affair afford afraid again age agent agree ahead aim air airport aisle alarm album
        alcohol alert alien all alley allow almost alone alpha already also alter always amateur amazing among
        amount amused analyst anchor ancient anger angle angry animal ankle announce annual another answer antenna antique
        anxiety any apart apology appear apple approve april arch arctic area arena argue arm armed armor
        army around arrange arrest arrive arrow art artefact artist artwork ask aspect assault asset assist assume
        asthma athlete atom attack attend attitude attract auction audit august aunt author auto autumn average avocado
        avoid awake aware away awesome awful awkward axis baby bachelor bacon badge bag balance balcony ball
        bamboo banana banner bar barely bargain barrel base basic basket battle beach bean beauty because become
        beef before begin behave behind believe below belt bench benefit best betray better between beyond bicycle
        bid bike bind biology bird birth bitter black blade blame blanket blast bleak bless blind blood
        blossom blouse blue blur blush board boat body boil bomb bone bonus book boost border boring
        borrow boss bottom bounce box boy bracket brain brand brass brave bread breeze brick bridge brief
        bright bring brisk broccoli broken bronze broom brother brown brush bubble buddy budget buffalo build bulb
        bulk bullet bundle bunker burden burger burst bus business busy butter buyer buzz cabbage cabin cable
        cactus cage cake call calm camera camp can canal cancel candy cannon canoe canvas canyon capable
        capital captain car carbon card cargo carpet carry cart case cash casino castle casual cat catalog
        catch category cattle caught cause caution cave ceiling celery cement census century cereal certain chair chalk
        champion change chaos chapter charge chase chat cheap check cheese chef cherry chest chicken chief child
        chimney choice choose chronic chuckle chunk churn cigar cinnamon circle citizen city civil claim clap clarify
        claw clay clean clerk clever click client cliff climb clinic clip clock clog close cloth cloud
        clown club clump cluster clutch coach coast coconut code coffee coil coin collect color column combine
        come comfort comic common company concert conduct confirm congress connect consider control convince cook cool copper
        copy coral core corn correct cost cotton couch country couple course cousin cover coyote crack cradle
        craft cram crane crash crater crawl crazy cream credit creek crew cricket crime crisp critic crop
        cross crouch crowd crucial cruel cruise crumble crunch crush cry crystal cube culture cup cupboard curious
        current curtain curve cushion custom cute cycle dad damage damp dance danger daring dash daughter dawn
        day deal debate debris decade december decide decline decorate decrease deer defense define defy degree delay
        deliver demand demise denial dentist deny depart depend deposit depth deputy derive describe desert design desk
        despair destroy detail detect develop device devote diagram dial diamond diary dice diesel diet differ digital
        dignity dilemma dinner dinosaur direct dirt disagree discover disease dish dismiss disorder display distance divert divide
        divorce dizzy doctor document dog doll dolphin domain donate donkey donor door dose double dove draft
        dragon drama drastic draw dream dress drift drill drink drip drive drop drum dry duck dumb
        dune during dust dutch duty dwarf dynamic eager eagle early earn earth easily east easy echo
        ecology economy edge edit educate effort egg eight either elbow elder electric elegant element elephant elevator
        elite else embark embody embrace emerge emotion employ empower empty enable enact end endless endorse enemy
        energy enforce engage engine enhance enjoy enlist enough enrich enroll ensure enter entire entry envelope episode
        equal equip era erase erode erosion error erupt escape essay essence estate eternal ethics evidence evil
        evoke evolve exact example excess exchange excite exclude excuse execute exercise exhaust exhibit exile exist exit
        exotic expand expect expire explain expose express extend extra eye eyebrow fabric face faculty fade faint
        faith fall false fame family famous fan fancy fantasy farm fashion fat fatal father fatigue fault
        favorite feature february federal fee feed feel female fence festival fetch fever few fiber fiction field
        figure file film filter final find fine finger finish fire firm first fiscal fish fit fitness
        fix flag flame flash flat flavor flee flight flip float flock floor flower fluid flush fly
        foam focus fog foil fold follow food foot force forest forget fork fortune forum forward fossil
        foster found fox fragile frame frequent fresh friend fringe frog front frost frown frozen fruit fuel
        fun funny furnace fury future gadget gain galaxy gallery game gap garage garbage garden garlic garment
        gas gasp gate gather gauge gaze general genius genre gentle genuine gesture ghost giant gift giggle
        ginger giraffe girl give glad glance glare glass glide glimpse globe gloom glory glove glow glue
        goat goddess gold good goose gorilla gospel gossip govern gown grab grace grain grant grape grass
        gravity great green grid grief grit grocery group grow grunt guard guess guide guilt guitar gun
        gym habit hair half hammer hamster hand happy harbor hard harsh harvest hat have hawk hazard
        head health heart heavy hedgehog height hello helmet help hen hero hidden high hill hint hip
        hire history hobby hockey hold hole holiday hollow home honey hood hope horn horror horse hospital
        host hotel hour hover hub huge human humble humor hundred hungry hunt hurdle hurry hurt husband
        hybrid ice icon idea identify idle ignore ill illegal illness image imitate immense immune impact impose
        improve impulse inch include income increase index indicate indoor industry infant inflict inform inhale inherit initial
        inject injury inmate inner innocent input inquiry insane insect inside inspire install intact interest into invest
        invite involve iron island isolate issue item ivory jacket jaguar jar jazz jealous jeans jelly jewel
        job join joke journey joy judge juice jump jungle junior junk just kangaroo keen keep ketchup
        key kick kid kidney kind kingdom kiss kit kitchen kite kitten kiwi knee knife knock know
        lab label labor ladder lady lake lamp language laptop large later latin laugh laundry lava law
        lawn lawsuit layer lazy leader leaf learn leave lecture left leg legal legend leisure lemon lend
        length lens leopard lesson letter level liar liberty library license life lift light like limb limit
        link lion liquid list little live lizard load loan lobster local lock logic lonely long loop
        lottery loud lounge love loyal lucky luggage lumber lunar lunch luxury lyrics machine mad magic magnet
        maid mail main major make mammal man manage mandate mango mansion manual maple marble march margin
        marine market marriage mask mass master match material math matrix matter maximum maze meadow mean measure
        meat mechanic medal media melody melt member memory mention menu mercy merge merit merry mesh message
        metal method middle midnight milk million mimic mind minimum minor minute miracle mirror misery miss mistake
        mix mixed mixture mobile model modify mom moment monitor monkey monster month moon moral more morning
        mosquito mother motion motor mountain mouse move movie much muffin mule multiply muscle museum mushroom music
        must mutual myself mystery myth naive name napkin narrow nasty nation nature near neck need negative
        neglect neither nephew nerve nest net network neutral never news next nice night noble noise nominee
        noodle normal north nose notable note nothing notice novel now nuclear number nurse nut oak obey
        object oblige obscure observe obtain obvious occur ocean october odor off offer office often oil okay
        old olive olympic omit once one onion online only open opera opinion oppose option orange orbit
        orchard order ordinary organ orient original orphan ostrich other outdoor outer output outside oval oven over
        own owner oxygen oyster ozone pact paddle page pair palace palm panda panel panic panther paper
        parade parent park parrot party pass patch path patient patrol pattern pause pave payment peace peanut
        pear peasant pelican pen penalty pencil people pepper perfect permit person pet phone photo phrase physical
        piano picnic picture piece pig pigeon pill pilot pink pioneer pipe pistol pitch pizza place planet
        plastic plate play please pledge pluck plug plunge poem poet point polar pole police pond pony
        pool popular portion position possible post potato pottery poverty powder power practice praise predict prefer prepare
        present pretty prevent price pride primary print priority prison private prize problem process produce profit program
        project promote proof property prosper protect proud provide public pudding pull pulp pulse pumpkin punch pupil
        puppy purchase purity purpose purse push put puzzle pyramid quality quantum quarter question quick quit quiz
        quote rabbit raccoon race rack radar radio rail rain raise rally ramp ranch random range rapid
        rare rate rather raven raw razor ready real reason rebel rebuild recall receive recipe record recycle
        reduce reflect reform refuse region regret regular reject relax release relief rely remain remember remind remove
        render renew rent reopen repair repeat replace report require rescue resemble resist resource response result retire
        retreat return reunion reveal review reward rhythm rib ribbon rice rich ride ridge rifle right rigid
        ring riot ripple risk ritual rival river road roast robot robust rocket romance roof rookie room
        rose rotate rough round route royal rubber rude rug rule run runway rural sad saddle sadness
        safe sail salad salmon salon salt salute same sample sand satisfy satoshi sauce sausage save say
        scale scan scare scatter scene scheme school science scissors scorpion scout scrap screen script scrub sea
        search season seat second secret section security seed seek segment select sell seminar senior sense sentence
        series service session settle setup seven shadow shaft shallow share shed shell sheriff shield shift shine
        ship shiver shock shoe shoot shop short shoulder shove shrimp shrug shuffle shy sibling sick side
        siege sight sign silent silk silly silver similar simple since sing siren sister situate six size
        skate sketch ski skill skin skirt skull slab slam sleep slender slice slide slight slim slogan
        slot slow slush small smart smile smoke smooth snack snake snap sniff snow soap soccer social
        sock soda soft solar soldier solid solution solve someone song soon sorry sort soul sound soup
        source south space spare spatial spawn speak special speed spell spend sphere spice spider spike spin
        spirit split spoil sponsor spoon sport spot spray spread spring spy square squeeze squirrel stable stadium
        staff stage stairs stamp stand start state stay steak steel stem step stereo stick still sting
        stock stomach stone stool story stove strategy street strike strong struggle student stuff stumble style subject
        submit subway success such sudden suffer sugar suggest suit summer sun sunny sunset super supply supreme
        sure surface surge surprise surround survey suspect sustain swallow swamp swap swarm swear sweet swift swim
        swing switch sword symbol symptom syrup system table tackle tag tail talent talk tank tape target
        task taste tattoo taxi teach team tell ten tenant tennis tent term test text thank that
        theme then theory there they thing this thought three thrive throw thumb thunder ticket tide tiger
        tilt timber time tiny tip tired tissue title toast tobacco today toddler toe together toilet token
        tomato tomorrow tone tongue tonight tool tooth top topic topple torch tornado tortoise toss total tourist
        toward tower town toy track trade traffic tragic train transfer trap trash travel tray treat tree
        trend trial tribe trick trigger trim trip trophy trouble truck true truly trumpet trust truth try
        tube tuition tumble tuna tunnel turkey turn turtle twelve twenty twice twin twist two type typical
        ugly umbrella unable unaware uncle uncover under undo unfair unfold unhappy uniform unique unit universe unknown
        unlock until unusual unveil update upgrade uphold upon upper upset urban urge usage use used useful
        useless usual utility vacant vacuum vague valid valley valve van vanish vapor various vast vault vehicle
        velvet vendor venture venue verb verify version very vessel veteran viable vibrant vicious victory video view
        village vintage violin virtual virus visa visit visual vital vivid vocal voice void volcano volume vote
        voyage wage wagon wait walk wall walnut want warfare warm warrior wash wasp waste water wave
        way wealth weapon wear weasel weather web wedding weekend weird welcome west wet whale what wheat
        wheel when where whip whisper wide width wife wild will win window wine wing wink winner
        winter wire wisdom wise wish witness wolf woman wonder wood wool word work world worry worth
        wrap wreck wrestle wrist write wrong yard year yellow you young youth zebra zero zone zoo
        """
        return packed.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }()

    /// Normalization: strip leading and trailing whitespace, lowercase, collapse any run of whitespace into a single space.
    /// `lowercased()` uses the Unicode invariable mapping (not the `lowercased(with:)` kind),
    /// so an `I` under a Turkish locale is not folded into `ı` — that would make a correctly copied mnemonic never match.
    static func normalize(_ phrase: String) -> String {
        phrase.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizedWords(_ phrase: String) -> [String] {
        let normalized = normalize(phrase)
        return normalized.isEmpty ? [] : normalized.components(separatedBy: " ")
    }

    /// Take the 11 bits starting at bit `offset`, MSB first.
    private static func elevenBits(atBit offset: Int, in bytes: [UInt8]) -> Int {
        var value = 0
        for step in 0..<11 {
            let position = offset + step
            let byte = bytes[position / 8]
            let bit = Int((byte >> (7 - position % 8)) & 1)
            value = (value << 1) | bit
        }
        return value
    }

    /// Generation: 128 bit system random entropy → 4 bit SHA-256 checksum → 12 words.
    /// When the entropy source fails (returns empty) there is **no downgrade**; nil is returned so the caller fails explicitly.
    static func generate() -> [String]? {
        let entropy = PopopxDuressCrypto.randomBytes(count: entropyBytes)
        guard entropy.count == entropyBytes else { return nil }
        // The digest is first turned into a `[UInt8]` before taking the first byte: a bare `.first` on `SHA256Digest` resolves to
        // the `first(where:)` function value (the compiler reports "condition binding is not an optional type", and neither reading reaches the byte),
        // while an array's `first` means exactly what it says. SHA-256 is always 32 bytes, so this line can never actually take nil.
        let digest = [UInt8](SHA256.hash(data: entropy))
        guard let checksum = digest.first else { return nil }
        var stream = [UInt8](entropy)
        // The checksum uses only the first CS(=4) bits, placed in the **high** nibble of the next byte; reading is bit by bit, so the spare low nibble is never touched.
        stream.append(checksum & 0xF0)
        return (0..<wordCount).map { elevenBits(atBit: $0 * 11, in: stream) }.map { englishWords[$0] }
    }

    /// Validation: word count, whether every word is in the table, whether the checksum recomputes back. A third of input errors are blocked right here.
    static func validate(_ words: [String]) -> Bool {
        guard words.count == wordCount else { return false }
        var indices = [Int]()
        indices.reserveCapacity(wordCount)
        for word in words {
            guard let index = englishWords.firstIndex(of: word) else { return false }
            indices.append(index)
        }
        // 12 × 11 bit written back into 17 bytes (in the last byte only the low 4 bits are the checksum, the rest stay empty).
        var stream = [UInt8](repeating: 0, count: (wordCount * 11 + 7) / 8)
        for (slot, index) in indices.enumerated() {
            for step in 0..<11 {
                let bit = (index >> (10 - step)) & 1
                let position = slot * 11 + step
                if bit & 1 == 1 { stream[position / 8] |= 1 << (7 - position % 8) }
            }
        }
        let entropy = Data(stream.prefix(entropyBytes))
        let expected = [UInt8](SHA256.hash(data: entropy)).first.map { $0 & 0xF0 } ?? 0
        let got = stream[entropyBytes] & 0xF0
        return expected == got
    }

    static func validate(phrase: String) -> Bool {
        validate(normalizedWords(phrase))
    }
}

// MARK: - Progressive cooldown schedule

/// The cooldown table modelled on the native iOS lock screen. **Pure functions**, so that a unit test can check it cell by cell.
///
/// Why the cooldown step is independent of "whether it is the same kind of input": the brief merges wrong password and wrong mnemonic into the same counter,
/// and that is right — a coercer gets one table, not two; two tables would be telling him "typing 12 words pays off better".
enum PopopxLockoutSchedule {
    /// The first 4 attempts only report the error, no lock.
    static let freeAttempts = 4
    /// The 10th attempt: wipes the data if the switch is on.
    static let wipeThreshold = 10
    /// The default lock duration from the 8th attempt on, and also the duration of the 10th and every later attempt when wiping is off.
    static let finalLockSeconds: TimeInterval = 3_600

    /// Attempts 5/6/7 each lock one step higher; attempts 8 and 9 both lock at the ceiling.
    static func lockoutSeconds(afterAttemptCount count: Int) -> TimeInterval {
        switch count {
        case ..<(freeAttempts + 1): return 0
        case 5: return 60
        case 6: return 300
        case 7: return 900
        default: return finalLockSeconds
        }
    }

    /// Turns the remaining seconds into human words such as "4 min 59 s". **Three places share this one function**: the countdown in the middle of the overlay,
    /// the message of `PopopxDuressSetupError.lockedOut`, and the escalating table on the settings page. The same remaining duration read out in three
    /// places as three different shapes ("300 seconds" / "5 minutes" / "05:00") is worse than one uniformly coarser reading —
    /// the owner would suspect the three numbers are not about the same thing.
    ///
    /// Rounds up: the countdown must never produce "try again in 0 seconds", still locked while claiming the time is up.
    static func phrase(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let rest = whole % 60
        if hours > 0 { return minutes > 0 ? String(format: NSLocalizedString("%1$lld h %2$lld min", comment: ""), hours, minutes) : String(format: NSLocalizedString("%lld h", comment: ""), hours) }
        if minutes > 0 { return rest > 0 ? String(format: NSLocalizedString("%1$lld min %2$lld s", comment: ""), minutes, rest) : String(format: NSLocalizedString("%lld min", comment: ""), minutes) }
        return String(format: NSLocalizedString("%lld s", comment: ""), rest)
    }
}

/// The cooldown record that lands in the Keychain.
///
/// `lockoutEndTimestamp` is a **wall-clock** timestamp rather than a monotonic clock: the only reason this record exists is
/// "still there after killing the process and reopening it", and `DispatchTime` stops meaning anything once it leaves the process. Honest boundary — the owner can
/// move the system time forward to unfreeze early, and this layer cannot stop that; what it does stop is the other half: `failedAttempts` is likewise on disk,
/// so adjusting the clock and going on guessing only walks all the way to the gate at attempt 10.
struct PopopxLockoutRecord: Codable, Equatable {
    var failedAttempts: Int
    var lockoutEndTimestamp: Double?
}

// MARK: - Verifier storage

/// The dual-password feature's own Keychain items.
///
/// Not reusing `KeyChainItem`: it only stores and reads `String`, and its access level is
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (KeyChain.swift:13). The task requires
/// `WhenUnlockedThisDeviceOnly` — with the device locked even the derived value cannot be read; that is the layer behind "a coercer staring at the lock screen
/// still cannot get the verifier". So the Security queries are written here by hand, reusing upstream's access group
/// (`PDBA6XRBQT.com.popopxchat.popopx`; KeyChain.swift:14 is `private`, so its value is restated here),
/// so that items do not land in the wrong group and become unreadable after a reinstall.
enum PopopxDuressKeychain {
    static let normalAccount = "popopx.duress.normal"
    static let duressAccount = "popopx.duress.duress"
    /// Derived hash of the 12-word mnemonic phrase. **Independent of** `normalAccount`: clearing the entry code does not clear the recovery ability with it,
    /// and conversely using the mnemonic to swap in a new entry code does not invalidate this phrase (the copy the owner wrote on paper stays valid).
    /// **The comparison accepts only this record** and never reads `mnemonicPhraseAccount` — see the reason on the record below.
    static let mnemonicAccount = "popopx.duress.mnemonic"
    /// The mnemonic's plaintext (those 12 normalized words), existing **only for the settings page's "view"**.
    /// The file header's section "the mnemonic is this module's only recoverable-in-plaintext store" documents the whole of this trade,
    /// and why it is no weaker than the plaintext items upstream already has.
    static let mnemonicPhraseAccount = "popopx.duress.mnemonic-phrase"
    /// Cooldown record: consecutive failure count + unfreeze moment. **Not** in `UserDefaults`; see `PopopxLockoutRecord` for the reason.
    static let lockoutAccount = "popopx.duress.lockout"

    private static let service = "popopx.duress"
    private static let accessGroup = "PDBA6XRBQT.com.popopxchat.popopx"

    private static func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(iOS) && !targetEnvironment(simulator)
        query[kSecAttrAccessGroup as String] = accessGroup
        #endif
        return query
    }

    static func read(_ account: String) -> PopopxDuressVerifier? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return PopopxDuressVerifier.decode(data)
    }

    static func write(_ verifier: PopopxDuressVerifier, account: String) -> Bool {
        guard let data = verifier.encoded else { return false }
        var query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Delete. The return code is not checked for `errSecItemNotFound`: for a self-destruct, "it was never there" is already done.
    @discardableResult
    static func delete(_ account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary) == errSecSuccess
    }

    static func exists(_ account: String) -> Bool {
        read(account) != nil
    }

    /// Reads one plaintext item (used by the mnemonic plaintext). Kept separate from `read(_:)` instead of reusing it because the latter decodes
    /// the JSON of `PopopxDuressVerifier`: stuffing a plaintext phrase into that type would make "this record is a hash" invisible
    /// at the type level, and that distinction is exactly what this module most needs to make visible.
    static func readString(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes one plaintext item, with the **same** accessibility as the two verifier records (`WhenUnlockedThisDeviceOnly`):
    /// this record holds plaintext that can be turned back into a secret, so downgrading it to `AfterFirstUnlock` trades the wrong thing for cheapness.
    @discardableResult
    static func writeString(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        var query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Cooldown record

    /// Reads the cooldown record. **Returns nil when it cannot be read**, leaving the caller to keep the in-memory value — treating "read failed" as "never failed"
    /// would mean one Keychain hiccup hands the attacker 4 free attempts, so this side prefers to stay locked rather than let through.
    static func readLockout() -> PopopxLockoutRecord? {
        var query = baseQuery(lockoutAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let record = try? JSONDecoder().decode(PopopxLockoutRecord.self, from: data)
        else { return nil }
        return record
    }

    /// Writes the cooldown record using "update first, add if missing": clear-then-add would turn any failed write into **deleting the old record too**,
    /// and this record says "how many times this person has already guessed wrong" — wiping it hands those attempts back.
    ///
    /// The accessibility used is `AfterFirstUnlock`, **deliberately different from the three credential records**: those three are read only while the user is typing,
    /// so being unable to read them before unlocking changes nothing; this record is the countdown itself, and when the app is relaunched after being suspended
    /// (the interface may not be unlocked yet at that moment) it must still be able to read "how many minutes are left", otherwise
    /// `errSecInteractionNotAllowed` would make a 60-minute cooldown look like it had already ended.
    /// It contains no credentials at all, only the count and the moment.
    static func writeLockout(_ record: PopopxLockoutRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let query = baseQuery(lockoutAccount)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            logger.error("duress lockout: keychain update failed \(status)")
            return false
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess { return true }
        logger.error("duress lockout: keychain add failed \(added)")
        return false
    }
}

// MARK: - Wipe and rebuild (the only copy in the whole app)

/// "Wipe the identities on this device, then hand over a clean, usable app".
///
/// Upstream, this code lives in `LocalAuthView.deleteStorageAndRestart` (Shared/Views/LocalAuth/LocalAuthView.swift),
/// originally a 56-line private method. This module needs the same thing, so **it was moved out into the single implementation and upstream now calls it**
/// (upstream is left with one `PopopxStorageWipe.run` call) rather than copied: the price of a copy is that someday only one side gets changed, and nobody remembers to check which side was changed.
///
/// The order is load-bearing, and every item has a reason:
/// 1. wait for `ctrlInitInProgress` to settle — closing the store mid-initialisation leaves a half-open handle;
/// 2. stop the chat thread (`stopChatAsync`);
/// 3. close the store (`chatCloseStore`) — iOS may refuse to delete files while the store is still open, see the original upstream comment;
/// 4. burn the mesh identities (`PopopxMeshIdentityWiper`) — must happen before deleting files, because it touches the sandbox itself;
/// 5. delete the database + all media/temporary files (`deleteAppDatabaseAndFiles`, from FileUtils.swift:110,
///    covering chat.db / agent.db / backups / exports / the temporary directory / the wallpaper directory / the
///    XFTP receiving directories that `deleteAppFiles()` handles, and it deletes `kcDatabasePassword` in passing);
/// 6. clear what has already been rendered in memory — the overlay covers the screen first, then the clearing proceeds, avoiding "the previous message still on screen during the rebuild";
/// 7. delete all passphrase-type Keychain items (two from upstream + five from this module: the two codes, the mnemonic's hash and plaintext,
///    the cooldown record). The two mnemonic records must die with the codes: the wipe's promise is "no recoverable identity remains on this device",
///    and leaving a backup that can reset the entry password voids that promise on the spot; the same goes for the cooldown record, which is itself the
///    fingerprint of "brute-force protection was once enabled here".
/// 8. clear notifications;
/// 9. rebuild the control layer, create a new user, start the thread;
/// 10. hand back to the caller for the aftermath (the duress path installs the smokescreen identity here).
enum PopopxStorageWipe {
    struct Options {
        /// The code written back to upstream's `kcAppPassword` after the wipe. The upstream self-destruct path passes "the self-destruct code itself"
        /// (behaviour: the device still has a lock, and the lock is this very code). The duress path passes nil — passing nil takes exactly
        /// the `kcAppPassword.remove()` branch inside `wipe`; the smokescreen must be enterable directly, and the fallback code
        /// should live only in this module's one verifier record; living in two places at once means reinstalling the second keyboard that was just removed.
        /// The "database passphrase" is deliberately not discussed here: `kcAppPassword` has nothing to do with SQLCipher, the library key is
        /// `kcDatabasePassword`, and the rebuilt new store has `chatMigrateInit` generate its own random key
        /// （POPOPXChat/API.swift:34-42）。
        var reinstatesAppPasscode: String?
        /// Display name of the newly created user. The upstream self-destruct path reads `DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME`;
        /// the duress path takes the simulated name supplied by module 4.
        var displayName: String?
        /// Whether to also switch off all of this module's anti-theft toggles. The duress path must be true — a rebuilt simulated identity
        /// carrying a runtime state of "anti-theft lock enabled, rebuild mode = simulated smokescreen" is telling the visitor that something real used to be here.
        var disarmsAntiTheft: Bool
        /// Hook for step 10. Async, on the main actor; throwing does not change the fact that the wipe itself succeeded.
        var afterRebuild: (@MainActor () async -> Void)?
    }

    /// Async version: the duress path uses it, which lets the whole sequence be awaited until it is really done before deciding when to dismiss the overlay.
    @MainActor
    static func wipe(options: Options) async -> PopopxWipeOutcome {
        let m = ChatModel.shared
        do {
            while m.ctrlInitInProgress {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if m.chatRunning == true {
                try await stopChatAsync()
            }
            if m.chatInitialized {
                chatCloseStore()
            }
            await PopopxMeshIdentityWiper.wipe()
            await deleteStorageFilesOffMain()
            clearRenderedState(m)
            if let passcode = options.reinstatesAppPasscode {
                _ = kcAppPassword.set(passcode)
            } else {
                _ = kcAppPassword.remove()
            }
            _ = kcSelfDestructPassword.remove()
            PopopxDuressKeychain.delete(PopopxDuressKeychain.normalAccount)
            PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
            PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicAccount)
            PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicPhraseAccount)
            PopopxDuressKeychain.delete(PopopxDuressKeychain.lockoutAccount)
            await NtfManager.shared.removeAllNotifications()
            UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
            UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME)
            if options.disarmsAntiTheft {
                PopopxAntiTheftSwitches.eraseAllTraces()
            }
            m.chatDbChanged = true
            m.chatInitialized = false
            resetChatCtrl()
            try initializeChat(start: true)
            m.chatDbChanged = false
            AppChatState.shared.set(.active)
            if m.currentUser == nil {
                var profile: Profile? = nil
                if let displayName = options.displayName, !displayName.isEmpty {
                    profile = Profile(displayName: displayName, fullName: "")
                }
                m.currentUser = try apiCreateActiveUser(profile, pastTimestamp: true)
                onboardingStageDefault.set(.onboardingComplete)
                m.onboardingStage = .onboardingComplete
                try startChat()
            }
            if let afterRebuild = options.afterRebuild {
                await afterRebuild()
            }
            return .success
        } catch {
            // Only the stage is recorded, never any input content. `localizedDescription` comes from the FFI/file layer and contains no passphrase.
            logger.error("duress wipe: \(String(describing: type(of: error)))")
            return .failure(stage: "rebuild")
        }
    }

    /// The callback-style bridge used by upstream's `LocalAuthView`. Kept in the same shape as before: it starts a Task internally
    /// and calls the caller's `completed` at the end, so the host view needs no `Task`/`await` of its own.
    @MainActor
    static func run(options: Options, completed: @escaping (LAResult) -> Void) {
        Task { @MainActor in
            let outcome = await wipe(options: options)
            switch outcome {
            case .success:
                completed(.success)
            case .failure:
                // Consistent with upstream's original behaviour: when the wipe fails, outwardly it only says "wrong password". Reporting a self-destruct failure
                // truthfully would tell the coercer "this code is faulty, pressure him a different way".
                completed(.failed(authError: NSLocalizedString("Incorrect passcode", comment: "PIN entry")))
            }
        }
    }

    /// The file-deletion segment is the heaviest synchronous I/O in the whole flow (recursive directory-tree deletion). Upstream did it on the main thread;
    /// this module moves it to the background: the overlay's breathing animation must keep running through this whole segment, and a stalled main thread is one visible stutter.
    /// The order is unchanged — still after `chatCloseStore()` and before clearing memory.
    private static func deleteStorageFilesOffMain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                deleteAppDatabaseAndFiles()
                continuation.resume()
            }
        }
    }

    /// Clears what has already been drawn on screen. Copied verbatim from the hand-written sequence in upstream's `LocalAuthView.deleteStorageAndRestart`
    /// (those lines have since been moved wholesale into this file, their line numbers exist only in git history), including its handling of `secondaryIM` — the offline queue's `ItemsModel` has drawn messages too.
    private static func clearRenderedState(_ m: ChatModel) {
        m.chatId = nil
        ItemsModel.shared.reversedChatItems = []
        ItemsModel.shared.chatState.clear()
        m.secondaryIM?.reversedChatItems = []
        m.secondaryIM?.chatState.clear()
        m.updateChats([])
        m.users = []
    }
}

/// Burning the mesh identities.
///
/// Reuses `PopopxPanicWipeManager`, but **not** its default instance: the default-constructed
/// `termination` is `Self.processExit` (PanicWipeManager.swift:440/482), which calls `exit(0)`.
/// Neither the task red line nor the App Store allows that, so `termination: nil` is injected explicitly here; that manager already
/// documents the behaviour for such a host — do not exit, and record "the process is still alive" in its own report (:658-663).
/// `includeApplicationDatabase: false` is passed (the default): the chat store is deleted by `PopopxStorageWipe` itself, in its own
/// order, and having both sides touch the same file only makes them trip over each other.
enum PopopxMeshIdentityWiper {
    @MainActor
    static func wipe() async {
        let manager = PopopxPanicWipeManager(termination: nil)
        _ = await manager.execute(includeApplicationDatabase: false)
        logger.debug("duress wipe: mesh identity burned")
    }
}

/// The anti-theft traces that must be cleared together after a self-destruct.
///
/// Listing them separately has two reasons: first, "which keys get cleared" must be auditable and cannot be scattered through `if`s;
/// second, if the rebuilt simulated identity still carried a runtime state of "anti-theft lock enabled, rebuild mode = simulated smokescreen",
/// that would tell the visitor something real used to be here — worse than not wiping at all.
enum PopopxAntiTheftSwitches {
    /// Deletes **every** key this module wrote into UserDefaults and flips the runtime switch back to off.
    @MainActor
    static func eraseAllTraces() {
        // The order is load-bearing: flip the runtime switch first, then delete the keys. `enabled`'s `didSet` writes the value back
        // into UserDefaults, so doing it the other way round (delete first, flip second) writes the just-deleted key back by hand,
        // leaving not one trace fewer.
        PopopxAntiTheftMotionGuard.shared.enabled = false
        PopopxBehaviorGuard.shared.enabled = false
        let defaults = UserDefaults.standard
        for key in POPOPX_ANTI_THEFT_DEFAULT_KEYS {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Strategy 1: selective wipe that keeps only the chosen identity

/// The executor of `PopopxDuressRetentionStrategy.retainExistingProfile`.
///
/// It **does not delete the database**; this is the module's only self-destruct path that does not go through `PopopxStorageWipe`, and the reasons are written
/// in each step below. Correspondingly, "erase every dual-password trace" is achieved here by
/// `PopopxAntiTheftSwitches.eraseAllTraces()` plus step C overwriting the Keychain,
/// rather than by deleting files.
enum PopopxDuressProfileKeeper {
    /// The stage name goes only into the log, never into the interface. The caller uses it to decide whether to downgrade to a rebuild (see `runDuressFlow`).
    ///
    /// `appPasscode` is read fresh from `kcAppPassword` by the caller and passed in, used only as a **fallback** for the hidden identity's `viewPwd`.
    /// Honest boundary: the hidden identity's view passphrase is another code the owner typed by hand when switching identities
    /// (the `trimmedSearchTextOrPassword` at NewChatView.swift:464), and it is not guaranteed to equal the entry code;
    /// it is simply tried once here, and if it does not work the flow returns `failure` → the caller downgrades to a full rebuild (the branch more thorough in the safe direction).
    /// Once the owner enables/changes the POPOPX entry password on the settings page the entry code is migrated away (`migrateNativeEntryPassword`),
    /// and then this reads nil, so the success rate of "keep one hidden identity" drops — that is the price paid for removing the second keyboard,
    /// stated plainly so the fallback path does not hide it.
    @MainActor
    static func retain(profileId: Int64, appPasscode: String?) async -> PopopxWipeOutcome {
        // 1) The identity list follows the underlying layer: `ChatModel.users` may still be the copy read at launch,
        //    and here both "one identity too few deleted" and "one identity too many deleted" are incidents.
        let users: [UserInfo]
        do {
            users = try await listUsersAsync()
        } catch {
            logger.error("duress retain: listUsers failed \(responseError(error))")
            return .failure(stage: "listUsers")
        }
        guard users.contains(where: { $0.user.userId == profileId }) else {
            // The exact failure the brief names: the target is already gone → the caller safely downgrades to a simulated-smokescreen rebuild.
            return .failure(stage: "profileMissing")
        }
        // 2) Switch to the identity to keep first, then delete the rest. The other way round ends with a "current identity has been deleted"
        //    intermediate state: the underlying layer refuses to continue at that step, and by then every other identity is deleted while the active one is gone.
        do {
            try await changeActiveUserAsync_(profileId, viewPwd: nil)
        } catch {
            // A hidden identity can only be switched to with its view passphrase (same rule as NewChatView.swift:464).
            guard let appPasscode, !appPasscode.isEmpty else {
                logger.error("duress retain: setActiveUser failed, no viewPwd to retry with")
                return .failure(stage: "setActiveUser")
            }
            do {
                try await changeActiveUserAsync_(profileId, viewPwd: appPasscode)
            } catch {
                logger.error("duress retain: setActiveUser failed with viewPwd too")
                return .failure(stage: "setActiveUserRetry")
            }
        }
        // 3) Delete the remaining identities. `delSMPQueues: true` deletes the server-side queues too — deleting only locally
        //    leaves "this identity existed" behind on the relay server, and that is not the surface "keep the chosen nickname" means to narrow.
        for user in users where user.user.userId != profileId {
            do {
                try await apiDeleteUser(user.user.userId, true, viewPwd: appPasscode)
            } catch {
                // Failing to delete one identity **does not abort**: aborting downgrades the whole thing to a full rebuild and wipes the very identity
                // the owner named to keep, which betrays his choice more than leaving one secondary identity that could not be cleaned up.
                logger.error("duress retain: cannot delete user \(user.user.userId)")
            }
        }
        // 4) Cabin Bluetooth identity mappings (including the memory cache) + this module's own configuration traces.
        await PopopxMeshIdentityWiper.wipe()
        PopopxAntiTheftSwitches.eraseAllTraces()
        return .success
    }
}

// MARK: - Dual-password manager

@MainActor
@Observable
final class PopopxDuressAuthManager {
    static let shared = PopopxDuressAuthManager()

    static let pinLength = 6
    static let digits: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

    /// The fixed floor for every keyboard unlock, and for the duress path a **floor rather than a ceiling**.
    /// Two purposes: it covers for the real self-destruct (a normal unlock waits just as long, a stopwatch measures no difference),
    /// and it gives the breathing animation a minimum duration that cannot be exposed. The UI's 1.2 s of visible breathing is based on it,
    /// so the jitter only ever makes the interface "breathe a little longer", never shorter than the animation's designed duration.
    static let minimumFlowSeconds: TimeInterval = 1.2

    /// A random 0~1.2 seconds of jitter is layered on top of the floor; see the timing notes of `submit(pin:)` for the reason.
    static let flowJitterSeconds: TimeInterval = 1.2

    /// Maximum number of consecutive biometric failures: at that point this session accepts only the keyboard.
    /// Why 2: the 1st failure is usually damp skin or a mask and deserves a retry; by the 3rd it is no longer "not recognised".
    /// And the downgrade can only ever go towards a stronger proof (typing a code only the owner knows), never the reverse.
    static let maxBiometricFailuresBeforeKeypad = 2

    private(set) var normalConfigured = false
    private(set) var duressConfigured = false
    private(set) var biometricFailures = 0
    /// true = keyboard-forced mode (after consecutive biometric failures, or when the device has no biometric capability).
    private(set) var keypadRequired = false

    /// Consecutive failure count. The entry code and the mnemonic **share this one table** (the brief's own words); two tables would tell the visitor
    /// "typing 12 words pays off better". It lands in the Keychain's `lockoutAccount`; this is its in-memory copy, and the reason is written
    /// in the file header's section "why the cooldown counter is not kept in UserDefaults".
    private(set) var failedAttemptCount = 0

    /// The unfreeze moment. nil = not currently in cooldown (this includes the "1~4 wrong" tier: error only, no lock).
    private(set) var lockoutEndsAt: Date?

    /// Whether the mnemonic is usable = **both records are present**. Half new and half old (the hash accepts A while view shows B) is worse than having none:
    /// the settings page would display a phrase that can never pass a reset, while the paper in the owner's hand has already been voided.
    private(set) var mnemonicConfigured = false

    /// Remaining cooldown seconds. Only a `Date` minus one stored moment, so the overlay's once-per-second timer
    /// can call it directly; nothing has to "refresh" it.
    var lockoutRemainingSeconds: TimeInterval {
        lockoutEndsAt.map { max(0, $0.timeIntervalSinceNow) } ?? 0
    }

    var isLockedOut: Bool { lockoutRemainingSeconds > 0 }

    /// How many attempts are left before the 10th, for the settings page's red warning cell. **It is computed**, not another counter:
    /// one more piece of state is one more place that can end up contradicting `failedAttemptCount`.
    var strikesUntilWipe: Int {
        max(0, PopopxLockoutSchedule.wipeThreshold - failedAttemptCount)
    }

    /// Whether the 10th consecutive error wipes the data. Off by default and must be explicitly turned on by the owner on the settings page: this turns
    /// the cost of "ten wrong guesses" from "locked for an hour" into "the identities on this device are gone", and the cost of a misfire (family mashing the keyboard,
    /// one's own mistyped mnemonic) has to be borne by one deliberate action whose explanation is visible.
    var wipeOnTenthFailure: Bool {
        didSet {
            guard oldValue != wipeOnTenthFailure, !resyncingTenStrikeSwitch else { return }
            UserDefaults.standard.set(wipeOnTenthFailure, forKey: DEFAULT_ANTI_THEFT_TEN_STRIKE_WIPE)
        }
    }

    /// The same reason and the same gate as `resyncingRetentionStrategy`: `eraseAllTraces()` has just deleted this key, so
    /// if the very next assignment that "puts memory back in place" bypasses the gate it recreates the key by hand —
    /// the trace the wipe exists to remove gets written back by the wipe itself.
    private var resyncingTenStrikeSwitch = false

    /// The master switch for dual-password self-destruct. Once off, the duress code no longer exists (its record is deleted), avoiding the state of
    /// "switch turned off but the code still kept", the most dangerous one of all.
    var duressEnabled: Bool {
        didSet {
            guard oldValue != duressEnabled else { return }
            UserDefaults.standard.set(duressEnabled, forKey: DEFAULT_ANTI_THEFT_DURESS_ENABLED)
            if !duressEnabled {
                PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
                duressConfigured = false
            }
        }
    }

    var biometricsEnabled: Bool {
        didSet {
            guard oldValue != biometricsEnabled else { return }
            UserDefaults.standard.set(biometricsEnabled, forKey: DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED)
            if biometricsEnabled {
                biometricFailures = 0
                keypadRequired = false
            }
        }
    }

    var biometricsAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// The one check the overlay uses to decide whether to open with biometrics or go straight to the keyboard.
    /// `!isLockedOut` is the first landing here of the brief's hard requirement (Face ID must not appear during a cooldown);
    /// there is a second one inside `requestBiometricUnlock`, because callers may assemble the conditions themselves.
    var prefersBiometricUnlock: Bool {
        biometricsEnabled && !keypadRequired && !isLockedOut && biometricsAvailable && normalConfigured
    }

    private init() {
        let defaults = UserDefaults.standard
        duressEnabled = defaults.object(forKey: DEFAULT_ANTI_THEFT_DURESS_ENABLED) == nil
            ? true
            : defaults.bool(forKey: DEFAULT_ANTI_THEFT_DURESS_ENABLED)
        biometricsEnabled = defaults.object(forKey: DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED) == nil
            ? true
            : defaults.bool(forKey: DEFAULT_ANTI_THEFT_BIOMETRICS_ENABLED)
        // This one does not play "if it cannot be read, assume it is on": wiping data is the tier that turns ten misfires into an irreversible action,
        // so when the key does not exist it can only be false.
        wipeOnTenthFailure = defaults.bool(forKey: DEFAULT_ANTI_THEFT_TEN_STRIKE_WIPE)
        retentionStrategy = PopopxDuressRetentionStrategy.load(from: defaults)
        // The credential, mnemonic and cooldown states are all read from disk in one place (`didSet` has already initialised the three switch properties
        // above, so nothing here triggers another write-back).
        refreshConfiguration()
    }

    /// The Keychain gets changed by other processes/other sessions (a self-destruct is such a change), so every time the overlay
    /// or the settings page is entered the real state is read again instead of trusting the cached copy in memory.
    @MainActor
    func refreshConfiguration() {
        normalConfigured = PopopxDuressKeychain.exists(PopopxDuressKeychain.normalAccount)
        duressConfigured = duressEnabled && PopopxDuressKeychain.exists(PopopxDuressKeychain.duressAccount)
        mnemonicConfigured = PopopxDuressKeychain.read(PopopxDuressKeychain.mnemonicAccount) != nil
            && PopopxDuressKeychain.readString(PopopxDuressKeychain.mnemonicPhraseAccount) != nil
        // The cooldown record **overwrites memory only when it was actually read**. A failed read and "there really is no such record" are the same
        // nil at the Keychain layer, and the costs of guessing wrong are asymmetric: reading it as "never failed" hands out 4 free attempts,
        // while reading it as "still cooling down" costs the owner at most waiting once more through a time he already waited. So staying locked is preferred.
        if let record = PopopxDuressKeychain.readLockout() {
            failedAttemptCount = record.failedAttempts
            lockoutEndsAt = record.lockoutEndTimestamp.map { Date(timeIntervalSince1970: $0) }
        }
    }

    // MARK: Configuration

    static func isValidPin(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy { digits.contains($0) }
    }

    // MARK: Native entry-code migration (one front-end authentication entry only)

    /// Upstream's "entry password" and this module's dual-password lock are two front doors side by side: `authenticate(reason:)`
    /// (LocalAuthenticationUtils.swift:40), when `privacyLocalAuthModeDefault == .passcode`,
    /// presents the keyboard as `LocalAuthView` (ContentView.swift:100, ChatListView.swift:133), while
    /// `PopopxAppLockOverlayView` is this module's own keyboard. Two different codes = the same device locked twice,
    /// two identical codes = the same code typed twice. Enabling/changing the POPOPX entry password migrates the former away, leaving one front-end entry.
    ///
    /// The migration **does not need the library key rebuilt**: SQLCipher's passphrase is `kcDatabasePassword`
    /// (POPOPXChat/API.swift:43 reads it when opening the store) and has nothing to do with `kcAppPassword` — the latter is only the code
    /// that, in `.passcode` mode, is put into `LocalAuthRequest.password` for a string comparison (LocalAuthenticationUtils.swift:45).
    /// There is only one criterion: **whether that plaintext entry code is still in the Keychain**, regardless of mode.
    ///
    /// It deliberately uses the same condition as the first `guard` of `migrateNativeEntryPassword` (the same
    /// `kcAppPassword.get()`). The two judgements are "must the interface ask for the password" and "must the code have the password";
    /// if they ever disagree — mode already `.system` while the item is still there (upstream does not guarantee deleting the item when it changes mode) —
    /// it becomes a deadlock where the migration insists on one input and the page has no such field at all, and the owner can only watch.
    /// With mode `.system` this keyboard indeed does not appear (`authenticate` goes straight to `systemAuthenticate`,
    /// LocalAuthenticationUtils.swift:42), but that plaintext credential still lies in the Keychain and the owner should still close it by hand.
    @MainActor
    static var nativeEntryPasswordActive: Bool {
        kcAppPassword.get() != nil
    }

    /// The "ghost self-destruct code": the entry code is already gone (so the field above never appears), while the code that only the entry-code keyboard accepts
    /// is still there — `kcSelfDestructPassword` has an item, or `DEFAULT_LA_SELF_DESTRUCT` is still true.
    /// The condition is strictly isomorphic to `retireGhostSelfDestructCode`, same reason: the code cannot demand it while the interface never asks.
    @MainActor
    static var nativeSelfDestructGhostActive: Bool {
        kcAppPassword.get() == nil
            && (kcSelfDestructPassword.get() != nil
                || UserDefaults.standard.bool(forKey: DEFAULT_LA_SELF_DESTRUCT))
    }

    /// Verify first, migrate second. All three checks sit ahead of any write, so every failure branch means "nothing was changed".
    ///
    /// Migrating the code away also flips the mode back to upstream's own `.system` — deleting the code without changing the mode is not enough:
    /// with `.passcode` and no item `authenticate` returns `.unavailable`, and `authorize()` treats that as authorised
    /// (LocalAuthenticationUtils.swift:24), so the two call sites it guards silently let through on the spot. Upstream has nine more
    /// call sites that invoke `authenticate(reason:)` directly (six in PrivacySettings, two in ContentView, one in DatabaseView
    /// ), and this module neither depends on nor draws conclusions about how each of them handles `.unavailable`.
    /// `.system` is upstream's factory default (Shared/Views/UserSettings/SettingsView.swift:224,
    /// a different file with the same name as this page), and also its own existing configuration when biometric
    /// is enabled (PrivacySettings.swift:766 is exactly `kcAppPassword.remove()`),
    /// so after the migration these gates are held by the system's Face ID/device passcode and the only in-app keyboard left is this module's.
    ///
    /// The self-destruct code is deleted along with it, because it can **no longer be triggered**: its only entry point is `LocalAuthView`
    /// (LocalAuthView.swift:23 `password == sdPassword`), and that view is presented only in `.passcode` mode and when
    /// `kcAppPassword` yields a value (LocalAuthenticationUtils.swift:45-47) — the previous line just deleted
    /// the entry code, so this code has nowhere left to be typed. Keeping it is not "one more layer of insurance" but a credential nobody can press,
    /// plus a lie in the privacy settings cell: the switch state reads only the bool in UserDefaults (PrivacySettings.swift:512
    /// is its initial value, :898 is the write-back) and never reads the Keychain, so both must come down together for the page to honestly say "not enabled".
    /// The deletion aligns with upstream's own `resetSelfDestruct()` (PrivacySettings.swift:886-890 is exactly "delete the item + set false").
    ///
    /// The plaintext comparison goes through `PopopxDuressCrypto.matchesInConstantTime`: `kcAppPassword` is stored in plaintext
    /// (POPOPXChat/KeyChain.swift:21), and Swift's `==` short-circuits character by character, leaking "were the first digits right" into a timing difference.
    ///
    /// `kcDatabasePassword` is not touched at all — it is SQLCipher's library key, and deleting it would mean rebuilding the store.
    /// `DEFAULT_LA_SELF_DESTRUCT_DISPLAY_NAME` is kept: that name is read only when that keyboard really self-destructs
    /// (LocalAuthView.swift:61), and once the entry code is gone it is a dead key, not worth one extra deletion.
    /// - Parameters:
    ///   - passcode: the one raw entry-code input the interface asks the owner for. nil = not collected.
    ///   - selfDestructPasscode: only usable by the branch where the entry code is gone and only the ghost self-destruct code remains (see
    ///     `retireGhostSelfDestructCode`). The branch where the entry code still exists does not need it: identity was already proven
    ///     by the comparison above, and that code cannot be pressed anyway once the keyboard disappeared — this is the seam between the two rounds of rulings, stated plainly so that
    ///     later readers do not take it for a missing verification.
    static func migrateNativeEntryPassword(passcode: String?, selfDestructPasscode: String? = nil) throws {
        guard let stored = kcAppPassword.get() else {
            // The state of most devices: no native entry code. A possible ghost self-destruct code is handled first (it requires verification,
            // and on failure the whole branch changes nothing), then the half-migrated state "mode still stuck at .passcode while the item is already gone"
            // is corrected in passing — the reason for correcting it is exactly the silent pass-through by `authorize()` noted above.
            try retireGhostSelfDestructCode(passcode: selfDestructPasscode)
            if privacyLocalAuthModeDefault.get() == .passcode {
                privacyLocalAuthModeDefault.set(.system)
            }
            return
        }
        guard let passcode, !passcode.isEmpty else {
            throw PopopxDuressSetupError.nativePasscodeRequired
        }
        guard PopopxDuressCrypto.matchesInConstantTime(Data(passcode.utf8), Data(stored.utf8)) else {
            throw PopopxDuressSetupError.nativePasscodeIncorrect
        }
        _ = kcAppPassword.remove()
        _ = kcSelfDestructPassword.remove()
        UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
        privacyLocalAuthModeDefault.set(.system)
    }

    /// Clears the "ghost self-destruct code" — the entry code went first, so this code, typable only into that keyboard, became an unpressable dead credential.
    /// The ruling is verify first, clear second, but **only a real credential is verified**; the two kinds of residue are handled separately:
    ///
    /// - the item is still there → the owner must type it once. This is the migration's only path where "nothing else on hand can prove
    ///   identity" holds: deleting without asking is switching off, for a stranger, an insurance policy he does not know exists.
    /// - the item is gone and only `DEFAULT_LA_SELF_DESTRUCT` is true → it is dropped directly, without asking. That bool on its own
    ///   deletes no data: the self-destruct step requires `kcSelfDestructPassword.get()` to have a value equal to the input
    ///   (LocalAuthView.swift:23), so it is purely a display residue; and "please enter a password that no longer exists"
    ///   is a demand that can neither be met nor means anything.
    ///
    /// The reason the comparison goes through `matchesInConstantTime` is exactly the same as the one above: this code is also stored in plaintext
    /// （POPOPXChat/KeyChain.swift:23）。
    private static func retireGhostSelfDestructCode(passcode: String?) throws {
        guard let stored = kcSelfDestructPassword.get() else {
            if UserDefaults.standard.bool(forKey: DEFAULT_LA_SELF_DESTRUCT) {
                UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
            }
            return
        }
        guard let passcode, !passcode.isEmpty else {
            throw PopopxDuressSetupError.nativeSelfDestructCodeRequired
        }
        guard PopopxDuressCrypto.matchesInConstantTime(Data(passcode.utf8), Data(stored.utf8)) else {
            throw PopopxDuressSetupError.nativeSelfDestructCodeIncorrect
        }
        _ = kcSelfDestructPassword.remove()
        UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
    }

    /// The "unconditional retirement" used only by the downgrade flow; the actions line up with those `migrateNativeEntryPassword` takes after verification passes,
    /// (the entry code deleted + the mode back to `.system`), with exactly one difference: here it **cannot verify** — whoever stands at the keyboard is
    /// the coercer, and making him type the owner's original code once more is both impossible and an exposure. Deleting the old credential is itself the effect brief step C demands.
    ///
    /// The self-destruct code is not deleted a second time here: the full branch deletes it via `PopopxStorageWipe` (:870 the item + :877 that bool),
    /// the retaining branch via `scrubCredentialHistory` (:1989-:1990, both the item and the bool are in there),
    /// and both are scheduled before the function returns, so by the time control reaches this line it is already gone.
    /// These steps must be finished together and cannot be split: deleting only the code turns `authorize()` into a silent pass-through.
    private func retireNativeEntryPassword() {
        _ = kcAppPassword.remove()
        privacyLocalAuthModeDefault.set(.system)
    }

    /// Set/change the regular code. `confirming` and `first` must agree (the settings page makes the owner type it twice
    /// because one mistype would lock the owner out himself, and in this feature that means losing all the data).
    ///
    /// The migration is scheduled **before** writing the new code; the order is load-bearing: the reverse (write then migrate) leaves a window where two front doors coexist,
    /// while this branch has exactly one correct end state — old front door closed, new front door installed: either both succeed or nothing happened at all.
    /// When `nativePasscode` is nil and the native entry code is still in force, `.nativePasscodeRequired` is thrown,
    /// never silently deleting that code on the owner's behalf; when only the ghost self-destruct code is left, `nativeSelfDestructCode` speaks instead, same reasoning.
    ///
    /// Return value = the new phrase the brief asks for, "generate a 12-word mnemonic together with the entry password",
    /// shown once by the settings page so the owner can copy it down; **nil has two meanings**, and the caller tells them apart with `mnemonicConfigured`:
    /// one already exists (never overwritten — the paper in the owner's hand copies the old one, and silently swapping it voids his backup without his knowledge),
    /// or this time the random source/disk write failed (he presses "generate" himself on the mnemonic card).
    /// No extra error is thrown here: the entry code was already written successfully, and rolling back the primary credential for an auxiliary recovery means is the worse outcome.
    @discardableResult
    func setNormalPin(
        _ first: String,
        confirming second: String,
        nativePasscode: String? = nil,
        nativeSelfDestructCode: String? = nil
    ) async throws -> [String]? {
        guard Self.isValidPin(first), first == second else { throw PopopxDuressSetupError.malformedPin }
        try Self.migrateNativeEntryPassword(passcode: nativePasscode, selfDestructPasscode: nativeSelfDestructCode)
        let salt = PopopxDuressCrypto.randomSalt()
        guard !salt.isEmpty else { throw PopopxDuressSetupError.keychainWriteFailed }
        let normalHash = await derive(secret: first, salt: salt, iterations: PopopxDuressCrypto.iterations)
        let verifier = PopopxDuressVerifier(salt: salt, hash: normalHash, iterations: PopopxDuressCrypto.iterations)
        guard PopopxDuressKeychain.write(verifier, account: PopopxDuressKeychain.normalAccount) else {
            throw PopopxDuressSetupError.keychainWriteFailed
        }
        normalConfigured = true
        guard !mnemonicConfigured else { return nil }
        return await generateMnemonic()
    }

    /// Set/change the duress code. Two hard constraints: the format, and that it must not equal the regular code.
    func setDuressPin(_ first: String, confirming second: String) async throws {
        guard duressEnabled else { throw PopopxDuressSetupError.keychainWriteFailed }
        guard normalConfigured else { throw PopopxDuressSetupError.normalPinRequiredFirst }
        guard Self.isValidPin(first), first == second else { throw PopopxDuressSetupError.malformedPin }
        guard let normal = PopopxDuressKeychain.read(PopopxDuressKeychain.normalAccount) else {
            throw PopopxDuressSetupError.normalPinRequiredFirst
        }
        let salt = PopopxDuressCrypto.randomSalt()
        guard !salt.isEmpty else { throw PopopxDuressSetupError.keychainWriteFailed }
        let duressHash = await derive(secret: first, salt: salt, iterations: PopopxDuressCrypto.iterations)
        // "the two codes are identical" can only be judged at the derived-value level, but it **must re-derive using the regular record's own salt**:
        // the two records each carry their own random salt, and a hash computed with the new salt can never equal the regular record's hash —
        // that gate would look present yet never once close, and the red line would silently fail.
        // Same passphrase + same salt ⇒ same hash, so "colliding this code against the regular record" hitting means the two codes are identical.
        // The local is deliberately not named `hash`: that would shadow the method call itself below (`Data` is not a function).
        let againstNormal = await derive(secret: first, salt: normal.salt, iterations: normal.iterations)
        if PopopxDuressCrypto.matchesInConstantTime(againstNormal, normal.hash) {
            throw PopopxDuressSetupError.pinsMustDiffer
        }
        let verifier = PopopxDuressVerifier(salt: salt, hash: duressHash, iterations: PopopxDuressCrypto.iterations)
        guard PopopxDuressKeychain.write(verifier, account: PopopxDuressKeychain.duressAccount) else {
            throw PopopxDuressSetupError.keychainWriteFailed
        }
        duressConfigured = true
    }

    func clearDuressPin() {
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        duressConfigured = false
    }

    /// Turn the whole dual-password feature off (the settings page's "disarm"). Both codes, the mnemonic's pair of records and the cooldown record are all deleted, no residue:
    /// the owner has explicitly stopped wanting this lock, and "feature off but that paper can still reset out an entry password" is worse than keeping the codes —
    /// it would conjure an entry password nobody ever set.
    func clearAllPins() {
        PopopxDuressKeychain.delete(PopopxDuressKeychain.normalAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicPhraseAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.lockoutAccount)
        normalConfigured = false
        duressConfigured = false
        mnemonicConfigured = false
        failedAttemptCount = 0
        lockoutEndsAt = nil
        biometricFailures = 0
        keypadRequired = false
    }

    // MARK: Mnemonic phrase (12-word BIP-39 recovery)

    /// Generates a new set of 12 mnemonic words, writes it to disk, and returns the plaintext phrase to the interface to be shown once so the owner can copy it down.
    ///
    /// The entropy comes from `SecRandomCopyBytes` and the checksum bits are computed from SHA-256 per BIP-39, so this phrase is in
    /// **standard wallet format**: the owner can later check with any BIP-39 tool whether he copied it right, without having to trust this app's display.
    ///
    /// Overwrites an existing phrase. If either half of `storeMnemonic` fails, the whole pair rolls back, so "regenerate" either replaces the entire set
    /// or leaves the old one intact, and never leaves behind "the hash accepts A while view shows B" — a half-finished state where `mnemonicConfigured` reports true yet
    /// a reset never passes.
    @discardableResult
    func generateMnemonic() async -> [String]? {
        guard let words = PopopxBIP39.generate() else { return nil }
        return await storeMnemonic(words) ? words : nil
    }

    /// Writes one set of words as two records at once: the derived verifier and the re-viewable plaintext.
    ///
    /// Before writing, `validate` runs once over our own generated result: this does not defend against user input but against the wordlist or the bit splitting
    /// being broken later — once a mnemonic with a wrong checksum lands on disk, the paper in the owner's hand becomes an unopenable backup,
    /// and **nobody would know**, until the day he really forgets the password. Returning nil here is the better outcome.
    private func storeMnemonic(_ words: [String]) async -> Bool {
        let phrase = PopopxBIP39.normalize(words.joined(separator: " "))
        let salt = PopopxDuressCrypto.randomSalt()
        guard PopopxBIP39.validate(phrase: phrase), !salt.isEmpty else {
            logger.error("duress mnemonic: generated phrase failed self-validation, nothing stored")
            return false
        }
        let hash = await derive(secret: phrase, salt: salt, iterations: PopopxDuressCrypto.iterations)
        let verifier = PopopxDuressVerifier(salt: salt, hash: hash, iterations: PopopxDuressCrypto.iterations)
        guard
            PopopxDuressKeychain.write(verifier, account: PopopxDuressKeychain.mnemonicAccount),
            PopopxDuressKeychain.writeString(phrase, account: PopopxDuressKeychain.mnemonicPhraseAccount)
        else {
            PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicAccount)
            PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicPhraseAccount)
            mnemonicConfigured = false
            logger.error("duress mnemonic: store failed, pair rolled back")
            return false
        }
        mnemonicConfigured = true
        return true
    }

    /// The first gate: proves only "knows the current entry password right now" and hands nothing over.
    ///
    /// This half is also the gate for the two questions "view the mnemonic" and "regenerate a new set" — one thing must not have two sets of release conditions,
    /// so both call here instead of writing their own comparison. Three deliberate trade-offs:
    /// 1. Compared only against the regular record. The emergency erase password is a separate item, and deriving from it cannot match →
    ///    `.entryPinIncorrect`, nothing happens. This is not a missing path: whoever hands over the duress code gets
    ///    "an immediate self-destruct" in exchange, and should not additionally earn a readable backup or the right to change the phrase.
    /// 2. **Does not consume cooldown counts** (`settleWrongAttempt` is not called). The keyboard is the only door a coercer has, so that
    ///    table stands there; wiring these two settings-page cells into it too would hand the visitor a second entry to try at,
    ///    and hand the owner a denial-of-service handle worth "three miscopies and you are locked for 60 minutes". The cost of failing here is clear enough already:
    ///    nothing happens.
    /// 3. The comparison uses the same `matches(pin:record:)`, the same 100_000 rounds and the same constant time, so
    ///    "looking at the mnemonic once" and "unlocking once" cost the same time, and a stopwatch cannot tell that a view or a regeneration happened here.
    ///
    /// No regular record = there is no "current entry password" to compare against. If that state really occurs (Keychain cleared by hand,
    /// or `clearAllPins` interleaving with a persisted mnemonic) it is treated as not passed,
    /// rather than "no password, so no check" — this cell's release condition must be proof that the owner knows the entry password.
    func verifyEntryPin(_ pin: String) async throws {
        guard Self.isValidPin(pin) else { throw PopopxDuressSetupError.entryPinRequired }
        guard let normal = PopopxDuressKeychain.read(PopopxDuressKeychain.normalAccount) else {
            throw PopopxDuressSetupError.entryPinRequired
        }
        guard await matches(pin: pin, record: normal) else {
            throw PopopxDuressSetupError.entryPinIncorrect
        }
    }

    /// View the mnemonic: first exchange the **current entry password** for the plaintext phrase.
    /// The proof itself lives in `verifyEntryPin(_:)`, where the three trade-offs there apply to this path unchanged.
    func revealMnemonic(unlockingWith pin: String) async throws -> [String] {
        refreshConfiguration()
        guard mnemonicConfigured else { throw PopopxDuressSetupError.mnemonicMissing }
        try await verifyEntryPin(pin)
        return try readRevealedMnemonic()
    }

    /// The second gate: proves only "Face ID recognised the owner in person just now" and hands nothing over.
    ///
    /// "View with Face ID" and "verify with Face ID then regenerate" share this half, so both questions must get
    /// the same judgement, not "the view question a bit stricter and the change question a bit looser".
    ///
    /// All three prerequisite gates **close rather than release**: master switch off, just downgraded to the keyboard by "two consecutive failures", the system cannot tell it is usable —
    /// all of them throw immediately. This is the opposite choice to upstream's `authorize()` (it lets `.unavailable` pass straight through,
    /// see LocalAuthenticationUtils.swift:20-24): that layer governs "the convenience of unlocking the device",
    /// while these two questions hand over a plaintext that can reset the entry password, plus the right to void that paper,
    /// so when nothing can be asked of the system it can only count as not passed.
    ///
    /// The cooldown table is deliberately not consulted here: that table blocks the three input points on the lock-screen overlay, and these two questions do not consume failure counts
    /// (the reason is written in the settings cell's own explanation), so there is nothing to zero out either.
    ///
    /// It also deliberately does **not** reuse `requestBiometricUnlock`: that path, on success, also calls `unlock()` on the overlay and clears the counter,
    /// turning "take a look at the phrase" into "unlock once" — two entirely different things.
    func verifyIdentityWithBiometrics(reason: String) async throws {
        guard biometricsEnabled, !keypadRequired, biometricsAvailable else {
            throw PopopxDuressSetupError.biometricDenied
        }
        let context = LAContext()
        let granted = await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, _ in
                resume.resume(returning: ok)
            }
        }
        guard granted else { throw PopopxDuressSetupError.biometricDenied }
    }

    /// The "view with Face ID" path (the brief's own words: "verify the current entry password **or FaceID** before viewing").
    /// The proof is switched to `verifyIdentityWithBiometrics(reason:)`; the rest matches `revealMnemonic(unlockingWith:)`
    /// verbatim — what has to be handed over is the same thing, so the endings of the two gates must not differ.
    func revealMnemonicWithBiometrics(reason: String) async throws -> [String] {
        refreshConfiguration()
        guard mnemonicConfigured else { throw PopopxDuressSetupError.mnemonicMissing }
        try await verifyIdentityWithBiometrics(reason: reason)
        return try readRevealedMnemonic()
    }

    /// The half that reads the phrase back, shared by both proof paths. The plaintext record in the Keychain must still pass BIP-39's
    /// structural validation, otherwise it is better to say "there is no mnemonic" — showing a string of broken bytes as "your 12 words"
    /// would have the owner reset from a bad sheet of paper and then be locked out completely at the next gate.
    private func readRevealedMnemonic() throws -> [String] {
        guard
            let stored = PopopxDuressKeychain.readString(PopopxDuressKeychain.mnemonicPhraseAccount),
            PopopxBIP39.validate(phrase: stored)
        else {
            throw PopopxDuressSetupError.mnemonicMissing
        }
        return PopopxBIP39.normalizedWords(stored)
    }

    /// Structural validation only (12 words, all in the table, checksum recomputes back): no Keychain access, no derivation, no failure counting.
    ///
    /// For "should the submit button be disabled" while typing. One derivation costs 355 ms, so running it on every changed character is both slow
    /// and leaks "the first few words are already right" as a timing difference before the real validation.
    func verifyMnemonic(_ phrase: String) -> Bool {
        PopopxBIP39.validate(phrase: phrase)
    }

    /// Reset the entry password with the mnemonic: validate the phrase → write the new entry password → **set the emergency erase password to unset** →
    /// zero the cooldown counter.
    ///
    /// Shares the same `settleWrongAttempt` with the keyboard; this is the landing point of the brief's "one and the same table applies to wrong password and
    /// wrong mnemonic alike", but only a **structurally valid phrase whose derivation does not match** counts — copying `watch` as `wach`
    /// takes `.mnemonicMalformed` and throws directly (see the reason on that case).
    ///
    /// A reset **does not consume** the mnemonic: after success the phrase can still perform the next reset. The owner has just lost a password once,
    /// and voiding the only backup at that moment would lock him out a second time; for "burn after use" he presses "regenerate" himself.
    ///
    /// The emergency erase password is always deleted, **regardless of whether it was set** — the landing point of the assertion "after a reset the self-destruct code is zeroed".
    /// On-device acceptance: set the self-destruct code first → reset with the mnemonic → then try to unlock with that pre-reset self-destruct code;
    /// it must produce an ordinary failure (count +1), not a silent self-destruct.
    func resetEntryPinWithMnemonic(
        phrase: String,
        newPin: String,
        confirmingPin: String
    ) async throws {
        refreshConfiguration()
        guard !isLockedOut else {
            throw PopopxDuressSetupError.lockedOut(remaining: lockoutRemainingSeconds)
        }
        guard mnemonicConfigured else { throw PopopxDuressSetupError.mnemonicMissing }
        let normalized = PopopxBIP39.normalize(phrase)
        guard PopopxBIP39.validate(phrase: normalized) else {
            throw PopopxDuressSetupError.mnemonicMalformed
        }
        guard Self.isValidPin(newPin), newPin == confirmingPin else {
            throw PopopxDuressSetupError.malformedPin
        }
        guard let record = PopopxDuressKeychain.read(PopopxDuressKeychain.mnemonicAccount) else {
            throw PopopxDuressSetupError.mnemonicMissing
        }
        guard await matches(pin: normalized, record: record) else {
            // A real guess. The return value is unused here: this path's interface has already switched to the reset form,
            // and the cooldown brings its state back through `isLockedOut` / `lockoutRemainingSeconds`.
            _ = await settleWrongAttempt()
            throw PopopxDuressSetupError.mnemonicIncorrect
        }
        let salt = PopopxDuressCrypto.randomSalt()
        guard !salt.isEmpty else { throw PopopxDuressSetupError.keychainWriteFailed }
        let pinHash = await derive(secret: newPin, salt: salt, iterations: PopopxDuressCrypto.iterations)
        guard PopopxDuressKeychain.write(
            PopopxDuressVerifier(salt: salt, hash: pinHash, iterations: PopopxDuressCrypto.iterations),
            account: PopopxDuressKeychain.normalAccount
        ) else {
            throw PopopxDuressSetupError.keychainWriteFailed
        }
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        normalConfigured = true
        duressConfigured = false
        clearFailures()
    }

    // MARK: Verification

    /// One PBKDF2 derivation. The parameter is named `secret` rather than `pin`: two kinds of secret reach this line — the 6 digits,
    /// and the normalized 12-word phrase. The derivation is exactly the same (same 100_000 rounds, same 32-byte output),
    /// so comparing the mnemonic costs as much as comparing the two codes and is just as constant-time.
    ///
    /// `popopxSecureErase` is this repository's existing destruction convention (PopopxSecurePayload.swift:446):
    /// a `String` is managed by ARC and cannot be overwritten, so the secret is copied into `Data` the moment it lands and zeroed in place after use.
    /// The only promise that can be made is about this copy — `Task.detached` shares the same buffer during the derivation,
    /// and `bytes` becomes exclusively owned only after `.value` returns and the closure is released, so what `defer` erases really is the original and not
    /// a COW copy. If this is not written out clearly, a later reader will break it.
    private func derive(secret: String, salt: Data, iterations: Int) async -> Data {
        var bytes = Data(secret.utf8)
        defer { popopxSecureErase(&bytes) }
        return await Task.detached(priority: .userInitiated) {
            PopopxDuressCrypto.pbkdf2SHA256(
                password: bytes,
                salt: salt,
                iterations: iterations,
                outputCount: PopopxDuressCrypto.hashBytes
            )
        }.value
    }

    /// Pure verification, zero side effects. The settings page's "one-tap drill" may only use this; it must never be allowed to lead to a wipe.
    func verify(pin: String) async -> PopopxDuressAuthOutcome {
        refreshConfiguration()
        guard normalConfigured else { return .notConfigured }
        let normal = PopopxDuressKeychain.read(PopopxDuressKeychain.normalAccount)
        let duress = duressConfigured ? PopopxDuressKeychain.read(PopopxDuressKeychain.duressAccount) : nil
        // Constant work: always two derivations. Whichever record is missing, a record that can never match supplies one equivalent derivation,
        // making "two codes set" and "only one code set", as well as "hit the regular" and "hit the duress", indistinguishable by duration.
        let normalRecord = normal ?? PopopxDuressVerifier.workloadPad(salt: PopopxDuressCrypto.randomSalt())
        let duressRecord = duress ?? PopopxDuressVerifier.workloadPad(salt: PopopxDuressCrypto.randomSalt())
        let normalHit = await matches(pin: pin, record: normalRecord) && normal != nil
        let duressHit = await matches(pin: pin, record: duressRecord) && duress != nil
        if duressHit { return .duress }
        if normalHit { return .unlocked }
        return .wrong
    }

    private func matches(pin: String, record: PopopxDuressVerifier) async -> Bool {
        let derived = await derive(secret: pin, salt: record.salt, iterations: record.iterations)
        return PopopxDuressCrypto.matchesInConstantTime(derived, record.hash)
    }

    // MARK: Retention strategy (choose one of three)

    /// What account is handed over after a self-destruct. The settings page's segmented control writes it, and the duress flow reads it once only (see the snapshot in `submit`).
    ///
    /// `.retainExistingProfile` carries a `displayName` — that is **identity information**, no longer a "harmless preference".
    /// So the first round's "this key need not be deleted when self-destruct is turned off" no longer holds here: this module's
    /// `PopopxAntiTheftSwitches.eraseAllTraces()` deletes this key along with the others (it is in
    /// `POPOPX_ANTI_THEFT_DEFAULT_KEYS`), and the self-destruct paths do reach the deletion.
    var retentionStrategy: PopopxDuressRetentionStrategy {
        didSet {
            guard oldValue != retentionStrategy else { return }
            // The assignment made for alignment **must not reach disk**; see `resyncingRetentionStrategy` for the reason.
            guard !resyncingRetentionStrategy else { return }
            retentionStrategy.store()
        }
    }

    /// After `eraseAllTraces()`, flips the in-memory value back to the default without writing the key back.
    ///
    /// Without this gate something rather ironic happens: self-destruct has just deleted the `DEFAULT_ANTI_THEFT_RETENTION_STRATEGY`
    /// key, and the next assignment, "make memory agree with disk", recreates it unchanged through `didSet` —
    /// a POPOPX-specific key name reappearing in UserDefaults is exactly what this entire wipe exists to remove.
    private var resyncingRetentionStrategy = false

    /// Keyboard submission. The overlay calls this single method and then **handles every verdict other than `.unlocked`, `.duress` and `.lockedOut`
    /// on the same branch** — the cooldown branch also only renders the countdown, it does not pop an "error".
    ///
    /// Timing: check the cooldown first (**ahead of any derivation**) → draw this run's target duration → two constant derivations → branch on the verdict
    /// (duress hit → double snapshot + the whole wipe and rebuild; wrong → counting and cooldown; 10th attempt with the switch on → silent wipe)
    /// → and only at the end is time short of the target topped up. The top-up sits last rather than first so that the real self-destruct
    /// hides entirely inside the same floor; the target duration is drawn **before any verdict happens**, otherwise the random number would leak the branch.
    ///
    /// Why random jitter rather than a flat 1.2 second wait: one 100k derivation measures 355ms, and both branches pay
    /// those two derivations ≈ 0.71 seconds, so a normal unlock always equals the floor; a duress unlock additionally pays the whole erase+rebuild,
    /// which **exceeds** the floor. A fixed value turns a stopwatch into a criterion (1.20 s = live account, longer = the account is already gone).
    /// Jitter spreads normal unlocks over 1.2~2.4 seconds, overlapping the duress path's real duration, so a single press yields no conclusion.
    /// Honest boundary: this only makes **one** attempt undecidable; an unusually slow erase (e.g. a large store) still shows its tail,
    /// and the genuinely strong criterion is "did the interface change after pressing", which is guaranteed by `PopopxAppLockState.showsLockUI`
    /// staying false throughout the whole flow (the overlay keeps covering, with only the same breathing).
    func submit(pin: String) async -> PopopxDuressAuthOutcome {
        refreshConfiguration()
        // During the cooldown not one derivation is paid. This is not saving CPU: an interface that paid the 0.71 seconds still looks like it is "verifying",
        // while in fact it releases nothing — the brief asks for the keyboard, Face ID and mnemonic entries to be disabled together.
        guard !isLockedOut else { return .lockedOut(remaining: lockoutRemainingSeconds) }
        let started = Date()
        let target = Self.flowTargetSeconds()
        var outcome = await verify(pin: pin)
        switch outcome {
        case .unlocked:
            // "after any correct verification succeeds, zero `failedAttemptCount` immediately".
            clearFailures()
        case .duress:
            clearFailures()
            await runDuressUnlock(pin: pin)
        case .wrong:
            outcome = await settleWrongAttempt()
        case .notConfigured:
            break
        case .lockedOut:
            // `verify` never returns this branch (it is pure verification); it only leaves an honest landing point for switch exhaustiveness.
            break
        }
        await pad(to: started, target: target)
        return outcome
    }

    /// The silent pipeline run when the emergency code is hit (brief steps A → B → C → D).
    /// Split out of `submit` only so that `submit`'s branch shape can be checked at a glance; the order, the snapshots and the flag-raising all stay as they were.
    private func runDuressUnlock(pin: String) async {
        // Step A (the double snapshot is locked before erasure). Both things must precede any erasure action, for different reasons:
        // A1 the strategy snapshot: `PopopxStorageWipe` deletes every UserDefaults key of this module,
        //    including the retention strategy (`.retainExistingProfile` still carries the target profileId,
        //    which is an identity datum, also inside this key). So it is read into this local constant before anything starts,
        //    and the rebuild phase honours only that copy, never reading the configuration again.
        // A2 the credential snapshot: the emergency code just typed is re-derived with a **brand-new 32-byte salt**.
        //    The erasure deletes both old records, leaving only the plaintext passphrase in hand afterwards; and this derivation measures 355ms,
        //    so putting it after the erasure means paying one perceptible pause more underneath the overlay.
        let strategy = retentionStrategy
        var demoted = await demotedVerifier(for: pin)
        // Raise the flag; from here the overlay takes the "breathe as usual" branch, and whether the erasure succeeds or fails `endDuressFlow()` collects it.
        // false = a round is already running (that chain is not reentrant). Then **no second round starts, but the verdict is still .duress**:
        // turning it into `.wrong` would pop a "wrong password" on the spot, exactly the exposure the whole path exists to avoid.
        guard PopopxAppLockState.shared.beginDuressFlow() else { return }
        await runDuressFlow(strategy: strategy, demoted: &demoted)
        PopopxAppLockState.shared.endDuressFlow()
        PopopxAppLockState.shared.unlock()
    }

    /// The derivation side of step A2: computes the full record of "the single entry password after the downgrade" (new salt + new hash).
    private func demotedVerifier(for pin: String) async -> PopopxDuressVerifier {
        let salt = PopopxDuressCrypto.randomSalt()
        let derived = await derive(secret: pin, salt: salt, iterations: PopopxDuressCrypto.iterations)
        return PopopxDuressVerifier(salt: salt, hash: derived, iterations: PopopxDuressCrypto.iterations)
    }

    /// Steps B → C → D; the naming is aligned with the brief item by item so that acceptance can check by number.
    ///
    /// The three branches converge on exactly one point: **in the Keychain only one normal record is left at the end, and it accepts this downgraded code**,
    /// while upstream's `LocalAuthView` keyboard retires at the same time, leaving this module's single front-end authentication entry.
    /// Neither branch writes the downgraded code back into `kcAppPassword`: the same code living in two places at once means reinstalling the
    /// second keyboard right where it was removed (for the full branch see the nil passed by `runFullWipe`, for the retaining branch see the step below).
    private func runDuressFlow(
        strategy: PopopxDuressRetentionStrategy,
        demoted: inout PopopxDuressVerifier
    ) async {
        // Step B: runs the selective or the full physical erasure according to the strategy. The second return value is "the simulated plan to install only after C has written",
        // and the reason it is handed over after C is written in the comment on `runFullWipe` (the order is safe); it is not a casual choice.
        let outcome = await executeErasure(strategy: strategy)
        let effective = outcome.strategy
        // Single front door: the native entry code retires here, covering both branches (the full branch's `PopopxStorageWipe` already deleted it once by passing nil,
        // so this is the idempotent second time plus completing the mode). Sitting **after** `executeErasure` is load-bearing:
        // the retaining branch needs `kcAppPassword` as the fallback for the hidden identity's `viewPwd` (see `PopopxDuressProfileKeeper.retain`),
        // and deleting it first would cut off that road itself; it also sits before step C, so the screen never shows the instant of "both front doors present
        // and both accepting the downgraded code".
        retireNativeEntryPassword()
        // Step C (write the downgraded credential one way): the order is load-bearing at the back end — inside B both old credentials were deleted
        // (the full path: see `PopopxStorageWipe.wipe`; the retaining path: see `scrubCredentialHistory()`),
        // so writing first would have it deleted by ourselves; written here, no second path can ever read the emergency record again.
        // Deleting `duressAccount` once more is idempotent, but it guarantees the retaining path leaves no emergency code behind even if it fails midway.
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        // Step D: immediately after a successful write to disk, the salt and hash in memory are overwritten in place.
        let written = demoteCredential(&demoted)
        if written {
            normalConfigured = true
        } else {
            // A failed write **shows nothing**: any prompt on this interface is an exposure. Better to degrade into
            // "the downgraded code cannot get in while the owner's original code still can" than to leave a single word on screen.
            logger.error("duress demote: keychain write failed")
            normalConfigured = false
        }
        duressConfigured = false
        // The rebuild side of step D: the simulated content reaches disk only **after the downgraded credential has been written into the Keychain**.
        // `install` writes that layout file itself, so placing this step after C means: the traces left on disk inside a crash window
        // point at most to the one that is "as strong as the entry password", rather than to a layout no longer protected by any credential.
        await installDecoyPlan(outcome.pendingDecoy)
        if effective.isRetainExisting {
            // The retaining branch does not go through the rebuild, so the module's in-memory configuration cache has to be put back deliberately once:
            // the key has already been deleted by `eraseAllTraces()`, yet memory still holds the identity id the owner named.
            // Going through the gate rather than assigning directly keeps this restore from writing the key back into UserDefaults (see the comment above).
            resyncingRetentionStrategy = true
            retentionStrategy = .emptyProfile
            resyncingRetentionStrategy = false
        }
        resyncErasedSwitches()
    }

    /// After the wipe, puts back in place the two items that are "still in memory but already deleted from disk by `eraseAllTraces()`":
    /// the mnemonic state and the 10th-attempt switch. Both branches are covered (the full one via `disarmsAntiTheft`, the retaining one via
    /// step 4 of `PopopxDuressProfileKeeper.retain`; both call the same scrub).
    ///
    /// The switch item is **assigned through the gate**, for word-for-word the same reason as `resyncingRetentionStrategy`: not restoring it leaves the settings page
    /// showing "enabled" (while the key is gone, so the next cold launch turns it back to off — one device saying two things about one fact),
    /// and restoring it without the gate recreates the just-deleted key by hand.
    ///
    /// The two mnemonic records themselves are deleted by the erasure (full: step 7 of `PopopxStorageWipe`; retaining:
    /// `scrubCredentialHistory`); only the in-memory state is flattened here. Recovery capability going away with the identity is **deliberate**:
    /// a `popopx.duress.mnemonic` item is itself the fingerprint of "this device once had the anti-theft dual password".
    /// The price stated plainly: the downgraded code then has no offline recovery, and forgetting it means self-destructing once more; an owner who wants recovery
    /// has to regenerate one on the settings page and copy it down again.
    private func resyncErasedSwitches() {
        mnemonicConfigured = false
        resyncingTenStrikeSwitch = true
        wipeOnTenthFailure = false
        resyncingTenStrikeSwitch = false
    }

    /// The 10th consecutive error + the switch on: runs **exactly the same** erasure and rebuild pipeline as the emergency-code path
    /// (B → retire the native entry code → install the simulated content → put things back), with one step different: **no step C credential downgrade**.
    ///
    /// That step's input is "the code just proven correct", while what was just proven here is "this code is wrong". Downgrading
    /// would promote the visitor's 10th wrong guess into the device's only entry password — the one thing this module must least let happen.
    /// So the end state is "dual password not set": after the wipe a freshly installed empty app is handed over, and even that keyboard no longer appears
    /// (`PopopxAppLockOverlayModel.begin()` takes the `normalConfigured == false` branch).
    /// This difference from the brief's "self-destruct and rebuild flow completely identical to the emergency erase password" is deliberate, and is written into the acceptance report.
    private func runTenStrikeWipe() async {
        let strategy = retentionStrategy
        let outcome = await executeErasure(strategy: strategy)
        retireNativeEntryPassword()
        // The credentials are deleted once more here: `PopopxStorageWipe` on the full branch and
        // `scrubCredentialHistory` on the retaining branch have both already deleted them; this pair is an idempotent third time, but it guarantees that even "erasure failing midway"
        // leaves no credential that can still open the door — this time there is not even a downgraded code, so keeping an old credential means keeping the real identity.
        // The mnemonic pair counts as part of the same "can still open the door" set: that paper can reset out an entry password,
        // so like the two codes it must be dropped here for the third time. The cooldown record is not in this list — it is handled by
        // the `clearFailures()` below, which zeroes the in-memory `lockoutEndsAt` at the same time.
        PopopxDuressKeychain.delete(PopopxDuressKeychain.normalAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicPhraseAccount)
        normalConfigured = false
        duressConfigured = false
        // The counter and the cooldown are cleared together: the device is already empty, so "you have guessed wrong 10 times" no longer has anything to protect,
        // and keeping it would make the next lock screen pop a one-hour countdown straight away (a false alarm shown to the owner).
        clearFailures()
        await installDecoyPlan(outcome.pendingDecoy)
        if outcome.strategy.isRetainExisting {
            resyncingRetentionStrategy = true
            retentionStrategy = .emptyProfile
            resyncingRetentionStrategy = false
        }
        resyncErasedSwitches()
    }

    // MARK: Progressive cooldown (modelled on the native iOS lock screen)

    /// Settles one wrong verification: count +1, lock according to the table, and on the 10th attempt switch to a silent wipe when the switch is on.
    ///
    /// The keyboard path (`submit`) uses the return value as this run's verdict; the mnemonic path (`resetEntryPinWithMnemonic`)
    /// ignores the return value and only throws outward — over there the interface has already switched to the reset form, and the cooldown brings its state back through
    /// `isLockedOut` and `lockoutRemainingSeconds`, two read-only properties. Both paths share the same settlement,
    /// so "one and the same table" has exactly one implementation in the code.
    @discardableResult
    private func settleWrongAttempt() async -> PopopxDuressAuthOutcome {
        let strikes = registerFailure()
        guard strikes >= PopopxLockoutSchedule.wipeThreshold, wipeOnTenthFailure else {
            return isLockedOut ? .lockedOut(remaining: lockoutRemainingSeconds) : .wrong
        }
        guard PopopxAppLockState.shared.beginDuressFlow() else {
            // A round is already running: no second round starts, and `.wrong` is not returned either (that would pop
            // a "wrong password" on the overlay while the self-destruct is in progress, and any abnormal feedback from this interface is an exposure). Returning `.duress` lets the UI
            // keep taking the "breathe as usual" branch, exactly isomorphic to `runDuressUnlock`'s non-reentrancy.
            return .duress
        }
        await runTenStrikeWipe()
        // The counter and the cooldown are zeroed together. Three reasons stack on this one line:
        // 1. The brief requires this path to be "a self-destruct and rebuild flow completely identical to the emergency erase password" — the emergency-hit branch
        //    inside `submit` runs `clearFailures()` first, and not clearing cannot be called completely identical.
        // 2. After the wipe the regular code record no longer exists (`PopopxStorageWipe` step 7 deletes it along with the rest),
        //    so this table has nothing left to protect; keeping it would only make the overlay, on a device that "has no password at all",
        //    show a one-hour countdown — the cell that is hardest for the owner to explain about himself.
        // 3. The record on disk has already been deleted by the wipe, so an uncleared memory copy becomes a piece of state
        //    ghost state - it disappears on restart, the exact opposite of the promise that "brute-force protection survives killing the process and relaunching".
        clearFailures()
        PopopxAppLockState.shared.endDuressFlow()
        PopopxAppLockState.shared.unlock()
        return .duress
    }

    /// Records one failure and locks according to `PopopxLockoutSchedule`. Returns which attempt number this was.
    ///
    /// Order: change memory first, then write the disk. The reverse (disk first) would leave, when the write fails, the split "5 on disk, 4 in memory",
    /// and the memory value is the one the interface reads this round; the only consequence of a failed write is "killing and relaunching falls back to 4 attempts",
    /// which is one degradation, not one bypass - and it has already left a trace in `logger` (containing no credentials).
    @discardableResult
    private func registerFailure() -> Int {
        let strikes = failedAttemptCount + 1
        failedAttemptCount = strikes
        let seconds = PopopxLockoutSchedule.lockoutSeconds(afterAttemptCount: strikes)
        lockoutEndsAt = seconds > 0 ? Date().addingTimeInterval(seconds) : nil
        if !PopopxDuressKeychain.writeLockout(
            PopopxLockoutRecord(
                failedAttempts: strikes,
                lockoutEndTimestamp: lockoutEndsAt?.timeIntervalSince1970
            )
        ) {
            logger.error("duress lockout: persistence failed at strike \(strikes)")
        }
        return strikes
    }

    /// Zeroing: memory and disk together. **Delete the entry** rather than write a 0 into it - keeping a record of "0 attempts" is the same as
    /// long-term storage in the Keychain of the fact that "this device had brute-force protection enabled", and that is exactly what the self-destruct path clears
    /// (`PopopxStorageWipe` step 7 and `scrubCredentialHistory` delete it on the same terms).
    private func clearFailures() {
        failedAttemptCount = 0
        lockoutEndsAt = nil
        PopopxDuressKeychain.delete(PopopxDuressKeychain.lockoutAccount)
    }

    /// Implementation of step B. Returns the strategy **actually executed** plus a decoy plan "left to be installed after step C":
    /// returning the strategy to the caller is what lets "the identity named for retention is already gone" degrade safely to `.simulatedDecoy`
    /// a full rebuild (the brief's own words: never hang on a white screen); returning the plan to the caller is what orders the disk write after the demoted credentials.
    private func executeErasure(
        strategy: PopopxDuressRetentionStrategy
    ) async -> (strategy: PopopxDuressRetentionStrategy, pendingDecoy: PopopxDecoyPlan?) {
        if strategy.isRetainExisting, let profileId = strategy.retainedProfileId {
            let outcome = await PopopxDuressProfileKeeper.retain(
                profileId: profileId,
                appPasscode: kcAppPassword.get()
            )
            switch outcome {
            case .success:
                scrubCredentialHistory()
                return (strategy, nil)
            case .failure(let stage):
                // Log only. The degradation direction is "the more thorough kind of wipe"; it can never reverse into "wipe a little less".
                logger.error("duress retain failed at \(stage); falling back to simulated decoy")
                let fallback = PopopxDuressRetentionStrategy.simulatedDecoy
                return (fallback, await runFullWipe(strategy: fallback))
            }
        }
        return (strategy, await runFullWipe(strategy: strategy))
    }

    /// The half of the installation deferred until after step C. `install` is itself a no-op for a plan that "injects no content"
    /// (neither writes to disk nor flips a switch), so the strategy is not re-judged here - judging it in two places gives two places that can disagree.
    private func installDecoyPlan(_ plan: PopopxDecoyPlan?) async {
        guard let plan else { return }
        await PopopxDecoyProfileGenerator.shared.install(plan)
    }

    /// Full erasure: the database, the XFTP cache, the mesh identity mappings, the offline sandbox and the old credentials all go through
    /// `PopopxStorageWipe` (which internally already covers `kcAppPassword`/`kcSelfDestructPassword`
    /// and this module's two records, plus the whole trail behind `disarmsAntiTheft`).
    ///
    /// Return value = the decoy plan still to install (`nil` = this tier injects no content at all). **Deliberately not installed inside `afterRebuild`
    /// itself**: that hook runs before step C, so module four would write the layout files to disk and only then would the flow write the demoted credentials;
    /// crash once in the middle and the sandbox keeps a trace of "there used to be an account that no credential protects any more".
    /// Deferred until after C, the disk order becomes credentials -> content, so no interruption can leave anything weaker than the credentials.
    private func runFullWipe(strategy: PopopxDuressRetentionStrategy) async -> PopopxDecoyPlan? {
        // Blank account = install no simulated content at all; smokescreen = install on module four's schedule. The **erasure** of the two is identical,
        // the only difference is whether the account handed over after the rebuild contains fabricated chat history.
        let plan: PopopxDecoyPlan? = strategy == .emptyProfile ? nil : PopopxDecoyProfileGenerator.shared.makePlan(strategy: strategy)
        let options = PopopxStorageWipe.Options(
            // The demotion code is written only into this module's own verifier entry. Writing it back to `kcAppPassword` would rebuild a second keypad in place,
            // while passing nil takes exactly the `kcAppPassword.remove()` branch inside `wipe`: the newly rebuilt database is left to
            // `chatMigrateInit` to generate its own random `kcDatabasePassword` (API.swift:34-42),
            // unrelated to the entry code, so no "rebuild the database key" step is needed here - and none exists.
            reinstatesAppPasscode: nil,
            displayName: plan?.userDisplayName,
            disarmsAntiTheft: true,
            afterRebuild: nil
        )
        let outcome = await PopopxStorageWipe.wipe(options: options)
        if case .failure(let stage) = outcome {
            // When the wipe fails **nothing is displayed at all** and the flow goes straight into the ordinary branch: an error popup is louder than any copy.
            // The correctness of this branch rests on the rehearsal in the settings page plus the acceptance report, not on an on-the-spot hint.
            // and it also **installs no simulated content**: if the database was not rebuilt successfully, inserting fake rows into a half-dead chat list only looks faker.
            logger.error("duress wipe failed at \(stage)")
            return nil
        }
        return plan
    }

    /// Credential scrubbing for the retain path. On the full path `PopopxStorageWipe` is responsible for deleting these entries,
    /// while the retain path does not delete the database, so the same entries are deleted here once more on the same terms.
    /// `kcAppPassword` is not deleted here, but that **does not mean it is not deleted**: it is retired by
    /// `retireNativeEntryPassword()` inside `runDuressFlow` after `executeErasure` returns - it has to be ordered after that,
    /// because this function's caller (`PopopxDuressProfileKeeper.retain`) still needs it as the `viewPwd` fallback for the hidden identity.
    /// It was never the database key (the database key is `kcDatabasePassword`, see POPOPXChat/API.swift:43).
    ///
    /// The self-destruct code's bool is in the cleanup as well, for exactly the reason stated in `migrateNativeEntryPassword`:
    /// that cell in privacy settings reads only `UserDefaults`, not the Keychain (PrivacySettings.swift:512/:898),
    /// with the entry deleted but the bool still standing, the page would go on showing "self-destruct code enabled" while there is no credential left to compare against.
    /// The terms match the full path's `PopopxStorageWipe` (:877 does removeObject the same way).
    ///
    /// The mnemonic pair and the cooldown record are deleted here too; "the same terms" means the five entries of `PopopxStorageWipe` step 7:
    /// the retain path does not delete the database, so if only the two codes were deleted, the sheet of paper in the owner's hand could still reset
    /// an entry password that opens the **real identity** - the only door on this path that is not shut. The cooldown record is the fingerprint of "brute-force protection was enabled here".
    private func scrubCredentialHistory() {
        _ = kcSelfDestructPassword.remove()
        UserDefaults.standard.removeObject(forKey: DEFAULT_LA_SELF_DESTRUCT)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.normalAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.duressAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.mnemonicPhraseAccount)
        PopopxDuressKeychain.delete(PopopxDuressKeychain.lockoutAccount)
    }

    /// The write side of steps C + D: write to disk first, then overwrite those two buffers in memory **in place**.
    ///
    /// `inout` is load-bearing, not a style choice: were the value type passed by value, the caller's copy would still point at the same
    /// salt/hash buffer as the parameter (reference count 2), so `withUnsafeMutableBytes` would copy on write first and `memset_s` would erase
    /// the freshly made private copy while the original loses not one byte - exactly the false safety of "looks erased, was not erased".
    /// `inout` borrows the copy the caller owns exclusively (same terms as the comment at `PopopxSecurePayload.swift:455`).
    ///
    /// Honest boundary: the passphrase plaintext itself is an ARC-managed `String` and cannot be overwritten at the Swift layer. Across the whole pipeline it lands
    /// as `Data` exactly once (inside `derive(secret:salt:iterations:)`), and that function's own `defer` zeroes it on the spot;
    /// beyond that it is stored in no property, no collection and no log.
    private func demoteCredential(_ verifier: inout PopopxDuressVerifier) -> Bool {
        let written = PopopxDuressKeychain.write(verifier, account: PopopxDuressKeychain.normalAccount)
        popopxSecureErase(&verifier.salt)
        popopxSecureErase(&verifier.hash)
        return written
    }

    /// The target duration of this unlock: `minimumFlowSeconds` plus 0~1.2 seconds of jitter.
    /// It uses `SystemRandomNumberGenerator` (the engine under `Double.random`) - it was designed for unpredictability;
    /// cryptographic strength is not needed here, because an attacker cannot work the drawn number back from the observed duration (the true value is swallowed by the erasure time),
    /// and it is enough that **the owner cannot predict it either** - whether the next one is 1.3 seconds or 2.2 seconds.
    static func flowTargetSeconds() -> TimeInterval {
        minimumFlowSeconds + Double.random(in: 0...flowJitterSeconds)
    }

    private func pad(to started: Date, target: TimeInterval) async {
        let spent = Date().timeIntervalSince(started)
        let remaining = target - spent
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    /// Biometric quick unlock. Uses `.deviceOwnerAuthenticationWithBiometrics` rather than the upstream
    /// `systemAuthenticate`'s `.deviceOwnerAuthentication` (LocalAuthenticationUtils.swift:65):
    /// the latter falls back on its own to the **device** unlock passcode, and that road bypasses this module's keypad, hence the duress code too -
    /// whoever forces the owner onto the fingerprint gets no choice over "which code to type", and that choice is the whole pivot of the dual-password scheme.
    /// So on failure/unavailability it degrades to this module's own 6-digit keypad, and that step cannot be dropped.
    ///
    /// On success this method has **already** released the lock (`PopopxAppLockState.unlock()`); the `false`
    /// from `completion` only means "the keypad should be handed over now", so the overlay does not have to work out whether to change the lock state.
    /// Biometrics can never lead to self-destruct: it proves "this is the owner", it cannot prove "which code was used".
    ///
    /// `!isLockedOut` is the second gate for the brief's "no Face ID during the cooldown" (the first one is in
    /// `prefersBiometricUnlock`). Put here and not only there: callers may assemble the condition themselves,
    /// while the nature of this rule is "no entry point may leave a backdoor into the cooldown", so it blocks once more as close to the action as possible.
    /// When blocked it answers `completion(false)` - that means exactly "the keypad should be handed over now", and the keypad is itself
    /// disabled by `isLockedOut`, so the UI stays parked on the countdown, which is precisely what the design asks for.
    ///
    /// The success path also calls `clearFailures()`: the brief says "reset immediately after any correct verification",
    /// and a biometric match is a correct verification. Without this an absurd state would appear - the owner unlocks with his own face,
    /// yet the next lock screen still plays him an hour-long countdown because a visitor guessed wrong 5 times.
    func requestBiometricUnlock(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard biometricsEnabled, !keypadRequired, !isLockedOut,
              context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            Task { @MainActor in
                guard success else {
                    self.biometricFailures += 1
                    if self.biometricFailures >= Self.maxBiometricFailuresBeforeKeypad {
                        self.keypadRequired = true
                    }
                    completion(false)
                    return
                }
                self.biometricFailures = 0
                self.keypadRequired = false
                self.clearFailures()
                PopopxAppLockState.shared.unlock()
                completion(true)
            }
        }
    }

    /// Called after the keypad unlocks successfully; resets the failure count so the next overlay opening can still use biometrics.
    ///
    /// The cooldown count is not cleared here - the branch of `submit(pin:)` that hits the regular code has already called `clearFailures()`,
    /// which is the zeroing point of that table; this function only handles biometrics' own "switch to the keypad after 2 consecutive failures",
    /// the two are separate tables, and merging them would make one slipped Face ID look like one guessed passcode.
    func resetBiometricFailures() {
        biometricFailures = 0
        keypadRequired = false
    }
}
