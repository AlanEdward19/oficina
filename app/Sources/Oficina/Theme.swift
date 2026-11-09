import AppKit
import SwiftUI

// Peças visuais das telas. O que se move fica no Core Animation (servidor de
// janelas): o app só monta as camadas e volta a dormir. Nunca usar
// `repeatForever` do SwiftUI aqui, porque ele recalcula a view a cada quadro.

private let palette = ["#FF7A59", "#FF5C8A", "#B56CFF", "#5B8CFF", "#22B8CF", "#20C997", "#94D82D", "#FCC419"]

private func stableHash(_ s: String) -> Int {
    Int(s.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } >> 3)
}

/// Cada agente tem sempre a mesma cor, derivada do nome.
func agentColor(_ name: String) -> Color { colorFromHex(palette[stableHash(name.lowercased()) % palette.count]) }

func nsColor(_ hex: String) -> NSColor { NSColor(colorFromHex(hex)) }

private func repeating(_ key: String, from: Any?, to: Any?, duration: CFTimeInterval, offset: CFTimeInterval = 0) -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: key)
    a.fromValue = from
    a.toValue = to
    a.duration = duration
    a.autoreverses = true
    a.repeatCount = .infinity
    a.beginTime = CACurrentMediaTime() + offset
    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    a.isRemovedOnCompletion = false
    return a
}

/// View que hospeda camadas: o AppKit não toca nelas.
class LayerHost: NSView {
    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}

// MARK: Fundo vivo

/// Manchas de cor passeando. O gradiente é desenhado uma vez, em baixa
/// resolução (é borrado mesmo); depois só a posição muda.
struct AuroraView: NSViewRepresentable {
    var colors: [NSColor]

    final class Host: LayerHost {
        private var blobs: [CAGradientLayer] = []
        private var laidOut = CGSize.zero

        func paint(_ colors: [NSColor]) {
            while blobs.count < colors.count {
                let b = CAGradientLayer()
                b.type = .radial
                b.startPoint = CGPoint(x: 0.5, y: 0.5)
                b.endPoint = CGPoint(x: 1, y: 1)
                b.contentsScale = 0.25
                layer?.addSublayer(b)
                blobs.append(b)
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            for (b, c) in zip(blobs, colors) {
                b.colors = [c.withAlphaComponent(0.75).cgColor, c.withAlphaComponent(0).cgColor]
            }
            CATransaction.commit()
            place()
        }

        override func layout() {
            super.layout()
            place()
        }

        private func place() {
            let size = bounds.size
            guard size.width > 0, size != laidOut || blobs.contains(where: { $0.animationKeys() == nil }) else { return }
            laidOut = size
            layer?.masksToBounds = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let side = max(size.width, size.height) * 0.9
            for (i, b) in blobs.enumerated() {
                let f = CGFloat(i) / CGFloat(max(blobs.count - 1, 1))
                let start = CGPoint(x: size.width * (0.12 + 0.76 * f), y: size.height * (i % 2 == 0 ? 0.25 : 0.8))
                b.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                b.position = start
                let end = CGPoint(x: start.x + (i % 2 == 0 ? 0.22 : -0.22) * size.width, y: start.y + (i % 2 == 0 ? 0.5 : -0.5) * size.height)
                b.add(repeating("position", from: NSValue(point: start), to: NSValue(point: end), duration: 7 + Double(i) * 2.5), forKey: "drift")
            }
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ v: Host, context: Context) { v.paint(colors) }
}

// MARK: Estado

/// Bolinha de estado; quando ativa, solta um anel que cresce e some.
struct PulseDot: NSViewRepresentable {
    var color: Color
    var active: Bool
    var size: CGFloat = 9

    final class Host: LayerHost {
        let dot = CALayer()
        let ring = CALayer()

        override init() {
            super.init()
            layer?.addSublayer(ring)
            layer?.addSublayer(dot)
        }

        func update(_ color: CGColor, active: Bool, size: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            for l in [ring, dot] {
                l.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                l.cornerRadius = size / 2
                l.position = c
                l.backgroundColor = color
            }
            ring.opacity = active ? 1 : 0
            CATransaction.commit()
            if active, ring.animation(forKey: "pulse") == nil {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 1
                scale.toValue = 2.6
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.7
                fade.toValue = 0
                let group = CAAnimationGroup()
                group.animations = [scale, fade]
                group.duration = 1.3
                group.repeatCount = .infinity
                group.isRemovedOnCompletion = false
                ring.add(group, forKey: "pulse")
            } else if !active {
                ring.removeAllAnimations()
            }
        }

        override func layout() {
            super.layout()
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.position = c
            dot.position = c
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ v: Host, context: Context) { v.update(NSColor(color).cgColor, active: active, size: size) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? {
        CGSize(width: size * 2.8, height: size * 2.8)
    }
}

/// Três pontinhos pulando, sem acordar o app.
struct BouncingDots: NSViewRepresentable {
    var color: Color = .secondary

    final class Host: LayerHost {
        private var dots: [CALayer] = []

        func start(_ color: CGColor) {
            guard dots.isEmpty else { return }
            for i in 0..<3 {
                let d = CALayer()
                d.frame = CGRect(x: 2 + CGFloat(i) * 9, y: 3, width: 6, height: 6)
                d.cornerRadius = 3
                d.backgroundColor = color
                layer?.addSublayer(d)
                d.add(repeating("transform.translation.y", from: 0, to: 6, duration: 0.32, offset: Double(i) * 0.13), forKey: "hop")
                dots.append(d)
            }
        }
    }

    func makeNSView(context: Context) -> Host {
        let h = Host()
        h.start(NSColor(color).cgColor)
        return h
    }

    func updateNSView(_ v: Host, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? { CGSize(width: 32, height: 16) }
}

// MARK: Personagens

/// A própria Faísca, com as animações de verdade do pet.
struct LivePet: NSViewRepresentable {
    var settings: AssistantSettings
    var side: CGFloat = 130

    final class Host: LayerHost {
        private let figure = PetFigure(size: NSSize(width: 84, height: 88))
        private var worn: AssistantSettings?

        override init() {
            super.init()
            layer?.addSublayer(figure.root)
        }

        func show(_ s: AssistantSettings, side: CGFloat) {
            let scale = side / 110
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            figure.root.transform = CATransform3DMakeScale(scale, scale, 1)
            figure.root.position = CGPoint(x: (side - 84 * scale) / 2, y: side * 0.04)
            CATransaction.commit()
            var look = s
            look.name = ""
            look.personality = ""
            look.brain_model = ""
            look.brain_effort = ""
            guard look != worn else { return }
            let first = worn == nil
            worn = look
            figure.customize(s)
            if !first { hop() }
        }

        /// Pulinho de reação a cada mudança de aparência.
        private func hop() {
            let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
            a.values = [0, 12, 0, 4, 0]
            a.keyTimes = [0, 0.35, 0.65, 0.82, 1]
            a.duration = 0.42
            layer?.add(a, forKey: "hop")
        }
    }

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ v: Host, context: Context) { v.show(settings, side: side) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? { CGSize(width: side, height: side) }
}

/// Carinha de agente: a cor e o olhar vêm do nome.
struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 28
    var active = false

    var body: some View {
        let tint = agentColor(name)
        let style = stableHash(name) % 3
        ZStack {
            Circle().fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .top, endPoint: .bottom))
            HStack(spacing: size * 0.15) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule()
                        .fill(Color(white: 0.1))
                        .frame(width: size * (style == 2 ? 0.1 : 0.13), height: size * [0.24, 0.14, 0.1][style])
                }
            }
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: size * 0.17, height: size * 0.17)
                .offset(x: size * 0.3, y: -size * 0.38)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if active {
                PulseDot(color: .cyan, active: true, size: max(5, size * 0.2))
                    .offset(x: size * 0.16, y: size * 0.16)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Modelos

struct ModelInfo {
    let id: String
    let name: String
    let icon: String
    let note: String
    let tint: Color
}

let modelInfos = [
    ModelInfo(id: "auto", name: "Automático", icon: "wand.and.stars", note: "O mais barato que dá conta", tint: .orange),
    ModelInfo(id: "haiku", name: "Haiku", icon: "hare.fill", note: "Rápido e econômico", tint: .green),
    ModelInfo(id: "sonnet", name: "Sonnet", icon: "sparkle", note: "Bom para quase tudo", tint: .blue),
    ModelInfo(id: "opus", name: "Opus", icon: "brain.head.profile", note: "Para o que é difícil", tint: .purple),
    ModelInfo(id: "fable", name: "Fable", icon: "book.closed.fill", note: "Só quando você escolher", tint: .pink),
]

func modelInfo(_ id: String) -> ModelInfo? { modelInfos.first { $0.id == id } }

/// Etiqueta do modelo que respondeu.
struct ModelChip: View {
    let model: String

    var body: some View {
        let info = modelInfo(model)
        Label(info?.name ?? model.capitalized, systemImage: info?.icon ?? "cpu")
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(info?.tint ?? .secondary)
            .background((info?.tint ?? .secondary).opacity(0.15), in: Capsule())
    }
}

/// Escolha de modelo em cartões, com o selecionado em destaque.
struct ModelCards: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 7) {
            ForEach(modelInfos, id: \.id) { m in
                let on = selection == m.id
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) { selection = m.id }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: m.icon).font(.system(size: 18, weight: .semibold)).frame(height: 22)
                        Text(m.name).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(m.note).font(.system(size: 9)).foregroundStyle(on ? .primary : .secondary).multilineTextAlignment(.center).lineLimit(2).frame(height: 24, alignment: .top)
                    }
                    .foregroundStyle(on ? m.tint : .primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(on ? m.tint.opacity(0.18) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(on ? m.tint : .clear, lineWidth: 1.5))
                    .scaleEffect(on ? 1.04 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(m.name): \(m.note)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: Estilos

/// Botão em cápsula que afunda ao clicar.
struct PillButton: ButtonStyle {
    var tint: Color = .accentColor
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(filled ? Color.white : tint)
            .background(filled ? AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(tint.opacity(0.14)), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension View {
    /// Cartão com borda na cor de quem ele representa.
    func card(_ accent: Color = .primary) -> some View {
        padding(13)
            .background(
                LinearGradient(colors: [accent.opacity(0.13), accent.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.28)))
    }

    /// Entrada com mola: uma vez só, quando aparece.
    func popIn() -> some View { modifier(PopIn()) }
}

private struct PopIn: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.94, anchor: .bottom)
            .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { shown = true } }
    }
}
