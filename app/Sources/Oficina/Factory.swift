import AppKit
import SwiftUI

// MARK: Modelos

struct AssistantSettings: Codable, Equatable {
    var name = "Faísca"
    var personality = "Curta, direta e carinhosa."
    var brain_model = "haiku"
    var brain_effort = ""
    var body_color = "#FF9E29"
    var spark_color = "#FFD60A"
    var eyes = "tall"
    var antenna = true
    var size = 1.0
}

struct MissionLog: Decodable, Equatable {
    let stage: String
    let verdict: String
    let evidence: [String]
}

struct MissionItem: Decodable, Equatable {
    let goal: String
    let stage: Int
    let status: String
    let log: [MissionLog]
}

struct AgentItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let role: String
    let model: String
    let effort: String
    let place: String
    let project: String?
    let team: String?
    let conversation: String
    let mission: MissionItem?
    let status: String?
}

struct TeamItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let conversation: String
}

struct FactoryState: Decodable, Equatable {
    var agents: [AgentItem] = []
    var teams: [TeamItem] = []
    var router: RouterStats?
}

struct RouterStats: Decodable, Equatable {
    let haiku: Int
    let sonnet: Int
    let opus: Int
    let escalations: Int
    let learned: Int
}

let effortLevels = ["low", "medium", "high", "xhigh", "max"]
private let effortNames = ["auto": "Automático", "low": "Baixo", "medium": "Médio", "high": "Alto", "xhigh": "Muito alto", "max": "Máximo"]

func colorFromHex(_ hex: String) -> Color {
    var v: UInt64 = 0
    Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
    return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

func hexFromColor(_ c: Color) -> String {
    let n = NSColor(c).usingColorSpace(.sRGB) ?? .orange
    return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
}

/// Rodapé de seção alinhado à esquerda, como nos Ajustes do Sistema.
private struct FormNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Personalizar

private let traits = [
    (name: "Carinhosa", text: "Curta, direta e carinhosa."),
    (name: "Engraçada", text: "Bem-humorada, faz piadas leves, mas resolve o que foi pedido."),
    (name: "Séria", text: "Formal, objetiva e sem brincadeiras."),
    (name: "Mentora", text: "Paciente, explica o porquê das coisas e sugere próximos passos."),
]

private let eyeStyles = [("tall", "Compridos"), ("round", "Redondos"), ("dots", "Pontinhos")]

struct PersonalizeView: View {
    @ObservedObject var core: Core
    @State private var s = AssistantSettings()

    private var style: Binding<String> {
        Binding(
            get: { traits.contains { $0.text == s.personality } ? s.personality : "" },
            set: { s.personality = $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                LivePet(settings: s, side: 96)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                TextField("Nome", text: $s.name)
            }
            Section("Aparência") {
                color("Cor do Corpo", $s.body_color)
                Picker("Olhos", selection: $s.eyes) {
                    ForEach(eyeStyles, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Antena", isOn: $s.antenna)
                color("Cor da Antena", $s.spark_color).disabled(!s.antenna)
                Slider(value: $s.size, in: 0.7...1.4) { Text("Tamanho") }
            }
            Section("Personalidade") {
                Picker("Estilo", selection: style) {
                    ForEach(traits, id: \.name) { Text($0.name).tag($0.text) }
                    Divider()
                    Text("Personalizado").tag("")
                }
                TextField("Descrição", text: $s.personality, prompt: Text("Descreva do seu jeito"), axis: .vertical)
                    .lineLimit(2...4)
                    .labelsHidden()
            }
            Section {
                Picker("Modelo", selection: $s.brain_model) {
                    ForEach(modelInfos, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Esforço", selection: $s.brain_effort) {
                    Text("Padrão").tag("")
                    ForEach(effortLevels, id: \.self) { Text(effortNames[$0] ?? $0).tag($0) }
                }
            } header: {
                Text("Cérebro")
            } footer: {
                FormNote(modelInfo(s.brain_model)?.note ?? "")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 480)
        .navigationTitle("Personalizar")
        .onAppear { s = core.settings }
        // Salva sozinho, com uma pausa para não gravar a cada letra.
        .task(id: s) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled && s != core.settings { core.saveSettings(s) }
        }
    }

    private func color(_ title: String, _ value: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(get: { colorFromHex(value.wrappedValue) }, set: { value.wrappedValue = hexFromColor($0) }), supportsOpacity: false)
    }
}

// MARK: Fábrica

private let stageNames = ["Investigar", "Propor", "Executar", "Verificar"]

private enum FactoryPick: Hashable {
    case overview
    case agent(String)
    case team(String)
}

private struct Removal: Identifiable {
    let path: String
    let title: String
    let message: String
    let action: String
    var id: String { path }
}

struct FactoryView: View {
    @ObservedObject var core: Core
    let openConversation: (String) -> Void
    @State private var state = FactoryState()
    @State private var pick: FactoryPick? = .overview
    @State private var creatingAgent = false
    @State private var creatingTeam = false
    @State private var name = ""
    @State private var role = ""
    @State private var model = "auto"
    @State private var effort = "auto"
    @State private var place = "mac"
    @State private var project = ""
    @State private var teamName = ""
    @State private var missionFor: AgentItem?
    @State private var goal = ""
    @State private var problem: String?
    @State private var removal: Removal?

    private var showProblem: Binding<Bool> {
        Binding(get: { problem != nil && !creatingAgent }, set: { if !$0 { problem = nil } })
    }

    private var showRemoval: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pick) {
                Label("Visão Geral", systemImage: "square.grid.2x2").tag(FactoryPick.overview)
                if !state.agents.isEmpty {
                    Section("Agentes") {
                        ForEach(state.agents) { sidebarRow($0).tag(FactoryPick.agent($0.id)) }
                    }
                }
                if !state.teams.isEmpty {
                    Section("Equipes") {
                        ForEach(state.teams) { Label($0.name, systemImage: "number").tag(FactoryPick.team($0.id)) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Fábrica")
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Novo Agente…", action: startAgent)
                            Button("Nova Equipe…") { creatingTeam = true }
                        } label: {
                            Label("Adicionar", systemImage: "plus")
                        }
                        .help("Adicionar agente ou equipe")
                    }
                }
        }
        .frame(minWidth: 680, minHeight: 460)
        .task {
            while !Task.isCancelled {
                await refresh()
                testPick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $creatingAgent) { agentSheet }
        .sheet(isPresented: $creatingTeam) { teamSheet }
        .sheet(item: $missionFor) { missionSheet($0) }
        .alert("Não foi possível concluir", isPresented: showProblem) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .alert(removal?.title ?? "", isPresented: showRemoval, presenting: removal) { r in
            Button(r.action, role: .destructive) { remove(r) }
            Button("Cancelar", role: .cancel) {}
        } message: { r in
            Text(r.message)
        }
    }

    private var subtitle: String {
        let working = state.agents.filter { $0.status == "trabalhando" }.count
        let count = "\(state.agents.count) \(state.agents.count == 1 ? "agente" : "agentes")"
        return working > 0 ? "\(count), \(working) trabalhando" : count
    }

    private func sidebarRow(_ a: AgentItem) -> some View {
        HStack {
            Label {
                Text(a.name).lineLimit(1)
            } icon: {
                AgentAvatar(name: a.name, size: 18)
            }
            Spacer(minLength: 0)
            statusMark(a.status)
        }
    }

    @ViewBuilder private func statusMark(_ s: String?) -> some View {
        switch s {
        case "trabalhando": ProgressView().controlSize(.mini).accessibilityLabel("Trabalhando")
        case "aguardando": Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("Aguardando você")
        case "erro": Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).accessibilityLabel("Com erro")
        default: EmptyView()
        }
    }

    @ViewBuilder private var detail: some View {
        switch pick {
        case .agent(let id):
            if let a = state.agents.first(where: { $0.id == id }) { agentPage(a) } else { overview }
        case .team(let id):
            if let t = state.teams.first(where: { $0.id == id }) { teamPage(t) } else { overview }
        default:
            overview
        }
    }

    // MARK: Visão geral

    @ViewBuilder private var overview: some View {
        if state.agents.isEmpty && state.teams.isEmpty {
            ContentUnavailableView {
                Label("Nenhum Agente", systemImage: "person.2")
            } description: {
                Text("Crie um agente aqui ou peça no chat.")
            } actions: {
                Button("Novo Agente…", action: startAgent)
            }
        } else {
            Form {
                Section {
                    LabeledContent("Agentes", value: "\(state.agents.count)")
                    LabeledContent("Trabalhando", value: "\(state.agents.filter { $0.status == "trabalhando" }.count)")
                    LabeledContent("Equipes", value: "\(state.teams.count)")
                }
                if let r = state.router { routerSection(r) }
            }
            .formStyle(.grouped)
        }
    }

    private func routerSection(_ r: RouterStats) -> some View {
        Section {
            LabeledContent("Haiku", value: "\(r.haiku)")
            LabeledContent("Sonnet", value: "\(r.sonnet)")
            LabeledContent("Opus", value: "\(r.opus)")
            LabeledContent("Subidas de Modelo", value: "\(r.escalations)")
            LabeledContent("Resultados Aprendidos", value: "\(r.learned)")
        } header: {
            Text("Modelo Automático")
        } footer: {
            FormNote("Cada tarefa vai para o modelo mais barato que dá conta. Se ele falhar, sobe um degrau e aprende.")
        }
    }

    // MARK: Agente

    private func agentPage(_ a: AgentItem) -> some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AgentAvatar(name: a.name, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.headline).lineLimit(1)
                        Text(statusName(a.status)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Nova Missão…") { missionFor = a }
                    Button("Conversar") { openConversation(a.conversation) }
                        .buttonStyle(.borderedProminent)
                }
            }
            Section {
                LabeledContent("Papel") { Text(a.role).textSelection(.enabled) }
                LabeledContent("Modelo", value: a.place == "nuvem" ? "Padrão da nuvem" : (modelInfo(a.model)?.name ?? a.model.capitalized))
                LabeledContent("Esforço", value: effortNames[a.effort] ?? a.effort)
                LabeledContent("Onde Roda", value: a.place == "nuvem" ? "Nuvem" : "Este Mac")
                if let p = a.project { LabeledContent("Projeto", value: p.components(separatedBy: "/").last ?? p) }
                Picker("Equipe", selection: Binding(
                    get: { a.team ?? "" },
                    set: { new in Task { _ = await core.factoryPost("agents/\(a.id)/team", ["team": new.isEmpty ? NSNull() : new]); await refresh() } }
                )) {
                    Text("Nenhuma").tag("")
                    ForEach(state.teams) { Text($0.name).tag($0.id) }
                }
            }
            if let m = a.mission { missionSection(m) }
            Section {} footer: {
                HStack {
                    Spacer()
                    Button("Apagar Agente…") {
                        removal = Removal(path: "agents/\(a.id)", title: "Apagar \(a.name)?", message: "O agente sai da Fábrica. Esta ação não pode ser desfeita.", action: "Apagar")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func missionSection(_ m: MissionItem) -> some View {
        Section {
            LabeledContent("Objetivo") { Text(m.goal).textSelection(.enabled) }
            ForEach(Array(stageNames.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 8) {
                    stageIcon(i, m).frame(width: 16)
                    Text(s).foregroundStyle(i > m.stage ? .secondary : .primary)
                }
                .accessibilityElement(children: .combine)
            }
            if m.log.last?.verdict == "sem-evidencia" {
                Label("Parou: a etapa não citou evidência.", systemImage: "exclamationmark.triangle.fill")
            } else if let e = m.log.last?.evidence.first {
                LabeledContent("Evidência") { Text(e).lineLimit(3).textSelection(.enabled) }
            }
        } header: {
            Text("Missão")
        } footer: {
            FormNote(missionName(m.status))
        }
    }

    @ViewBuilder private func stageIcon(_ i: Int, _ m: MissionItem) -> some View {
        if i < m.stage || (i == m.stage && m.status == "concluida") {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Concluída")
        } else if i > m.stage {
            Image(systemName: "circle").foregroundStyle(.tertiary).accessibilityLabel("Pendente")
        } else if m.status == "rodando" {
            ProgressView().controlSize(.small).accessibilityLabel("Em andamento")
        } else if m.status == "aguardando" {
            Image(systemName: "hand.raised.circle.fill").foregroundStyle(.orange).accessibilityLabel("Aguardando aprovação")
        } else {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Interrompida")
        }
    }

    // MARK: Equipe

    private func teamPage(_ team: TeamItem) -> some View {
        let crew = state.agents.filter { $0.team == team.id }
        return Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "number")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(team.name).font(.headline).lineLimit(1)
                        Text(crew.isEmpty ? "Sem agentes" : "\(crew.count) \(crew.count == 1 ? "agente" : "agentes")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Abrir Canal") { openConversation(team.conversation) }
                        .buttonStyle(.borderedProminent)
                }
            }
            Section {
                if crew.isEmpty {
                    Text("Escolha esta equipe na página de um agente.").foregroundStyle(.secondary)
                }
                ForEach(crew) { a in
                    LabeledContent {
                        Text(statusName(a.status))
                    } label: {
                        Label {
                            Text(a.name)
                        } icon: {
                            AgentAvatar(name: a.name, size: 22)
                        }
                    }
                }
            } header: {
                Text("Membros")
            } footer: {
                FormNote("Num canal, escreva @Nome para chamar um agente. Eles também chamam uns aos outros.")
            }
            Section {} footer: {
                HStack {
                    Spacer()
                    Button("Apagar Equipe…") {
                        removal = Removal(path: "teams/\(team.id)", title: "Apagar a equipe \(team.name)?", message: "Os agentes continuam na Fábrica, sem equipe.", action: "Apagar")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Folhas

    private func startAgent() {
        name = ""
        role = ""
        model = "auto"
        effort = "auto"
        place = "mac"
        project = ""
        problem = nil
        creatingAgent = true
    }

    private func sheetButtons(_ action: String, enabled: Bool, cancel: @escaping () -> Void, go: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Cancelar", action: cancel).keyboardShortcut(.cancelAction)
            Button(action, action: go).keyboardShortcut(.defaultAction).disabled(!enabled)
        }
        .padding([.horizontal, .bottom], 20)
    }

    private func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var agentSheet: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nome", text: $name, prompt: Text("Revisora"))
                    TextField("Papel", text: $role, prompt: Text("O que este agente faz"), axis: .vertical).lineLimit(2...5)
                }
                Section {
                    Picker("Modelo", selection: $model) {
                        ForEach(modelInfos, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("Esforço", selection: $effort) {
                        Text("Automático").tag("auto")
                        ForEach(effortLevels, id: \.self) { Text(effortNames[$0] ?? $0).tag($0) }
                    }
                } footer: {
                    FormNote(place == "nuvem" ? "Na nuvem, o modelo é o padrão do Claude na nuvem." : (modelInfo(model)?.note ?? ""))
                }
                Section {
                    Picker("Onde Roda", selection: $place) {
                        Text("Este Mac").tag("mac")
                        Text("Nuvem").tag("nuvem")
                    }
                    Picker("Projeto", selection: $project) {
                        Text("Nenhum").tag("")
                        ForEach(core.usage?.projects ?? [], id: \.path) { Text($0.name).tag($0.path) }
                    }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            sheetButtons("Criar Agente", enabled: filled(name) && filled(role), cancel: { creatingAgent = false }, go: createAgent)
        }
        .frame(width: 460, height: 440)
    }

    private func createAgent() {
        let body: [String: Any] = ["name": name, "role": role, "model": model, "effort": effort, "place": place, "project": project]
        Task {
            problem = await core.factoryPost("agents", body)
            if problem == nil { creatingAgent = false }
            await refresh()
        }
    }

    private var teamSheet: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Nome", text: $teamName, prompt: Text("Produto"))
            }
            .formStyle(.grouped)
            sheetButtons("Criar Equipe", enabled: filled(teamName), cancel: {
                teamName = ""
                creatingTeam = false
            }, go: {
                let n = teamName
                teamName = ""
                creatingTeam = false
                Task { problem = await core.factoryPost("teams", ["name": n, "members": []]); await refresh() }
            })
        }
        .frame(width: 380, height: 150)
    }

    private func missionSheet(_ agent: AgentItem) -> some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Objetivo", text: $goal, axis: .vertical).lineLimit(3...6)
                } header: {
                    Text("Missão para \(agent.name)")
                } footer: {
                    FormNote("Investigar, Propor, Executar (com sua aprovação) e Verificar. Cada etapa precisa citar evidência.")
                }
            }
            .formStyle(.grouped)
            sheetButtons("Iniciar", enabled: filled(goal), cancel: { missionFor = nil }, go: {
                let g = goal
                goal = ""
                missionFor = nil
                Task { problem = await core.factoryPost("agents/\(agent.id)/missions", ["goal": g]); await refresh() }
            })
        }
        .frame(width: 440, height: 260)
    }

    private func remove(_ r: Removal) {
        pick = .overview
        Task {
            await core.factoryDelete(r.path)
            await refresh()
        }
    }

    /// Só para teste visual: abre direto a página de um agente ou equipe.
    private func testPick() {
        guard pick == .overview else { return }
        if CommandLine.arguments.contains("--fabrica=agente"), let a = state.agents.first { pick = .agent(a.id) }
        if CommandLine.arguments.contains("--fabrica=equipe"), let t = state.teams.first { pick = .team(t.id) }
        if CommandLine.arguments.contains("--fabrica=novo"), !creatingAgent { startAgent() }
    }

    private func refresh() async {
        if let s = await core.loadFactory(), s != state { state = s }
    }

    private func missionName(_ s: String) -> String {
        ["rodando": "Em andamento", "aguardando": "Aguardando sua aprovação no chat", "concluida": "Concluída",
         "bloqueada": "Bloqueada", "falhou": "Falhou", "cancelada": "Cancelada"][s] ?? s
    }

    private func statusName(_ s: String?) -> String {
        ["trabalhando": "Trabalhando", "aguardando": "Aguardando você", "erro": "Com erro"][s ?? ""] ?? "Livre"
    }
}
