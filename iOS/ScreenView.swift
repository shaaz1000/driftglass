import AVFoundation
import SwiftUI
import UIKit

/// Shared between the SwiftUI chrome and the UIKit touch surface.
final class ScreenModel: ObservableObject {
    enum Mode { case direct, trackpad }
    @Published var mode: Mode = .direct
    @Published var zoomed = false
    weak var view: ScreenView?

    func showKeyboard() { view?.keys.toggle() }
    func resetZoom() { view?.resetZoom() }
}

struct ScreenSurface: UIViewRepresentable {
    let session: Session
    let model: ScreenModel
    let natural: Bool

    func makeUIView(context: Context) -> ScreenView {
        let v = ScreenView(session: session, model: model)
        model.view = v
        return v
    }

    func updateUIView(_ v: ScreenView, context: Context) {
        v.macSize = session.macSize
        v.natural = natural
    }
}

/// The Mac's screen as a touch surface.
///
/// Direct mode works like touching the Mac's screen: tap to click there, drag to scroll,
/// press and hold then move to drag. Trackpad mode turns the whole phone into a trackpad
/// that moves the pointer you see in the picture.
final class ScreenView: UIView, UIGestureRecognizerDelegate {
    let session: Session
    let model: ScreenModel
    let content = UIView()
    let keys = KeyCatcher()
    var natural = true
    var macSize = CGSize(width: 1440, height: 900) { didSet { if macSize != oldValue { setNeedsLayout() } } }

    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var lastLong = CGPoint.zero
    private var momentum: CADisplayLink?
    private var velocity = CGPoint.zero
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(session: Session, model: ScreenModel) {
        self.session = session
        self.model = model
        super.init(frame: .zero)
        backgroundColor = .black
        content.layer.addSublayer(session.layer)
        addSubview(content)
        keys.session = session
        addSubview(keys)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        let tap2 = UITapGestureRecognizer(target: self, action: #selector(onTap2))
        tap2.numberOfTouchesRequired = 2
        let long = UILongPressGestureRecognizer(target: self, action: #selector(onLong))
        long.minimumPressDuration = 0.32
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan))
        pan.maximumNumberOfTouches = 1
        let pan2 = UIPanGestureRecognizer(target: self, action: #selector(onPan2))
        pan2.minimumNumberOfTouches = 2
        pan2.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch))
        let swipe3 = UIPanGestureRecognizer(target: self, action: #selector(onSwipe3))
        swipe3.minimumNumberOfTouches = 3
        for g in [tap, tap2, long, pan, pan2, pinch, swipe3] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let fit = AVMakeRect(aspectRatio: macSize, insideRect: bounds).size
        content.transform = .identity
        content.bounds = CGRect(origin: .zero, size: fit)
        applyTransform()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.layer.frame = content.bounds
        CATransaction.commit()
    }

    private func applyTransform() {
        let fit = content.bounds.size
        // Keep the zoomed picture covering the screen: no panning off into black.
        let maxX = max(0, (fit.width * zoom - bounds.width) / 2)
        let maxY = max(0, (fit.height * zoom - bounds.height) / 2)
        offset.x = min(max(offset.x, -maxX), maxX)
        offset.y = min(max(offset.y, -maxY), maxY)
        content.center = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        content.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        let z = zoom > 1.01
        if model.zoomed != z { model.zoomed = z }
    }

    func resetZoom() {
        UIView.animate(withDuration: 0.25) {
            self.zoom = 1
            self.offset = .zero
            self.applyTransform()
        }
    }

    /// Mac points per phone point at the current zoom.
    private var scale: CGFloat { macSize.width / max(content.bounds.width * zoom, 1) }

    private func norm(_ g: UIGestureRecognizer) -> (Double, Double) {
        let p = g.location(in: content)
        return (Double(p.x / content.bounds.width), Double(p.y / content.bounds.height))
    }

    // MARK: gestures

    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        (a is UIPinchGestureRecognizer && b is UIPanGestureRecognizer) || (b is UIPinchGestureRecognizer && a is UIPanGestureRecognizer)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopMomentum()
        super.touchesBegan(touches, with: event)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        if model.mode == .direct {
            let (x, y) = norm(g)
            session.send(InputEvent(k: .click, x: x, y: y, b: 0))
        } else {
            session.send(InputEvent(k: .click, b: 0))
        }
        haptic.impactOccurred(intensity: 0.5)
    }

    @objc private func onTap2(_ g: UITapGestureRecognizer) {
        if model.mode == .direct {
            let (x, y) = norm(g)
            session.send(InputEvent(k: .click, x: x, y: y, b: 1))
        } else {
            session.send(InputEvent(k: .click, b: 1))
        }
        haptic.impactOccurred(intensity: 0.7)
    }

    @objc private func onLong(_ g: UILongPressGestureRecognizer) {
        let direct = model.mode == .direct
        let (x, y) = norm(g)
        let p = g.location(in: self)
        switch g.state {
        case .began:
            haptic.impactOccurred(intensity: 1)
            lastLong = p
            session.send(direct ? InputEvent(k: .down, x: x, y: y) : InputEvent(k: .down))
        case .changed:
            if direct {
                session.send(InputEvent(k: .moveTo, x: x, y: y))
            } else {
                session.send(InputEvent(k: .move, x: Double((p.x - lastLong.x) * scale * 1.3), y: Double((p.y - lastLong.y) * scale * 1.3)))
                lastLong = p
            }
        case .ended, .cancelled, .failed:
            session.send(direct ? InputEvent(k: .up, x: x, y: y) : InputEvent(k: .up))
        default: break
        }
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if model.mode == .trackpad {
            let v = g.velocity(in: self)
            let speed = hypot(v.x, v.y)
            let gain = scale * (0.9 + min(speed / 700, 2.2)) // gentle pointer acceleration
            session.send(InputEvent(k: .move, x: Double(d.x * gain), y: Double(d.y * gain)))
        } else {
            scroll(g, d)
        }
    }

    @objc private func onPan2(_ g: UIPanGestureRecognizer) {
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if zoom > 1.01 {
            offset.x += d.x
            offset.y += d.y
            applyTransform()
        } else {
            scroll(g, d)
        }
    }

    /// Scrolls so the content under the finger moves with it, then coasts like a trackpad.
    private func scroll(_ g: UIPanGestureRecognizer, _ d: CGPoint) {
        let k = scale * (natural ? 1 : -1)
        switch g.state {
        case .began:
            session.send(InputEvent(k: .scroll, x: Double(d.x * k), y: Double(d.y * k), phase: 1))
        case .changed:
            session.send(InputEvent(k: .scroll, x: Double(d.x * k), y: Double(d.y * k), phase: 2))
        case .ended, .cancelled:
            session.send(InputEvent(k: .scroll, x: 0, y: 0, phase: 4))
            let v = g.velocity(in: self)
            if hypot(v.x, v.y) > 200 { startMomentum(CGPoint(x: v.x * k / 60, y: v.y * k / 60)) }
        default: break
        }
    }

    private func startMomentum(_ v: CGPoint) {
        stopMomentum()
        velocity = v
        session.send(InputEvent(k: .scroll, x: Double(v.x), y: Double(v.y), momentum: 1))
        let link = CADisplayLink(target: self, selector: #selector(coast))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func coast() {
        velocity.x *= 0.95
        velocity.y *= 0.95
        if hypot(velocity.x, velocity.y) < 0.6 { stopMomentum(); return }
        session.send(InputEvent(k: .scroll, x: Double(velocity.x), y: Double(velocity.y), momentum: 2))
    }

    private func stopMomentum() {
        guard let m = momentum else { return }
        m.invalidate()
        momentum = nil
        session.send(InputEvent(k: .scroll, x: 0, y: 0, momentum: 3))
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        let before = g.location(in: content)
        zoom = min(max(zoom * g.scale, 1), 6)
        g.scale = 1
        // Zoom around the fingers rather than the centre.
        let after = content.convert(before, to: self)
        let target = g.location(in: self)
        offset.x += target.x - after.x
        offset.y += target.y - after.y
        applyTransform()
        if g.state == .ended && zoom < 1.05 { resetZoom() }
    }

    @objc private func onSwipe3(_ g: UIPanGestureRecognizer) {
        guard g.state == .ended else { return }
        let t = g.translation(in: self)
        guard max(abs(t.x), abs(t.y)) > 60 else { return }
        let action: String
        if abs(t.x) > abs(t.y) { action = t.x < 0 ? "space_right" : "space_left" }
        else { action = t.y < 0 ? "mission" : "desktop" }
        session.send(InputEvent(k: .action, s: action))
        haptic.impactOccurred(intensity: 0.8)
    }
}

/// An invisible text input: brings up the iPhone keyboard and types every key on the Mac.
final class KeyCatcher: UIView, UIKeyInput {
    weak var session: Session?
    private var mods = Set<String>()
    private var modButtons: [String: UIButton] = [:]

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    override var canBecomeFirstResponder: Bool { true }

    func toggle() { _ = isFirstResponder ? resignFirstResponder() : becomeFirstResponder() }

    private func takeMods() -> [String] {
        let m = Array(mods)
        mods.removeAll()
        modButtons.values.forEach { $0.isSelected = false; $0.backgroundColor = Self.keyBG }
        return m
    }

    func insertText(_ text: String) {
        if text == "\n" { session?.send(InputEvent(k: .key, s: "enter", m: takeMods())); return }
        session?.send(InputEvent(k: .text, s: text, m: takeMods()))
    }

    func deleteBackward() { session?.send(InputEvent(k: .key, s: "backspace", m: takeMods())) }

    // MARK: accessory bar

    private static let keyBG = UIColor(white: 1, alpha: 0.10)
    private static let sea = UIColor(red: 0.62, green: 0.85, blue: 0.79, alpha: 1)

    private lazy var bar: UIView = {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 50), inputViewStyle: .keyboard)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(scroll)
        let stack = UIStackView()
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 38),
        ])
        let items: [(String, String)] = [
            ("esc", "k:escape"), ("tab", "k:tab"), ("⌘", "m:cmd"), ("⌥", "m:alt"), ("⌃", "m:ctrl"), ("⇧", "m:shift"),
            ("←", "k:left"), ("↑", "k:up"), ("↓", "k:down"), ("→", "k:right"), ("⌦", "k:delete"),
            ("⌘C", "c:c"), ("⌘V", "c:v"), ("⌘Z", "c:z"), ("⌘A", "c:a"), ("⌄", "hide"),
        ]
        for (title, id) in items {
            var cfg = UIButton.Configuration.plain()
            cfg.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 17, weight: .medium)]))
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 13, bottom: 0, trailing: 13)
            cfg.baseForegroundColor = .white
            let b = UIButton(configuration: cfg)
            b.backgroundColor = Self.keyBG
            b.layer.cornerRadius = 9
            b.addAction(UIAction { [weak self, weak b] _ in self?.tapped(id, b) }, for: .touchUpInside)
            if id.hasPrefix("m:") { modButtons[String(id.dropFirst(2))] = b }
            stack.addArrangedSubview(b)
        }
        return bar
    }()

    override var inputAccessoryView: UIView? { bar }

    private func tapped(_ id: String, _ b: UIButton?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.4)
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "k": session?.send(InputEvent(k: .key, s: parts[1], m: takeMods()))
        case "c": session?.send(InputEvent(k: .key, s: parts[1], m: ["cmd"]))
        case "m":
            let m = parts[1]
            if mods.contains(m) { mods.remove(m) } else { mods.insert(m) }
            b?.backgroundColor = mods.contains(m) ? Self.sea.withAlphaComponent(0.55) : Self.keyBG
        case "hide": resignFirstResponder()
        default: break
        }
    }
}
