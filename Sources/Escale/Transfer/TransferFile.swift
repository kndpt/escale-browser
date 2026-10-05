// The envelope of a transfer file: what leaves the Mac as one sealed blob and
// what is refused before anything is decoded. The passphrase is stretched with
// PBKDF2 (CommonCrypto: the one passphrase KDF Apple ships, no dependency) and
// the payload is sealed with AES-GCM (CryptoKit), the header authenticated as
// associated data, so a changed version, salt or cost makes the file unopenable
// rather than merely different. Nothing here names the keychain, a Space or a
// path of the Mac that wrote it: the file opens anywhere with the passphrase.
//
// Layout, big endian: "ESCLXFER" · version (2) · PBKDF2 rounds (4) · salt (16)
// · AES-GCM combined box (nonce 12 · ciphertext · tag 16).
//
// GCM cannot tell a wrong passphrase from a changed file, so the two share one
// honest message. The rounds are read from the file, hence bounded: a hostile
// file must not be able to ask for an hour of key stretching, and one sealed
// in memory is bounded too (`largest`), which the whole import then reads once.
import CommonCrypto
import CryptoKit
import Foundation
import Security

enum TransferError: LocalizedError, Equatable {
    case notATransfer
    case unsupported(Int)
    case truncated
    case tooLarge
    case cannotOpen
    case emptyPassphrase
    case invalid(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notATransfer: return "This isn't an Escale file."
        case .unsupported(let version): return "This file comes from a newer Escale (format \(version)). Update Escale to open it."
        case .truncated: return "The file is incomplete. Copy it again from the Mac it came from."
        case .tooLarge: return "The file is larger than Escale will open."
        case .cannotOpen: return "The passphrase is wrong, or the file was changed."
        case .emptyPassphrase: return "Enter a passphrase."
        case .invalid(let why): return "The file can't be used: \(why)"
        case .unavailable(let why): return why
        }
    }
}

enum TransferFile {
    static let magic = Array("ESCLXFER".utf8)
    static let version = 1
    static let saltLength = 16
    static let headerLength = 8 + 2 + 4 + saltLength
    /// About a third of a second on a current Mac, paid once per open or save.
    static let rounds: UInt32 = 600_000
    static let roundsRange: ClosedRange<UInt32> = 100_000...5_000_000
    /// The whole file, read once into memory: bookmarks, sessions and histories
    /// are kilobytes, so this is a bound, not a size anyone approaches.
    static let largest = 64 * 1024 * 1024
    /// Header, nonce and tag: the smallest file that can hold anything.
    static let shortest = headerLength + 12 + 16

    /// The rounds a file asks for, after the checks that need no passphrase.
    /// Refuses what is not ours, not of this format, cut short or oversized.
    static func inspect(_ file: Data) throws -> UInt32 {
        guard file.count <= largest else { throw TransferError.tooLarge }
        guard file.count >= magic.count, Array(file.prefix(magic.count)) == magic else { throw TransferError.notATransfer }
        guard file.count >= shortest else { throw TransferError.truncated }
        let bytes = Array(file.prefix(headerLength))
        let found = Int(bytes[8]) << 8 | Int(bytes[9])
        guard found == version else { throw TransferError.unsupported(found) }
        let asked = bytes[10..<14].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard roundsRange.contains(asked) else { throw TransferError.invalid("unusual key stretching") }
        return asked
    }

    static func seal(_ payload: Data, passphrase: String, rounds: UInt32 = TransferFile.rounds) throws -> Data {
        guard !passphrase.isEmpty else { throw TransferError.emptyPassphrase }
        guard roundsRange.contains(rounds), payload.count < largest - shortest else { throw TransferError.tooLarge }
        var salt = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw TransferError.unavailable("Escale couldn't make a random key.")
        }
        var header = magic
        header += [UInt8(version >> 8), UInt8(version & 0xff)]
        header += (0..<4).map { UInt8((rounds >> UInt32(24 - 8 * $0)) & 0xff) }
        header += salt
        let key = try derive(passphrase, salt: salt, rounds: rounds)
        guard let box = try? AES.GCM.seal(payload, using: key, authenticating: Data(header)).combined else {
            throw TransferError.unavailable("Escale couldn't seal the file.")
        }
        return Data(header) + box
    }

    static func open(_ file: Data, passphrase: String) throws -> Data {
        let asked = try inspect(file)
        guard !passphrase.isEmpty else { throw TransferError.emptyPassphrase }
        let header = file.prefix(headerLength)
        let salt = Array(header.suffix(saltLength))
        let key = try derive(passphrase, salt: salt, rounds: asked)
        guard let box = try? AES.GCM.SealedBox(combined: file.dropFirst(headerLength)),
              let opened = try? AES.GCM.open(box, using: key, authenticating: Data(header)) else {
            throw TransferError.cannotOpen
        }
        return opened
    }

    /// Two spellings of the same letters are one passphrase: a Mac types
    /// "é" composed, another may type it decomposed.
    private static func derive(_ passphrase: String, salt: [UInt8], rounds: UInt32) throws -> SymmetricKey {
        let secret = Array(passphrase.precomposedStringWithCanonicalMapping.utf8).map { Int8(bitPattern: $0) }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret, secret.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count)
        guard status == kCCSuccess else { throw TransferError.unavailable("Escale couldn't derive a key.") }
        defer { derived = [UInt8](repeating: 0, count: 32) }
        return SymmetricKey(data: derived)
    }
}
