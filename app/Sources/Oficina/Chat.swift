import SwiftUI

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private let suggestions = [
    "O que você consegue fazer por mim?",
    "/pc Crie notas.md com ideias para um painel de cozinha",
    "/nuvem Pesquise placas ESP32 com tela touch",
]

struct ChatView: View {
    @ObservedObject var core: Core
    let close: () -> Void
    @State private var draft = ""
    @State private var target = "auto"
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @State private var toast: String?
    @State private var crew: [AgentItem] = []
    @FocusState private var focused: Bool

    private var tint: Color { colorFromHex(core.settings.body_color) }
    private var thread: [TaskItem] { core.thread }
    private var conversation: ConversationItem? { core.conversations.first { $0.id == core.current } }

    var body: some View {
        HStack(spacing: 0) {
            ConversationList(core: core) { focused = true }
                .frame(width: 216)
            Rectangle().fill(Bench.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                if thread.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messages
                }
                composer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 580)
        .background(Bench.canvas)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Bench.canvas, in: Capsule())
                    .overlay(Capsule().strokeBorder(Bench.line))
                    .padding(.top, 54)
                    .transition(.opacity)
            }
        }
        .onAppear {
            focused = true
            core.loadConversations()
        }
        .onExitCommand(perform: close)
        .task(id: conversation?.id) { await loadCrew() }
        .alert("Renomear conversa", isPresented: $renaming) {
            TextField("Título", text: $newTitle)
            Button("Salvar") { if let id = core.current { core.renameConversation(id, newTitle) } }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog("Apagar esta conversa?", isPresented: $confirmDelete) {
            Button("Apagar", role: .destructive) { if let id = core.current { core.deleteConversation(id) } }
        } message: {
            Text("Some da Oficina. A sessão continua no Claude Code.")
        }
    }

    // MARK: Cabeçalho

    private var isCrewChat: Bool { conversation?.team != nil || conversation?.agent != nil }
    private var working: Set<String> { Set(thread.filter(\.isActive).compactMap(\.agent)) }

    /// Só canais e agentes precisam saber quem participa.
    private func loadCrew() async {
        guard let c = conversation, isCrewChat, let s = await core.loadFactory() else {
            crew = []
            return
        }
        crew = s.agents.filter { c.team != nil ? $0.team == c.team : $0.id == c.agent }
    }

    /// Título sem o "# " dos canais: o ícone já diz que é canal.
    private var plainTitle: String? { conversation?.title.replacingOccurrences(of: "# ", with: "") }

    private var crewLine: String {
        crew.map { working.contains($0.id) ? loc("%@ (trabalhando)", $0.name) : $0.name }.joined(separator: ", ")
    }

    private var header: some View {
        HStack(spacing: 10) {
            if conversation?.team != nil {
                Text(verbatim: "#").font(Bench.display(26)).foregroundStyle(Bench.faint).frame(width: 28, height: 28)
            } else if let c = conversation, c.agent != nil {
                AgentAvatar(name: c.title, size: 28)
            } else {
                FaiscaAvatar(size: 28, mood: headerMood)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(plainTitle ?? loc("Nova Conversa")).font(Bench.display(20)).tracking(-0.4).lineLimit(1)
                Text(conversation?.team != nil && !crew.isEmpty ? crewLine : conversation?.agent != nil ? (crew.first?.role ?? subtitle) : subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: core.newConversation) {
                Image(systemName: "square.and.pencil").font(.title3)
            }
            .buttonStyle(QuietStyle(tint: tint))
            .keyboardShortcut("n")
            .help("Nova conversa (⌘N)")
            Menu {
                if let c = conversation {
                    Button("Renomear…", systemImage: "pencil") {
                        newTitle = c.title
                        renaming = true
                    }
                    if c.session != nil {
                        Button("Continuar no Claude Code", systemImage: "terminal") { copyResume(c) }
                    }
                    Divider()
                    Button("Apagar conversa", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    Divider()
                }
                Button("Fechar", systemImage: "xmark", action: close)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Mais opções")
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var headerMood: Mood {
        if thread.contains(where: { $0.status == "awaiting_approval" }) { return .waiting }
        return thread.contains(where: \.isActive) ? .thinking : .idle
    }

    private var subtitle: String {
        if !core.connected { return loc("Reconectando ao core…") }
        if let t = thread.last(where: \.isActive) { return runningLabel(t) }
        if let s = core.usage?.limits.first(where: { $0.kind == "session" }) {
            return loc("%@ · sessão do Claude em %@%%", core.settings.name, "\(Int(s.percent.rounded()))")
        }
        return core.settings.name
    }

    /// A conversa é uma sessão do Claude Code: este comando a retoma lá.
    private func copyResume(_ c: ConversationItem) {
        guard let session = c.session else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Oficina/brain").path
        let command = "cd \"\(dir)\" && claude --resume \(session)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        withAnimation { toast = loc("Comando copiado: cole no Terminal") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { toast = nil } }
    }

    // MARK: Mensagens

    private var crewEmpty: some View {
        VStack(spacing: 10) {
            if conversation?.team == nil, let c = conversation { AgentAvatar(name: c.title, size: 52) }
            Text(conversation?.team != nil ? loc("Canal Vazio") : loc("Fale com %@", plainTitle ?? loc("o agente")))
                .font(Bench.display(26)).tracking(-0.6)
            Text(conversation?.team != nil
                 ? (crew.isEmpty ? loc("Coloque agentes nesta equipe pela Fábrica.") : loc("Chame alguém com @Nome. Se ninguém for chamado, %@ responde.", crew[0].name))
                 : loc("Escreva o que precisa. O modelo é escolhido pelo tamanho da tarefa."))
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 50)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if isCrewChat { crewEmpty } else { assistantEmpty }
    }

    private var assistantEmpty: some View {
        VStack(spacing: 10) {
            FaiscaAvatar(size: 60, mood: .idle)
            Text("Oi! Sou \(core.settings.name).").font(Bench.display(30)).tracking(-0.8)
            Text("Converso, abro agentes na nuvem e trabalho neste Mac quando você deixar.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 50)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button(loc(s)) {
                        draft = loc(s)
                        focused = true
                    }
                    .buttonStyle(QuietStyle(tint: tint))
                    .lineLimit(1)
                }
            }
            .padding(.top, 14)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(thread) { task in
                        Turn(task: task, core: core).id(task.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
            .onChange(of: thread.last?.output) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: thread.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: core.current) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    // MARK: Entrada

    private var running: TaskItem? { thread.last(where: \.isActive) }

    private var composer: some View {
        VStack(spacing: 8) {
            if let problem = core.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if conversation?.team != nil && !crew.isEmpty { mentionChips }
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

                TextField("Mensagem para \(isCrewChat ? (plainTitle ?? "") : core.settings.name)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 3)

                if let running {
                    Button { core.act(running.id, "cancel") } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .help("Parar")
                    .accessibilityLabel("Parar resposta")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? tint : Bench.faint)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Enviar (Return)")
                }
            }
            .padding(.top, 2)
            Rectangle().fill(Bench.line).frame(height: 1)
            Text("Return envia · ⌥Return quebra linha · /nuvem e /pc escolhem o destino")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private var mentionChips: some View {
        HStack(spacing: 6) {
            ForEach(crew) { a in
                Button {
                    draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + "@\(a.name) "
                    focused = true
                } label: {
                    Text("@\(a.name)")
                }
                .buttonStyle(QuietStyle(tint: tint))
                .accessibilityLabel("Chamar \(a.name)")
            }
            Spacer()
        }
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
        case "cloud": return loc("nuvem")
        case "machine": return loc("este Mac")
        default: return loc("automático")
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        core.send(text, target: target)
        draft = ""
    }
}

/// Barra lateral: conversas agrupadas por data, como nos apps de chat.
private struct ConversationList: View {
    @ObservedObject var core: Core
    let picked: () -> Void

    private var groups: [(String, [ConversationItem])] {
        let cal = Calendar.current
        let now = Date()
        var out: [String: [ConversationItem]] = [:]
        for c in core.conversations where c.agent == nil && c.team == nil {
            let d = Date(timeIntervalSince1970: TimeInterval(c.updatedAt) / 1000)
            let key: String
            if cal.isDateInToday(d) { key = "Hoje" }
            else if cal.isDateInYesterday(d) { key = "Ontem" }
            else if now.timeIntervalSince(d) < 7 * 86_400 { key = "Últimos 7 dias" }
            else { key = "Mais antigas" }
            out[key, default: []].append(c)
        }
        return ["Hoje", "Ontem", "Últimos 7 dias", "Mais antigas"].compactMap { k in out[k].map { (k, $0) } }
    }

    private var tint: Color { colorFromHex(core.settings.body_color) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                section("Equipes", core.conversations.filter { $0.team != nil })
                section("Agentes", core.conversations.filter { $0.agent != nil })
                ForEach(groups, id: \.0) { title, items in section(title, items) }
            }
            .padding(.horizontal, 10)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .overlay {
            if core.conversations.isEmpty {
                Text("Suas conversas aparecem aqui.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [ConversationItem]) -> some View {
        if !items.isEmpty {
            Text(loc(title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Bench.faint)
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 2)
            ForEach(items) { row($0) }
        }
    }

    private func row(_ c: ConversationItem) -> some View {
        let on = core.current == c.id
        return HoverRow {
            if c.team != nil {
                Text(verbatim: "#").font(.system(size: 14, weight: .semibold)).foregroundStyle(on ? tint : Bench.faint).frame(width: 18)
            } else if c.agent != nil {
                AgentAvatar(name: c.title, size: 18)
            }
            Text(c.title.replacingOccurrences(of: "# ", with: ""))
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .lineLimit(1)
        } trailing: {
            EmptyView()
        }
        .onTapGesture {
            core.select(c.id)
            picked()
        }
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("Apagar", role: .destructive) { core.deleteConversation(c.id) }
        }
    }
}

/// Texto da resposta com Markdown e blocos de código (com botão de copiar).
struct MessageBody: View {
    let text: String

    private var parts: [(code: Bool, lang: String, body: String)] {
        var out: [(Bool, String, String)] = []
        let chunks = text.components(separatedBy: "```")
        for (i, chunk) in chunks.enumerated() {
            if i % 2 == 1 {
                var lines = chunk.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                if !lines.isEmpty { lines.removeFirst() }
                out.append((true, lang, lines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            } else if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append((false, "", chunk.trimmingCharacters(in: .newlines)))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                if p.code {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(p.lang.isEmpty ? loc("código") : p.lang).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p.body, forType: .string)
                            } label: {
                                Label("Copiar", systemImage: "doc.on.doc").font(.caption2)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(p.body)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 8)
                        }
                    }
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(inline(p.body)).textSelection(.enabled)
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

private func runningLabel(_ t: TaskItem) -> String {
    switch (t.status, t.target) {
    case ("queued", _): return loc("Na fila…")
    case (_, "cloud"): return loc("Abrindo agente na nuvem…")
    case (_, "request"): return loc("Abrindo issue no GitHub…")
    case (_, "agent"): return loc("Agente trabalhando…")
    case (_, "machine"): return loc("Trabalhando em %@…", t.machine ?? loc("uma máquina"))
    default: return loc("Pensando…")
    }
}

/// Uma ida e volta: o pedido e tudo o que aconteceu com ele.
private struct Turn: View {
    let task: TaskItem
    @ObservedObject var core: Core

    private var agentName: String? { task.agent.flatMap { core.agentNames[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !task.text.isEmpty { HStack {
                Spacer(minLength: 48)
                Text(task.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
            } }
            HStack(alignment: .top, spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 8) {
                    if agentName == nil, let model = task.model, !task.isActive { modelText(model) }
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

    /// O bichinho balança enquanto trabalha; parado, não custa nada.
    @ViewBuilder private var avatar: some View {
        if task.isActive {
            Bob(active: true, content: portrait).frame(width: 24, height: 24)
        } else {
            portrait
        }
    }

    @ViewBuilder private var portrait: some View {
        if let agentName {
            AgentAvatar(name: agentName, size: 24)
        } else {
            FaiscaAvatar(size: 22, mood: avatarMood)
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
        if let name = agentName {
            HStack(spacing: 6) {
                Text(name).font(.headline)
                if let model = task.model { modelText(model) }
                if task.text.isEmpty { Text("chamado no canal").font(.caption).foregroundStyle(.secondary) }
            }
        } else if task.target != "auto" && task.target != "chat" && task.target != "agent" && task.target != "new_agent" {
            Label(task.target == "cloud" ? loc("Agente na nuvem") : task.target == "request" ? loc("Pedido de melhoria") : loc("Agente em %@", task.machine ?? loc("este Mac")),
                  systemImage: task.target == "cloud" ? "cloud" : task.target == "request" ? "sparkles.rectangle.stack" : "desktopcomputer")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        if !task.output.isEmpty {
            MessageBody(text: task.output)
        }
        switch task.status {
        case "queued", "running":
            HStack(spacing: 8) {
                Text(runningLabel(task)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { core.act(task.id, "cancel") }
                    .buttonStyle(QuietStyle(tint: .red))
            }
        case "awaiting_approval":
            ApprovalCard(task: task, core: core)
        case "failed":
            Label {
                Text(task.error ?? loc("Não deu certo.")).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .font(.callout)
        case "cancelled":
            Label("Cancelada", systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
        if let raw = task.url, let url = URL(string: raw), url.scheme == "https" {
            Link(destination: url) {
                Label(loc(raw.contains("github.com") ? "Abrir issue no GitHub" : "Abrir sessão na nuvem"), systemImage: "arrow.up.right.square")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private func modelText(_ model: String) -> some View {
        Text(loc(modelInfo(model)?.name ?? model.capitalized)).font(.caption).foregroundStyle(.secondary)
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
        let request = task.target == "request"
        let newAgent = task.target == "new_agent"
        let mission = task.target == "agent"
        VStack(alignment: .leading, spacing: 8) {
            Text(request ? loc("Quero abrir um pedido de melhoria (%@):", loc(task.kind ?? "funcionalidade"))
                  : loc(newAgent ? "Quero criar este agente (nome | papel | modelo | esforço | lugar):"
                  : mission ? "Esta etapa altera arquivos. Posso seguir?" : "Quero usar seu computador para isto:"))
                .font(.headline)
            Text(task.prompt ?? task.text)
                .font(.callout)
                .textSelection(.enabled)
            Text(loc(request
                 ? "Vira uma issue pública no GitHub da Oficina, e um agente do Claude implementa e abre um pull request."
                 : newAgent ? "Ele aparece na Fábrica e na barra de conversas."
                 : mission ? "O agente edita arquivos do projeto dele, sem comandos livres no terminal."
                 : "Posso ler e editar arquivos da pasta de trabalho, sem comandos livres no terminal."))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(loc(request ? "Abrir issue" : newAgent ? "Criar agente" : mission ? "Aprovar" : "Executar neste Mac")) { core.act(task.id, "approve") }
                    .buttonStyle(SolidStyle())
                Button("Recusar") { core.act(task.id, "cancel") }
                    .buttonStyle(QuietStyle(tint: colorFromHex(core.settings.body_color)))
                    .padding(.leading, 6)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Bench.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Bench.line).frame(height: 1) }
    }
}

/// A Faísca em miniatura, com o mesmo desenho do pet.
struct FaiscaAvatar: View {
    /// Cores escolhidas em Personalizar.
    nonisolated(unsafe) static var bodyColor = Color(red: 1, green: 0.62, blue: 0.16)
    nonisolated(unsafe) static var sparkColor = Color.yellow

    var size: CGFloat
    var mood: Mood
    var body_: Color?
    var spark_: Color?

    init(size: CGFloat, mood: Mood, body: Color? = nil, spark: Color? = nil) {
        self.size = size
        self.mood = mood
        body_ = body
        spark_ = spark
    }

    var body: some View {
        let body: Color = mood == .sad ? Color(red: 0.62, green: 0.56, blue: 0.62) : (body_ ?? Self.bodyColor)
        let spark: Color = mood == .thinking ? .cyan : mood == .waiting ? .yellow : mood == .sad ? .red : (spark_ ?? Self.sparkColor)
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
