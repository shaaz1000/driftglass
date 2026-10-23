import AVFoundation
import Network
import Security
import UIKit

/// Finds Driftglass Macs on the local network.
final class Discovery: ObservableObject {
    struct Mac: Identifiable, Hashable {
        var name: String
        var endpoint: NWEndpoint
        var hostID: String     // from the Mac's TXT record; what pairings are pinned to
        var salt: Data?        // the salt the Mac's current key was derived with
        var id: String { hostID }
    }

    @Published var macs: [Mac] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        // The TXT variant is needed to receive each Mac's ID and salt alongside its address.
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.service, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { r -> Mac? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var hostID = "name:" + name, salt: Data?
                if case let .bonjour(txt) = r.metadata {
                    if let id = txt["id"] { hostID = id }
                    salt = txt["salt"].flatMap { Data(hex: $0) }
                }
                return Mac(name: name, endpoint: r.endpoint, hostID: hostID, salt: salt)
            }.sorted { $0.name < $1.name }
            DispatchQueue.main.async { self?.macs = macs }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// One live connection to a Mac: receives HEVC video, decodes it in hardware straight into a
/// display layer, and sends input events back.
final class Session: ObservableObject {
    enum State: Equatable { case connecting, live, wrongPassword, failed(String) }

    @Published private(set) var state: State = .connecting
    @Published private(set) var fps: Double = 0
    @Published private(set) var macSize = CGSize(width: 1440, height: 900)
    @Published private(set) var hostName: String

    var onWrongPassword: (() -> Void)?
    var onAuthenticated: (() -> Void)?
    let layer = AVSampleBufferDisplayLayer()
    private let conn: NWConnection
    private let net = DispatchQueue(label: "driftglass.client", qos: .userInteractive)
    private let bitrate: Int
    private var format: CMVideoFormatDescription?
    private var frameTimes: [CFTimeInterval] = []
    private var keyframeAsked = false

    init(mac: Discovery.Mac, key: Data, bitrate: Int) {
        hostName = mac.name
        self.bitrate = bitrate
        conn = NWConnection(to: mac.endpoint, using: Wire.parameters(key: key))
        layer.videoGravity = .resize
        layer.preventsDisplaySleepDuringVideoPlayback = true
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            #if DEBUG
            NSLog("Driftglass connection state: \(s)")
            #endif
            switch s {
            case .ready:
                self.conn.sendJSON(.clientHello, ClientHello(name: UIDevice.current.name, bitrate: self.bitrate))
                self.publish { $0.state = .live; $0.onAuthenticated?() }
            case .waiting(let e), .failed(let e):
                // A PSK mismatch surfaces as a TLS handshake error.
                if case .tls = e { self.publish { $0.state = .wrongPassword } }
                else { self.publish { $0.state = .failed(e.localizedDescription) } }
                if case .failed = s {} else { self.conn.cancel() }
            default: break
            }
        }
        conn.receiveLoop { [weak self] type, body in self?.received(type, body) }
        conn.start(queue: net)
        // A wrong code doesn't always surface as an error: the connection keeps retrying other
        // paths and sits in "preparing". The Mac was just seen on Bonjour, so a handshake that
        // hasn't finished in a few seconds almost always means the code doesn't match.
        net.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.conn.state != .ready, self.conn.state != .cancelled else { return }
            self.conn.cancel()
            self.publish { $0.state = .wrongPassword }
        }
    }

    func stop() {
        conn.cancel()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }

    func send(_ e: InputEvent) { conn.sendJSON(.input, e) }

    private func publish(_ change: @escaping (Session) -> Void) {
        DispatchQueue.main.async { change(self) }
    }

    // MARK: receive (network queue)

    private func received(_ type: MsgType, _ body: Data) {
        switch type {
        case .hello:
            if let h = try? JSONDecoder().decode(HostHello.self, from: body) {
                publish { $0.hostName = h.name; $0.macSize = CGSize(width: h.width, height: h.height) }
            }
        case .format:
            format = makeFormat(body)
        case .frame:
            var ack = Data()
            ack.appendU32(body.u32(at: 0))
            conn.send(.ack, ack)
            display(body.dropFirst(4))
        default: break
        }
    }

    private func makeFormat(_ d: Data) -> CMVideoFormatDescription? {
        var sets: [Data] = []
        var off = 1
        for _ in 0..<Int(d[d.startIndex]) {
            let len = Int(d.u16(at: off))
            off += 2
            sets.append(Data(d[d.startIndex + off ..< d.startIndex + off + len]))
            off += len
        }
        let bufs = sets.map { s -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            s.copyBytes(to: p, count: s.count)
            return p
        }
        defer { bufs.forEach { $0.deallocate() } }
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: sets.count, parameterSetPointers: bufs.map { UnsafePointer($0) },
            parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
        if let fd {
            let dims = CMVideoFormatDescriptionGetDimensions(fd)
            NSLog("Driftglass format \(dims.width)x\(dims.height)")
        }
        return fd
    }

    private func display(_ payload: Data) {
        let renderer = layer.sampleBufferRenderer
        guard let fd = format else { askKeyframe(); return }
        if renderer.status == .failed {
            renderer.flush()
            askKeyframe()
            return
        }
        let len = payload.count
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: len,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return }
        payload.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: len) }
        var sb: CMSampleBuffer?
        var size = len
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sb)
        guard let sb else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sb)
        keyframeAsked = false

        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        let fps = Double(frameTimes.count)
        publish { $0.fps = fps }
    }

    private func askKeyframe() {
        guard !keyframeAsked else { return }
        keyframeAsked = true
        conn.send(.keyframe)
    }
}

/// What the phone remembers about each paired Mac, in the Keychain (this device only).
/// It stores the derived key rather than the password, pinned to the Mac's ID and salt.
struct PairingRecord: Codable {
    var key: Data
    var salt: Data

    private static func account(_ hostID: String) -> String { "pair." + hostID }

    static func load(_ mac: Discovery.Mac) -> PairingRecord? {
        Keychain.data(account(mac.hostID)).flatMap { try? JSONDecoder().decode(PairingRecord.self, from: $0) }
    }

    /// A pairing only counts if the Mac still advertises the salt we paired with. A new salt
    /// means its code changed (or it isn't the same Mac), so ask again rather than reuse the key.
    static func usable(_ mac: Discovery.Mac) -> PairingRecord? {
        guard let r = load(mac), r.salt == mac.salt else { return nil }
        return r
    }

    func save(for mac: Discovery.Mac) {
        if let d = try? JSONEncoder().encode(self) { Keychain.set(d, Self.account(mac.hostID)) }
    }

    static func forget(_ mac: Discovery.Mac) { Keychain.delete(account(mac.hostID)) }
}
