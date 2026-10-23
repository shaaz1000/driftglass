import AppKit
import Combine
import Network
import ServiceManagement

/// Advertises this Mac on the local network and serves one iPhone at a time.
@MainActor
final class Host: ObservableObject {
    enum State: Equatable { case idle, waiting, connected(String), failed(String) }

    @Published var state: State = .idle
    @Published var fps: Double = 0
    @Published var password: String {
        didSet { UserDefaults.standard.set(password, forKey: "password"); restart() }
    }
    @Published var screenOK = CGPreflightScreenCaptureAccess()
    @Published var inputOK = AXIsProcessTrusted()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var listener: NWListener?
    private var conn: NWConnection?
    // Streamer serialises its own work on a private queue, so any thread may call it.
    nonisolated(unsafe) private let streamer = Streamer()
    private let net = DispatchQueue(label: "driftglass.net", qos: .userInteractive)
    private var permissionTimer: Timer?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "password"), !saved.isEmpty {
            password = saved
        } else {
            password = String(format: "%06d", Int.random(in: 0...999_999))
            UserDefaults.standard.set(password, forKey: "password")
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

    func start() {
        guard !password.isEmpty, let l = try? NWListener(using: Wire.parameters(password: password)) else {
            state = .failed("Could not start listening")
            return
        }
        l.service = NWListener.Service(name: machineName, type: Wire.service)
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
        drop() // a new phone takes over from the old one
        conn = c
        c.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                guard let self, self.conn === c else { return }
                switch s {
                case .ready:
                    let b = CGDisplayBounds(CGMainDisplayID())
                    c.sendJSON(.hello, HostHello(name: self.machineName, width: b.width, height: b.height))
                case .failed, .cancelled:
                    self.drop()
                default: break
                }
            }
        }
        c.receiveLoop { [weak self] type, body in self?.received(type, body, from: c) }
        c.start(queue: net)
    }

    /// Called on the network queue; input is posted straight from here to keep latency down.
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
        conn?.cancel()
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
