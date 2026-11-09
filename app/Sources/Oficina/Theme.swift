import AppKit
import SwiftUI

// Peças compartilhadas das telas. A aparência vem do próprio macOS; aqui ficam
// só a prévia do pet, o monograma dos agentes e os nomes dos modelos.

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

/// Monograma do agente, como o de um contato sem foto.
struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Text(name.prefix(1).uppercased())
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(nsColor: .systemGray), in: Circle())
            .accessibilityHidden(true)
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
