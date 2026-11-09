import AppKit
import QuartzCore

enum Mood: Equatable {
    case idle, thinking, waiting, happy, sad, sleeping
}

/// A Faísca: uma gota de solda com antena. Tudo é animado pelo Core Animation,
/// que roda no servidor de renderização; o app fica parado entre mudanças.
final class PetView: NSView {
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    private let body = CAShapeLayer()
    private let leftEye = CALayer()
    private let rightEye = CALayer()
    private let spark = CALayer()
    private let stem = CAShapeLayer()
    private let badge = CATextLayer()
    private var dragOffset: NSPoint?
    private var dragged = false
    private(set) var mood: Mood = .idle
    private var blinkTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        build()
        apply(.idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func build() {
        guard let root = layer else { return }
        root.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        let w = bounds.width
        let path = CGMutablePath()
        // Gota arredondada, mais larga na base.
        path.move(to: CGPoint(x: w / 2, y: 62))
        path.addCurve(to: CGPoint(x: w - 12, y: 26), control1: CGPoint(x: w / 2 + 16, y: 56), control2: CGPoint(x: w - 12, y: 44))
        path.addCurve(to: CGPoint(x: w / 2, y: 6), control1: CGPoint(x: w - 12, y: 13), control2: CGPoint(x: w / 2 + 14, y: 6))
        path.addCurve(to: CGPoint(x: 12, y: 26), control1: CGPoint(x: w / 2 - 14, y: 6), control2: CGPoint(x: 12, y: 13))
        path.addCurve(to: CGPoint(x: w / 2, y: 62), control1: CGPoint(x: 12, y: 44), control2: CGPoint(x: w / 2 - 16, y: 56))
        path.closeSubpath()

        body.frame = bounds
        body.anchorPoint = CGPoint(x: 0.5, y: 0.08)
        body.position = CGPoint(x: w / 2, y: bounds.height * 0.08)
        body.path = path
        body.shadowColor = NSColor.black.cgColor
        body.shadowOpacity = 0.3
        body.shadowRadius = 4
        body.shadowOffset = CGSize(width: 0, height: -2)
        root.addSublayer(body)

        for (eye, x) in [(leftEye, w / 2 - 15.0), (rightEye, w / 2 + 6.0)] {
            eye.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor
            eye.frame = CGRect(x: x, y: 24, width: 9, height: 14)
            eye.cornerRadius = 4.5
            body.addSublayer(eye)
        }

        let stemPath = CGMutablePath()
        stemPath.move(to: CGPoint(x: w / 2, y: 60))
        stemPath.addQuadCurve(to: CGPoint(x: w / 2 + 7, y: 74), control: CGPoint(x: w / 2 - 1, y: 69))
        stem.path = stemPath
        stem.strokeColor = NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
        stem.fillColor = nil
        stem.lineWidth = 2
        stem.lineCap = .round
        body.addSublayer(stem)

        spark.frame = CGRect(x: w / 2 + 3, y: 71, width: 9, height: 9)
        spark.cornerRadius = 4.5
        spark.shadowOpacity = 0.9
        spark.shadowRadius = 5
        spark.shadowOffset = .zero
        body.addSublayer(spark)

        badge.frame = CGRect(x: w - 20, y: 50, width: 18, height: 18)
        badge.cornerRadius = 9
        badge.backgroundColor = NSColor.systemYellow.cgColor
        badge.foregroundColor = NSColor.black.cgColor
        badge.fontSize = 13
        badge.font = NSFont.boldSystemFont(ofSize: 13)
        badge.alignmentMode = .center
        badge.string = "!"
        badge.contentsScale = root.contentsScale
        badge.isHidden = true
        root.addSublayer(badge)
    }

    func apply(_ next: Mood) {
        mood = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for l in [body, spark, leftEye, rightEye] { l.removeAllAnimations() }
        blinkTimer?.invalidate()
        blinkTimer = nil
        badge.isHidden = next != .waiting

        let (bodyColor, sparkColor): (NSColor, NSColor)
        switch next {
        case .idle, .happy, .waiting:
            (bodyColor, sparkColor) = (NSColor(calibratedRed: 1, green: 0.62, blue: 0.16, alpha: 1), .systemYellow)
        case .thinking:
            (bodyColor, sparkColor) = (NSColor(calibratedRed: 1, green: 0.55, blue: 0.12, alpha: 1), .cyan)
        case .sad:
            (bodyColor, sparkColor) = (NSColor(calibratedRed: 0.62, green: 0.56, blue: 0.62, alpha: 1), .systemRed)
        case .sleeping:
            (bodyColor, sparkColor) = (NSColor(calibratedRed: 0.72, green: 0.48, blue: 0.24, alpha: 1), .darkGray)
        }
        body.fillColor = bodyColor.cgColor
        spark.backgroundColor = sparkColor.cgColor
        spark.shadowColor = sparkColor.cgColor

        setEyes(height: next == .sleeping ? 2 : 14, y: next == .sad ? 21 : 24)

        switch next {
        case .idle:
            breathe(amount: 1.03, duration: 1.8)
            scheduleBlink()
        case .sleeping:
            breathe(amount: 1.02, duration: 3.5)
        case .thinking:
            breathe(amount: 1.04, duration: 0.7)
            pulseSpark(duration: 0.35)
            setEyes(height: 14, y: 28)
        case .waiting:
            bounce(height: 5, duration: 0.45, repeats: .infinity)
            pulseSpark(duration: 0.5)
        case .happy:
            bounce(height: 16, duration: 0.22, repeats: 4)
        case .sad:
            breathe(amount: 0.98, duration: 2.6)
        }
    }

    private func setEyes(height: CGFloat, y: CGFloat) {
        for eye in [leftEye, rightEye] {
            eye.frame = CGRect(x: eye.frame.minX, y: y, width: 9, height: height)
            eye.cornerRadius = min(height, 9) / 2
        }
    }

    private func breathe(amount: CGFloat, duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "transform.scale.y")
        a.fromValue = 1
        a.toValue = amount
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        body.add(a, forKey: "breathe")
    }

    private func bounce(height: CGFloat, duration: CFTimeInterval, repeats: Float) {
        let a = CABasicAnimation(keyPath: "transform.translation.y")
        a.fromValue = 0
        a.toValue = height
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = repeats
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        body.add(a, forKey: "bounce")
    }

    private func pulseSpark(duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.25
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = .infinity
        spark.add(a, forKey: "pulse")
    }

    private func scheduleBlink() {
        let t = Timer(timeInterval: .random(in: 2.5...7), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mood == .idle else { return }
                for eye in [self.leftEye, self.rightEye] {
                    let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
                    a.values = [1, 0.1, 1]
                    a.duration = 0.16
                    eye.add(a, forKey: "blink")
                }
                self.scheduleBlink()
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    // MARK: Gestos

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let m = NSEvent.mouseLocation
        dragOffset = NSPoint(x: m.x - window.frame.minX, y: m.y - window.frame.minY)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let off = dragOffset else { return }
        dragged = true
        let m = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: m.x - off.x, y: m.y - off.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
        if !dragged { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}

/// Janela do pet e o passeio pela base da tela.
@MainActor
final class PetController {
    let window: NSPanel
    let view: PetView
    private var walkTimer: Timer?
    private var celebrateUntil = Date.distantPast
    private var base: Mood = .idle

    init() {
        let size = NSSize(width: 84, height: 88)
        window = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view = PetView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.maxX - 220, y: screen.minY))
        }
        window.orderFrontRegardless()
        scheduleWalk()
    }

    /// `tasks` define o humor; o sucesso vira uma comemoração curta.
    func update(tasks: [TaskItem], finished: String?) {
        if tasks.contains(where: { $0.status == "awaiting_approval" }) {
            base = .waiting
        } else if tasks.contains(where: \.isActive) {
            base = .thinking
        } else {
            base = .idle
        }
        if finished == "done" {
            celebrateUntil = Date().addingTimeInterval(1.8)
            set(.happy)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) { [weak self] in self?.refresh() }
        } else if finished == "failed" {
            celebrateUntil = Date().addingTimeInterval(4)
            set(.sad)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.05) { [weak self] in self?.refresh() }
        } else {
            refresh()
        }
    }

    private func refresh() {
        guard Date() >= celebrateUntil else { return }
        set(base == .idle && systemIdleSeconds() > 180 ? .sleeping : base)
    }

    private func set(_ mood: Mood) {
        if view.mood != mood { view.apply(mood) }
    }

    private func systemIdleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func scheduleWalk() {
        let t = Timer(timeInterval: .random(in: 20...55), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.walk()
                self?.scheduleWalk()
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        walkTimer = t
    }

    private func walk() {
        refresh()
        guard view.mood == .idle, !isDragging, let screen = window.screen?.visibleFrame else { return }
        let dx = CGFloat.random(in: 50...180) * (Bool.random() ? 1 : -1)
        var target = window.frame
        target.origin.x = min(max(target.minX + dx, screen.minX), screen.maxX - target.width)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Double(abs(dx)) / 70
            window.animator().setFrame(target, display: false)
        }
    }

    private var isDragging: Bool { NSEvent.pressedMouseButtons != 0 }
}
