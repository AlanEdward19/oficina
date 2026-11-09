import AppKit
import QuartzCore

enum Mood: Equatable {
    case idle, thinking, waiting, happy, sad, sleeping
    case curious, bored, tired, lonely, focused
}

private func color(_ hex: String) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
    return CGColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/// A Faísca: uma gota de solda com antena. Tudo é animado pelo Core Animation,
/// que roda no servidor de renderização; o app fica parado entre mudanças.
@MainActor
final class PetFigure {
    /// Camada raiz, solta: quem a move é o Core Animation, fora do app.
    let root = CALayer()

    private let body = CAShapeLayer()
    private let leftEye = CALayer()
    private let rightEye = CALayer()
    private let spark = CALayer()
    private let stem = CAShapeLayer()
    private let badge = CATextLayer()
    private let outfitLayer = CALayer()
    private let propLayer = CALayer()
    private var bodyColor = NSColor(calibratedRed: 1, green: 0.62, blue: 0.16, alpha: 1).cgColor
    private(set) var mood: Mood = .idle
    private var blinkTimer: Timer?

    init(size: NSSize) {
        root.anchorPoint = .zero
        root.bounds = CGRect(origin: .zero, size: size)
        root.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        build()
        apply(.idle)
    }

    private var w: CGFloat { root.bounds.width }
    private var bounds: CGRect { root.bounds }

    /// Camadas fora de uma view não herdam a escala da tela: sem isso, borram.
    private func crispen(_ layer: CALayer? = nil) {
        let l = layer ?? root
        l.contentsScale = root.contentsScale
        l.sublayers?.forEach { crispen($0) }
    }

    private func build() {

        let path = CGMutablePath()
        // Gota arredondada, mais larga na base.
        path.move(to: CGPoint(x: w / 2, y: 62))
        path.addCurve(to: CGPoint(x: w - 12, y: 26), control1: CGPoint(x: w / 2 + 16, y: 56), control2: CGPoint(x: w - 12, y: 44))
        path.addCurve(to: CGPoint(x: w / 2, y: 6), control1: CGPoint(x: w - 12, y: 13), control2: CGPoint(x: w / 2 + 14, y: 6))
        path.addCurve(to: CGPoint(x: 12, y: 26), control1: CGPoint(x: w / 2 - 14, y: 6), control2: CGPoint(x: 12, y: 13))
        path.addCurve(to: CGPoint(x: w / 2, y: 62), control1: CGPoint(x: 12, y: 44), control2: CGPoint(x: w / 2 - 16, y: 56))
        path.closeSubpath()

        root.addSublayer(propLayer)
        propLayer.frame = bounds

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

        outfitLayer.frame = bounds
        body.addSublayer(outfitLayer)

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
        crispen()
    }

    // MARK: Humor

    func apply(_ next: Mood) {
        mood = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for l in [body, spark, leftEye, rightEye] { l.removeAllAnimations() }
        blinkTimer?.invalidate()
        blinkTimer = nil
        badge.isHidden = next != .waiting

        var fill = NSColor(cgColor: bodyColor) ?? .orange
        var sparkColor: NSColor = .systemYellow
        switch next {
        case .thinking: sparkColor = .cyan
        case .sad, .lonely:
            fill = fill.blended(withFraction: next == .sad ? 0.55 : 0.35, of: .gray) ?? fill
            sparkColor = next == .sad ? .systemRed : .systemPurple
        case .sleeping, .tired:
            fill = fill.blended(withFraction: next == .sleeping ? 0.3 : 0.15, of: .brown) ?? fill
            sparkColor = next == .sleeping ? .darkGray : .systemOrange
        case .curious: sparkColor = .systemGreen
        case .focused: sparkColor = .systemBlue
        default: break
        }
        body.fillColor = fill.cgColor
        spark.backgroundColor = sparkColor.cgColor
        spark.shadowColor = sparkColor.cgColor

        switch next {
        case .sleeping: setEyes(height: 2, y: 26)
        case .tired: setEyes(height: 5, y: 26)
        case .bored: setEyes(height: 7, y: 25)
        case .focused: setEyes(height: 8, y: 26)
        case .sad, .lonely: setEyes(height: 12, y: 21)
        case .thinking: setEyes(height: 14, y: 28)
        default: setEyes(height: 14, y: 24)
        }

        switch next {
        case .idle:
            breathe(amount: 1.03, duration: 1.8)
            scheduleBlink()
        case .sleeping:
            breathe(amount: 1.02, duration: 3.5)
        case .thinking:
            breathe(amount: 1.04, duration: 0.7)
            pulseSpark(duration: 0.35)
        case .waiting:
            bounce(height: 5, duration: 0.45, repeats: .infinity)
            pulseSpark(duration: 0.5)
        case .happy:
            bounce(height: 16, duration: 0.22, repeats: 4)
        case .sad, .lonely:
            breathe(amount: 0.98, duration: 2.6)
        case .curious:
            breathe(amount: 1.03, duration: 1.4)
            glance()
            scheduleBlink()
        case .bored:
            breathe(amount: 1.015, duration: 3.0)
        case .tired:
            breathe(amount: 1.02, duration: 2.8)
            scheduleBlink()
        case .focused:
            breathe(amount: 1.01, duration: 2.4)
        }
    }

    private func setEyes(height: CGFloat, y: CGFloat) {
        for (eye, x) in [(leftEye, w / 2 - 15.0), (rightEye, w / 2 + 6.0)] {
            eye.frame = CGRect(x: x, y: y, width: 9, height: height)
            eye.cornerRadius = min(height, 9) / 2
        }
    }

    /// Olhar para um lado (-1 esquerda, 1 direita), sem animar sempre.
    func look(_ dir: CGFloat) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        let dx = max(-1, min(1, dir)) * 3
        leftEye.frame.origin.x = w / 2 - 15 + dx
        rightEye.frame.origin.x = w / 2 + 6 + dx
        CATransaction.commit()
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

    /// Curiosa: os olhos passeiam de um lado para o outro.
    private func glance() {
        for eye in [leftEye, rightEye] {
            let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
            a.values = [0, -3, -3, 3, 3, 0]
            a.keyTimes = [0, 0.15, 0.4, 0.55, 0.85, 1]
            a.duration = 4
            a.repeatCount = .infinity
            eye.add(a, forKey: "glance")
        }
    }

    /// Passinhos enquanto anda.
    func walking(_ on: Bool) {
        if on {
            let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
            a.values = [0, 3, 0]
            a.duration = 0.28
            a.repeatCount = .infinity
            body.add(a, forKey: "step")
        } else {
            body.removeAnimation(forKey: "step")
        }
    }

    /// Rastejar: achata e estica enquanto sobe ou desce pela borda.
    func crawling(_ on: Bool) {
        if on {
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = [1, 0.82, 1.05, 1]
            a.duration = 0.45
            a.repeatCount = .infinity
            body.add(a, forKey: "crawl")
        } else {
            body.removeAnimation(forKey: "crawl")
        }
    }

    /// Giro de comemoração.
    func spin() {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = CGFloat.pi * 2
        a.duration = 0.6
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        body.add(a, forKey: "spin")
    }

    /// Olhos fechados de felicidade por um instante.
    func bliss() {
        for eye in [leftEye, rightEye] {
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = [1, 0.2, 0.2, 1]
            a.keyTimes = [0, 0.1, 0.85, 1]
            a.duration = 1.4
            eye.add(a, forKey: "bliss")
        }
    }

    private func scheduleBlink() {
        let t = Timer(timeInterval: .random(in: 2.5...7), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, [.idle, .curious, .tired].contains(self.mood) else { return }
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

    // MARK: Roupinha

    func wear(_ outfit: OutfitData?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        outfitLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        propLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        bodyColor = outfit.map { color($0.body) } ?? NSColor(calibratedRed: 1, green: 0.62, blue: 0.16, alpha: 1).cgColor
        guard let o = outfit else {
            apply(mood)
            return
        }
        let c = w / 2
        func shape(_ path: CGPath, fill: String?, stroke: String? = nil, width: CGFloat = 2, into parent: CALayer? = nil) {
            let l = CAShapeLayer()
            l.path = path
            l.fillColor = fill.map(color)
            l.strokeColor = stroke.map(color)
            l.lineWidth = width
            l.lineCap = .round
            l.lineJoin = .round
            (parent ?? outfitLayer).addSublayer(l)
        }
        func ellipse(_ r: CGRect) -> CGPath { CGPath(ellipseIn: r, transform: nil) }
        func rect(_ r: CGRect, _ radius: CGFloat = 2) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
        func poly(_ pts: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts)
            p.closeSubpath()
            return p
        }

        switch o.neck.shape {
        case "bowtie":
            shape(poly([CGPoint(x: c, y: 14), CGPoint(x: c - 9, y: 19), CGPoint(x: c - 9, y: 9)]), fill: o.neck.color)
            shape(poly([CGPoint(x: c, y: 14), CGPoint(x: c + 9, y: 19), CGPoint(x: c + 9, y: 9)]), fill: o.neck.color)
            shape(ellipse(CGRect(x: c - 2.5, y: 11.5, width: 5, height: 5)), fill: o.neck.color)
        case "scarf":
            shape(rect(CGRect(x: 16, y: 13, width: w - 32, height: 7), 3.5), fill: o.neck.color)
            shape(rect(CGRect(x: c + 6, y: 4, width: 7, height: 12), 3), fill: o.neck.color)
        case "lanyard":
            let p = CGMutablePath()
            p.move(to: CGPoint(x: c - 13, y: 22)); p.addLine(to: CGPoint(x: c, y: 12)); p.addLine(to: CGPoint(x: c + 13, y: 22))
            shape(p, fill: nil, stroke: o.neck.color, width: 2)
            shape(rect(CGRect(x: c - 5, y: 3, width: 10, height: 10), 2), fill: "#FFFFFF", stroke: o.neck.color, width: 1)
        case "tie":
            shape(poly([CGPoint(x: c - 4, y: 18), CGPoint(x: c + 4, y: 18), CGPoint(x: c, y: 14)]), fill: o.neck.color)
            shape(poly([CGPoint(x: c - 3, y: 15), CGPoint(x: c + 3, y: 15), CGPoint(x: c + 4, y: 6), CGPoint(x: c, y: 3), CGPoint(x: c - 4, y: 6)]), fill: o.neck.color)
        default: break
        }

        let ly = 31.0, lx = c - 10.5, rx = c + 10.5
        switch o.face.shape {
        case "glasses_round":
            shape(ellipse(CGRect(x: lx - 7.5, y: ly - 7.5, width: 15, height: 15)), fill: nil, stroke: o.face.color, width: 2)
            shape(ellipse(CGRect(x: rx - 7.5, y: ly - 7.5, width: 15, height: 15)), fill: nil, stroke: o.face.color, width: 2)
            let b = CGMutablePath(); b.move(to: CGPoint(x: lx + 7.5, y: ly + 1)); b.addLine(to: CGPoint(x: rx - 7.5, y: ly + 1))
            shape(b, fill: nil, stroke: o.face.color, width: 2)
        case "glasses_square":
            shape(rect(CGRect(x: lx - 8, y: ly - 6.5, width: 16, height: 13), 3), fill: nil, stroke: o.face.color, width: 2)
            shape(rect(CGRect(x: rx - 8, y: ly - 6.5, width: 16, height: 13), 3), fill: nil, stroke: o.face.color, width: 2)
            let b = CGMutablePath(); b.move(to: CGPoint(x: lx + 8, y: ly + 1)); b.addLine(to: CGPoint(x: rx - 8, y: ly + 1))
            shape(b, fill: nil, stroke: o.face.color, width: 2)
        case "visor":
            let l = CAShapeLayer()
            l.path = rect(CGRect(x: 17, y: 25, width: w - 34, height: 12), 6)
            l.fillColor = color(o.face.color).copy(alpha: 0.75)
            outfitLayer.addSublayer(l)
        case "monocle":
            shape(ellipse(CGRect(x: rx - 8, y: ly - 8, width: 16, height: 16)), fill: nil, stroke: o.face.color, width: 2)
            let ch = CGMutablePath(); ch.move(to: CGPoint(x: rx + 6, y: ly - 6)); ch.addQuadCurve(to: CGPoint(x: rx + 10, y: 12), control: CGPoint(x: rx + 12, y: ly - 14))
            shape(ch, fill: nil, stroke: o.face.color, width: 1)
        default: break
        }

        switch o.head.shape {
        case "cap":
            shape(CGPath(roundedRect: CGRect(x: c - 18, y: 50, width: 36, height: 16), cornerWidth: 16, cornerHeight: 14, transform: nil), fill: o.head.color)
            shape(rect(CGRect(x: c + 4, y: 49, width: 24, height: 5), 2.5), fill: o.head.color)
        case "beanie":
            shape(CGPath(roundedRect: CGRect(x: c - 20, y: 49, width: 40, height: 19), cornerWidth: 18, cornerHeight: 16, transform: nil), fill: o.head.color)
            shape(rect(CGRect(x: c - 21, y: 48, width: 42, height: 6), 3), fill: "#FFFFFF")
        case "headset":
            let band = CGMutablePath()
            band.move(to: CGPoint(x: 13, y: 34)); band.addCurve(to: CGPoint(x: w - 13, y: 34), control1: CGPoint(x: 13, y: 74), control2: CGPoint(x: w - 13, y: 74))
            shape(band, fill: nil, stroke: o.head.color, width: 3)
            shape(rect(CGRect(x: 8, y: 26, width: 9, height: 15), 3), fill: o.head.color)
            shape(rect(CGRect(x: w - 17, y: 26, width: 9, height: 15), 3), fill: o.head.color)
            let mic = CGMutablePath(); mic.move(to: CGPoint(x: 11, y: 27)); mic.addQuadCurve(to: CGPoint(x: c - 10, y: 16), control: CGPoint(x: 12, y: 16))
            shape(mic, fill: nil, stroke: o.head.color, width: 2)
            shape(ellipse(CGRect(x: c - 13, y: 13, width: 6, height: 6)), fill: o.head.color)
        case "crown":
            shape(poly([CGPoint(x: c - 14, y: 54), CGPoint(x: c + 14, y: 54), CGPoint(x: c + 14, y: 68), CGPoint(x: c + 7, y: 61),
                        CGPoint(x: c, y: 70), CGPoint(x: c - 7, y: 61), CGPoint(x: c - 14, y: 68)]), fill: o.head.color)
        case "hardhat":
            shape(CGPath(roundedRect: CGRect(x: c - 19, y: 50, width: 38, height: 18), cornerWidth: 18, cornerHeight: 16, transform: nil), fill: o.head.color)
            shape(rect(CGRect(x: c - 25, y: 48, width: 50, height: 5), 2.5), fill: o.head.color)
        case "wizard":
            shape(poly([CGPoint(x: c - 18, y: 54), CGPoint(x: c + 18, y: 54), CGPoint(x: c + 4, y: 86)]), fill: o.head.color)
            shape(rect(CGRect(x: c - 22, y: 51, width: 44, height: 5), 2.5), fill: o.head.color)
        default: break
        }

        if let b = o.badge {
            let l = CATextLayer()
            l.frame = CGRect(x: c + 9, y: 9, width: 18, height: 11)
            l.backgroundColor = color(b.color)
            l.cornerRadius = 3
            l.string = b.shape
            l.fontSize = 7
            l.font = NSFont.boldSystemFont(ofSize: 7)
            l.foregroundColor = NSColor.white.cgColor
            l.alignmentMode = .center
            l.contentsScale = root.contentsScale
            outfitLayer.addSublayer(l)
        }

        switch o.prop {
        case "laptop":
            shape(rect(CGRect(x: 0, y: 2, width: 18, height: 12), 2), fill: "#3A3A3C", into: propLayer)
            shape(rect(CGRect(x: -2, y: 0, width: 22, height: 3), 1.5), fill: "#8E8E93", into: propLayer)
            shape(ellipse(CGRect(x: 7, y: 6, width: 4, height: 4)), fill: "#FFFFFF", into: propLayer)
        case "coffee":
            shape(rect(CGRect(x: w - 15, y: 1, width: 11, height: 12), 2), fill: "#FFFFFF", into: propLayer)
            shape(ellipse(CGRect(x: w - 7, y: 4, width: 6, height: 6)), fill: nil, stroke: "#FFFFFF", width: 2, into: propLayer)
        case "wrench":
            let p = CGMutablePath(); p.move(to: CGPoint(x: 2, y: 2)); p.addLine(to: CGPoint(x: 13, y: 13))
            shape(p, fill: nil, stroke: "#A0A0A8", width: 3, into: propLayer)
            shape(ellipse(CGRect(x: 10, y: 10, width: 7, height: 7)), fill: nil, stroke: "#A0A0A8", width: 2.5, into: propLayer)
        case "flask":
            shape(poly([CGPoint(x: w - 13, y: 14), CGPoint(x: w - 9, y: 14), CGPoint(x: w - 9, y: 10), CGPoint(x: w - 4, y: 1),
                        CGPoint(x: w - 18, y: 1), CGPoint(x: w - 13, y: 10)]), fill: "#7CF2C4", stroke: "#FFFFFF", width: 1, into: propLayer)
        default: break
        }
        crispen(outfitLayer)
        crispen(propLayer)
        apply(mood)
    }
}

/// Área de toque invisível do tamanho da Faísca: clique, arraste e carinho.
final class PetHitView: NSView {
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onDragStart: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDrop: (() -> Void)?
    var onPetted: (() -> Void)?

    private var dragOffset: NSPoint?
    private var dragged = false
    private var strokes: [(x: CGFloat, at: Date)] = []
    private var lastStrokeDir: CGFloat = 0
    private var lastPetted = Date.distantPast

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    /// Carinho: passar o mouse de um lado para o outro em cima dela.
    override func mouseMoved(with event: NSEvent) {
        let x = event.locationInWindow.x
        let now = Date()
        if let last = strokes.last {
            let dx = x - last.x
            if abs(dx) > 3 {
                let dir: CGFloat = dx > 0 ? 1 : -1
                if dir != lastStrokeDir {
                    lastStrokeDir = dir
                    strokes.append((x, now))
                } else {
                    strokes[strokes.count - 1] = (x, last.at)
                }
            }
        } else {
            strokes.append((x, now))
        }
        strokes.removeAll { now.timeIntervalSince($0.at) > 1.5 }
        if strokes.count >= 5, now.timeIntervalSince(lastPetted) > 2.5 {
            lastPetted = now
            strokes.removeAll()
            onPetted?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        strokes.removeAll()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let m = NSEvent.mouseLocation
        dragOffset = NSPoint(x: m.x - window.frame.minX, y: m.y - window.frame.minY)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let off = dragOffset else { return }
        if !dragged { onDragStart?() }
        dragged = true
        let m = NSEvent.mouseLocation
        let origin = NSPoint(x: m.x - off.x, y: m.y - off.y)
        window.setFrameOrigin(origin)
        onDrag?(origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
        if dragged { onDrop?() } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}

/// A Faísca na tela: a casa na Dock, as saídas, gravidade e passeios.
/// Existe uma Faísca só: ou está sentada na Dock, ou está andando pela tela.
///
/// O desenho fica num palco transparente que cobre a tela e ignora o mouse;
/// os movimentos são animações do Core Animation, executadas pelo servidor
/// de janelas, então andar não custa CPU do app. Uma janelinha invisível do
/// tamanho dela recebe clique, arraste e carinho, e só muda de lugar quando
/// um movimento termina.
@MainActor
final class PetController {
    /// Janela de toque (invisível). Serve de âncora para balão e conversa.
    let window: NSPanel
    let view: PetHitView
    let figure: PetFigure
    private let stage: NSPanel
    private let size = NSSize(width: 84, height: 88)

    /// Topo da Dock (embaixo) e sua faixa horizontal, se estiver à vista.
    var shelf: () -> (y: CGFloat, x: ClosedRange<CGFloat>)? = { nil }
    /// Onde ela fica quando está em casa (pode estar fora da tela).
    var homeFrame: () -> NSRect? = { nil }
    var dockVisible: () -> Bool = { false }
    var dockFrame: () -> NSRect? = { nil }
    var iconX: (String) -> CGFloat? = { _ in nil }
    var randomIcon: () -> String? = { nil }
    var nudge: (String) -> Void = { _ in }
    var onEvent: (String) -> Void = { _ in }
    /// Enquanto houver uma pergunta no balão, ela não sai andando.
    var busy: () -> Bool = { false }

    private(set) var home = false
    private var origin = NSPoint.zero
    private var token = 0
    private var walkTimer: Timer?
    private var celebrateUntil = Date.distantPast
    private var taskMood: Mood?
    private var mindMood: Mood = .idle
    private var moving = false
    private var outUntil = Date.distantPast
    private let foot: CGFloat = 5

    init() {
        let screen = (NSScreen.screens.first ?? NSScreen.main)?.frame ?? .zero

        stage = NSPanel(contentRect: screen, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        stage.isOpaque = false
        stage.backgroundColor = .clear
        stage.hasShadow = false
        stage.ignoresMouseEvents = true
        stage.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        stage.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // View que hospeda camadas: o AppKit não mexe nas subcamadas.
        let host = NSView(frame: NSRect(origin: .zero, size: screen.size))
        host.layer = CALayer()
        host.wantsLayer = true
        stage.contentView = host
        stage.setFrame(screen, display: false)

        figure = PetFigure(size: size)
        host.layer?.addSublayer(figure.root)

        window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        // Quase transparente: o bastante para receber o mouse.
        window.backgroundColor = NSColor(white: 1, alpha: 0.004)
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view = PetHitView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view

        stage.orderFrontRegardless()
        place(NSPoint(x: screen.maxX - 220, y: screen.minY), duration: 0)

        view.onDragStart = { [weak self] in
            guard let self else { return }
            self.interrupt()
            self.home = false
            self.onEvent("pet_drag")
        }
        view.onDrag = { [weak self] p in self?.follow(p) }
        view.onDrop = { [weak self] in self?.dropped() }
        view.onPetted = { [weak self] in
            self?.figure.bliss()
            self?.celebrate(.happy, seconds: 1.6)
            self?.onEvent("pet_petted")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resizeStage() }
        }
        scheduleWalk()
    }

    var frame: NSRect { NSRect(origin: origin, size: size) }
    var mood: Mood { figure.mood }

    private var screen: NSRect { stage.frame }

    private func resizeStage() {
        let s = (NSScreen.screens.first ?? NSScreen.main)?.frame ?? .zero
        stage.setFrame(s, display: false)
        stage.contentView?.frame = NSRect(origin: .zero, size: s.size)
        place(origin, duration: 0)
    }

    // MARK: Movimento

    /// Leva o desenho até `p` (canto inferior esquerdo, em coordenadas da
    /// tela). A janela de toque some durante o trajeto e aparece no destino.
    private func place(_ p: NSPoint, duration: Double, timing: CAMediaTimingFunctionName = .easeOut, done: (() -> Void)? = nil) {
        origin = p
        let local = CGPoint(x: p.x - stage.frame.minX, y: p.y - stage.frame.minY)
        let mine = token
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: timing))
            window.orderOut(nil)
        } else {
            CATransaction.setDisableActions(true)
        }
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == mine else { return }
                self.window.setFrameOrigin(p)
                self.window.orderFrontRegardless()
                done?()
            }
        }
        figure.root.position = local
        CATransaction.commit()
    }

    /// Para tudo onde está (para o arraste começar do ponto visível).
    private func interrupt() {
        token += 1
        moving = false
        figure.walking(false)
        figure.crawling(false)
        if let shown = figure.root.presentation()?.position {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            figure.root.removeAllAnimations()
            figure.root.position = shown
            CATransaction.commit()
            origin = NSPoint(x: shown.x + stage.frame.minX, y: shown.y + stage.frame.minY)
        }
    }

    /// Durante o arraste o desenho acompanha o dedo, sem animação.
    private func follow(_ p: NSPoint) {
        origin = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        figure.root.position = CGPoint(x: p.x - stage.frame.minX, y: p.y - stage.frame.minY)
        CATransaction.commit()
    }

    // MARK: Humor

    /// `tasks` define o humor principal; o sucesso vira uma comemoração curta.
    func update(tasks: [TaskItem], finished: String?) {
        if tasks.contains(where: { $0.status == "awaiting_approval" }) {
            taskMood = .waiting
        } else if tasks.contains(where: \.isActive) {
            taskMood = .thinking
        } else {
            taskMood = nil
        }
        if finished == "done" {
            celebrate(.happy, seconds: 1.8)
        } else if finished == "failed" {
            celebrate(.sad, seconds: 4)
        } else {
            refresh()
        }
    }

    /// Humor que vem da mente no core.
    func setMind(_ mood: String, sleeping: Bool) {
        mindMood = switch sleeping ? "dormindo" : mood {
        case "dormindo": .sleeping
        case "feliz": .idle
        case "curiosa": .curious
        case "entediada": .bored
        case "cansada": .tired
        case "carente": .lonely
        case "focada": .focused
        default: .idle
        }
        refresh()
        // Para dormir, volta para casa.
        if sleeping, !home { goHome() }
    }

    func celebrate(_ mood: Mood, seconds: Double) {
        celebrateUntil = Date().addingTimeInterval(seconds)
        set(mood)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard Date() >= celebrateUntil else { return }
        set(taskMood ?? mindMood)
    }

    private func set(_ mood: Mood) {
        if figure.mood != mood { figure.apply(mood) }
    }

    func wear(_ outfit: OutfitData?) {
        figure.wear(outfit)
    }

    // MARK: Casa na Dock

    /// Está em casa com a Dock recolhida: fora da vista.
    var hiddenAtHome: Bool { home && !dockVisible() }

    /// A Dock se mexeu: em casa, ela acompanha; fora, só ajusta o chão.
    func dockMoved(home target: NSRect?, animated: Bool) {
        guard !moving, NSEvent.pressedMouseButtons == 0 else { return }
        if home, let target {
            place(target.origin, duration: animated ? 0.22 : 0)
        } else if home {
            // Sem casa (Dock desligada ou de lado): ela fica na tela.
            home = false
            settle(animated: animated)
        } else {
            settle(animated: true)
        }
    }

    /// Primeira posição: sentada em casa, se houver casa.
    func startAtHome() {
        guard let target = homeFrame() else {
            settle(animated: false)
            return
        }
        home = true
        place(target.origin, duration: 0)
    }

    /// Sai de casa: pula da Dock ou, recolhida, rasteja de baixo da borda.
    func comeOut(then done: (() -> Void)? = nil) {
        guard home, !moving, let start = homeFrame() else {
            done?()
            return
        }
        home = false
        outUntil = Date().addingTimeInterval(.random(in: 90...240))
        moving = true
        if dockVisible() {
            figure.look(-1)
            place(NSPoint(x: start.minX, y: floorY(start.midX)), duration: 0.28) { [weak self] in
                self?.moving = false
                done?()
            }
        } else {
            // Começa logo abaixo da borda, onde a Dock estaria, e sobe.
            place(NSPoint(x: start.minX, y: screen.minY - size.height + 4), duration: 0)
            figure.crawling(true)
            place(NSPoint(x: start.minX, y: screen.minY), duration: 1.1) { [weak self] in
                self?.figure.crawling(false)
                self?.moving = false
                done?()
            }
        }
    }

    /// Volta para casa: anda até a Dock e senta, ou rasteja para baixo da borda.
    func goHome() {
        guard !home, let target = homeFrame() else { return }
        go(to: target.midX) { [weak self] in
            guard let self, let target = self.homeFrame() else { return }
            self.moving = true
            if self.dockVisible() {
                self.place(target.origin, duration: 0.25, timing: .easeIn) {
                    self.moving = false
                    self.home = true
                }
            } else {
                self.figure.crawling(true)
                self.place(NSPoint(x: self.origin.x, y: self.screen.minY - self.size.height + 4), duration: 0.9, timing: .easeIn) {
                    self.figure.crawling(false)
                    self.place(target.origin, duration: 0)
                    self.moving = false
                    self.home = true
                }
            }
        }
    }

    /// Solta em cima da Dock: entra em casa. Fora dela: cai até o chão.
    private func dropped() {
        if let dock = dockFrame(), dockVisible(), dock.contains(NSPoint(x: frame.midX, y: frame.minY + 20)),
           let target = homeFrame() {
            moving = true
            place(target.origin, duration: 0.3, timing: .easeInEaseOut) { [weak self] in
                self?.moving = false
                self?.home = true
            }
            return
        }
        home = false
        outUntil = Date().addingTimeInterval(300)
        settle(animated: true)
    }

    // MARK: Chão e caminhada

    /// Onde ela fica de pé num dado x: em cima da Dock ou na base da tela.
    private func floorY(_ centerX: CGFloat) -> CGFloat {
        if let s = shelf(), s.x.contains(centerX) { return s.y - foot }
        return screen.minY
    }

    private func clampX(_ centerX: CGFloat) -> CGFloat {
        min(max(centerX, screen.minX + size.width / 2), screen.maxX - size.width / 2)
    }

    /// Cai (ou sobe) até o chão onde está.
    func settle(animated: Bool) {
        guard !home, !moving, NSEvent.pressedMouseButtons == 0 else { return }
        let y = floorY(frame.midX)
        guard abs(origin.y - y) > 0.5 else { return }
        let fall = origin.y - y
        let duration = animated ? min(0.5, max(0.15, Double(abs(fall)) / 1400)) : 0
        place(NSPoint(x: origin.x, y: y), duration: duration, timing: fall > 0 ? .easeIn : .easeOut)
    }

    /// Anda até um x, pulando para cima ou para baixo da Dock no caminho.
    func go(to centerX: CGFloat, speed: CGFloat = 90, then done: (() -> Void)? = nil) {
        guard !home, NSEvent.pressedMouseButtons == 0 else { return }
        let target = clampX(centerX)
        let start = frame.midX
        guard abs(target - start) > 2 else {
            done?()
            return
        }
        let dir: CGFloat = target > start ? 1 : -1
        figure.look(dir)
        moving = true
        figure.walking(true)
        var stops: [CGFloat] = []
        if let s = shelf() {
            for edge in [s.x.lowerBound, s.x.upperBound] where (edge - start) * dir > 0 && (target - edge) * dir > 0 {
                stops.append(edge)
            }
            stops.sort { ($0 - start) * dir < ($1 - start) * dir }
        }
        stops.append(target)
        step(stops, dir: dir, speed: speed) { [weak self] in
            self?.moving = false
            self?.figure.walking(false)
            self?.figure.look(0)
            done?()
        }
    }

    private func step(_ stops: [CGFloat], dir: CGFloat, speed: CGFloat, done: @escaping () -> Void) {
        guard let next = stops.first else {
            done()
            return
        }
        let distance = abs(next - frame.midX)
        // Na beirada da Dock, o chão do outro lado decide: sobe ou desce num pulo.
        let landing = floorY(next + dir * 2)
        let hop = abs(landing - origin.y) > 1
        place(NSPoint(x: next - size.width / 2, y: origin.y), duration: Double(distance / speed), timing: .linear) { [weak self] in
            guard let self, self.moving else { return }
            if hop {
                self.place(NSPoint(x: self.origin.x + dir * 6, y: landing), duration: 0.2) {
                    self.step(Array(stops.dropFirst()), dir: dir, speed: speed, done: done)
                }
            } else {
                self.step(Array(stops.dropFirst()), dir: dir, speed: speed, done: done)
            }
        }
    }

    // MARK: Vida

    /// Alguém abriu um app pela Dock: ela sai, corre até o ícone e volta.
    func appOpened(_ id: String) {
        guard figure.mood != .sleeping, dockVisible(), iconX(id) != nil, !busy() else { return }
        let visit = { [weak self] in
            guard let self, let x = self.iconX(id) else { return }
            self.go(to: x, speed: 320) {
                self.nudge(id)
                self.celebrate(.happy, seconds: 1.2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.goHome() }
            }
        }
        if home { comeOut(then: visit) } else { visit() }
    }

    /// Troca de ambiente: um giro de alegria, onde estiver.
    func environmentChanged() {
        figure.spin()
        celebrate(.happy, seconds: 1)
    }

    private func scheduleWalk() {
        let t = Timer(timeInterval: .random(in: 25...70), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wander()
                self?.scheduleWalk()
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        walkTimer = t
    }

    /// Em casa, às vezes sai para passear. Fora, passeia e, depois de um
    /// tempo, volta. Curiosa ou entediada, vai mexer num ícone da Dock.
    private func wander() {
        guard !moving, !busy(), [.idle, .curious, .bored, .lonely].contains(figure.mood), NSEvent.pressedMouseButtons == 0 else { return }
        let restless = figure.mood == .curious || figure.mood == .bored || figure.mood == .lonely
        if home {
            guard restless || Double.random(in: 0...1) < 0.35 else { return }
            comeOut { [weak self] in self?.stroll(restless: restless) }
            return
        }
        if Date() > outUntil {
            goHome()
            return
        }
        stroll(restless: restless)
    }

    private func stroll(restless: Bool) {
        if dockVisible(), restless || Bool.random(), let id = randomIcon(), let x = iconX(id) {
            go(to: x) { [weak self] in
                self?.nudge(id)
                self?.onEvent("pet_visit")
            }
            return
        }
        let dx = CGFloat.random(in: 80...260) * (Bool.random() ? 1 : -1)
        go(to: frame.midX + dx)
    }
}
