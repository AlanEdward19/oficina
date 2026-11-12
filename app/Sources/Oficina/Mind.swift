import AppKit
import SwiftUI

// MARK: Modelos

struct OutfitPiece: Decodable, Equatable {
    let shape: String
    let color: String
}

struct OutfitData: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let theme: String
    let body: String
    let head: OutfitPiece
    let face: OutfitPiece
    let neck: OutfitPiece
    let badge: OutfitPiece?
    let prop: String
}

struct DecorData: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let theme: String
    let bed: OutfitPiece
    let blanket: OutfitPiece
    let extra: OutfitPiece
}

struct ThoughtData: Decodable, Equatable {
    let text: String
    let at: UInt64
}

struct InitiativeAction: Decodable, Equatable {
    let type: String
    let bundle: String?
    let name: String?
    let theme: String?
    let text: String?
    let meeting: String?
}

struct InitiativeData: Decodable, Equatable, Identifiable {
    let id: String
    let kind: String
    let text: String
    let accept: String
    let decline: String
    let action: InitiativeAction
    /// Terceira resposta, como "Nunca no Zoom".
    let never: String?
}

struct MindBrief: Decodable, Equatable {
    let mood: String
    let sleeping: Bool
    let thought: ThoughtData?
    let initiative: InitiativeData?
    let outfit: OutfitData?
    let decor: DecorData?
    /// App da chamada em andamento.
    let call: String?
}

/// O que ela entende que você está fazendo agora.
struct WorkContextData: Decodable {
    let project: String?
    let branch: String?
    let languages: [String]
    let activity: String
    let since: UInt64
    let dirty: Int
    let subjects: [String]
    let call: String?
    let pending: [String]
    let agenda: String?
}

struct NamedValue: Decodable {
    let name: String
    let value: Double
}

struct AppUse: Decodable {
    let name: String
    let minutes: Double
    let ai: Bool
}

struct InterestData: Decodable {
    let word: String
    let count: Int
}

struct FactData: Decodable {
    let text: String
    let at: UInt64
}

struct MemoryData: Decodable {
    let apps: [AppUse]
    let interests: [InterestData]
    let facts: [FactData]
    let peak: [Int]?
}

struct MindSnapshot: Decodable {
    let mood: String
    let sleeping: Bool
    let thought: ThoughtData?
    let initiative: InitiativeData?
    let outfit: OutfitData?
    let energy: Double
    let drives: [NamedValue]
    let inputs: [NamedValue]
    let neurons: [Double]
    let thoughts: [ThoughtData]
    let memory: MemoryData
    let outfits: [OutfitData]
    let decor: DecorData?
    let decors: [DecorData]?
    let context: WorkContextData?
    let today: String?
}

private let driveLabels: [String: String] = [
    "alegria": "Alegria", "curiosidade": "Curiosidade", "tedio": "Tédio", "cansaco": "Cansaço",
    "carencia": "Carência", "foco": "Seu foco", "iniciativa": "Iniciativa",
]

private let inputLabels: [String: String] = [
    "trabalhando": "Você trabalhando", "ia": "Assunto IA", "ociosidade": "Ociosidade", "tarefa": "Tarefa rodando",
    "sucesso": "Sucesso", "falha": "Falha", "carinho": "Carinho", "cutucada": "Cutucada", "ignorada": "Ignorada",
    "noite": "Noite", "novidade": "Novidade", "troca": "Troca de app",
]

private let groupColors: [Color] = [.yellow, .green, .gray, .brown, .purple, .blue, .orange]

// MARK: Balão de fala

/// O que aparece no balão acima da Faísca.
@MainActor
final class BubbleModel: ObservableObject {
    @Published var text: String?
    @Published var initiative: InitiativeData?
    var answer: (InitiativeData, Bool) -> Void = { _, _ in }
    var never: (InitiativeData) -> Void = { _ in }
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let i = model.initiative {
                Text(i.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(i.accept) { model.answer(i, true) }.buttonStyle(.borderedProminent)
                    Button(i.decline) { model.answer(i, false) }
                }
                .controlSize(.small)
                if let never = i.never {
                    Button(never) { model.never(i) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } else if let t = model.text {
                Text(t).font(.callout).italic().fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .padding(4)
        .fixedSize()
    }
}

/// Balão que acompanha a Faísca. Pensamentos somem sozinhos; perguntas ficam
/// até a resposta.
@MainActor
final class BubbleController {
    let model = BubbleModel()
    private let panel: NSPanel
    private let host: TrackingHost<BubbleView>
    private weak var anchor: NSWindow?

    init(anchor: NSWindow) {
        self.anchor = anchor
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        host = TrackingHost(rootView: BubbleView(model: model))
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: anchor, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    func ask(_ initiative: InitiativeData?) {
        model.initiative = initiative
        if initiative == nil {
            panel.orderOut(nil)
        } else if !moving {
            show()
        }
    }

    private var moving = false

    /// Enquanto a Faísca anda, a pergunta some; volta quando ela para.
    func hideForMove() {
        moving = true
        panel.orderOut(nil)
    }

    func showAfterMove() {
        moving = false
        if model.initiative != nil { show() }
    }

    private func show() {
        place()
        panel.orderFrontRegardless()
    }

    private func place() {
        guard let a = anchor else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = (a.screen ?? NSScreen.main)?.visibleFrame ?? a.frame
        var x = a.frame.midX - size.width / 2
        x = min(max(x, screen.minX + 6), screen.maxX - size.width - 6)
        let y = min(a.frame.maxY - 6, screen.maxY - size.height)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

// MARK: Painel da mente

struct MindView: View {
    @ObservedObject var core: Core
    @State private var snap: MindSnapshot?
    @State private var confirmForget = false

    var body: some View {
        ScrollView {
            if let s = snap {
                VStack(alignment: .leading, spacing: 18) {
                    header(s)
                    section("O que ela sente") { drives(s) }
                    section("Neurônios") { neurons(s) }
                    section("O que ela percebe agora") { inputs(s) }
                    section("Pensamentos") { thoughts(s) }
                    section("O que você está fazendo") { context(s) }
                    section("Projetos em que você atua") { projects }
                    section("O que ela lembra de você") { memory(s) }
                    section("Roupinhas") { outfits(s) }
                    section("Casinha") { homes(s) }
                }
                .padding(18)
            } else {
                ProgressView().padding(40)
            }
        }
        .frame(width: 460, height: 640)
        .task {
            while !Task.isCancelled {
                if let s = await core.mindSnapshot() { snap = s }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .confirmationDialog("Esquecer tudo o que a Faísca aprendeu sobre você?", isPresented: $confirmForget) {
            Button("Esquecer tudo", role: .destructive) { core.forgetMind() }
        } message: {
            Text("Apaga apps, horários, interesses e fatos. As roupinhas ficam. Não dá para desfazer.")
        }
    }

    private func header(_ s: MindSnapshot) -> some View {
        HStack(spacing: 14) {
            FaiscaAvatar(size: 54, mood: s.sleeping ? .sleeping : .idle)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.sleeping ? "Dormindo" : s.mood.capitalized).font(.title2.weight(.semibold))
                if let t = s.thought { Text("“\(t.text)”").font(.callout).italic().foregroundStyle(.secondary) }
                HStack(spacing: 6) {
                    Text("Energia").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: s.energy).frame(width: 120)
                }
            }
            Spacer()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func bar(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack {
            Text(label).font(.callout).frame(width: 130, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: g.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(value * 100)) por cento")
    }

    private func drives(_ s: MindSnapshot) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(s.drives.enumerated()), id: \.offset) { i, d in
                bar(driveLabels[d.name] ?? d.name, d.value, groupColors[i % groupColors.count])
            }
        }
    }

    private func neurons(_ s: MindSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(s.neurons.enumerated()), id: \.offset) { i, r in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(groupColors[i % 7].opacity(0.12 + 0.88 * min(r * 2.5, 1)))
                        .frame(width: 18, height: 18)
                }
            }
            Text("49 interneurônios de disparo, um grupo por cor de impulso. Mais forte, mais disparos agora.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func inputs(_ s: MindSnapshot) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(s.inputs.enumerated()).filter { $0.element.value > 0.02 }, id: \.offset) { _, d in
                bar(inputLabels[d.name] ?? d.name, d.value, .accentColor)
            }
            if s.inputs.allSatisfy({ $0.value <= 0.02 }) {
                Text("Nada acontecendo agora.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func thoughts(_ s: MindSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(s.thoughts.prefix(8).enumerated()), id: \.offset) { _, t in
                HStack(alignment: .top) {
                    Text(Date(timeIntervalSince1970: TimeInterval(t.at)), format: .dateTime.hour().minute())
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text(t.text).font(.callout)
                }
            }
            if s.thoughts.isEmpty { Text("Ainda pensando…").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func memory(_ s: MindSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if s.memory.apps.isEmpty && s.memory.interests.isEmpty && s.memory.facts.isEmpty {
                Text("Ainda conhecendo você. Fica tudo só neste Mac.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(s.memory.apps.enumerated()), id: \.offset) { _, a in
                HStack {
                    Text(a.name)
                    if a.ai { Text("IA").font(.caption2.bold()).padding(.horizontal, 4).background(Color.orange.opacity(0.25), in: Capsule()) }
                    Spacer()
                    Text(minutes(a.minutes)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if let p = s.memory.peak, p.count == 2 {
                Text("Costuma usar o Mac das \(p[0])h às \(p[1])h.").font(.callout)
            }
            if !s.memory.interests.isEmpty {
                Text(s.memory.interests.prefix(10).map { "\($0.word) (\($0.count))" }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(s.memory.facts.enumerated()), id: \.offset) { _, f in
                Label(f.text, systemImage: "pin").font(.callout)
            }
            HStack {
                Button("Me sugere algo") { core.suggest() }
                Button("Esquecer tudo…", role: .destructive) { confirmForget = true }
            }
            .controlSize(.small)
            Text("Para ela lembrar de algo, diga no chat: “lembre que …”.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func context(_ s: MindSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let c = s.context {
                let since = Date(timeIntervalSince1970: TimeInterval(c.since))
                HStack {
                    Text(c.activity.isEmpty ? "—" : c.activity.capitalized).font(.callout.weight(.semibold))
                    Text("desde \(since.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                if let p = c.project {
                    Label([p, c.branch].compactMap { $0 }.joined(separator: " · "), systemImage: "hammer").font(.callout)
                }
                if !c.languages.isEmpty {
                    Text(c.languages.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                if c.dirty > 0 {
                    Text("\(c.dirty) arquivo(s) sem commit").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(c.subjects.prefix(3), id: \.self) { Text("· \($0)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let call = c.call { Label("Em chamada no \(call)", systemImage: "phone").font(.callout) }
                if let a = c.agenda { Label(a, systemImage: "calendar").font(.callout) }
                ForEach(c.pending, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout) }
            }
            if let t = s.today { Text("Hoje: \(t)").font(.callout) }
            Text("Vem do git e do Claude Code dos seus projetos, nunca da tela.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 4) {
            let list = core.usage?.projects ?? []
            if list.isEmpty {
                Text("Ainda não vi projetos no Claude Code.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(list, id: \.path) { p in
                HStack {
                    Label(p.name, systemImage: "folder")
                    if let b = p.branch { Text(b).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(tokens(p.week)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private func tokens(_ n: UInt64) -> String {
        n >= 1_000_000 ? String(format: "%.1f M", Double(n) / 1_000_000) : "\(n / 1000) mil"
    }

    private func outfits(_ s: MindSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if s.outfits.isEmpty {
                Text("Nenhuma ainda. Ela pede antes de gastar tokens para criar uma.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(s.outfits) { o in
                HStack {
                    Text(o.name)
                    Spacer()
                    if s.outfit?.id == o.id {
                        Button("Tirar") { core.wear(nil) }
                    } else {
                        Button("Vestir") { core.wear(o.id) }
                    }
                }
                .font(.callout)
                .controlSize(.small)
            }
        }
    }

    @State private var wish = ""

    private func homes(_ s: MindSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Caminha fofinha (padrão)")
                Spacer()
                if s.decor?.id == "padrao" || s.decor == nil {
                    Text("Em uso").foregroundStyle(.secondary)
                } else {
                    Button("Usar") { core.useDecor(nil) }
                }
            }
            ForEach(s.decors ?? []) { d in
                HStack {
                    Text(d.name)
                    Spacer()
                    if s.decor?.id == d.id {
                        Text("Em uso").foregroundStyle(.secondary)
                    } else {
                        Button("Usar") { core.useDecor(d.id) }
                    }
                }
            }
            HStack {
                TextField("Sugira um tema (ex.: praia, pirata, espaço)", text: $wish)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createHome)
                Button("Criar", action: createHome)
                    .disabled(wish.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Criar uma casinha gasta alguns tokens do Claude.").font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
        .controlSize(.small)
    }

    private func createHome() {
        let text = wish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        core.createDecor(suggestion: text)
        wish = ""
    }

    private func minutes(_ m: Double) -> String {
        m >= 60 ? String(format: "%.0f h %02.0f min", (m / 60).rounded(.down), m.truncatingRemainder(dividingBy: 60)) : String(format: "%.0f min", m)
    }
}
