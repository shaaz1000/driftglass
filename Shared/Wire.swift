import CryptoKit
import Foundation
import Network

/// The Driftglass wire protocol, shared by the Mac host and the iPhone client.
///
/// One TCP connection, wrapped in TLS with a pre-shared key derived from the password, so a
/// phone with the wrong password fails the handshake and nothing on the network can read
/// the stream. Every message is `[type: u8][length: u32 big-endian][payload]`.
enum Wire {
    static let service = "_driftglass._tcp"

    static func parameters(password: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(password.utf8))
        let psk = HMAC<SHA256>.authenticationCode(for: Data("driftglass-psk-v1".utf8), using: key)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("driftglass".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let sec = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(sec, pskData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 4
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo
        return params
    }
}

enum MsgType: UInt8 {
    // Mac → phone
    case hello = 1        // JSON HostHello
    case format = 2       // HEVC parameter sets: [count u8] then [len u16][bytes]...
    case frame = 3        // [seq u32][AVCC NAL units, 4-byte lengths]
    // phone → Mac
    case clientHello = 10 // JSON ClientHello
    case input = 11       // JSON InputEvent
    case ack = 12         // [seq u32]
    case keyframe = 13    // empty: decoder lost sync, send a fresh keyframe
}

struct HostHello: Codable {
    var name: String
    var width: Double     // main display size in points
    var height: Double
}

struct ClientHello: Codable {
    var name: String
    var bitrate: Int      // bits per second
}

struct InputEvent: Codable {
    enum Kind: String, Codable {
        case move       // relative pointer motion: x, y in Mac points
        case moveTo     // absolute: x, y normalised 0...1 on the main display
        case click      // b = button (0 left, 1 right); at x, y if present, else in place
        case down, up   // left button press/release (drag); at x, y if present
        case scroll     // x, y pixel deltas; phase / momentum mimic a real trackpad
        case key        // s = key name, m = modifiers
        case text       // s = text to type
        case action     // s = action name (mission, spotlight, ...)
    }
    var k: Kind
    var x: Double? = nil
    var y: Double? = nil
    var b: Int? = nil
    var s: String? = nil
    var m: [String]? = nil
    var phase: Int? = nil     // 1 began, 2 changed, 4 ended
    var momentum: Int? = nil  // 1 begin, 2 continue, 3 end
}

// MARK: - framing

extension Data {
    mutating func appendU32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendU16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    func u32(at i: Int) -> UInt32 {
        let b = [UInt8](self[startIndex + i ..< startIndex + i + 4])
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }
    func u16(at i: Int) -> UInt16 {
        UInt16(self[startIndex + i]) << 8 | UInt16(self[startIndex + i + 1])
    }
}

extension NWConnection {
    func send(_ type: MsgType, _ payload: Data = Data(), completion: (() -> Void)? = nil) {
        var d = Data(capacity: payload.count + 5)
        d.append(type.rawValue)
        d.appendU32(UInt32(payload.count))
        d.append(payload)
        send(content: d, completion: .contentProcessed { _ in completion?() })
    }

    func sendJSON<T: Encodable>(_ type: MsgType, _ value: T) {
        if let d = try? JSONEncoder().encode(value) { send(type, d) }
    }

    /// Reads messages forever, calling `handler` for each; stops on error or close.
    func receiveLoop(_ handler: @escaping (MsgType, Data) -> Void) {
        receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] head, _, done, err in
            guard let self, let head, head.count == 5, err == nil else { return }
            let type = MsgType(rawValue: head[head.startIndex])
            let len = Int(head.u32(at: 1))
            let next = {
                if done { return }
                self.receiveLoop(handler)
            }
            if len == 0 {
                if let type { handler(type, Data()) }
                next()
                return
            }
            self.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, _, err in
                guard let body, err == nil else { return }
                if let type { handler(type, body) }
                next()
            }
        }
    }
}
