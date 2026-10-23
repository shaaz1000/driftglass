import CommonCrypto
import CryptoKit
import Foundation
import Network
import Security

/// Pairing secrets: how a password becomes the TLS pre-shared key, and where secrets live.
enum Pairing {
    /// PBKDF2-HMAC-SHA256 rounds. Deliberately slow (~0.3 s), so a recorded handshake can't be
    /// brute-forced quickly; both sides pay it once per pairing, not per frame.
    static let rounds: UInt32 = 600_000

    /// Codes are typed by hand, so ignore case, spaces and dashes.
    static func normalize(_ password: String) -> String {
        password.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    static func deriveKey(password: String, salt: Data) -> Data {
        let pw = Array(normalize(password).utf8CString.dropLast())
        var out = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
        }
        return Data(out)
    }

    /// A random code like `K7QM-2XRP-9HWD`: 12 characters from a 32-symbol alphabet with no
    /// look-alikes (no I, O, 0, 1), so 60 bits of entropy.
    static func newCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let bytes = randomBytes(12)
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] } // 256 is a multiple of 32: no bias
        return stride(from: 0, to: chars.count, by: 4).map { String(chars[$0 ..< $0 + 4]) }.joined(separator: "-")
    }

    static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    // MARK: Bonjour TXT: who this Mac is, and the salt its key was derived with.

    static func txt(hostID: String, salt: Data) -> NWTXTRecord {
        NWTXTRecord(["v": "2", "id": hostID, "salt": salt.hex])
    }
}

/// Generic-password Keychain items under the "driftglass" service.
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "driftglass", kSecAttrAccount as String: account]
    }

    static func data(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func set(_ data: Data, _ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        #if os(iOS)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var d = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i ..< j], radix: 16) else { return nil }
            d.append(b)
            i = j
        }
        self = d
    }
}
