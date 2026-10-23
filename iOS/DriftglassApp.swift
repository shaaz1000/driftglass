import SwiftUI

@main
struct DriftglassApp: App {
    var body: some Scene {
        WindowGroup { Root().preferredColorScheme(.dark) }
    }
}

private let ink = Color(red: 0.04, green: 0.07, blue: 0.08)
private let sea = Color(red: 0.62, green: 0.85, blue: 0.79)
private let amber = Color(red: 0.91, green: 0.77, blue: 0.54)

private func serif(_ size: CGFloat) -> Font { .custom("InstrumentSerif-Italic", size: size, relativeTo: .largeTitle) }

struct Root: View {
    @StateObject private var discovery = Discovery()
    @State private var session: Session?
    @State private var asking: Discovery.Mac?
    @State private var passwordError = false
    @AppStorage("lastMac") private var lastMac = ""
    @AppStorage("bitrate") private var bitrate = 20_000_000
    @AppStorage("natural") private var natural = true
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            if let session {
                Live(session: session, natural: natural) { disconnect(forgetAuto: true) }
                    .transition(.opacity)
            } else {
                home
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session == nil)
        .onAppear { discovery.start() }
        .onChange(of: discovery.macs) { _, macs in
            #if DEBUG
            if Demo.flag("dgSheet"), session == nil, let mac = macs.first { asking = mac; return }
            #endif
            autoConnect(macs)
        }
        .onChange(of: phase) { _, p in
            // iOS suspends sockets in the background; reconnect cleanly on return.
            if p == .background, session != nil { disconnect(forgetAuto: false) }
            if p == .active { discovery.start(); autoConnect(discovery.macs) }
        }
        .sheet(item: $asking) { mac in
            PasswordSheet(mac: mac, error: passwordError) { pw in
                Vault.save(pw, for: mac.name)
                asking = nil
                connect(mac)
            }
            .presentationDetents([.height(330)])
            .presentationBackground(.ultraThinMaterial)
        }
    }

    private var home: some View {
        ZStack {
            ink.ignoresSafeArea()
            RadialGradient(colors: [Color(red: 0.31, green: 0.62, blue: 0.55).opacity(0.35), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 520).ignoresSafeArea()
            RadialGradient(colors: [amber.opacity(0.12), .clear], center: .bottomLeading, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 10) {
                        (Text("Drift") + Text("glass").foregroundColor(sea))
                            .font(serif(64))
                        Text("Your Mac, in your hand. Same Wi‑Fi, same password.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("NEARBY").font(.caption2).kerning(1.6).foregroundStyle(.secondary)
                        if discovery.macs.isEmpty {
                            Searching()
                        }
                        ForEach(discovery.macs) { mac in
                            Button { tapped(mac) } label: { MacCard(name: mac.name, remembered: Vault.password(for: mac.name) != nil) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Forget password", role: .destructive) { Vault.forget(mac.name) }
                                }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("PICTURE").font(.caption2).kerning(1.6).foregroundStyle(.secondary)
                        Picker("Quality", selection: $bitrate) {
                            Text("Light").tag(10_000_000)
                            Text("Balanced").tag(20_000_000)
                            Text("Crisp").tag(35_000_000)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Natural scrolling", isOn: $natural).tint(sea)
                    }
                    .padding(18)
                    .background(Glass())

                    Text("Run Driftglass on your Mac (the waves in the menu bar) and enter the password it shows.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 40)
            }
        }
    }

    private func tapped(_ mac: Discovery.Mac) {
        if Vault.password(for: mac.name) == nil {
            passwordError = false
            asking = mac
        } else {
            connect(mac)
        }
    }

    private func connect(_ mac: Discovery.Mac) {
        guard let pw = Vault.password(for: mac.name) else { asking = mac; return }
        let s = Session(mac: mac, password: pw, bitrate: bitrate)
        s.onWrongPassword = { [mac] in
            Vault.forget(mac.name)
            disconnect(forgetAuto: false)
            passwordError = true
            asking = mac
        }
        session = s
        lastMac = mac.name
        UIApplication.shared.isIdleTimerDisabled = true
        s.start()
    }

    private func disconnect(forgetAuto: Bool) {
        session?.stop()
        session = nil
        if forgetAuto { lastMac = "" }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func autoConnect(_ macs: [Discovery.Mac]) {
        guard session == nil, asking == nil, phase == .active, !lastMac.isEmpty,
              let mac = macs.first(where: { $0.name == lastMac }), Vault.password(for: mac.name) != nil else { return }
        connect(mac)
    }
}

// MARK: - live view

struct Live: View {
    @ObservedObject var session: Session
    let natural: Bool
    let close: () -> Void
    @StateObject private var model = ScreenModel()

    var body: some View {
        GeometryReader { geo in
            // The Mac's 16:10 picture never fills a phone, so the controls live permanently in
            // the spare margin: a rail on the side in landscape, a bar underneath in portrait.
            // They never cover the picture, and touching them never reaches the Mac.
            let wide = geo.size.width > geo.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ZStack {
                    ScreenSurface(session: session, model: model, natural: natural)
                    if session.state != .live || session.fps == 0 {
                        status.allowsHitTesting(false)
                    }
                }
                Controls(session: session, model: model, vertical: wide, close: close)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onChange(of: session.state) { _, s in
            if s == .wrongPassword { session.onWrongPassword?() }
        }
        #if DEBUG
        .task { await Demo.run(session: session, model: model) }
        #endif
    }

    private var status: some View {
        VStack(spacing: 10) {
            Spacer()
            switch session.state {
            case .connecting, .live:
                ProgressView().tint(sea)
                Text("Reaching \(session.hostName)…").font(serif(24))
            case .wrongPassword:
                Text("That password didn't work").font(serif(24))
            case .failed(let msg):
                Text("Lost the connection").font(serif(26))
                Text(msg).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }
}

/// Always-visible controls in fixed positions: one tap, never hidden.
struct Controls: View {
    @ObservedObject var session: Session
    @ObservedObject var model: ScreenModel
    let vertical: Bool
    let close: () -> Void

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            VStack(spacing: 3) {
                Circle().fill(session.state == .live && session.fps > 0 ? sea : amber).frame(width: 8, height: 8)
                Text("\(Int(session.fps))").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(width: vertical ? 50 : 30, height: vertical ? 34 : 50)

            key(model.mode == .direct ? "hand.tap" : "rectangle.and.hand.point.up.left",
                model.mode == .direct ? "Touch" : "Trackpad", on: model.mode == .trackpad) {
                model.mode = model.mode == .direct ? .trackpad : .direct
            }
            key("keyboard", "Keys") { model.showKeyboard() }
            key("rectangle.3.group", "Spaces") { session.send(.init(k: .action, s: "mission")) }
            key("magnifyingglass", "Search") { session.send(.init(k: .action, s: "spotlight")) }
            Menu {
                Button { session.send(.init(k: .action, s: "switcher")) } label: { Label("Last app", systemImage: "arrow.left.arrow.right") }
                Button { session.send(.init(k: .action, s: "desktop")) } label: { Label("Show desktop", systemImage: "menubar.dock.rectangle") }
                Divider()
                Button { session.send(.init(k: .action, s: "play")) } label: { Label("Play / pause", systemImage: "playpause") }
                Button { session.send(.init(k: .action, s: "volup")) } label: { Label("Volume up", systemImage: "speaker.wave.3") }
                Button { session.send(.init(k: .action, s: "voldown")) } label: { Label("Volume down", systemImage: "speaker.wave.1") }
                Divider()
                Button { session.send(.init(k: .action, s: "screenshot")) } label: { Label("Screenshot", systemImage: "camera.viewfinder") }
                Button { session.send(.init(k: .action, s: "lock")) } label: { Label("Lock Mac", systemImage: "lock") }
            } label: {
                face("ellipsis", "More", on: false)
            }
            key("arrow.down.right.and.arrow.up.left", "Fit", on: false) { model.resetZoom() }
                .disabled(!model.zoomed)
                .opacity(model.zoomed ? 1 : 0.35)
            if vertical { Spacer(minLength: 0) }
            key("xmark", "Leave") { close() }
        }
        .padding(vertical ? .vertical : .horizontal, 6)
        .padding(vertical ? .horizontal : .vertical, 4)
        .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
        .background(Color(white: 0.06))
        .foregroundStyle(.white)
    }

    private func key(_ icon: String, _ label: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
            action()
        } label: {
            face(icon, label, on: on)
        }
    }

    private func face(_ icon: String, _ label: String, on: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium))
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(width: vertical ? 52 : nil, height: vertical ? 44 : 50)
        .frame(maxWidth: vertical ? nil : .infinity)
        .background(on ? sea.opacity(0.32) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - pieces

struct Glass: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(colors: [sea.opacity(0.11), sea.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(sea.opacity(0.16)))
    }
}

struct MacCard: View {
    let name: String
    let remembered: Bool
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(sea)
                .frame(width: 52, height: 52)
                .background(sea.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline)
                Text(remembered ? "Tap to drift in" : "Needs the password once")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Glass())
        .contentShape(Rectangle())
    }
}

struct Searching: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(sea).frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.6 : 0.8).opacity(pulse ? 0.25 : 1)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            Text("Looking for Macs on your Wi‑Fi…").foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Glass())
        .onAppear { pulse = true }
    }
}

struct PasswordSheet: View {
    let mac: Discovery.Mac
    let error: Bool
    let done: (String) -> Void
    @State private var pw = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mac.name).font(serif(32))
            Text(error ? "That password didn't match. Check the waves icon in your Mac's menu bar."
                       : "Enter the password shown in Driftglass on your Mac. You only do this once.")
                .font(.callout).foregroundStyle(error ? amber : .secondary)
            SecureField("Password", text: $pw)
                .textContentType(.password)
                .font(.title3)
                .padding(14)
                .background(Glass())
                .focused($focused)
                .onSubmit { if pw.count >= 4 { done(pw) } }
            Button { done(pw) } label: {
                Text("Connect").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(sea, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(ink)
            }
            .disabled(pw.count < 4)
        }
        .padding(24)
        .onAppear { focused = true }
    }
}
