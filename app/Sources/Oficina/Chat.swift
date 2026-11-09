import SwiftUI

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private let suggestions: [(icon: String, text: String)] = [
    ("sparkles", "O que você consegue fazer por mim?"),
    ("desktopcomputer", "/pc Crie notas.md com ideias para um painel de cozinha"),
    ("cloud", "/nuvem Pesquise placas ESP32 com tela touch para um painel de cozinha"),
]

struct ChatView: View {
    @ObservedObject var core: Core
    let close: () -> Void
    @State private var draft = ""
    @State private var target = "auto"
    @AppStorage("chatClearedAt") private var clearedAt: Double = 0
    @FocusState private var focused: Bool

    private var visible: [TaskItem] {
        core.tasks.filter { Double($0.createdAt) > clearedAt }.suffix(60)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if visible.isEmpty { emptyState } else { messages }
            composer
        }
        .frame(width: 420, height: 580)
        .background(.regularMaterial)
        .onAppear { focused = true }
        .onExitCommand(perform: close)
    }

    // MARK: Cabeçalho

    private var header: some View {
        HStack(spacing: 10) {
            FaiscaAvatar(size: 30, mood: headerMood)
            VStack(alignment: .leading, spacing: 1) {
                Text("Faísca").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Nova conversa", systemImage: "square.and.pencil", action: newConversation)
                    .keyboardShortcut("n")
                Divider()
                Button("Fechar", systemImage: "xmark", action: close)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Mais opções")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var headerMood: Mood {
        if visible.contains(where: { $0.status == "awaiting_approval" }) { return .waiting }
        return visible.contains(where: \.isActive) ? .thinking : .idle
    }

    private var subtitle: String {
        if !core.connected { return "Reconectando ao core…" }
        if let t = visible.last(where: \.isActive) { return runningLabel(t) }
        if let s = core.usage?.limits.first(where: { $0.kind == "session" }) {
            return "Pronta · sessão do Claude em \(Int(s.percent.rounded()))%"
        }
        return "Pronta"
    }

    // MARK: Mensagens

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            FaiscaAvatar(size: 64, mood: .idle)
            Text("Oi! Sou a Faísca.").font(.title3.weight(.semibold))
            Text("Converso, abro agentes na nuvem e trabalho neste Mac quando você deixar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            VStack(spacing: 6) {
                ForEach(suggestions, id: \.text) { s in
                    Button {
                        draft = s.text
                        focused = true
                    } label: {
                        Label(s.text, systemImage: s.icon)
                            .font(.callout)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(visible) { task in
                        Turn(task: task, core: core).id(task.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .onChange(of: visible.last?.output) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: visible.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    // MARK: Entrada

    private var composer: some View {
        VStack(spacing: 8) {
            if let problem = core.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Picker("Onde executar", selection: $target) {
                        Label("Automático", systemImage: "sparkles").tag("auto")
                        Label("Nuvem", systemImage: "cloud").tag("cloud")
                        Label("Este Mac", systemImage: "desktopcomputer").tag("machine")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: targetIcon).frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Onde executar: \(targetName)")
                .accessibilityLabel("Onde executar: \(targetName)")

                TextField("Pedir alguma coisa…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 3)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Enviar (Return)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            Text("Return envia · ⌥Return quebra linha · /nuvem e /pc escolhem o destino")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && core.connected
    }

    private var targetIcon: String {
        switch target {
        case "cloud": return "cloud"
        case "machine": return "desktopcomputer"
        default: return "sparkles"
        }
    }

    private var targetName: String {
        switch target {
        case "cloud": return "nuvem"
        case "machine": return "este Mac"
        default: return "automático"
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        core.send(text, target: target)
        draft = ""
    }

    private func newConversation() {
        clearedAt = Date().timeIntervalSince1970 * 1000
        core.resetBrain()
        focused = true
    }
}

private func runningLabel(_ t: TaskItem) -> String {
    switch (t.status, t.target) {
    case ("queued", _): return "Na fila…"
    case (_, "cloud"): return "Abrindo agente na nuvem…"
    case (_, "machine"): return "Trabalhando em \(t.machine ?? "uma máquina")…"
    default: return "Pensando…"
    }
}

/// Uma ida e volta: o pedido e tudo o que aconteceu com ele.
private struct Turn: View {
    let task: TaskItem
    @ObservedObject var core: Core

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 48)
                Text(task.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            HStack(alignment: .top, spacing: 8) {
                FaiscaAvatar(size: 22, mood: avatarMood)
                VStack(alignment: .leading, spacing: 8) {
                    reply
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu {
            Button("Copiar pedido") { copy(task.text) }
            if !task.output.isEmpty { Button("Copiar resposta") { copy(task.output) } }
            if task.isActive { Button("Cancelar", role: .destructive) { core.act(task.id, "cancel") } }
        }
    }

    private var avatarMood: Mood {
        switch task.status {
        case "failed": return .sad
        case "awaiting_approval": return .waiting
        case "queued", "running": return .thinking
        default: return .idle
        }
    }

    @ViewBuilder private var reply: some View {
        if task.target != "auto" && task.target != "chat" {
            Label(task.target == "cloud" ? "Agente na nuvem" : "Agente em \(task.machine ?? "este Mac")",
                  systemImage: task.target == "cloud" ? "cloud" : "desktopcomputer")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        if !task.output.isEmpty {
            Text(markdown(task.output)).textSelection(.enabled)
        }
        switch task.status {
        case "queued", "running":
            HStack(spacing: 8) {
                if task.output.isEmpty { TypingDots() }
                Text(runningLabel(task)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { core.act(task.id, "cancel") }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
        case "awaiting_approval":
            ApprovalCard(task: task, core: core)
        case "failed":
            Label {
                Text(task.error ?? "Não deu certo.").textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        case "cancelled":
            Label("Cancelada", systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
        if let raw = task.url, let url = URL(string: raw), url.scheme == "https" {
            Link(destination: url) {
                Label("Abrir sessão na nuvem", systemImage: "arrow.up.right.square")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct ApprovalCard: View {
    let task: TaskItem
    @ObservedObject var core: Core

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Quero usar seu computador para isto:", systemImage: "hand.raised.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.yellow)
            Text(task.prompt ?? task.text)
                .font(.callout)
                .textSelection(.enabled)
            Text("Posso ler e editar arquivos da pasta de trabalho, sem comandos livres no terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Executar neste Mac") { core.act(task.id, "approve") }
                    .buttonStyle(.borderedProminent)
                Button("Recusar") { core.act(task.id, "cancel") }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.yellow.opacity(0.35)))
    }
}

private struct TypingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 5, height: 5)
                        .opacity(i == step ? 1 : 0.35)
                }
            }
        }
        .accessibilityLabel("Trabalhando")
    }
}

/// A Faísca em miniatura, com o mesmo desenho do pet.
struct FaiscaAvatar: View {
    var size: CGFloat
    var mood: Mood

    var body: some View {
        let body: Color = mood == .sad ? Color(red: 0.62, green: 0.56, blue: 0.62) : Color(red: 1, green: 0.62, blue: 0.16)
        let spark: Color = mood == .thinking ? .cyan : mood == .waiting ? .yellow : mood == .sad ? .red : .yellow
        ZStack {
            Circle().fill(body)
            HStack(spacing: size * 0.14) {
                ForEach(0..<2) { _ in
                    Capsule()
                        .fill(Color(white: 0.1))
                        .frame(width: size * 0.12, height: mood == .sleeping ? size * 0.04 : size * 0.2)
                }
            }
            .offset(y: mood == .sad ? size * 0.06 : 0)
            Circle()
                .fill(spark)
                .frame(width: size * 0.22, height: size * 0.22)
                .shadow(color: spark, radius: size * 0.08)
                .offset(x: size * 0.28, y: -size * 0.4)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
