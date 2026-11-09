import AppKit
import Combine
import SwiftUI

// MARK: Modelo

struct DockEnv: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    var apps: [String]
}

private struct DockFile: Codable {
    var environments: [DockEnv]
    var active: Int
}

struct DockApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let running: Bool
    let pinned: Bool
}

enum DockEdge: String {
    case bottom, left, right
}

/// Aparência que vem dos ajustes de Mesa e Dock do macOS.
struct DockLook: Equatable {
    var autohide = true
    /// Atraso para aparecer (autohide-delay do macOS; padrão 0,5 s).
    var revealDelay: Double = 0.5
    /// Multiplicador da velocidade da animação (autohide-time-modifier).
    var speed: Double = 1
    var tile: CGFloat = 48
    var magnify: CGFloat = 1
    var edge: DockEdge = .bottom
}

/// Ambientes, apps fixados e apps abertos. Tudo muda por eventos do sistema:
/// nada fica verificando em ciclo.
@MainActor
final class DockStore: ObservableObject {
    @Published private(set) var envs: [DockEnv]
    @Published private(set) var active: Int
    @Published private(set) var runningIDs: [String] = []
    @Published var usage: UsageData?
    @Published var look = DockLook()
    @Published var nudged: String?
    /// A casa da Faísca abre só quando ela está (ou está chegando) em casa.
    @Published var homeOpen = true
    var openChat: () -> Void = {}
    var onOpen: (String) -> Void = { _ in }
    var onSwitch: (DockEnv) -> Void = { _ in }

    private let file: URL
    private var icons: [String: NSImage] = [:]
    private var names: [String: String] = [:]
    private let finder = "com.apple.finder"

    init(home: URL) {
        file = home.appendingPathComponent("dock.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(DockFile.self, from: data),
           !saved.environments.isEmpty {
            envs = saved.environments
            active = min(max(saved.active, 0), saved.environments.count - 1)
        } else {
            envs = DockStore.seed()
            active = 0
            save()
        }
        refreshRunning()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            }
        }
    }

    /// O primeiro ambiente começa com os apps fixados na Dock do macOS.
    private static func seed() -> [DockEnv] {
        var work = ["com.apple.finder"]
        let tiles = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        for tile in tiles {
            if let data = tile["tile-data"] as? [String: Any], let id = data["bundle-identifier"] as? String, !work.contains(id) {
                work.append(id)
            }
        }
        let personal = ["com.apple.finder", "com.apple.Safari", "com.apple.Music", "com.apple.Photos", "com.apple.MobileSMS"]
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return [
            DockEnv(id: UUID().uuidString, name: "Trabalho", symbol: "briefcase.fill", apps: work),
            DockEnv(id: UUID().uuidString, name: "Pessoal", symbol: "house.fill", apps: personal),
        ]
    }

    var current: DockEnv { envs[active] }
    var pinned: [DockApp] { current.apps.map(item) }
    var others: [DockApp] { runningIDs.filter { !current.apps.contains($0) }.map(item) }
    var allIDs: [String] { current.apps + runningIDs.filter { !current.apps.contains($0) } }

    private func refreshRunning() {
        let mine = Bundle.main.bundleIdentifier
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != mine }
        if ids != runningIDs { runningIDs = ids }
    }

    private func item(_ id: String) -> DockApp {
        DockApp(id: id, name: name(id), icon: icon(id), running: runningIDs.contains(id), pinned: current.apps.contains(id))
    }

    private func icon(_ id: String) -> NSImage {
        if let cached = icons[id] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first, let i = app.icon {
            image = i
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        image.size = NSSize(width: 128, height: 128)
        icons[id] = image
        return image
    }

    func name(_ id: String) -> String {
        if let cached = names[id] { return cached }
        let n = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            }
            ?? id
        names[id] = n
        return n
    }

    // MARK: Ações

    /// Igual à Dock do macOS: abre, ou traz para frente e reabre a janela.
    func open(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.unhide()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        onOpen(id)
    }

    /// Faz o ícone balançar, como se alguém tivesse cutucado.
    func nudge(_ id: String) {
        nudged = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.nudged == id { self?.nudged = nil }
        }
    }

    /// Troca de ambiente: esconde o que é só do anterior e mostra o do novo.
    func switchTo(_ index: Int) {
        guard index != active, envs.indices.contains(index) else { return }
        let target = Set(envs[index].apps)
        let leaving = Set(envs[active].apps)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != finder, id != Bundle.main.bundleIdentifier else { continue }
            if leaving.contains(id) && !target.contains(id) {
                app.hide()
            } else if target.contains(id) && app.isHidden {
                app.unhide()
            }
        }
        active = index
        save()
        onSwitch(envs[index])
    }

    func pin(_ id: String) {
        guard !envs[active].apps.contains(id) else { return }
        envs[active].apps.append(id)
        save()
    }

    func unpin(_ id: String) {
        envs[active].apps.removeAll { $0 == id }
        save()
    }

    func move(_ id: String, to index: Int) {
        guard envs.indices.contains(index), index != active else { return }
        envs[active].apps.removeAll { $0 == id }
        if !envs[index].apps.contains(id) { envs[index].apps.append(id) }
        save()
    }

    func quit(_ id: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
    }

    func reveal(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func addEnvironment(_ name: String) {
        let symbols = ["book.fill", "gamecontroller.fill", "paintbrush.fill", "hammer.fill", "music.note", "leaf.fill", "star.fill"]
        envs.append(DockEnv(id: UUID().uuidString, name: name, symbol: symbols[envs.count % symbols.count], apps: [finder]))
        switchTo(envs.count - 1)
        save()
    }

    func renameCurrent(_ name: String) {
        envs[active].name = name
        save()
    }

    func deleteCurrent() {
        guard envs.count > 1 else { return }
        let removed = active
        switchTo(removed == 0 ? 1 : removed - 1)
        envs.remove(at: removed)
        if active > removed { active -= 1 }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(DockFile(environments: envs, active: active)) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: Dock do macOS

/// Tira a Dock do macOS do caminho e lê os ajustes de Mesa e Dock.
/// Guarda os valores originais e devolve tudo ao sair.
@MainActor
enum SystemDock {
    /// Domínio de preferências da Dock. Os testes usam outro, e aí a Dock
    /// real não é tocada nem reiniciada.
    private static let testing = ProcessInfo.processInfo.environment["OFICINA_DOCK_DOMAIN"]
    private static let domain = (testing ?? "com.apple.dock") as CFString
    private static let savedKey = testing == nil ? "systemDockOriginal" : "systemDockOriginalTest"

    private static func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private static func set(_ key: String, _ v: Any?) {
        CFPreferencesSetAppValue(key as CFString, v as CFPropertyList?, domain)
    }

    private static var replaceKey: String { testing == nil ? "dockReplace" : "dockReplaceTest" }
    /// Ligada por padrão: a Dock da Oficina substitui a do macOS.
    static var replacing: Bool { UserDefaults.standard.object(forKey: replaceKey) as? Bool ?? true }

    /// Ajustes atuais. Enquanto a Oficina substitui a Dock, o "ocultar" que
    /// vale é o que o usuário tinha antes (ou mudou depois).
    static func look() -> DockLook {
        CFPreferencesAppSynchronize(domain)
        var look = DockLook()
        let saved = UserDefaults.standard.dictionary(forKey: savedKey)
        look.autohide = replacing ? (saved?["intent"] as? Bool ?? true) : (value("autohide") as? Bool ?? false)
        let tile = (value("tilesize") as? NSNumber)?.doubleValue ?? 48
        look.tile = CGFloat(min(max(tile, 24), 96))
        if value("magnification") as? Bool == true {
            let large = (value("largesize") as? NSNumber)?.doubleValue ?? 128
            look.magnify = max(1, min(CGFloat(large) / look.tile, 2.2))
        }
        look.edge = DockEdge(rawValue: value("orientation") as? String ?? "bottom") ?? .bottom
        // Enquanto a Oficina substitui a Dock, o atraso de verdade fica guardado.
        let delay = replacing ? saved?["delay"] as? Double : (value("autohide-delay") as? NSNumber)?.doubleValue
        look.revealDelay = min(max(delay ?? 0.5, 0), 5)
        let modifier = (value("autohide-time-modifier") as? NSNumber)?.doubleValue ?? 1
        look.speed = min(max(modifier, 0), 5)
        // Só para testes: mantém a Dock à vista.
        if ProcessInfo.processInfo.environment["OFICINA_DOCK_FIXA"] != nil { look.autohide = false }
        return look
    }

    /// Se alguém desligou o "ocultar" lá nos Ajustes, isso vira a intenção
    /// do usuário para a nossa Dock e a do macOS volta a ficar escondida.
    static func enforce() {
        guard replacing else { return }
        CFPreferencesAppSynchronize(domain)
        let delay = (value("autohide-delay") as? NSNumber)?.doubleValue
        let hidden = value("autohide") as? Bool == true && (delay ?? 0) >= 100
        guard !hidden else { return }
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        if saved["autohide"] == nil {
            saved["autohide"] = value("autohide") as? Bool ?? false
        }
        // Atraso mudado (ex.: pelo Terminal) vira o atraso da nossa Dock.
        if let delay, delay < 100 { saved["delay"] = delay }
        if let a = value("autohide") as? Bool { saved["intent"] = a }
        UserDefaults.standard.set(saved, forKey: savedKey)
        hideSystemDock()
    }

    static func enable() {
        CFPreferencesAppSynchronize(domain)
        if UserDefaults.standard.dictionary(forKey: savedKey) == nil {
            var saved: [String: Any] = ["autohide": value("autohide") as? Bool ?? false]
            saved["intent"] = saved["autohide"]
            if let d = value("autohide-delay") as? NSNumber { saved["delay"] = d.doubleValue }
            UserDefaults.standard.set(saved, forKey: savedKey)
        }
        UserDefaults.standard.set(true, forKey: replaceKey)
        hideSystemDock()
    }

    /// Devolve a Dock do macOS como estava. `keepChoice` mantém a preferência
    /// de substituir para a próxima abertura (usado ao sair).
    static func restore(keepChoice: Bool) {
        if !keepChoice { UserDefaults.standard.set(false, forKey: replaceKey) }
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) else { return }
        // Volta com a escolha mais recente do usuário, inclusive a feita nos
        // Ajustes enquanto a Oficina estava aberta.
        set("autohide", saved["intent"] as? Bool ?? saved["autohide"] as? Bool ?? false)
        set("autohide-delay", (saved["delay"] as? Double).map { NSNumber(value: $0) })
        CFPreferencesAppSynchronize(domain)
        if keepChoice {
            // A intenção do usuário sobrevive para a próxima abertura.
            UserDefaults.standard.set(["intent": saved["intent"] ?? saved["autohide"] ?? false], forKey: savedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: savedKey)
        }
        restartDock()
    }

    /// Roteiro de verificação: liga, simula uma mudança feita nos Ajustes,
    /// sai e desliga, imprimindo o estado a cada passo.
    static func selfTest() {
        guard testing != nil else { return }
        func state(_ step: String) {
            CFPreferencesAppSynchronize(domain)
            let a = value("autohide").map { "\($0)" } ?? "-"
            let d = value("autohide-delay").map { "\($0)" } ?? "-"
            print("\(step): autohide=\(a) delay=\(d) replacing=\(replacing) intent=\(look().autohide)")
        }
        set("autohide", false); set("autohide-delay", nil); CFPreferencesAppSynchronize(domain)
        UserDefaults.standard.removeObject(forKey: savedKey); UserDefaults.standard.set(false, forKey: replaceKey)
        state("inicio")
        enable(); state("substituindo")
        enforce(); state("enforce sem mudança")
        set("autohide", true); set("autohide-delay", nil); CFPreferencesAppSynchronize(domain)
        enforce(); state("usuario ligou ocultar nos Ajustes")
        restore(keepChoice: true); state("saiu da Oficina")
        enforce(); state("abriu de novo")
        restore(keepChoice: false); state("desligou a substituicao")
        CFPreferencesSetAppValue("autohide" as CFString, nil, domain); CFPreferencesAppSynchronize(domain)
    }

    private static func hideSystemDock() {
        set("autohide", true)
        set("autohide-delay", NSNumber(value: 1000.0))
        CFPreferencesAppSynchronize(domain)
        restartDock()
    }

    private static func restartDock() {
        guard testing == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }
}

// MARK: Interface

/// Posição do mouse sobre a Dock. Vem da própria janela: o hover do SwiftUI
/// não funciona em janelas que não estão em foco.
@MainActor
final class DockPointer: ObservableObject {
    @Published var location: CGPoint?
}

private struct IconFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Largura da casa: cabe o corpo dela inteiro.
let dockHomeWidth: CGFloat = 60

/// Espaço livre além da barra para o ícone ampliado e o nome do app.
func dockHeadroom(_ look: DockLook) -> CGFloat {
    max(34, look.tile * (look.magnify - 1) + 30)
}

struct DockView: View {
    @ObservedObject var store: DockStore
    @ObservedObject var pointer: DockPointer
    let askName: (_ title: String, _ initial: String, _ done: @escaping (String) -> Void) -> Void
    let framesChanged: ([String: CGRect]) -> Void
    @State private var frames: [String: CGRect] = [:]

    private var look: DockLook { store.look }
    private var vertical: Bool { look.edge != .bottom }
    private var headroom: CGFloat { dockHeadroom(look) }

    private var hovered: String? {
        guard let p = pointer.location else { return nil }
        switch look.edge {
        case .bottom:
            guard p.y >= headroom else { return nil }
            return frames.first { $0.value.minX - 4 <= p.x && p.x <= $0.value.maxX + 4 }?.key
        case .left, .right:
            return frames.first { $0.value.minY - 4 <= p.y && p.y <= $0.value.maxY + 4 }?.key
        }
    }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 8))
        layout {
            environments
            separator
            ForEach(store.pinned) { icon($0) }
            if !store.others.isEmpty {
                separator
                ForEach(store.others) { icon($0) }
            }
            separator
            widgets
        }
        .padding(vertical ? .vertical : .horizontal, 12)
        .padding(vertical ? .horizontal : .vertical, 8)
        .background(Glass().clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .padding(headroomEdge, headroom)
        .fixedSize()
        .coordinateSpace(name: "dock")
        .onPreferenceChange(IconFrames.self) { f in
            frames = f
            framesChanged(f)
        }
        .environment(\.colorScheme, .dark)
    }

    private var headroomEdge: Edge.Set {
        switch look.edge {
        case .bottom: return .top
        case .left: return .trailing
        case .right: return .leading
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: vertical ? look.tile - 8 : 1, height: vertical ? 1 : look.tile - 8)
            .padding(vertical ? .horizontal : .bottom, 4)
    }

    private var anchor: UnitPoint {
        switch look.edge {
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private func icon(_ app: DockApp) -> some View {
        let isHovered = hovered == app.id
        let wobble = store.nudged == app.id
        return Button { store.open(app.id) } label: {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: look.tile, height: look.tile)
                .background(GeometryReader { g in
                    Color.clear.preference(key: IconFrames.self, value: [app.id: g.frame(in: .named("dock"))])
                })
                .scaleEffect(isHovered ? look.magnify : 1, anchor: anchor)
                .rotationEffect(.degrees(wobble ? 8 : 0), anchor: .bottom)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isHovered)
                .animation(wobble ? .easeInOut(duration: 0.09).repeatCount(5, autoreverses: true) : .default, value: wobble)
        }
        .buttonStyle(.plain)
        .overlay(alignment: runningDotAlignment) {
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 4, height: 4)
                .offset(runningDotOffset)
                .opacity(app.running ? 1 : 0)
        }
        .overlay(alignment: labelAlignment) {
            if isHovered {
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .fixedSize()
                    .offset(labelOffset)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(app.running ? "\(app.name), aberto" : app.name)
        .contextMenu { menu(for: app) }
    }

    private var runningDotAlignment: Alignment {
        look.edge == .bottom ? .bottom : look.edge == .left ? .leading : .trailing
    }

    private var runningDotOffset: CGSize {
        switch look.edge {
        case .bottom: return CGSize(width: 0, height: 6)
        case .left: return CGSize(width: -6, height: 0)
        case .right: return CGSize(width: 6, height: 0)
        }
    }

    private var labelAlignment: Alignment {
        look.edge == .bottom ? .top : look.edge == .left ? .trailing : .leading
    }

    private var labelOffset: CGSize {
        let lift = look.tile * look.magnify - look.tile + 26
        switch look.edge {
        case .bottom: return CGSize(width: 0, height: -lift)
        case .left: return CGSize(width: lift + 20, height: 0)
        case .right: return CGSize(width: -lift - 20, height: 0)
        }
    }

    @ViewBuilder private func menu(for app: DockApp) -> some View {
        if app.pinned {
            Button("Remover de \(store.current.name)") { store.unpin(app.id) }
            if store.envs.count > 1 {
                Menu("Mover para") {
                    ForEach(Array(store.envs.enumerated()), id: \.element.id) { i, env in
                        if i != store.active { Button(env.name) { store.move(app.id, to: i) } }
                    }
                }
            }
        } else {
            Button("Fixar em \(store.current.name)") { store.pin(app.id) }
        }
        Divider()
        Button("Mostrar no Finder") { store.reveal(app.id) }
        if app.running {
            Button("Sair") { store.quit(app.id) }
        }
    }

    private var environments: some View {
        VStack(spacing: 3) {
            let stack = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
            stack {
                ForEach(Array(store.envs.enumerated()), id: \.element.id) { i, env in
                    Button { store.switchTo(i) } label: {
                        Image(systemName: env.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(i == store.active ? Color.white.opacity(0.2) : Color.clear, in: Circle())
                            .foregroundStyle(i == store.active ? Color.white : Color.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ambiente \(env.name)\(i == store.active ? ", atual" : "")")
                }
            }
            if !vertical {
                Text(store.current.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.bottom, 2)
        .contextMenu {
            Button("Novo ambiente…") {
                askName("Novo ambiente", "") { store.addEnvironment($0) }
            }
            Button("Renomear \(store.current.name)…") {
                askName("Renomear ambiente", store.current.name) { store.renameCurrent($0) }
            }
            if store.envs.count > 1 {
                Divider()
                Button("Apagar \(store.current.name)") { store.deleteCurrent() }
            }
        }
    }

    private var widgets: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return stack {
            if let session = store.usage?.limits.first(where: { $0.kind == "session" }) {
                UsageRing(percent: session.percent)
            }
            TimelineView(.everyMinute) { ctx in
                VStack(spacing: 0) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                    if !vertical {
                        Text(ctx.date, format: .dateTime.weekday(.abbreviated).day())
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .foregroundStyle(.white)
            }
            // A casa da Faísca: ela mesma senta aqui quando está na Dock.
            if !vertical {
                Color.clear
                    .frame(width: store.homeOpen ? dockHomeWidth : 0, height: look.tile)
                    .animation(.easeInOut(duration: 0.25), value: store.homeOpen)
                    .accessibilityLabel("Casa da Faísca")
            }
        }
        .frame(minHeight: vertical ? nil : look.tile)
    }
}

private struct UsageRing: View {
    let percent: Double

    var body: some View {
        let color: Color = percent >= 90 ? .red : percent >= 70 ? .orange : .cyan
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(percent, 0), 100) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(percent.rounded()))")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
        .help("Sessão do Claude: \(Int(percent.rounded()))%")
        .accessibilityLabel("Sessão do Claude em \(Int(percent.rounded())) por cento")
    }
}

// MARK: Janela

final class TrackingHost<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    var onMove: ((CGPoint?) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
        onMove?(point(event))
    }

    override func mouseMoved(with event: NSEvent) { onMove?(point(event)) }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        onMove?(nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class DockController {
    let store: DockStore
    private let pointer = DockPointer()
    private let panel: NSPanel
    private let host: TrackingHost<DockView>
    private let edge: NSPanel
    private var shown = true
    /// Para onde a Dock vai. Tudo que a Faísca consulta usa o destino, não o
    /// quadro no meio de uma animação.
    private var target = NSRect.zero
    private var watch: Timer?
    private var frames: [String: CGRect] = [:]
    private var bag = Set<AnyCancellable>()
    /// Avisa para onde a Dock vai (quadro final), em quanto tempo e com que curva.
    var onLayout: (NSRect, Double, CAMediaTimingFunction?) -> Void = { _, _, _ in }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "dockEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dockEnabled"); apply() }
    }

    init(store: DockStore, askName: @escaping (String, String, @escaping (String) -> Void) -> Void) {
        self.store = store
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let relay = FrameRelay()
        host = TrackingHost(rootView: DockView(store: store, pointer: pointer, askName: askName, framesChanged: { relay.send($0) }))
        panel.contentView = host

        // Faixa quase invisível na borda que revela a Dock oculta.
        edge = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        edge.isOpaque = false
        edge.backgroundColor = NSColor(white: 1, alpha: 0.004)
        edge.hasShadow = false
        edge.level = .floating
        edge.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let edgeView = TrackingHost(rootView: Color.clear)
        edge.contentView = edgeView

        relay.receive = { [weak self] f in self?.frames = f }
        store.look = SystemDock.look()
        shown = !store.look.autohide
        host.onMove = { [weak self] p in
            if self?.pointer.location != p { self?.pointer.location = p }
        }
        edgeView.onHover = { [weak self] inside in
            if inside { self?.scheduleReveal() } else { self?.pendingReveal?.invalidate() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.layout(animated: false) } }
        }.store(in: &bag)
        // Ao sair dos Ajustes do sistema, relê Mesa e Dock.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier, id == "com.apple.systempreferences" || id == "com.apple.Settings" else { return }
            MainActor.assumeIsolated { self?.syncSystemSettings() }
        }
        if SystemDock.replacing { SystemDock.enforce() }
        apply()
    }

    /// Relê os ajustes de Mesa e Dock e aplica na nossa Dock.
    func syncSystemSettings() {
        SystemDock.enforce()
        let look = SystemDock.look()
        guard look != store.look else { return }
        store.look = look
        shown = !look.autohide
        layout(animated: false)
    }

    var replacingSystemDock: Bool {
        get { SystemDock.replacing }
        set {
            if newValue { SystemDock.enable() } else { SystemDock.restore(keepChoice: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.syncSystemSettings() }
        }
    }

    /// Topo da barra (embaixo) e sua faixa horizontal, em coordenadas da tela.
    var shelf: (y: CGFloat, x: ClosedRange<CGFloat>)? {
        guard enabled, shown, store.look.edge == .bottom else { return nil }
        let f = target
        let barHeight = f.height - dockHeadroom(store.look)
        return (f.minY + barHeight, (f.minX + 6)...(f.maxX - 6))
    }

    /// A Dock está à vista agora?
    var visible: Bool { enabled && shown }

    /// Quadro da Faísca sentada na casa, para um quadro da Dock. A casa é o
    /// último item, antes da margem. Com a Dock recolhida, fica fora da tela.
    func petHome(for dock: NSRect) -> NSRect? {
        guard enabled, store.look.edge == .bottom else { return nil }
        let midX = dock.maxX - 12 - dockHomeWidth / 2
        return NSRect(x: midX - 42, y: dock.minY + 4, width: 84, height: 88)
    }

    var petHome: NSRect? { petHome(for: target) }

    var frame: NSRect { target }

    /// Centro do ícone em coordenadas da tela.
    func iconX(_ id: String) -> CGFloat? {
        guard enabled, shown, store.look.edge == .bottom, let r = frames[id] else { return nil }
        return target.minX + r.midX
    }

    private func apply() {
        if enabled {
            panel.orderFrontRegardless()
            layout(animated: false)
        } else {
            panel.orderOut(nil)
            edge.orderOut(nil)
            onLayout(panel.frame, 0, nil)
        }
    }

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private var slideToken = 0
    /// Subida suave, quase sem freio no fim; descida que acelera.
    private let showCurve = CAMediaTimingFunction(controlPoints: 0.16, 0.9, 0.3, 1)
    private let hideCurve = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.8, 0.4)

    private func layout(animated: Bool) {
        guard enabled else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let s = screen.frame
        let gap: CGFloat = 6
        let shownFrame: NSRect
        let hiddenFrame: NSRect
        switch store.look.edge {
        case .bottom:
            shownFrame = NSRect(x: s.midX - size.width / 2, y: s.minY + gap, width: size.width, height: size.height)
            hiddenFrame = shownFrame.offsetBy(dx: 0, dy: -(size.height + gap + 2))
        case .left:
            shownFrame = NSRect(x: s.minX + gap, y: s.midY - size.height / 2, width: size.width, height: size.height)
            hiddenFrame = shownFrame.offsetBy(dx: -(size.width + gap + 2), dy: 0)
        case .right:
            shownFrame = NSRect(x: s.maxX - size.width - gap, y: s.midY - size.height / 2, width: size.width, height: size.height)
            hiddenFrame = shownFrame.offsetBy(dx: size.width + gap + 2, dy: 0)
        }
        let target = shown ? shownFrame : hiddenFrame
        self.target = target
        slideToken += 1
        let token = slideToken
        let layer = host.layer
        // Se outra animação estava no meio, continua de onde está.
        let current = (layer?.presentation()?.value(forKeyPath: "transform.translation") as? NSValue)?.sizeValue
        layer?.removeAnimation(forKey: "slide")

        let wasAway = panel.frame.origin != shownFrame.origin && current == nil
        if animated && (shown || !wasAway) {
            // A janela fica parada na posição visível e o conteúdo desliza
            // por Core Animation, no servidor de janelas.
            let away = CGSize(width: hiddenFrame.minX - shownFrame.minX, height: hiddenFrame.minY - shownFrame.minY)
            let from = current ?? (shown ? away : .zero)
            // Antes de a janela ir para o lugar, o conteúdo já fica na posição de
            // saída; senão a Dock pisca inteira por um quadro e dá um tranco.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.transform = CATransform3DMakeTranslation(from.width, from.height, 0)
            CATransaction.commit()
            CATransaction.flush()
            panel.setFrame(shownFrame, display: true)
            let anim = CABasicAnimation(keyPath: "transform.translation")
            anim.fromValue = NSValue(size: from)
            anim.toValue = NSValue(size: shown ? .zero : away)
            anim.duration = (shown ? 0.3 : 0.24) * max(store.look.speed, 0.05)
            anim.timingFunction = shown ? showCurve : hideCurve
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.transform = CATransform3DIdentity
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.slideToken == token else { return }
                    if !self.shown { self.panel.setFrame(hiddenFrame, display: false) }
                    self.host.layer?.removeAnimation(forKey: "slide")
                }
            }
            layer?.add(anim, forKey: "slide")
            CATransaction.commit()
            onLayout(target, anim.duration, anim.timingFunction)
        } else {
            panel.setFrame(target, display: true)
            onLayout(target, 0, nil)
        }
        if store.look.autohide && !shown {
            let strip: NSRect
            switch store.look.edge {
            case .bottom: strip = NSRect(x: target.minX, y: s.minY, width: target.width, height: 3)
            case .left: strip = NSRect(x: s.minX, y: target.minY, width: 3, height: target.height)
            case .right: strip = NSRect(x: s.maxX - 3, y: target.minY, width: 3, height: target.height)
            }
            edge.setFrame(strip, display: false)
            edge.orderFrontRegardless()
        } else {
            edge.orderOut(nil)
        }
        // À mostra com ocultação ligada, sempre há quem confira se o mouse saiu,
        // venha a Dock de onde vier.
        if store.look.autohide && shown && !(watch?.isValid ?? false) {
            startWatching()
        }
    }

    /// Área que conta como "na Dock": a barra mais a fresta até a borda.
    /// Como na Dock do macOS: vale a barra (mais a fresta até a borda). O
    /// espaço acima só conta com ampliação ligada, onde os ícones crescem.
    private var hotZone: NSRect {
        let f = panel.frame
        let s = screen.frame
        let extra = store.look.magnify > 1 ? dockHeadroom(store.look) : 4
        let bar = dockHeadroom(store.look)
        switch store.look.edge {
        case .bottom: return NSRect(x: f.minX, y: s.minY, width: f.width, height: f.maxY - bar + extra - s.minY)
        case .left: return NSRect(x: s.minX, y: f.minY, width: f.maxX - bar + extra - s.minX, height: f.height)
        case .right: return NSRect(x: f.minX + bar - extra, y: f.minY, width: s.maxX - f.minX - bar + extra, height: f.height)
        }
    }

    private var pendingReveal: Timer?

    /// Espera o atraso de "mostrar" do macOS com o mouse na borda.
    private func scheduleReveal() {
        pendingReveal?.invalidate()
        let delay = store.look.revealDelay
        guard delay > 0.01 else {
            reveal()
            return
        }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reveal() }
        }
        RunLoop.main.add(t, forMode: .common)
        pendingReveal = t
    }

    private func reveal() {
        guard store.look.autohide, !shown else { return }
        shown = true
        layout(animated: true)
    }

    /// Enquanto a Dock está revelada, verifica de vez em quando se o mouse
    /// saiu dela. Escondida ou fixa, nada roda.
    private func startWatching() {
        watch?.invalidate()
        // Rápido o bastante para sumir na hora; só roda com a Dock à mostra.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHide() }
        }
        // Modo padrão: não roda com um menu de contexto aberto.
        RunLoop.main.add(t, forMode: .default)
        watch = t
    }

    private func checkHide() {
        guard store.look.autohide, shown else {
            watch?.invalidate()
            return
        }
        if hotZone.contains(NSEvent.mouseLocation) { return }
        // Mouse fora: some na hora, como a Dock do macOS.
        watch?.invalidate()
        shown = false
        layout(animated: true)
    }
}

/// Leva os quadros dos ícones da SwiftUI para o controlador. Guarda o último
/// valor: a primeira medida chega antes de o controlador estar pronto.
private final class FrameRelay {
    private var last: [String: CGRect]?
    var receive: (([String: CGRect]) -> Void)? {
        didSet { if let last { receive?(last) } }
    }
    func send(_ f: [String: CGRect]) {
        last = f
        receive?(f)
    }
}
