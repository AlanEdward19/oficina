import AppKit
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

/// Ambientes, apps fixados e apps abertos. Tudo muda por eventos do sistema:
/// nada fica verificando em ciclo.
@MainActor
final class DockStore: ObservableObject {
    @Published private(set) var envs: [DockEnv]
    @Published private(set) var active: Int
    @Published private(set) var runningIDs: [String] = []
    @Published var usage: UsageData?
    var openChat: () -> Void = {}

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

    var others: [DockApp] {
        runningIDs.filter { !current.apps.contains($0) }.map(item)
    }

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

    private func name(_ id: String) -> String {
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
        let symbol = symbols[envs.count % symbols.count]
        envs.append(DockEnv(id: UUID().uuidString, name: name, symbol: symbol, apps: [finder]))
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

// MARK: Interface

private let iconSize: CGFloat = 46
/// Espaço livre acima da barra para o ícone ampliado e o nome do app.
let dockHeadroom: CGFloat = 46

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

struct DockView: View {
    @ObservedObject var store: DockStore
    @ObservedObject var pointer: DockPointer
    let askName: (_ title: String, _ initial: String, _ done: @escaping (String) -> Void) -> Void
    @State private var frames: [String: CGRect] = [:]

    private var hovered: String? {
        guard let p = pointer.location, p.y >= dockHeadroom else { return nil }
        return frames.first { $0.value.minX - 4 <= p.x && p.x <= $0.value.maxX + 4 }?.key
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Glass().clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .padding(.top, dockHeadroom)
        .fixedSize()
        .coordinateSpace(name: "dock")
        .onPreferenceChange(IconFrames.self) { frames = $0 }
        .environment(\.colorScheme, .dark)
    }

    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: iconSize - 8).padding(.bottom, 4)
    }

    private func icon(_ app: DockApp) -> some View {
        let isHovered = hovered == app.id
        return Button { store.open(app.id) } label: {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .background(GeometryReader { g in
                    Color.clear.preference(key: IconFrames.self, value: [app.id: g.frame(in: .named("dock"))])
                })
                .scaleEffect(isHovered ? 1.3 : 1, anchor: .bottom)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Circle().fill(Color.white.opacity(0.85)).frame(width: 4, height: 4).offset(y: 6).opacity(app.running ? 1 : 0)
        }
        .overlay(alignment: .top) {
            if isHovered {
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .fixedSize()
                    .offset(y: -40)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(app.running ? "\(app.name), aberto" : app.name)
        .contextMenu { menu(for: app) }
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
            HStack(spacing: 2) {
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
            Text(store.current.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
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
        HStack(alignment: .center, spacing: 12) {
            if let session = store.usage?.limits.first(where: { $0.kind == "session" }) {
                UsageRing(percent: session.percent)
            }
            TimelineView(.everyMinute) { ctx in
                VStack(spacing: 0) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                    Text(ctx.date, format: .dateTime.weekday(.abbreviated).day())
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .foregroundStyle(.white)
            }
            Button(action: store.openChat) {
                FaiscaAvatar(size: 34, mood: .idle)
            }
            .buttonStyle(.plain)
            .help("Conversar com a Faísca")
            .accessibilityLabel("Conversar com a Faísca")
        }
        .frame(height: iconSize)
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

private final class TrackingHost<Content: View>: NSHostingView<Content> {
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
    private var hideTimer: Timer?
    private var bag: [NSObjectProtocol] = []

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "dockEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dockEnabled"); apply() }
    }

    /// Ainda fora do menu: a revelação pela borda disputa espaço com a Dock do
    /// macOS e não pôde ser verificada. Volta junto com essa decisão.
    var autoHide: Bool {
        get { UserDefaults.standard.bool(forKey: "dockAutoHide") }
        set { UserDefaults.standard.set(newValue, forKey: "dockAutoHide"); shown = !newValue; apply() }
    }

    init(store: DockStore, askName: @escaping (String, String, @escaping (String) -> Void) -> Void) {
        self.store = store
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        host = TrackingHost(rootView: DockView(store: store, pointer: pointer, askName: askName))
        panel.contentView = host

        // Faixa invisível na borda inferior que revela a Dock oculta.
        edge = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        edge.isOpaque = false
        edge.backgroundColor = NSColor(white: 1, alpha: 0.02)
        edge.hasShadow = false
        edge.level = .floating
        edge.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let edgeView = TrackingHost(rootView: Color.clear)
        edge.contentView = edgeView

        shown = !autoHide
        host.onHover = { [weak self] inside in self?.hover(inside) }
        host.onMove = { [weak self] p in
            if self?.pointer.location != p { self?.pointer.location = p }
        }
        edgeView.onHover = { [weak self] inside in if inside { self?.reveal() } }
        bag.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.layout(animated: false) } })
        storeChanged = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.layout(animated: false) } }
        }
        apply()
    }

    private var storeChanged: Any?

    /// Faixa horizontal ocupada pela Dock, para o pet não passear por cima.
    var occupiedX: ClosedRange<CGFloat>? {
        guard enabled, shown else { return nil }
        return panel.frame.minX...panel.frame.maxX
    }

    private func apply() {
        if enabled {
            panel.orderFrontRegardless()
            layout(animated: false)
        } else {
            panel.orderOut(nil)
            edge.orderOut(nil)
        }
    }

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private func layout(animated: Bool) {
        guard enabled else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let frame = screen.frame
        let y = shown ? frame.minY + 6 : frame.minY - size.height - 2
        let target = NSRect(x: frame.midX - size.width / 2, y: y, width: size.width, height: size.height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        if autoHide && !shown {
            edge.setFrame(NSRect(x: target.minX, y: frame.minY, width: target.width, height: 3), display: false)
            edge.orderFrontRegardless()
        } else {
            edge.orderOut(nil)
        }
    }

    private func reveal() {
        guard autoHide, !shown else { return }
        shown = true
        layout(animated: true)
    }

    private func hover(_ inside: Bool) {
        hideTimer?.invalidate()
        guard autoHide, !inside else { return }
        // Timer no modo padrão: não dispara com um menu de contexto aberto.
        let t = Timer(timeInterval: 0.7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.shown = false
                self.layout(animated: true)
            }
        }
        RunLoop.main.add(t, forMode: .default)
        hideTimer = t
    }
}
