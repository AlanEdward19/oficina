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

// MARK: Personalizar

private let traits = [
    (name: "Carinhosa", text: "Curta, direta e carinhosa."),
    (name: "Engraçada", text: "Bem-humorada, faz piadas leves, mas resolve o que foi pedido."),
    (name: "Séria", text: "Formal, objetiva e sem brincadeiras."),
    (name: "Mentora", text: "Paciente, explica o porquê das coisas e sugere próximos passos."),
]

private let eyeStyles = [("tall", "Compridos"), ("round", "Redondos"), ("dots", "Pontinhos")]
private let swatches = ["#FF9E29", "#FF5C7A", "#B56CFF", "#4D8DFF", "#22C3A6", "#7ED957", "#FFD60A", "#E9E9EF"]
private let modelWords = modelInfos.map { (id: $0.id, title: $0.name) }

private func sectionTitle(_ t: String) -> some View {
    Text(loc(t)).font(.system(size: 13, weight: .semibold))
}

struct PersonalizeView: View {
    @ObservedObject var core: Core
    @State private var s = AssistantSettings()

    private var tint: Color { colorFromHex(s.body_color) }

    var body: some View {
        HStack(spacing: 0) {
            stage.frame(width: 340)
            Rectangle().fill(Bench.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    looks
                    voice
                    brain
                }
                .padding(.horizontal, 40)
                .padding(.top, 48)
                .padding(.bottom, 40)
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .background(Bench.canvas)
        .ignoresSafeArea()
        .onAppear { s = core.settings }
        // Salva sozinho, com uma pausa para não gravar a cada letra.
        .task(id: s) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled && s != core.settings { core.saveSettings(s) }
        }
    }

    /// A Faísca em cena, em cima do chão, com o nome dela.
    private var stage: some View {
        VStack(spacing: 0) {
            Spacer()
            LivePet(settings: s, side: 230).frame(width: 230, height: 230).accessibilityHidden(true)
            Rectangle().fill(Bench.line).frame(height: 1).padding(.horizontal, 36)
            TextField("", text: $s.name, prompt: Text(loc("Nome")).foregroundStyle(Bench.faint))
                .textFieldStyle(.plain)
                .font(Bench.display(40))
                .tracking(-1)
                .multilineTextAlignment(.center)
                .accessibilityLabel(loc("Nome"))
                .padding(.horizontal, 24)
                .padding(.top, 22)
            Slider(value: $s.size, in: 0.7...1.4) { Text(loc("Tamanho")) }
                .labelsHidden()
                .tint(tint)
                .frame(width: 150)
                .padding(.top, 14)
            Spacer()
        }
    }

    private var looks: some View {
        VStack(alignment: .leading, spacing: 18) {
            colorRow("Corpo", $s.body_color)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                colorRow("Antena", $s.spark_color).opacity(s.antenna ? 1 : 0.35).disabled(!s.antenna)
                Spacer(minLength: 8)
                Button(loc(s.antenna ? "Tirar" : "Pôr de volta")) { s.antenna.toggle() }
                    .buttonStyle(QuietStyle(tint: tint))
            }
            HStack(spacing: 22) {
                sectionTitle("Olhos").frame(width: 62, alignment: .leading)
                ForEach(eyeStyles, id: \.0) { eye($0.0, $0.1) }
            }
        }
    }

    private func colorRow(_ title: String, _ value: Binding<String>) -> some View {
        HStack(spacing: 10) {
            sectionTitle(title).frame(width: 62, alignment: .leading)
            ForEach(swatches, id: \.self) { hex in
                let on = value.wrappedValue.caseInsensitiveCompare(hex) == .orderedSame
                Button { value.wrappedValue = hex } label: {
                    Circle()
                        .fill(colorFromHex(hex))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(Circle().strokeBorder(on ? Color.primary : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(loc(title)) \(hex)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            ColorPicker(loc(title), selection: Binding(get: { colorFromHex(value.wrappedValue) }, set: { value.wrappedValue = hexFromColor($0) }), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func eye(_ id: String, _ title: String) -> some View {
        let on = s.eyes == id
        return Button { s.eyes = id } label: {
            HStack(spacing: 7) {
                HStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(on ? Color.primary : Bench.faint).frame(width: 4, height: id == "tall" ? 13 : id == "round" ? 7 : 4)
                    }
                }
                .frame(width: 18, height: 16)
                Text(loc(title))
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.primary : Bench.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Frase escolhida na lista não se repete no campo livre.
    private var ownVoice: Binding<String> {
        Binding(
            get: { traits.contains { $0.text == s.personality || loc($0.text) == s.personality } ? "" : s.personality },
            set: { s.personality = $0 }
        )
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Jeito de falar")
            ForEach(traits, id: \.name) { t in
                let on = s.personality == t.text || s.personality == loc(t.text)
                Button { s.personality = loc(t.text) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(on ? tint : .clear).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(loc(t.text))
                            .font(.system(size: 14))
                            .foregroundStyle(on ? Color.primary : Bench.faint)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            HairField(prompt: "Ou descreva do seu jeito", text: ownVoice, lines: 1...3).padding(.top, 4)
        }
    }

    private var brain: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Cérebro")
            WordPicker(options: modelWords, selection: $s.brain_model, tint: tint)
            WordPicker(options: [("", "Padrão")] + effortLevels.map { ($0, effortNames[$0] ?? $0) }, selection: $s.brain_effort, tint: tint)
            Text(loc(modelInfo(s.brain_model)?.note ?? "")).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

// MARK: Fábrica

private let stageNames = ["Investigar", "Propor", "Executar", "Verificar"]

/// A linha de produção: o agente fica em cima da etapa em que está.
private struct ProductionLine: View {
    let agent: AgentItem
    let tint: Color

    private let creature: CGFloat = 32
    private let lineY: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let m = agent.mission
            let stage = min(m?.stage ?? 0, 3)
            let inset: CGFloat = 26
            let step = (geo.size.width - inset * 2) / 3
            let x = { (i: Int) in inset + CGFloat(i) * step }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Bench.line).frame(width: step * 3, height: 2).offset(x: inset, y: lineY - 1)
                if m != nil, stage > 0 {
                    Rectangle().fill(tint).frame(width: CGFloat(stage) * step, height: 2).offset(x: inset, y: lineY - 1)
                }
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(m != nil && i <= stage ? tint : Bench.canvas)
                        .overlay(Circle().strokeBorder(m != nil && i <= stage ? tint : Bench.faint, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .position(x: x(i), y: lineY)
                    if m != nil {
                        Text(loc(stageNames[i]))
                            .font(.system(size: 11, weight: i == stage ? .semibold : .regular))
                            .foregroundStyle(i == stage ? Color.primary : Bench.faint)
                            .fixedSize()
                            .position(x: x(i), y: lineY + 18)
                    }
                }
                Bob(active: agent.status == "trabalhando", content: AgentAvatar(name: agent.name, size: creature))
                    .frame(width: creature, height: creature)
                    .position(x: x(stage), y: lineY - creature / 2 - 5)
                    .animation(.easeInOut(duration: 0.5), value: stage)
            }
        }
        .frame(height: 76)
        .accessibilityElement()
        .accessibilityLabel(agent.mission.map { loc(stageNames[min($0.stage, 3)]) } ?? loc("Sem missão"))
    }
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

    private var tint: Color { colorFromHex(core.settings.body_color) }
    private var showProblem: Binding<Bool> {
        Binding(get: { problem != nil && !creatingAgent }, set: { if !$0 { problem = nil } })
    }
    private var showRemoval: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    var body: some View {
        Group {
            if state.agents.isEmpty && state.teams.isEmpty { empty } else { floor }
        }
        .frame(minWidth: 720, minHeight: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Bench.canvas)
        .ignoresSafeArea()
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

    private var empty: some View {
        VStack(spacing: 14) {
            AgentAvatar(name: "Faísca", size: 56)
            Text(loc("A fábrica está parada.")).font(Bench.display(28)).tracking(-0.6)
            Button(loc("Novo agente"), action: startAgent).buttonStyle(SolidStyle())
        }
    }

    private var floor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                ForEach(state.teams) { team in
                    teamBlock(team, state.agents.filter { $0.team == team.id })
                }
                let loose = state.agents.filter { a in !state.teams.contains { $0.id == a.team } }
                if !loose.isEmpty { lanes(loose, title: state.teams.isEmpty ? nil : "Sem equipe") }
                if let r = state.router, r.haiku + r.sonnet + r.opus > 0 { routerLine(r) }
            }
            .padding(.horizontal, 44)
            .padding(.top, 52)
            .padding(.bottom, 36)
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc("Fábrica")).font(Bench.display(44)).tracking(-1.2)
                Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(loc("Nova equipe")) { creatingTeam = true }.buttonStyle(QuietStyle(tint: tint))
                .padding(.trailing, 14)
            Button(loc("Novo agente"), action: startAgent).buttonStyle(SolidStyle())
        }
    }

    private var subtitle: String {
        let working = state.agents.filter { $0.status == "trabalhando" }.count
        let waiting = state.agents.filter { $0.status == "aguardando" }.count
        let count = loc(state.agents.count == 1 ? "%@ agente" : "%@ agentes", "\(state.agents.count)")
        if waiting > 0 { return loc("%@, %@ esperando você", count, "\(waiting)") }
        return working > 0 ? loc("%@, %@ trabalhando", count, "\(working)") : count
    }

    private func teamBlock(_ team: TeamItem, _ crew: [AgentItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(team.name).font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                Button(loc("Abrir canal")) { openConversation(team.conversation) }.buttonStyle(QuietStyle(tint: tint))
                Spacer()
                Button(loc("Apagar equipe…")) {
                    removal = Removal(path: "teams/\(team.id)", title: loc("Apagar a equipe %@?", team.name), message: loc("Os agentes continuam na Fábrica, sem equipe."), action: loc("Apagar"))
                }
                .buttonStyle(QuietStyle(tint: .red))
            }
            .padding(.bottom, 10)
            Rectangle().fill(Bench.line).frame(height: 1)
            if crew.isEmpty {
                Text(loc("Ninguém nesta equipe ainda.")).font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 18)
            }
            ForEach(crew) { lane($0) }
        }
    }

    private func lanes(_ list: [AgentItem], title: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(loc(title)).font(.system(size: 20, weight: .semibold)).tracking(-0.3).padding(.bottom, 10)
            }
            Rectangle().fill(Bench.line).frame(height: 1)
            ForEach(list) { lane($0) }
        }
    }

    private func lane(_ a: AgentItem) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(a.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        Text(statusName(a.status))
                            .font(.system(size: 12, weight: a.status == "aguardando" ? .semibold : .regular))
                            .foregroundStyle(a.status == "aguardando" ? tint : Color.secondary)
                    }
                    Text(a.role).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                    if let m = a.mission {
                        Text(m.goal).font(.system(size: 13, weight: .medium)).lineLimit(2).padding(.top, 2)
                        missionNote(m)
                    }
                    HStack(spacing: 16) {
                        Button(loc("Conversar")) { openConversation(a.conversation) }
                        Button(loc("Nova missão")) { missionFor = a }
                        more(a)
                    }
                    .buttonStyle(QuietStyle(tint: tint))
                    .padding(.top, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProductionLine(agent: a, tint: tint).frame(width: 330)
            }
            .padding(.vertical, 18)
            Rectangle().fill(Bench.line).frame(height: 1)
        }
    }

    @ViewBuilder private func missionNote(_ m: MissionItem) -> some View {
        if m.log.last?.verdict == "sem-evidencia" {
            Text(loc("Parou: a etapa não citou evidência.")).font(.system(size: 12)).foregroundStyle(.red)
        } else if m.status != "rodando" {
            Text(loc(missionName(m.status))).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func more(_ a: AgentItem) -> some View {
        Menu {
            Section(detailLine(a)) {}
            Picker(loc("Equipe"), selection: Binding(
                get: { a.team ?? "" },
                set: { new in Task { _ = await core.factoryPost("agents/\(a.id)/team", ["team": new.isEmpty ? NSNull() : new]); await refresh() } }
            )) {
                Text(loc("Nenhuma")).tag("")
                ForEach(state.teams) { Text($0.name).tag($0.id) }
            }
            Divider()
            Button(loc("Apagar agente…"), role: .destructive) {
                removal = Removal(path: "agents/\(a.id)", title: loc("Apagar %@?", a.name), message: loc("O agente sai da Fábrica. Esta ação não pode ser desfeita."), action: loc("Apagar"))
            }
        } label: {
            Text(loc("Mais")).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func detailLine(_ a: AgentItem) -> String {
        var parts = [loc(a.place == "nuvem" ? "Padrão da nuvem" : (modelInfo(a.model)?.name ?? a.model.capitalized)),
                     loc(effortNames[a.effort] ?? a.effort),
                     loc(a.place == "nuvem" ? "Nuvem" : "Este Mac")]
        if let p = a.project { parts.append(p.components(separatedBy: "/").last ?? p) }
        return parts.joined(separator: " · ")
    }

    private func routerLine(_ r: RouterStats) -> some View {
        Text(loc("Modelo automático: Haiku %@, Sonnet %@, Opus %@. Subiu de modelo %@ vezes e aprendeu com %@ resultados.", "\(r.haiku)", "\(r.sonnet)", "\(r.opus)", "\(r.escalations)", "\(r.learned)"))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .monospacedDigit()
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
        HStack(spacing: 16) {
            Spacer()
            Button(loc("Cancelar"), action: cancel).buttonStyle(QuietStyle(tint: tint)).keyboardShortcut(.cancelAction)
            Button(loc(action), action: go).buttonStyle(SolidStyle()).keyboardShortcut(.defaultAction).disabled(!enabled)
        }
    }

    private func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func sheetTitle(_ t: String) -> some View {
        Text(t).font(Bench.display(26)).tracking(-0.6)
    }

    private func choice<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            content()
        }
    }

    private var agentSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                AgentAvatar(name: name.isEmpty ? "?" : name, size: 40)
                TextField("", text: $name, prompt: Text(loc("Nome do agente")).foregroundStyle(Bench.faint))
                    .textFieldStyle(.plain)
                    .font(Bench.display(26))
                    .tracking(-0.6)
                    .accessibilityLabel(loc("Nome do agente"))
            }
            HairField(prompt: "O que este agente faz", text: $role, lines: 2...4)
            choice("Modelo") {
                WordPicker(options: modelWords, selection: $model, tint: tint)
                Text(place == "nuvem" ? loc("Na nuvem, o modelo é o padrão do Claude na nuvem.") : loc(modelInfo(model)?.note ?? ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            choice("Esforço") {
                WordPicker(options: [("auto", "Automático")] + effortLevels.map { ($0, effortNames[$0] ?? $0) }, selection: $effort, tint: tint)
            }
            HStack(alignment: .top, spacing: 40) {
                choice("Onde roda") {
                    WordPicker(options: [("mac", "Este Mac"), ("nuvem", "Nuvem")], selection: $place, tint: tint)
                }
                choice("Projeto") {
                    WordDropdown(options: [("", "Nenhum")] + (core.usage?.projects ?? []).map { ($0.path, $0.name) }, selection: $project, tint: tint)
                }
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red) }
            sheetButtons("Criar agente", enabled: filled(name) && filled(role), cancel: { creatingAgent = false }, go: createAgent)
        }
        .padding(28)
        .frame(width: 500)
        .background(Bench.canvas)
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
        VStack(alignment: .leading, spacing: 20) {
            sheetTitle(loc("Nova equipe"))
            HairField(prompt: "Nome da equipe", text: $teamName)
            sheetButtons("Criar equipe", enabled: filled(teamName), cancel: {
                teamName = ""
                creatingTeam = false
            }, go: {
                let n = teamName
                teamName = ""
                creatingTeam = false
                Task { problem = await core.factoryPost("teams", ["name": n, "members": []]); await refresh() }
            })
        }
        .padding(28)
        .frame(width: 400)
        .background(Bench.canvas)
    }

    private func missionSheet(_ agent: AgentItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                AgentAvatar(name: agent.name, size: 40)
                sheetTitle(loc("Missão para %@", agent.name))
            }
            HairField(prompt: "Objetivo", text: $goal, lines: 3...6)
            Text(loc("Investigar, Propor, Executar (com sua aprovação) e Verificar. Cada etapa precisa citar evidência."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            sheetButtons("Iniciar", enabled: filled(goal), cancel: { missionFor = nil }, go: {
                let g = goal
                goal = ""
                missionFor = nil
                Task { problem = await core.factoryPost("agents/\(agent.id)/missions", ["goal": g]); await refresh() }
            })
        }
        .padding(28)
        .frame(width: 460)
        .background(Bench.canvas)
    }

    private func remove(_ r: Removal) {
        Task {
            await core.factoryDelete(r.path)
            await refresh()
        }
    }

    /// Só para teste visual: abre a folha de novo agente.
    private func testPick() {
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
        loc(["trabalhando": "Trabalhando", "aguardando": "Aguardando você", "erro": "Com erro"][s ?? ""] ?? "Livre")
    }
}
