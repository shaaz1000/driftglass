#if DEBUG
import UIKit

/// Debug-only launch flags for capturing screenshots and demo footage in the simulator.
///
///   -dgTestPassword <pw>   use this password for any Mac
///   -lastMac <name>        auto-connect to this Mac on launch
///   -dgSheet YES           open the password sheet for the first Mac found
///   -dgLandscape YES       rotate the live view to landscape
///   -dgKeyboard YES        bring up the keyboard once connected
///   -dgDemo YES            play a scripted input sequence through the real connection
enum Demo {
    static func flag(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    @MainActor
    static func run(session: Session, model: ScreenModel) async {
        if flag("dgLandscape") {
            try? await Task.sleep(for: .seconds(1))
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { NSLog("Driftglass rotate failed: \($0)") }
            }
        }
        if flag("dgKeyboard") {
            try? await Task.sleep(for: .seconds(1.5))
            model.showKeyboard()
        }
        guard flag("dgDemo") else { return }
        let send = session.send
        func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

        await pause(3)
        // Glide the pointer in a slow loop.
        for i in 0...150 {
            let t = Double(i) / 150 * 2 * .pi
            send(InputEvent(k: .moveTo, x: 0.5 + 0.22 * cos(t), y: 0.5 + 0.18 * sin(t)))
            await pause(1 / 60)
        }
        await pause(0.6)
        // Pan the map with a trackpad-style swipe, then let it coast.
        for i in 0..<45 {
            send(InputEvent(k: .scroll, x: -9, y: -3, phase: i == 0 ? 1 : 2))
            await pause(1 / 60)
        }
        send(InputEvent(k: .scroll, x: 0, y: 0, phase: 4))
        var v = 9.0
        send(InputEvent(k: .scroll, x: -v, y: -v / 3, momentum: 1))
        while v > 0.5 {
            v *= 0.94
            send(InputEvent(k: .scroll, x: -v, y: -v / 3, momentum: 2))
            await pause(1 / 60)
        }
        send(InputEvent(k: .scroll, x: 0, y: 0, momentum: 3))
        await pause(1.2)
        // Mission Control, then back.
        send(InputEvent(k: .action, s: "mission"))
        await pause(2.8)
        send(InputEvent(k: .key, s: "escape"))
        await pause(1.5)
    }
}
#endif
