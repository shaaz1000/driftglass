import SwiftUI

@main
struct DriftglassMac: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            Panel(host: delegate.host)
        } label: {
            MenuIcon(host: delegate.host)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Opening the app again (Finder, Spotlight, Dock) shows its panel in a window, since a
/// menu-bar-only app is otherwise easy to lose.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = Host()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return false
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Panel(host: host)))
            w.title = "Driftglass"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MenuIcon: View {
    @ObservedObject var host: Host
    var body: some View { Image(systemName: host.isConnected ? "water.waves" : "water.waves.slash") }
}

extension Host {
    var isConnected: Bool { if case .connected = state { return true } else { return false } }
}

private let sea = Color(red: 0.62, green: 0.85, blue: 0.79)

struct Panel: View {
    @ObservedObject var host: Host
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Drift").font(.custom("Georgia-Italic", size: 26))
                Text("glass").font(.custom("Georgia-Italic", size: 26)).foregroundStyle(sea)
                Spacer()
                statusPill
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("PASSWORD").font(.caption2).kerning(1.4).foregroundStyle(.secondary)
                if editing {
                    HStack {
                        TextField("New password", text: $draft).textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                        Button("Save", action: save).disabled(draft.count < 4)
                    }
                } else {
                    HStack {
                        Text(host.password).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Change") { draft = host.password; editing = true }
                    }
                }
                Text("Enter this in Driftglass on your iPhone. Same Wi‑Fi, same password, and it connects.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            permission("Screen Recording", ok: host.screenOK, hint: "lets your iPhone see the screen", action: host.requestScreen)
            permission("Accessibility", ok: host.inputOK, hint: "lets your iPhone click and type", action: host.requestInput)

            Divider()

            Toggle("Open at login", isOn: Binding(get: { host.launchAtLogin }, set: { _ in host.toggleLaunchAtLogin() }))
            HStack {
                Text("Lives in the menu bar: look for the waves.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func save() {
        guard draft.count >= 4 else { return }
        host.password = draft
        editing = false
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch host.state {
            case .idle: return ("Starting", .secondary)
            case .waiting: return ("Waiting for iPhone", .secondary)
            case .connected(let name): return ("\(name) · \(Int(host.fps)) fps", sea)
            case .failed(let msg): return (msg, .orange)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    private func permission(_ title: String, ok: Bool, hint: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? sea : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Allow", action: action) }
        }
    }
}
