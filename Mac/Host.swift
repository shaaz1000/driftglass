import AppKit
import Combine
import Network
import ServiceManagement

/// Advertises this Mac on the local network and serves one iPhone at a time.
@MainActor
final class Host: ObservableObject {
    enum State: Equatable { case idle, waiting, connected(String), paused, failed(String) }

    @Published var state: State = .idle
    @Published var fps: Double = 0
    /// The pairing code. Kept in the Keychain; changing it rotates the salt, so every paired
    /// phone has to pair again and old recorded handshakes become useless.
    @Published var password: String {
        didSet {
            Keychain.set(Data(password.utf8), Self.passwordAccount)
            salt = Self.rotateSalt()
            restart()
        }
    }
    @Published var screenOK = CGPreflightScreenCaptureAccess()
    @Published var inputOK = AXIsProcessTrusted()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Stable identity the phone pins at first pairing, so another device using this Mac's name
    /// isn't treated as the same Mac.
    let hostID: String
    private var salt: Data

    private var listener: NWListener?
    private var conn: NWConnection?              // the authenticated phone
    private var authenticated = Set<ObjectIdentifier>()
    private var failures: [Date] = []
    private var pausedUntil = Date.distantPast

    // Streamer serialises its own work on a private queue, so any thread may call it.
    nonisolated(unsafe) private let streamer = Streamer()
    private let net = DispatchQueue(label: "driftglass.net", qos: .userInteractive)
    private var permissionTimer: Timer?

    private static let passwordAccount = "host.password"
    // One wrong try from a phone fails several handshakes (it races every interface and IP
    // family), so this allows roughly five tries a minute while keeping guessing far too slow.
    private static let maxFailures = 20
    private static let failureWindow: TimeInterval = 60
    private static let pause: TimeInterval = 60
    private static let handshakeTimeout: TimeInterval = 10

    init() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "hostID") {
            hostID = id
        } else {
            hostID = UUID().uuidString
            defaults.set(hostID, forKey: "hostID")
        }
        salt = defaults.data(forKey: "salt") ?? Self.rotateSalt()

        // Earlier versions kept a short numeric password in plain-text defaults. Drop it and
        // issue a strong code instead.
        defaults.removeObject(forKey: "password")
        if let d = Keychain.data(Self.passwordAccount), let saved = String(data: d, encoding: .utf8), !saved.isEmpty {
            password = saved
        } else {
            password = Pairing.newCode()
            Keychain.set(Data(password.utf8), Self.passwordAccount)
        }

        streamer.onFormat = { [weak self] params in self?.conn?.send(.format, params) }
        streamer.onFrame = { [weak self] seq, data in
            var payload = Data(capacity: data.count + 4)
            payload.appendU32(seq)
            payload.append(data)
            self?.conn?.send(.frame, payload)
        }
        streamer.onStats = { [weak self] fps in Task { @MainActor in self?.fps = fps } }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.screenOK = CGPreflightScreenCaptureAccess()
                self?.inputOK = AXIsProcessTrusted()
            }
        }
        start()
    }

    var machineName: String { Foundation.Host.current().localizedName ?? "Mac" }

    private static func rotateSalt() -> Data {
        let s = Pairing.randomBytes(16)
        UserDefaults.standard.set(s, forKey: "salt")
        return s
    }

    func start() {
        state = .idle
        let pw = password, salt = salt
        Task {
            // The key derivation is deliberately slow, so keep it off the main thread.
            let key = await Task.detached(priority: .userInitiated) { Pairing.deriveKey(password: pw, salt: salt) }.value
            guard pw == self.password, salt == self.salt, self.listener == nil else { return } // superseded
            self.listen(key: key)
        }
    }

    private func listen(key: Data) {
        guard let l = try? NWListener(using: Wire.parameters(key: key)) else {
            state = .failed("Could not start listening")
            return
        }
        l.service = NWListener.Service(name: machineName, type: Wire.service, domain: nil,
                                       txtRecord: Pairing.txt(hostID: hostID, salt: salt))
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
        l.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                guard let self else { return }
                switch s {
                case .ready: if case .connected = self.state {} else { self.state = .waiting }
                case .failed(let e): self.state = .failed(e.localizedDescription)
                default: break
                }
            }
        }
        l.start(queue: net)
        listener = l
    }

    func restart() {
        drop()
        listener?.cancel()
        listener = nil
        start()
    }

    private func accept(_ c: NWConnection) {
        // After repeated wrong passwords, refuse everyone for a while: online guessing stays slow.
        if Date() < pausedUntil {
            c.cancel()
            return
        }
        let id = ObjectIdentifier(c)
        c.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                guard let self else { return }
                switch s {
                case .ready:
                    // Only a phone that proved it knows the password may take over.
                    self.authenticated.insert(id)
                    if let old = self.conn, old !== c { self.drop() }
                    self.conn = c
                    let b = CGDisplayBounds(CGMainDisplayID())
                    c.sendJSON(.hello, HostHello(name: self.machineName, width: b.width, height: b.height))
                case .failed:
                    if !self.authenticated.contains(id) { self.recordFailure() }
                    self.closed(c)
                case .cancelled:
                    self.closed(c)
                default: break
                }
            }
        }
        c.receiveLoop { [weak self] type, body in self?.received(type, body, from: c) }
        c.start(queue: net)
        // Don't let half-open handshakes linger.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
            guard let self, !self.authenticated.contains(id) else { return }
            c.cancel()
        }
    }

    private func closed(_ c: NWConnection) {
        authenticated.remove(ObjectIdentifier(c))
        if conn === c { drop() }
    }

    private func recordFailure() {
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0) < Self.failureWindow } + [now]
        guard failures.count >= Self.maxFailures else { return }
        failures.removeAll()
        pausedUntil = now.addingTimeInterval(Self.pause)
        if conn == nil { state = .paused }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pause) { [weak self] in
            if self?.state == .paused { self?.state = .waiting }
        }
    }

    /// Called on the network queue; input is posted straight from here to keep latency down.
    /// Messages only arrive after the TLS handshake, so the sender knows the password.
    nonisolated private func received(_ type: MsgType, _ body: Data, from c: NWConnection) {
        switch type {
        case .input:
            if let e = try? JSONDecoder().decode(InputEvent.self, from: body) { Input.shared.handle(e) }
        case .ack:
            streamer.ack()
        case .keyframe:
            streamer.requestKeyframe()
        case .clientHello:
            let hello = try? JSONDecoder().decode(ClientHello.self, from: body)
            Task { @MainActor in
                guard self.conn === c else { return }
                self.state = .connected(hello?.name ?? "iPhone")
                do {
                    try await self.streamer.start(bitrate: hello?.bitrate ?? 20_000_000)
                } catch {
                    self.state = .failed("Screen Recording permission is needed")
                    CGRequestScreenCaptureAccess()
                }
            }
        default: break
        }
    }

    private func drop() {
        streamer.stop()
        Input.shared.releaseAll()
        if let c = conn { authenticated.remove(ObjectIdentifier(c)); c.cancel() }
        conn = nil
        fps = 0
        if listener != nil { state = .waiting }
    }

    func requestScreen() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func requestInput() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("Driftglass login item: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
