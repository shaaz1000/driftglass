import AppKit
import CoreGraphics

/// Turns phone input events into real macOS mouse and keyboard events.
final class Input {
    static let shared = Input()

    private var dragging = false
    private var lastClick = (time: 0.0, button: -1, point: CGPoint.zero, count: 0)

    func handle(_ e: InputEvent) {
        switch e.k {
        case .move:
            let p = cursor
            moveTo(clamp(from: p, to: CGPoint(x: p.x + (e.x ?? 0), y: p.y + (e.y ?? 0))))
        case .moveTo:
            moveTo(absolute(e))
        case .click:
            if e.x != nil { moveTo(absolute(e)) }
            click(button: e.b ?? 0)
        case .down:
            if e.x != nil { moveTo(absolute(e)) }
            setDragging(true)
        case .up:
            if e.x != nil { moveTo(absolute(e)) }
            setDragging(false)
        case .scroll:
            scroll(dx: e.x ?? 0, dy: e.y ?? 0, phase: e.phase, momentum: e.momentum)
        case .key:
            if let s = e.s { key(s, mods: e.m ?? []) }
        case .text:
            if let s = e.s { type(s, mods: e.m ?? []) }
        case .action:
            if let s = e.s { action(s) }
        }
    }

    func releaseAll() { setDragging(false) }

    // MARK: pointer

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func absolute(_ e: InputEvent) -> CGPoint {
        let b = CGDisplayBounds(CGMainDisplayID())
        let x = min(max(e.x ?? 0, 0), 0.9999), y = min(max(e.y ?? 0, 0), 0.9999)
        return CGPoint(x: b.minX + x * b.width, y: b.minY + y * b.height)
    }

    private func displays() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
    }

    /// Keeps the pointer on a real display, even across gaps in multi-monitor layouts.
    private func clamp(from old: CGPoint, to new: CGPoint) -> CGPoint {
        let rects = displays()
        if rects.contains(where: { $0.contains(new) }) { return new }
        guard let r = rects.first(where: { $0.contains(old) }) ?? rects.first else { return new }
        return CGPoint(x: min(max(new.x, r.minX), r.maxX - 1), y: min(max(new.y, r.minY), r.maxY - 1))
    }

    private func moveTo(_ p: CGPoint) {
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func click(button: Int) {
        let p = cursor
        let now = ProcessInfo.processInfo.systemUptime
        // Finger taps land a little apart, so the double-click radius is looser than a mouse's.
        if now - lastClick.time < 0.45, lastClick.button == button, hypot(p.x - lastClick.point.x, p.y - lastClick.point.y) < 24 {
            lastClick.count += 1
        } else {
            lastClick.count = 1
        }
        lastClick = (now, button, p, lastClick.count)
        let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) =
            button == 1 ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for t in [down, up] {
            let ev = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: btn)
            ev?.setIntegerValueField(.mouseEventClickState, value: Int64(lastClick.count))
            ev?.post(tap: .cghidEventTap)
        }
    }

    private func setDragging(_ on: Bool) {
        guard on != dragging else { return }
        dragging = on
        CGEvent(mouseEventSource: nil, mouseType: on ? .leftMouseDown : .leftMouseUp,
                mouseCursorPosition: cursor, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Double, dy: Double, phase: Int?, momentum: Int?) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        // Phases make apps treat this as a trackpad: smooth scrolling, rubber-banding, momentum.
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        if let phase { ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase)) }
        if let momentum { ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum)) }
        ev.post(tap: .cghidEventTap)
    }

    // MARK: keyboard

    static let keycodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50,
        "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "delete": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    private func flags(_ mods: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in mods {
            switch m {
            case "cmd": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "alt": f.insert(.maskAlternate)
            case "ctrl": f.insert(.maskControl)
            default: break
            }
        }
        return f
    }

    func key(_ name: String, mods: [String] = []) {
        guard let code = Self.keycodes[name.lowercased()] else { return }
        let f = flags(mods)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            ev?.flags = f
            ev?.post(tap: .cghidEventTap)
        }
    }

    private func type(_ text: String, mods: [String]) {
        // With modifiers held, letters go out as real key codes so shortcuts like ⌘C register.
        if !mods.isEmpty {
            for ch in text {
                let s = String(ch)
                var m = mods
                if ch.isUppercase && !m.contains("shift") { m.append("shift") }
                key(s.lowercased(), mods: m)
            }
            return
        }
        for ch in text {
            if ch == "\n" { key("enter"); continue }
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                ev?.flags = []
                ev?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                ev?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: media + system

    private static let mediaKeys: [String: Int] = [
        "volup": 0, "voldown": 1, "brightup": 2, "brightdown": 3, "mute": 7,
        "play": 16, "next": 17, "prev": 18,
    ]

    private func media(_ k: Int) {
        for (flags, state) in [(0xA00, 0xA), (0xB00, 0xB)] {
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: (k << 16) | (state << 8), data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    private func action(_ name: String) {
        if let k = Self.mediaKeys[name] { media(k); return }
        switch name {
        case "mission": run("/usr/bin/open", ["-a", "Mission Control"])
        case "spotlight": key("space", mods: ["cmd"])
        case "switcher": key("tab", mods: ["cmd"])
        case "space_left": key("left", mods: ["ctrl"])
        case "space_right": key("right", mods: ["ctrl"])
        case "desktop": key("f11", mods: ["cmd"])
        case "lock": key("q", mods: ["ctrl", "cmd"])
        case "screenshot": key("5", mods: ["cmd", "shift"])
        case "display_sleep": run("/usr/bin/pmset", ["displaysleepnow"])
        default: break
        }
    }
}
