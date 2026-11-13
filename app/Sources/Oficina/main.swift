import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let core = Core()
    private var pet: PetController!
    private var notch: NotchController!
    private var dock: DockController!
    private var bubble: BubbleController!
    private var mindPanel: NSPanel?
    private var toolWindows: [String: NSWindow] = [:]
    private var presenceTimer: Timer?
    private var usageTimer: Timer?
    private var panel: KeyPanel!
    private var status: NSStatusItem!
    private var popover: NSPopover?
    private var bag = Set<AnyCancellable>()
    private var lastStatus: [String: String] = [:]
    private var hotKey: EventHotKeyRef?
    private var clipKey: EventHotKeyRef?
    let tools = Tools()
    private let calls = CallWatcher()
    private let agenda = Agenda()
    private var deviceVoice: DeviceVoice!
    private var listener: CallListener!

    func applicationDidFinishLaunching(_ note: Notification) {
        if CommandLine.arguments.contains("--testar-dock-sistema") {
            SystemDock.selfTest()
            exit(0)
        }
        pet = PetController()
        pet.view.onClick = { [weak self] in
            self?.core.mindEvents([["kind": "pet_click"]])
            self?.pet.wakeUp()
            self?.togglePanel()
        }
        pet.onEvent = { [weak self] kind in self?.core.mindEvents([["kind": kind]]) }
        bubble = BubbleController(anchor: pet.window)
        bubble.model.answer = { [weak self] initiative, accepted in self?.answer(initiative, accepted) }
        bubble.model.never = { [weak self] initiative in
            self?.bubble.ask(nil)
            self?.core.never(initiative.id)
        }
        pet.busy = { [weak self] in self?.bubble.model.initiative != nil }
        pet.view.onMenu = { [weak self] event in self?.showMenu(event) }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Oficina")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dockStore = DockStore(home: home)
        dockStore.openChat = { [weak self] in self?.openChat() }
        dock = DockController(store: dockStore) { [weak self] title, initial, done in self?.askName(title, initial, done) }
        wirePetToDock()
        notch = NotchController()
        notch.model.act = { [weak self] id, action in self?.core.act(id, action) }
        notch.model.openChat = { [weak self] in
            self?.notch.setExpanded(false)
            self?.openChat()
        }
        notch.onExpand = { [weak self] in self?.core.loadUsage(fresh: true) }
        buildPanel()
        buildStatusItem()
        registerHotKey()
        tools.restoreOnLaunch()
        tools.onToast = { [weak self] in self?.pet.say($0) }

        lastStatus = [:]
        core.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] tasks in MainActor.assumeIsolated { self?.tasksChanged(tasks) } }
            .store(in: &bag)
        core.$usage
            .receive(on: RunLoop.main)
            .sink { [weak self] usage in
                MainActor.assumeIsolated {
                    self?.notch.model.usage = usage
                    self?.dock.store.usage = usage
                }
            }
            .store(in: &bag)
        // Mantém o percentual do notch vivo sem acordar o Mac à toa.
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.core.loadUsage(fresh: false) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer
        core.$settings
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] s in
                MainActor.assumeIsolated {
                    FaiscaAvatar.bodyColor = colorFromHex(s.body_color)
                    AppDelegate.bodyHex = s.body_color
                    FaiscaAvatar.sparkColor = colorFromHex(s.spark_color)
                    self?.pet.figure.customize(s)
                    self?.mindPanel?.title = "Mente de \(s.name)"
                }
            }
            .store(in: &bag)
        core.$mind
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] brief in MainActor.assumeIsolated { self?.mindChanged(brief) } }
            .store(in: &bag)
        watchPresence()
        watchCalls()
        watchPresence2()
        core.start()
        if CommandLine.arguments.contains("--abrir-mente") { openMind() }
        if CommandLine.arguments.contains("--abrir-fabrica") {
            // Só para teste visual: abre como no uso normal, com o app já iniciado.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.openFactory() }
        }
        if CommandLine.arguments.contains("--abrir-limpeza") { openCleaner() }
        if CommandLine.arguments.contains("--abrir-hardware") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.openHardware() } }
        if CommandLine.arguments.contains("--abrir-reunioes") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.openMeetings() } }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--abrir-barra") }) {
            if let tab = arg.split(separator: "=").dropFirst().first { tools.tab = String(tab) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showBarPanel() }
        }
        if CommandLine.arguments.contains("--abrir-personalizar") {
            // Só para teste visual: espera os ajustes chegarem do core.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.openPersonalize() }
        }
        if CommandLine.arguments.contains("--dormir") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.pet.comeOut { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.pet.putToBed() } }
            }
        }
        if CommandLine.arguments.contains("--visitar-dock") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let id = self.dock.store.allIDs.dropFirst().first else { return }
                self.pet.visit(id)
            }
        }
        if CommandLine.arguments.contains("--abrir-notch") { notch.setExpanded(true) }
        // Só para teste visual: abre uma conversa específica.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--conversa=") }) { core.select(String(arg.dropFirst(11))) }
        if CommandLine.arguments.contains("--abrir-conversa") { togglePanel() }
    }

    func applicationWillTerminate(_ note: Notification) {
        // A Dock do macOS volta enquanto a Oficina estiver fechada.
        SystemDock.restore(keepChoice: true)
        core.stop()
    }

    // MARK: Faísca e Dock

    private func wirePetToDock() {
        pet.shelf = { [weak self] in self?.dock.shelf }
        pet.homeScale = { [weak self] in
            let tile = self?.dock.store.look.tile ?? 48
            return min(0.9, max(0.5, (tile + 4) / 74))
        }
        pet.homeFrame = { [weak self] in self?.dock.petHome }
        pet.dockVisible = { [weak self] in self?.dock.visible ?? false }
        pet.setHomeOpen = { [weak self] open in
            if self?.dock.store.homeOpen != open { self?.dock.store.homeOpen = open }
        }
        pet.dockFrame = { [weak self] in self?.dock.visible == true ? self?.dock.frame : nil }
        pet.iconX = { [weak self] id in self?.dock.iconX(id) }
        pet.randomIcon = { [weak self] in self?.dock.store.allIDs.randomElement() }
        pet.nudge = { [weak self] id in self?.dock.store.nudge(id) }
        dock.onLayout = { [weak self] target, duration, curve in
            guard let self else { return }
            self.pet.dockMoved(home: self.dock.petHome(for: target), duration: duration, curve: curve)
        }
        pet.onMoveStart = { [weak self] in self?.bubble.hideForMove() }
        pet.nearDock = { [weak self] in self?.dock.revealNow() }
        dock.keepOpen = { [weak self] in
            guard let pet = self?.pet else { return false }
            return pet.dragging || pet.holdsDock
        }
        pet.onRest = { [weak self] secs in self?.core.mindEvents([["kind": "pet_rest", "secs": secs]]) }
        // Ao acordar, se ainda houver uma pergunta guardada, ela faz agora.
        pet.onWake = { [weak self] in
            guard let self, let i = self.core.mind?.initiative else { return }
            self.present(i)
        }
        pet.onMoveEnd = { [weak self] in self?.bubble.showAfterMove() }
        dock.store.onOpen = { [weak self] id in
            self?.core.mindEvents([["kind": "dock_open", "bundle": id]])
            self?.pet.appOpened(id)
        }
        dock.store.onSwitch = { [weak self] env in
            self?.core.mindEvents([["kind": "env_switch", "name": env.name]])
            self?.pet.environmentChanged()
        }
        // Começa sentada em casa, assim que a Dock souber onde fica a casa.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.pet.startAtHome() }
    }

    // MARK: Mente

    /// Conta à mente o app em foco e, a cada minuto, se você está por perto.
    /// Só nomes de apps e tempo parado: nunca títulos de janela ou conteúdo.
    private func watchPresence() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
            let name = app.localizedName ?? id
            MainActor.assumeIsolated { self?.core.mindEvents([["kind": "app_focus", "bundle": id, "name": name]]) }
        }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportPresence() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        presenceTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reportPresence(includeFocus: true) }
    }

    // MARK: Presença única

    private func watchPresence2() {
        deviceVoice = DeviceVoice(core: core)
        core.onVoice = { [weak self] job in self?.deviceVoice.handle(job) }
        core.$presence
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] p in MainActor.assumeIsolated { self?.presenceChanged(p) } }
            .store(in: &bag)
    }

    private var lastPresence: PresenceData?

    private func presenceChanged(_ p: PresenceData?) {
        guard let p else { return }
        defer { lastPresence = p }
        guard p.away != (lastPresence?.away ?? false) else { return }
        if p.away {
            // Avisa e sai: ela está na caixa de som agora.
            pet.say("Fui à \(p.room).", force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard self?.core.presence?.away == true else { return }
                self?.pet.setAway(true)
            }
        } else {
            pet.setAway(false)
            pet.comeOut()
        }
    }

    @objc private func callBackNow() {
        Task { _ = await core.callPresence(force: true) }
    }

    @objc private func openDevices() {
        openTool("dispositivos", title: "Dispositivos", size: NSSize(width: 680, height: 600), DevicesView(core: core, tint: colorFromHex(core.settings.body_color)))
    }

    // MARK: Chamadas

    /// Percebe chamadas pelo microfone e, se você deixar, ouve e anota.
    private func watchCalls() {
        listener = CallListener(core: core)
        listener.onChange = { [weak self] on in
            guard let self else { return }
            self.pet.wear(on ? Self.withHeadset(self.lastBrief?.outfit) : self.lastBrief?.outfit)
        }
        calls.onStart = { [weak self] app in
            self?.core.mindEvents([["kind": "call_start", "bundle": app.bundle, "name": app.name]])
        }
        calls.onEnd = { [weak self] _ in
            self?.core.mindEvents([["kind": "call_end"]])
            if self?.listener.active == true {
                self?.listener.stop()
                self?.pet.say("A chamada acabou. Guardei as anotações.", force: true)
            }
        }
        calls.start()
        agenda.onEvents = { [weak self] events in self?.core.mindEvents(events) }
        // Espera o core conectar antes da primeira leitura.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.agenda.start() }
    }

    @objc private func toggleAgenda() {
        let on = !agenda.enabled
        Task {
            let ok = await agenda.setEnabled(on)
            if on {
                pet.say(ok ? "Agora eu vejo os horários da sua agenda. Te aviso antes das reuniões." : "Sem acesso ao Calendário. Dá para liberar em Ajustes do Sistema > Privacidade.", force: true)
            }
        }
    }

    /// Enquanto ouve, ela usa fones: dá para ver de longe que está ouvindo.
    private static func withHeadset(_ o: OutfitData?) -> OutfitData {
        let none = OutfitPiece(shape: "none", color: "#333333")
        return OutfitData(
            id: "ouvindo", name: o?.name ?? "Ouvindo", theme: o?.theme ?? "", body: o?.body ?? AppDelegate.bodyHex,
            head: OutfitPiece(shape: "headset", color: "#222222"),
            face: o?.face ?? none, neck: o?.neck ?? none,
            badge: OutfitPiece(shape: "REC", color: "#E5484D"), prop: o?.prop ?? "none"
        )
    }

    private static var bodyHex = "#FF9E29"

    private func listen(_ i: InitiativeData) {
        guard let app = calls.current else {
            pet.say("A chamada já acabou.", force: true)
            return
        }
        let processes = calls.processObjects(of: app)
        Task {
            if let note = await listener.start(app: app, processes: processes, title: agenda.current() ?? "") {
                pet.say(note, force: true)
            } else {
                pet.say("Tô ouvindo e anotando. Para parar, clique com o botão direito em mim.", force: true)
            }
        }
    }

    @objc private func stopListening() {
        listener.stop()
        pet.say("Parei de ouvir.", force: true)
    }

    private func reportPresence(includeFocus: Bool = false) {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
        var events: [[String: Any]] = [["kind": "presence", "idle": idle, "running": running]]
        if includeFocus, let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            events.append(["kind": "app_focus", "bundle": id, "name": app.localizedName ?? id])
        }
        core.mindEvents(events)
        dock.syncSystemSettings()
    }

    private var lastBrief: MindBrief?

    private func mindChanged(_ brief: MindBrief?) {
        guard let brief else { return }
        defer { lastBrief = brief }
        pet.setMind(brief.mood, sleeping: brief.sleeping)
        if brief.outfit != lastBrief?.outfit { pet.wear(listener?.active == true ? Self.withHeadset(brief.outfit) : brief.outfit) }
        if let d = brief.decor, d != lastBrief?.decor { pet.figure.setDecor(d) }
        if brief.initiative != lastBrief?.initiative {
            if let i = brief.initiative {
                // Descansando, a pergunta espera ela acordar.
                if !pet.resting { present(i) }
            } else {
                bubble.ask(nil)
            }
        }
        if let t = brief.thought, t != lastBrief?.thought, lastBrief != nil, pet.away {
            // Longe, os recados chegam num balão sem ela.
            bubble.note("\(core.settings.name), na \(core.presence?.room ?? "sala"): \(t.text)")
        } else if let t = brief.thought, t != lastBrief?.thought, lastBrief != nil, !brief.sleeping, brief.mood != "focada" {
            let important = t.text.hasPrefix("Olha minha") || t.text.hasPrefix("Anotado") || t.text.hasPrefix("Modo ")
            pet.say(t.text, force: important)
        }
    }

    /// Para perguntar, ela precisa estar à vista: sai de baixo da borda.
    private func present(_ i: InitiativeData) {
        if pet.hiddenAtHome {
            pet.comeOut { [weak self] in self?.bubble.ask(i) }
        } else {
            bubble.ask(i)
        }
    }

    private func answer(_ initiative: InitiativeData, _ accepted: Bool) {
        bubble.ask(nil)
        Task {
            guard let done = await core.answer(initiative.id, accept: accepted), accepted else { return }
            switch done.action.type {
            case "open_app":
                if let id = done.action.bundle { dock.store.open(id) }
            case "chat":
                openChat()
            case "outfit":
                pet.say("Já volto com a roupa nova!", force: true)
            case "task":
                pet.say("Mandei um agente pesquisar. Te aviso.", force: true)
            case "listen":
                listen(done)
            case "summarize":
                pet.say("Resumindo a reunião. O resumo aparece no chat.", force: true)
            default:
                break
            }
        }
    }

    @objc private func openMind() {
        if let p = mindPanel {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = "Mente de \(core.settings.name)"
        p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: MindView(core: core))
        p.center()
        mindPanel = p
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            // Fechar libera a tela, que para de consultar a mente.
            MainActor.assumeIsolated { self?.mindPanel = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    /// Janela da Oficina: desenha até a borda e existe só enquanto está aberta.
    private func openTool<V: View>(_ key: String, title: String, size: NSSize, _ view: V) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = toolWindows[key] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = loc(title)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.setContentSize(size)
        w.center()
        toolWindows[key] = w
        // Sem foco automático: senão o formulário rola e corta o topo.
        DispatchQueue.main.async { w.makeFirstResponder(nil) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toolWindows[key] = nil }
        }
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func openPersonalize() {
        openTool("personalizar", title: "Personalizar", size: NSSize(width: 880, height: 640), PersonalizeView(core: core))
    }

    @objc private func openFactory() {
        openTool("fabrica", title: "Fábrica", size: NSSize(width: 920, height: 640), FactoryView(core: core) { [weak self] conv in
            self?.core.select(conv)
            self?.openChat()
        })
    }

    @objc private func openMeetings() {
        openTool("reunioes", title: "Reuniões", size: NSSize(width: 860, height: 600), MeetingsView(core: core, tint: colorFromHex(core.settings.body_color)))
    }

    @objc private func openHardware() {
        openTool("hardware", title: "Oficina de hardware", size: NSSize(width: 1040, height: 680), HardwareView(core: core, tint: colorFromHex(core.settings.body_color)) { [weak self] conv in
            self?.core.select(conv)
            self?.openChat()
        })
    }

    @objc private func openCleaner() {
        openTool("limpeza", title: "Limpeza do Disco", size: NSSize(width: 860, height: 600), CleanView(core: core))
    }

    @objc private func openTools() { showBarPanel() }

    func openClipboard() {
        tools.tab = "clipboard"
        showBarPanel()
    }

    @objc private func suggestNow() { core.suggest() }
    @objc private func putToBed() { pet.putToBed() }

    /// Formulário curto: tipo, pedido e se um agente deve implementar.
    @objc private func askImprovement() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pedir melhoria"
        alert.informativeText = "Vira uma issue pública no GitHub da Oficina."
        alert.addButton(withTitle: "Abrir issue")
        alert.addButton(withTitle: "Cancelar")
        let kinds = [("Funcionalidade", "funcionalidade"), ("Widget da Dock", "widget"), ("Roupinha", "roupa"), ("Casinha", "casa"), ("Problema", "bug")]
        let kind = NSPopUpButton(frame: .zero, pullsDown: false)
        kind.addItems(withTitles: kinds.map(\.0))
        let text = NSTextField(string: "")
        text.placeholderString = "O que você quer? Ex.: widget de clima na Dock"
        let agent = NSButton(checkboxWithTitle: "Um agente do Claude implementa e abre um pull request", target: nil, action: nil)
        agent.state = .on
        let stack = NSStackView(views: [kind, text, agent])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 86)
        text.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        core.sendRequest(kind: kinds[kind.indexOfSelectedItem].1, text: value, agent: agent.state == .on)
        openChat()
    }

    private func tasksChanged(_ tasks: [TaskItem]) {
        var finished: String?
        var changedStatus = lastStatus.count != tasks.count
        for t in tasks where lastStatus[t.id] != t.status {
            changedStatus = true
            if lastStatus[t.id] != nil, t.status == "done" || t.status == "failed" {
                finished = t.status
            }
            lastStatus[t.id] = t.status
        }
        // Texto em streaming não muda o humor: evita trabalho por token.
        guard changedStatus else { return }
        pet.update(tasks: tasks, finished: finished)
        notch.model.tasks = Array(
            tasks.reversed().sorted { rank($0) < rank($1) }.prefix(3)
        )
    }

    /// Primeiro o que precisa de você, depois o que está rodando.
    private func rank(_ t: TaskItem) -> Int {
        t.status == "awaiting_approval" ? 0 : t.isActive ? 1 : 2
    }

    private var clickMonitors: [Any] = []

    private var releaseChat: DispatchWorkItem?

    private func hidePanel() {
        panel.orderOut(nil)
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        // Fechada por um minuto, a tela da conversa sai da memória.
        releaseChat?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.panel.contentView = nil
        }
        releaseChat = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    /// A tela da conversa só existe enquanto é usada.
    private func ensureChatView() {
        releaseChat?.cancel()
        guard panel.contentView == nil || !(panel.contentView is NSHostingView<ChatView>) else { return }
        let host = NSHostingView(rootView: ChatView(core: core) { [weak self] in self?.hidePanel() })
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true
        panel.contentView = host
    }

    /// Fecha a conversa quando o clique acontece fora dela. Os monitores só
    /// existem enquanto a janela está aberta.
    private func watchOutsideClicks() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                // A própria Faísca já alterna a conversa no clique.
                if let self, event.window !== self.panel, event.window !== self.pet.window {
                    self.hidePanel()
                }
            }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func buildPanel() {
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 580),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Trocar de app pelo teclado também fecha.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
    }

    private func togglePanel() {
        if panel.isVisible {
            hidePanel()
            return
        }
        ensureChatView()
        let pf = pet.frame
        let screen = NSScreen.screens.first?.visibleFrame ?? NSScreen.main?.visibleFrame ?? pf
        var x = pf.midX - panel.frame.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - panel.frame.width - 8)
        var y = pf.maxY + 8
        if y + panel.frame.height > screen.maxY { y = max(pf.minY - panel.frame.height - 8, screen.minY + 8) }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        watchOutsideClicks()
    }

    private func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Oficina")
        status.button?.target = self
        status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Clique abre o painel; botão direito abre o menu, como nos itens do sistema.
    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            status.menu = makeMenu()
            status.button?.performClick(nil)
            status.menu = nil
        } else if popover != nil {
            popover?.performClose(nil)
        } else {
            showBarPanel()
        }
    }

    /// O painel só existe enquanto está aberto.
    private func showBarPanel() {
        guard popover == nil, let button = status.button else { return }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.hasFullSizeContent = true
        p.contentViewController = NSHostingController(rootView: MenuBarPanel(tools: tools, tint: colorFromHex(core.settings.body_color), openCleaner: { [weak self] in self?.openCleaner() }, close: { [weak self] in self?.popover?.performClose(nil) }))
        popover = p
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) { popover = nil }

    /// O menu da Faísca (botão direito nela ou no ícone da barra): ela no topo,
    /// depois o que fazer agora, onde ela está, a Oficina e os ajustes.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let name = core.settings.name
        let tint = colorFromHex(core.settings.body_color)
        let p = core.presence
        let listening = listener?.active == true
        let place = p?.away == true ? "Na \(p?.room ?? "")" : "No Mac, com você"
        let status: String? = listening ? "Ouvindo a chamada" : core.mind?.call.map { "Em chamada no \($0)" }
        menu.addItem(menuHeader(MenuHeader(name: name, mood: core.mind?.mood ?? "", sleeping: core.mind?.sleeping ?? false,
                                           place: place, status: status, listening: listening, tint: tint)))
        menu.addItem(.separator())

        menu.addItem(menuItem("Conversar", "bubble.left.and.bubble.right", self, #selector(openChat), key: " ", modifiers: [.control, .option]))
        menu.addItem(menuItem("Me sugere algo", "sparkles", self, #selector(suggestNow)))
        if listening {
            menu.addItem(menuItem("Parar de ouvir a chamada", "stop.circle", self, #selector(stopListening)))
        }
        if p?.away == true {
            menu.addItem(menuItem("Chamar de volta agora", "arrow.uturn.backward.circle", self, #selector(callBackNow)))
        }

        menu.addItem(.separator())
        menu.addItem(menuSection("Onde ela está"))
        let go = menuItem("Ir para", "location", self, #selector(noop))
        let goMenu = NSMenu()
        let mac = menuItem("Mac", "laptopcomputer", self, #selector(goTo(_:)), on: p?.away != true)
        mac.representedObject = "casa"
        goMenu.addItem(mac)
        for b in p?.bodies ?? [] {
            let item = menuItem(b.room, "hifispeaker", self, #selector(goTo(_:)), on: p?.holder == b.id)
            item.representedObject = b.id
            item.isEnabled = b.online
            if !b.online { item.title = "\(b.room) (desligada)" }
            goMenu.addItem(item)
        }
        go.submenu = goMenu
        go.action = nil
        menu.addItem(go)
        menu.addItem(menuItem("Dispositivos…", "hifispeaker.2", self, #selector(openDevices)))
        menu.addItem(menuItem("Reuniões…", "text.bubble", self, #selector(openMeetings)))

        menu.addItem(.separator())
        menu.addItem(menuSection("Oficina"))
        menu.addItem(menuItem("Fábrica de agentes…", "person.3", self, #selector(openFactory)))
        menu.addItem(menuItem("Oficina de hardware…", "cpu", self, #selector(openHardware)))
        menu.addItem(menuItem("Limpeza do Disco…", "externaldrive", self, #selector(openCleaner)))
        menu.addItem(menuItem("Painel da barra de menus", "menubar.rectangle", self, #selector(openTools)))

        menu.addItem(.separator())
        menu.addItem(menuSection(name))
        menu.addItem(menuItem("Mente de \(name)…", "brain", self, #selector(openMind)))
        menu.addItem(menuItem("Personalizar…", "paintpalette", self, #selector(openPersonalize)))
        menu.addItem(menuItem("Colocar para dormir", "moon.zzz", self, #selector(putToBed)))
        menu.addItem(menuItem("Usar a agenda", "calendar", self, #selector(toggleAgenda), on: agenda.enabled))
        let dockItem = menuItem("Dock", "dock.rectangle", self, #selector(noop))
        dockItem.action = nil
        let dockMenu = NSMenu()
        dockMenu.addItem(menuItem("Mostrar Dock", "eye", self, #selector(toggleDock), on: dock.enabled))
        dockMenu.addItem(menuItem("Substituir a Dock do macOS", "rectangle.2.swap", self, #selector(toggleReplace), on: dock.replacingSystemDock))
        dockMenu.addItem(.separator())
        dockMenu.addItem(menuSection("Ambientes"))
        for (i, env) in dock.store.envs.enumerated() {
            let item = menuItem(env.title, "square.grid.2x2", self, #selector(pickEnvironment(_:)), key: i < 9 ? "\(i + 1)" : "",
                                modifiers: [.control, .option], on: i == dock.store.active, tag: i)
            dockMenu.addItem(item)
        }
        dockItem.submenu = dockMenu
        menu.addItem(dockItem)

        menu.addItem(.separator())
        menu.addItem(menuItem("Pedir melhoria…", "lightbulb", self, #selector(askImprovement)))
        let quit = NSMenuItem(title: "Sair da Oficina", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
        return menu
    }

    @objc private func noop() {}

    @objc private func goTo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id == "casa" {
            Task { _ = await core.callPresence(force: true) }
        } else {
            Task { _ = await core.movePresence(to: id, text: "Oi! Cheguei.") }
        }
    }

    private func showMenu(_ event: NSEvent) {
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: pet.view)
    }

    @objc private func toggleDock() { dock.enabled.toggle() }
    @objc private func toggleReplace() { dock.replacingSystemDock.toggle() }
    @objc private func pickEnvironment(_ sender: NSMenuItem) { dock.store.switchTo(sender.tag) }

    func askName(_ title: String, _ initial: String, _ done: @escaping (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: tr("Cancelar"))
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { done(String(name.prefix(24))) }
    }

    @objc private func openChat() {
        if !panel.isVisible { togglePanel() }
        // Ela está em outro cômodo: abrir a conversa é chamá-la (pesando a conversa de lá).
        if core.presence?.away == true {
            Task { _ = await core.callPresence(force: false) }
        }
    }

    /// ⌃⌥Espaço abre e fecha a conversa de qualquer lugar.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data -> OSStatus in
            guard let data, let event else { return noErr }
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let d = Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
            let id = Int(key.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if id == 1 { d.togglePanel() } else if let s = Snap(rawValue: UInt32(id)) { d.tools.snap(s) } else if id == 9 { d.openClipboard() } else if id >= 11 { d.dock.store.switchTo(id - 11) }
                }
            }
            return noErr
        }, 1, &spec, me, nil)
        let signature = OSType(0x4F46_4943)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: signature, id: 9), GetApplicationEventTarget(), 0, &clipKey)
        // ⌃⌥1…9 trocam de ambiente da Dock.
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, code) in digits.enumerated() {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey),
                                EventHotKeyID(signature: signature, id: UInt32(11 + i)), GetApplicationEventTarget(), 0, &ref)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
