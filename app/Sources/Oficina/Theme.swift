import AppKit
import SwiftUI

// Peças compartilhadas das telas: a prévia do pet, os agentes, os nomes dos
// modelos e a linguagem visual da Bancada.

/// View que hospeda camadas: o AppKit não toca nelas.
class LayerHost: NSView {
    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}

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

private let agentHues = ["#FF7A59", "#FF5C8A", "#B56CFF", "#5B8CFF", "#22B8CF", "#20C997", "#94D82D", "#FCC419"]

private func stableHash(_ s: String) -> Int {
    Int(s.lowercased().utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } >> 3)
}

/// Agente da família da Faísca: a cor e o olhar vêm do nome.
struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let hash = stableHash(name)
        let style = hash % 3
        ZStack {
            Circle().fill(colorFromHex(agentHues[hash % agentHues.count]))
            HStack(spacing: size * 0.15) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule()
                        .fill(Color(white: 0.1))
                        .frame(width: size * (style == 2 ? 0.1 : 0.13), height: size * [0.24, 0.14, 0.1][style])
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: Bancada: a linguagem visual das telas

/// Uma superfície só, sem caixas: hierarquia por tipografia e fio fino.
enum Bench {
    static let canvas = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.07, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    })
    static let line = Color.primary.opacity(0.1)
    /// O que flutua sobre a superfície, como listas suspensas.
    static let raised = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 1, alpha: 1)
    })
    static let faint = Color.primary.opacity(0.35)
    static let solidText = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.07, alpha: 1) : NSColor(white: 1, alpha: 1)
    })

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
}

/// A única coisa preenchida na tela: a ação principal.
struct SolidStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Bench.solidText)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Color.primary.opacity(!enabled ? 0.25 : configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

/// Ação em texto: acende na cor da Faísca quando o mouse passa.
struct QuietStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View { QuietLabel(configuration: configuration, tint: tint) }

    private struct QuietLabel: View {
        let configuration: Configuration
        let tint: Color
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? tint : Color.secondary)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// Escolha entre palavras: a escolhida ganha um traço na cor da Faísca.
struct WordPicker: View {
    let options: [(id: String, title: String)]
    @Binding var selection: String
    var tint: Color

    var body: some View {
        HStack(spacing: 16) {
            ForEach(options, id: \.id) { o in
                let on = selection == o.id
                Button { selection = o.id } label: {
                    VStack(spacing: 4) {
                        Text(loc(o.title))
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.primary : Bench.faint)
                            .fixedSize()
                        Rectangle().fill(on ? tint : .clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}

/// Campo sem caixa: só o texto e um fio embaixo.
struct HairField: View {
    let prompt: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 1...1

    var body: some View {
        VStack(spacing: 6) {
            TextField("", text: $text, prompt: Text(loc(prompt)).foregroundStyle(Bench.faint), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(lines)
                .accessibilityLabel(loc(prompt))
            Rectangle().fill(Bench.line).frame(height: 1)
        }
    }
}

/// Lista suspensa da Bancada: a palavra escolhida abre as outras.
struct WordDropdown: View {
    let options: [(id: String, title: String)]
    @Binding var selection: String
    var tint: Color
    // Só para teste visual: abre sem precisar de clique.
    @State private var open = CommandLine.arguments.contains("--dropdown-aberto")

    private var current: String { loc(options.first { $0.id == selection }?.title ?? selection) }

    var body: some View {
        Button { open.toggle() } label: {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Text(current).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Bench.faint)
                }
                Rectangle().fill(tint).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(current)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options, id: \.id) { o in
                        HoverRow {
                            Circle().fill(o.id == selection ? tint : .clear).frame(width: 6, height: 6)
                            Text(loc(o.title)).font(.system(size: 13, weight: o.id == selection ? .semibold : .regular)).lineLimit(1)
                        } trailing: {
                            EmptyView()
                        }
                        .onTapGesture {
                            selection = o.id
                            open = false
                        }
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(6)
            }
            .frame(width: 230, height: min(CGFloat(options.count) * 30 + 12, 250))
            .background(Bench.raised.padding(-40))
        }
    }
}

/// Linha com realce; o controle da direita só aparece no hover.
struct HoverRow<Content: View, Trailing: View>: View {
    var keepTrailing = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let trailing: () -> Trailing
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 4)
            trailing().opacity(hover || keepTrailing ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 30)
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Marca redonda: a seleção da Bancada.
struct BenchCheck: View {
    let on: Bool
    var tint: Color
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                Circle().strokeBorder(on ? tint : Bench.faint, lineWidth: 1.5)
                if on {
                    Circle().fill(tint)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Bench.solidText)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Chave da Bancada.
struct BenchSwitch: ToggleStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? tint : Bench.line)
                .frame(width: 30, height: 17)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? Bench.solidText : Bench.faint).frame(width: 13, height: 13).padding(2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? loc("Ligado") : loc("Desligado"))
    }
}

/// Nível no mesmo desenho da linha de produção: fio, traço e ponto.
struct LevelLine: View {
    let part: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width * min(max(part, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(Bench.line).frame(height: 2)
                Rectangle().fill(tint).frame(width: x, height: 2)
                Circle().fill(tint).frame(width: 8, height: 8).offset(x: max(0, x - 4))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// Balanço contínuo feito pelo Core Animation: o SwiftUI não recalcula nada.
struct Bob<C: View>: NSViewRepresentable {
    var active: Bool
    let content: C

    func makeNSView(context: Context) -> NSHostingView<C> {
        let v = NSHostingView(rootView: content)
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ v: NSHostingView<C>, context: Context) {
        v.rootView = content
        guard let layer = v.layer else { return }
        if active, layer.animation(forKey: "bob") == nil {
            let a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = 0
            a.toValue = 4
            a.duration = 0.34
            a.autoreverses = true
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: "bob")
        } else if !active {
            layer.removeAnimation(forKey: "bob")
        }
    }
}

struct ModelInfo {
    let id: String
    let name: String
    let note: String
}

let modelInfos = [
    ModelInfo(id: "auto", name: "Automático", note: "O mais barato que dá conta."),
    ModelInfo(id: "haiku", name: "Haiku", note: "Rápido e econômico."),
    ModelInfo(id: "sonnet", name: "Sonnet", note: "Bom para quase tudo."),
    ModelInfo(id: "opus", name: "Opus", note: "Para o que é difícil."),
    ModelInfo(id: "fable", name: "Fable", note: "Só quando você escolher."),
]

func modelInfo(_ id: String) -> ModelInfo? { modelInfos.first { $0.id == id } }
