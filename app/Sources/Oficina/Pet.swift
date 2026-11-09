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
        snore(next == .sleeping)
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

    /// Gingado enquanto anda: inclina de um lado para o outro a cada passo,
    /// com um leve sobe e desce. Correndo, os passos ficam mais curtos.
    func walking(_ on: Bool, fast: Bool = false) {
        body.removeAnimation(forKey: "step")
        guard on else { return }
        let period: CFTimeInterval = fast ? 0.3 : 0.52
        let tilt = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        tilt.values = [0, 0.09, 0, -0.09, 0]
        let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
        lift.values = [0, 2.5, 0, 2.5, 0]
        let group = CAAnimationGroup()
        group.animations = [tilt, lift]
        group.duration = period
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        body.add(group, forKey: "step")
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

    private var thought: CALayer?

    /// Pensamento em voz alta, preso acima dela: anda junto quando ela anda.
    /// `left` e `right` limitam o balão à tela, em coordenadas dela.
    func say(_ text: String, left: CGFloat, right: CGFloat) {
        thought?.removeFromSuperlayer()
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let r = attr.boundingRect(with: NSSize(width: 200, height: 300), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: ceil(r.width) + 22, height: ceil(r.height) + 14)
        var x = w / 2 - size.width / 2
        x = min(max(x, left + 6), right - size.width - 6)
        let box = CALayer()
        box.frame = CGRect(x: x, y: 90, width: size.width, height: size.height)
        box.cornerRadius = 11
        box.backgroundColor = CGColor(gray: 0.13, alpha: 0.94)
        box.borderColor = CGColor(gray: 1, alpha: 0.14)
        box.borderWidth = 1
        box.shadowOpacity = 0.3
        box.shadowRadius = 6
        box.shadowOffset = CGSize(width: 0, height: -2)
        let label = CATextLayer()
        label.frame = box.bounds.insetBy(dx: 11, dy: 7)
        label.string = attr
        label.isWrapped = true
        box.addSublayer(label)
        box.opacity = 0
        root.addSublayer(box)
        crispen(box)
        thought = box
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        box.add(fade, forKey: "in")
        box.opacity = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak box] in
            guard let box, self?.thought === box else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setCompletionBlock { box.removeFromSuperlayer() }
            box.opacity = 0
            CATransaction.commit()
        }
    }

    func hush() {
        thought?.removeFromSuperlayer()
        thought = nil
    }

    private var zzz: CALayer?

    /// Zzz subindo e sumindo enquanto dorme. Tudo no servidor de janelas.
    private func snore(_ on: Bool) {
        zzz?.removeFromSuperlayer()
        zzz = nil
        guard on else { return }
        let group = CALayer()
        group.frame = CGRect(x: w / 2 + 8, y: 60, width: 30, height: 40)
        for i in 0..<3 {
            let z = CATextLayer()
            z.string = "z"
            z.fontSize = CGFloat(10 + i * 3)
            z.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            z.foregroundColor = NSColor(white: 1, alpha: 0.85).cgColor
            z.alignmentMode = .center
            z.frame = CGRect(x: 0, y: 0, width: 16, height: 18)
            z.opacity = 0
            let rise = CABasicAnimation(keyPath: "position")
            rise.fromValue = NSValue(point: NSPoint(x: 6, y: 6))
            rise.toValue = NSValue(point: NSPoint(x: 22, y: 36))
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.2, 0.7, 1]
            let anim = CAAnimationGroup()
            anim.animations = [rise, fade]
            anim.duration = 2.4
            anim.repeatCount = .infinity
            anim.beginTime = CACurrentMediaTime() + Double(i) * 0.8
            z.add(anim, forKey: "zzz")
            group.addSublayer(z)
        }
        root.addSublayer(group)
        crispen(group)
        zzz = group
    }

    // MARK: Caminha

    private let bedBack = CALayer()
    private let bedFront = CALayer()
    private var decor: DecorData?

    private func shade(_ hex: String, _ amount: CGFloat) -> CGColor {
        let c = NSColor(cgColor: color(hex)) ?? .gray
        return (amount < 0 ? c.blended(withFraction: -amount, of: .black) : c.blended(withFraction: amount, of: .white))?.cgColor ?? c.cgColor
    }

    /// Desenha a caminha: o fundo fica atrás dela; manta e borda, na frente.
    func setDecor(_ d: DecorData) {
        decor = d
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if bedBack.superlayer == nil {
            for l in [bedBack, bedFront] {
                l.frame = bounds
                l.opacity = 0
                l.anchorPoint = CGPoint(x: 0.5, y: 0)
                l.position = CGPoint(x: w / 2, y: 0)
            }
            root.insertSublayer(bedBack, below: body)
            root.insertSublayer(bedFront, above: body)
        }
        bedBack.sublayers?.forEach { $0.removeFromSuperlayer() }
        bedFront.sublayers?.forEach { $0.removeFromSuperlayer() }

        func add(_ path: CGPath, _ fill: CGColor?, stroke: CGColor? = nil, width: CGFloat = 1.5, to parent: CALayer) {
            let l = CAShapeLayer()
            l.path = path
            l.fillColor = fill
            l.strokeColor = stroke
            l.lineWidth = width
            l.lineCap = .round
            parent.addSublayer(l)
        }
        func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
        func poly(_ pts: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p }
        let base = color(d.bed.color)
        let dark = shade(d.bed.color, -0.28)
        let light = shade(d.bed.color, 0.35)

        // Enfeites que ficam atrás.
        switch d.extra.shape {
        case "pillow":
            add(rr(CGRect(x: 4, y: 20, width: 28, height: 15), 7), color(d.extra.color), to: bedBack)
        case "moon":
            let m = CGMutablePath()
            m.addEllipse(in: CGRect(x: 66, y: 58, width: 16, height: 16))
            add(m, color(d.extra.color), to: bedBack)
            add(CGPath(ellipseIn: CGRect(x: 71, y: 62, width: 14, height: 14), transform: nil), CGColor(gray: 0.1, alpha: 0.9), to: bedBack)
        case "lamp":
            add(rr(CGRect(x: 77, y: 0, width: 3, height: 30), 1.5), CGColor(gray: 0.35, alpha: 1), to: bedBack)
            add(poly([CGPoint(x: 70, y: 28), CGPoint(x: 87, y: 28), CGPoint(x: 83, y: 40), CGPoint(x: 74, y: 40)]), color(d.extra.color), to: bedBack)
        default: break
        }

        switch d.bed.shape {
        case "basket":
            add(poly([CGPoint(x: 0, y: 32), CGPoint(x: 84, y: 32), CGPoint(x: 78, y: 0), CGPoint(x: 6, y: 0)]), dark, to: bedBack)
        case "nest":
            add(CGPath(ellipseIn: CGRect(x: -4, y: -2, width: 92, height: 34), transform: nil), dark, to: bedBack)
        case "cloud":
            let c = CGMutablePath()
            c.addEllipse(in: CGRect(x: 0, y: 6, width: 32, height: 26))
            c.addEllipse(in: CGRect(x: 22, y: 10, width: 40, height: 30))
            c.addEllipse(in: CGRect(x: 52, y: 6, width: 32, height: 26))
            add(c, light, to: bedBack)
        case "box":
            add(rr(CGRect(x: 4, y: 0, width: 76, height: 34), 2), dark, to: bedBack)
            add(poly([CGPoint(x: 4, y: 34), CGPoint(x: -8, y: 44), CGPoint(x: 18, y: 38)]), base, to: bedBack)
            add(poly([CGPoint(x: 80, y: 34), CGPoint(x: 92, y: 44), CGPoint(x: 66, y: 38)]), base, to: bedBack)
        default:
            add(rr(CGRect(x: 0, y: 2, width: 84, height: 30), 15), dark, to: bedBack)
        }

        // Manta por cima dela, com o padrão recortado na forma da manta.
        if d.blanket.shape != "none" {
            let blanket = CALayer()
            blanket.frame = CGRect(x: 14, y: 4, width: 56, height: 19)
            blanket.cornerRadius = 7
            blanket.masksToBounds = true
            blanket.backgroundColor = color(d.blanket.color)
            let pattern = shade(d.blanket.color, -0.3)
            switch d.blanket.shape {
            case "stripes":
                for x in stride(from: CGFloat(3), to: 56, by: 9) {
                    let s = CALayer()
                    s.frame = CGRect(x: x, y: 0, width: 4, height: 19)
                    s.backgroundColor = pattern
                    blanket.addSublayer(s)
                }
            case "dots":
                for (i, x) in stride(from: CGFloat(5), to: 54, by: 9).enumerated() {
                    add(CGPath(ellipseIn: CGRect(x: x, y: i % 2 == 0 ? 4 : 11, width: 4, height: 4), transform: nil), pattern, to: blanket)
                }
            case "stars":
                for (i, x) in stride(from: CGFloat(6), to: 54, by: 13).enumerated() {
                    let cx = x, cy: CGFloat = i % 2 == 0 ? 7 : 13
                    var pts: [CGPoint] = []
                    for k in 0..<10 {
                        let r: CGFloat = k % 2 == 0 ? 4 : 1.8
                        let a = CGFloat(k) * .pi / 5 - .pi / 2
                        pts.append(CGPoint(x: cx + r * cos(a), y: cy - r * sin(a)))
                    }
                    add(poly(pts), pattern, to: blanket)
                }
            default: break
            }
            bedFront.addSublayer(blanket)
        }

        // Borda da frente: é o que faz parecer que ela está dentro.
        switch d.bed.shape {
        case "basket":
            add(poly([CGPoint(x: 3, y: 15), CGPoint(x: 81, y: 15), CGPoint(x: 77, y: -3), CGPoint(x: 7, y: -3)]), base, to: bedFront)
            for y in [CGFloat(1), 6, 11] {
                let p = CGMutablePath(); p.move(to: CGPoint(x: 6, y: y)); p.addLine(to: CGPoint(x: 78, y: y))
                add(p, nil, stroke: dark, width: 1.2, to: bedFront)
            }
        case "nest":
            add(CGPath(ellipseIn: CGRect(x: -2, y: -6, width: 88, height: 22), transform: nil), base, to: bedFront)
            for i in 0..<9 {
                let x = CGFloat(4 + i * 9)
                let p = CGMutablePath(); p.move(to: CGPoint(x: x, y: 2 + CGFloat(i % 3) * 3)); p.addLine(to: CGPoint(x: x + 12, y: 6 + CGFloat((i + 1) % 3) * 3))
                add(p, nil, stroke: dark, width: 1.4, to: bedFront)
            }
        case "cloud":
            add(rr(CGRect(x: 0, y: -3, width: 84, height: 17), 8.5), base, to: bedFront)
        case "box":
            add(rr(CGRect(x: 4, y: -3, width: 76, height: 17), 2), base, to: bedFront)
            add(rr(CGRect(x: 36, y: -3, width: 12, height: 17), 1), light, to: bedFront)
        default:
            add(rr(CGRect(x: 2, y: -3, width: 80, height: 17), 8.5), base, to: bedFront)
            let shine = CGMutablePath(); shine.move(to: CGPoint(x: 12, y: 10)); shine.addLine(to: CGPoint(x: 72, y: 10))
            add(shine, nil, stroke: light, width: 1.5, to: bedFront)
        }

        // Enfeites da frente.
        switch d.extra.shape {
        case "plant":
            add(rr(CGRect(x: -4, y: -3, width: 12, height: 11), 2), CGColor(red: 0.72, green: 0.42, blue: 0.27, alpha: 1), to: bedFront)
            for (dx, dy) in [(-4.0, 16.0), (2.0, 20.0), (7.0, 14.0)] {
                add(CGPath(ellipseIn: CGRect(x: dx - 1, y: 6, width: 7, height: dy - 4), transform: nil), color(d.extra.color), to: bedFront)
            }
        case "bone":
            add(rr(CGRect(x: 60, y: 6, width: 16, height: 4), 2), color(d.extra.color), to: bedFront)
            for (x, y) in [(57.0, 3.0), (57.0, 8.0), (73.0, 3.0), (73.0, 8.0)] {
                add(CGPath(ellipseIn: CGRect(x: x, y: y, width: 6, height: 6), transform: nil), color(d.extra.color), to: bedFront)
            }
        default: break
        }
        crispen(bedBack)
        crispen(bedFront)
    }

    /// A caminha aparece (com um "pop") ou some.
    func showBed(_ on: Bool, animated: Bool) {
        if on, decor == nil { return }
        for (i, l) in [bedBack, bedFront].enumerated() {
            l.removeAnimation(forKey: "pop")
            if on && animated {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [0.4, 1.12, 0.96, 1]
                pop.keyTimes = [0, 0.55, 0.8, 1]
                pop.duration = 0.45
                pop.beginTime = CACurrentMediaTime() + Double(i) * 0.03
                pop.fillMode = .backwards
                l.add(pop, forKey: "pop")
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(animated ? 0.25 : 0)
            CATransaction.setDisableActions(!animated)
            l.opacity = on ? 1 : 0
            CATransaction.commit()
        }
    }

    enum Pose { case out, home, bed }
    private(set) var pose: Pose = .out
    /// Tamanho em casa, para caber na Dock (definido pelo tamanho dos ícones).
    var homeScale: CGFloat = 0.7

    /// Fora, tamanho normal. Em casa, menor. Na cama, menor e deitada.
    /// A escala parte da base dela, então os pés continuam no chão.
    func setPose(_ p: Pose, duration: Double) {
        if p != .bed && pose == .bed { showBed(false, animated: duration > 0) }
        if p == .bed && pose != .bed && bedFront.opacity == 0 { showBed(true, animated: duration > 0) }
        pose = p
        let s: CGFloat = p == .out ? 1 : homeScale
        let sx = p == .bed ? s * 1.1 : s
        let sy = p == .bed ? s * 0.86 : s
        var t = CATransform3DMakeTranslation(w / 2, 0, 0)
        t = CATransform3DScale(t, sx, sy, 1)
        t = CATransform3DTranslate(t, -w / 2, 0, 0)
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        root.sublayerTransform = t
        CATransaction.commit()
    }

    /// Como um cachorrinho antes de dormir: vira de um lado e do outro,
    /// amassa a caminha e só então se deita.
    func curlUp(then done: @escaping () -> Void) {
        let turn = CAKeyframeAnimation(keyPath: "transform.scale.x")
        turn.values = [1, 0.15, -1, -1, 0.15, 1, 1]
        turn.keyTimes = [0, 0.12, 0.24, 0.4, 0.52, 0.64, 1]
        let knead = CAKeyframeAnimation(keyPath: "transform.translation.y")
        knead.values = [0, 0, 0, -2.5, 0, -2.5, 0, -2.5, 0]
        knead.keyTimes = [0, 0.64, 0.68, 0.73, 0.78, 0.83, 0.88, 0.93, 1]
        let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sway.values = [0, 0.08, -0.08, 0.06, -0.06, 0, 0]
        sway.keyTimes = [0, 0.1, 0.3, 0.45, 0.6, 0.66, 1]
        let group = CAAnimationGroup()
        group.animations = [turn, knead, sway]
        group.duration = 2.2
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        body.add(group, forKey: "curl")
        CATransaction.commit()
        look(-1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.look(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.look(0) }
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
    /// Abre ou fecha a casa na Dock (os ícones abrem espaço para ela).
    var setHomeOpen: (Bool) -> Void = { _ in }
    var onMoveStart: () -> Void = {}
    /// Colocada na Dock: vai descansar (segundos de descanso).
    var onRest: (Double) -> Void = { _ in }
    /// Acordou de um descanso (sozinha ou cutucada).
    var onWake: () -> Void = {}
    private var restUntil = Date.distantPast
    private var restTimer: Timer?
    var resting: Bool { Date() < restUntil }
    /// Tamanho dela em casa, conforme o tamanho dos ícones da Dock.
    var homeScale: () -> CGFloat = { 0.7 }
    var onMoveEnd: () -> Void = {}
    private var lastSaid = Date.distantPast

    /// Pensamento em voz alta, de vez em quando. Escondida em casa, fica quieta.
    func say(_ text: String, force: Bool = false) {
        guard !hiddenAtHome, !busy(), !resting else { return }
        guard force || Date().timeIntervalSince(lastSaid) > 90 else { return }
        lastSaid = Date()
        figure.say(text, left: screen.minX - origin.x, right: screen.maxX - origin.x)
    }

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
            self.restTimer?.invalidate()
            self.restUntil = .distantPast
            self.figure.setPose(.out, duration: 0.15)
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
    private func place(_ p: NSPoint, duration: Double, timing: CAMediaTimingFunctionName = .easeOut,
                       curve: CAMediaTimingFunction? = nil, done: (() -> Void)? = nil) {
        origin = p
        let local = CGPoint(x: p.x - stage.frame.minX, y: p.y - stage.frame.minY)
        let mine = token
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(curve ?? CAMediaTimingFunction(name: timing))
            window.orderOut(nil)
            onMoveStart()
        } else {
            CATransaction.setDisableActions(true)
        }
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == mine else { return }
                self.window.setFrameOrigin(p)
                self.window.orderFrontRegardless()
                done?()
                if !self.moving { self.onMoveEnd() }
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
        guard !resting else { return }
        celebrateUntil = Date().addingTimeInterval(seconds)
        set(mood)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard Date() >= celebrateUntil else { return }
        // Descansando, continua dormindo; tarefas seguem visíveis no notch e no chat.
        let mood = resting ? .sleeping : (taskMood ?? mindMood)
        set(mood)
        // Em casa: deitada se dorme, sentadinha se não.
        if home {
            let pose: PetFigure.Pose = mood == .sleeping ? .bed : .home
            if figure.pose != pose { figure.setPose(pose, duration: 0.35) }
        }
    }

    // MARK: Descanso

    /// Fica em casa dormindo por um tempo: sem passeios nem conversa.
    private func rest() {
        let secs = Double.random(in: 600...900)
        restUntil = Date().addingTimeInterval(secs)
        figure.hush()
        // Ainda acordada durante o ritual; depois deita e dorme.
        celebrateUntil = Date().addingTimeInterval(2.3)
        set(.idle)
        // Primeiro ela coloca a caminha; depois se ajeita.
        figure.showBed(true, animated: true)
        figure.curlUp { [weak self] in
            guard let self, self.resting, self.home else { return }
            self.figure.setPose(.bed, duration: 0.35)
            self.celebrateUntil = .distantPast
            self.refresh()
        }
        onRest(secs)
        restTimer?.invalidate()
        let t = Timer(timeInterval: secs, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeUp() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        restTimer = t
    }

    /// Acorda antes da hora (clique) ou quando o descanso acaba.
    func wakeUp() {
        guard restUntil > .distantPast else { return }
        restTimer?.invalidate()
        restUntil = .distantPast
        if home { figure.setPose(.home, duration: 0.3) }
        refresh()
        onWake()
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
    func dockMoved(home target: NSRect?, duration: Double, curve: CAMediaTimingFunction?) {
        guard !moving, NSEvent.pressedMouseButtons == 0 else { return }
        if home, let target {
            // Indo para fora da tela com a Dock: o pensamento vai junto, calado.
            if target.maxY <= screen.minY + 10 { figure.hush() }
            // Mesma duração e curva da Dock: sobem e descem juntas.
            place(target.origin, duration: duration, curve: curve)
        } else if home {
            // Sem casa (Dock desligada ou de lado): ela fica na tela.
            home = false
            settle(animated: duration > 0)
        } else {
            // Em cima da faixa da Dock, ela sobe e desce junto, como num elevador.
            settle(duration: duration, curve: curve)
        }
    }

    /// Primeira posição: sentada em casa, se houver casa.
    func startAtHome() {
        guard let target = homeFrame() else {
            settle(animated: false)
            return
        }
        home = true
        figure.homeScale = homeScale()
        figure.setPose(.home, duration: 0)
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
        restTimer?.invalidate()
        restUntil = .distantPast
        figure.setPose(.out, duration: dockVisible() ? 0.3 : 0)
        if dockVisible() {
            // Pula para a esquerda, em cima da Dock; aí a casa fecha atrás dela.
            figure.look(-1)
            let x = start.midX - dockHomeWidth
            place(NSPoint(x: x - size.width / 2, y: floorY(x)), duration: 0.3) { [weak self] in
                self?.setHomeOpen(false)
                // A Dock encolhe e os ícones mudam de lugar: espera antes de mirar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    self?.moving = false
                    self?.settle(animated: true)
                    done?()
                }
            }
        } else {
            // Começa logo abaixo da borda, onde a Dock estaria, e sobe.
            place(NSPoint(x: start.minX, y: screen.minY - size.height + 4), duration: 0)
            figure.crawling(true)
            place(NSPoint(x: start.minX, y: screen.minY), duration: 1.1) { [weak self] in
                self?.figure.crawling(false)
                self?.setHomeOpen(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    self?.moving = false
                    done?()
                }
            }
        }
    }

    /// Volta para casa: anda até o fim da Dock; aí a casa abre e ela entra.
    /// Com a Dock recolhida, rasteja para baixo da borda.
    func goHome() {
        guard !home, let closed = homeFrame() else { return }
        // Com a casa fechada, o fim da Dock fica um pouco à esquerda.
        let doorway = closed.midX - dockHomeWidth
        go(to: dockVisible() ? doorway : closed.midX) { [weak self] in
            guard let self else { return }
            self.moving = true
            if self.dockVisible() {
                self.enterHome()
            } else {
                self.figure.crawling(true)
                self.figure.hush()
                self.place(NSPoint(x: self.origin.x, y: self.screen.minY - self.size.height + 4), duration: 0.9, timing: .easeIn) {
                    self.figure.crawling(false)
                    self.setHomeOpen(true)
                    self.figure.homeScale = self.homeScale()
                    self.figure.setPose(.home, duration: 0)
                    self.home = true
                    self.moving = false
                    if let t = self.homeFrame() { self.place(t.origin, duration: 0) }
                }
            }
        }
    }

    /// "Colocar para dormir": vai para casa e descansa um pouco.
    func putToBed() {
        if home {
            rest()
        } else if let dock = dockFrame(), dockVisible(), dock.contains(NSPoint(x: frame.midX, y: frame.minY + 20)) {
            enterHome(rest: true)
        } else {
            goHome()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restWhenHome() }
        }
    }

    private func restWhenHome(tries: Int = 40) {
        if home { rest(); return }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.restWhenHome(tries: tries - 1) }
    }

    /// A casa abre (os ícones abrem espaço) e ela pula para dentro.
    /// Colocada lá por você, vai descansar.
    private func enterHome(rest: Bool = false) {
        moving = true
        setHomeOpen(true)
        // A Dock recalcula a largura no próximo ciclo; aí a casa tem lugar certo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let target = self.homeFrame() else { return }
            self.figure.homeScale = self.homeScale()
            self.figure.setPose(.home, duration: 0.3)
            self.place(target.origin, duration: 0.3, timing: .easeInEaseOut) {
                self.moving = false
                self.home = true
                if rest { self.rest() }
            }
        }
    }

    /// Solta em cima da Dock: entra em casa. Fora dela: cai até o chão.
    private func dropped() {
        if let dock = dockFrame(), dockVisible(), dock.contains(NSPoint(x: frame.midX, y: frame.minY + 20)) {
            enterHome(rest: true)
            return
        }
        home = false
        outUntil = Date().addingTimeInterval(300)
        settle(animated: true)
    }

    // MARK: Chão e caminhada

    /// Onde ela fica de pé num dado x: em cima da Dock ou na base da tela.
    /// Conta o corpo dela (não só o centro): se a ponta da Dock fica
    /// embaixo dela, ela está em cima da Dock.
    private func floorY(_ centerX: CGFloat) -> CGFloat {
        let half: CGFloat = 22
        if let s = shelf(), centerX + half > s.x.lowerBound, centerX - half < s.x.upperBound { return s.y - foot }
        return screen.minY
    }

    private func clampX(_ centerX: CGFloat) -> CGFloat {
        min(max(centerX, screen.minX + size.width / 2), screen.maxX - size.width / 2)
    }

    /// Cai (ou sobe) até o chão onde está.
    func settle(animated: Bool) {
        let fall = origin.y - floorY(frame.midX)
        settle(duration: animated ? min(0.5, max(0.15, Double(abs(fall)) / 1400)) : 0)
    }

    private func settle(duration: Double, curve: CAMediaTimingFunction? = nil) {
        guard !home, !moving, NSEvent.pressedMouseButtons == 0 else { return }
        let y = floorY(frame.midX)
        guard abs(origin.y - y) > 0.5 else { return }
        place(NSPoint(x: origin.x, y: y), duration: duration, timing: origin.y > y ? .easeIn : .easeOut, curve: curve)
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
        figure.walking(true, fast: speed > 150)
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
            // A Dock pode ter se mexido no caminho: acerta o chão.
            self?.settle(animated: true)
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
        guard figure.mood != .sleeping, !resting, dockVisible(), iconX(id) != nil, !busy() else { return }
        let visit: () -> Void = { [weak self] in
            self?.reach(id, speed: 320) {
                guard let self else { return }
                self.nudge(id)
                self.celebrate(.happy, seconds: 1.2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.goHome() }
            }
        }
        if home { comeOut(then: visit) } else { visit() }
    }

    /// Vai até o ícone e, se a Dock mudou no caminho, corrige a mira.
    private func reach(_ id: String, speed: CGFloat = 90, tries: Int = 2, then done: @escaping () -> Void) {
        guard let x = iconX(id) else { return }
        go(to: x, speed: speed) { [weak self] in
            guard let self else { return }
            if tries > 0, let now = self.iconX(id), abs(now - self.frame.midX) > 3 {
                self.reach(id, speed: 160, tries: tries - 1, then: done)
            } else {
                done()
            }
        }
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
        guard !moving, !busy(), !resting, [.idle, .curious, .bored, .lonely].contains(figure.mood), NSEvent.pressedMouseButtons == 0 else { return }
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
        if dockVisible(), restless || Bool.random(), let id = randomIcon(), iconX(id) != nil {
            reach(id) { [weak self] in
                self?.nudge(id)
                self?.onEvent("pet_visit")
            }
            return
        }
        let dx = CGFloat.random(in: 80...260) * (Bool.random() ? 1 : -1)
        go(to: frame.midX + dx)
    }
}
