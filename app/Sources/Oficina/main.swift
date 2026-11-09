import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let core = Core()
    private var pet: PetController!
    private var notch: NotchController!
    private var dock: DockController!
    private var bubble: BubbleController!
    private var mindPanel: NSPanel?
    private var toolPanels: [String: NSPanel] = [:]
    private var presenceTimer: Timer?
    private var usageTimer: Timer?
    private var panel: KeyPanel!
    private var status: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    private var lastStatus: [String: String] = [:]
    private var hotKey: EventHotKeyRef?

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
        core.start()
        if CommandLine.arguments.contains("--abrir-mente") { openMind() }
        if CommandLine.arguments.contains("--abrir-fabrica") { openFactory() }
        if CommandLine.arguments.contains("--abrir-personalizar") { openPersonalize() }
        if CommandLine.arguments.contains("--dormir") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.pet.comeOut { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.pet.putToBed() } }
            }
        }
        if CommandLine.arguments.contains("--visitar-dock") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let id = self.dock.store.allIDs.dropFirst().first else { return }
                self.pet.appOpened(id)
            }
        }
        if CommandLine.arguments.contains("--abrir-notch") { notch.setExpanded(true) }
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
        if brief.outfit != lastBrief?.outfit { pet.wear(brief.outfit) }
        if let d = brief.decor, d != lastBrief?.decor { pet.figure.setDecor(d) }
        if brief.initiative != lastBrief?.initiative {
            if let i = brief.initiative {
                // Descansando, a pergunta espera ela acordar.
                if !pet.resting { present(i) }
            } else {
                bubble.ask(nil)
            }
        }
        if let t = brief.thought, t != lastBrief?.thought, lastBrief != nil, !brief.sleeping, brief.mood != "focada" {
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

    /// Janela de ferramenta: existe só enquanto está aberta.
    private func openTool<V: View>(_ key: String, title: String, size: NSSize, _ view: V) {
        if let p = toolPanels[key] {
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
            return
        }
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = title
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: view)
        p.center()
        toolPanels[key] = p
        // Sem foco automático: senão o formulário rola e corta o topo.
        DispatchQueue.main.async { p.makeFirstResponder(nil) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toolPanels[key] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    @objc private func openPersonalize() {
        openTool("personalizar", title: "Personalizar", size: NSSize(width: 540, height: 780), PersonalizeView(core: core))
    }

    @objc private func openFactory() {
        openTool("fabrica", title: "Fábrica de agentes", size: NSSize(width: 720, height: 720), FactoryView(core: core) { [weak self] conv in
            self?.core.select(conv)
            self?.openChat()
        })
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
        host.layer?.cornerRadius = 16
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
        status.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let chat = NSMenuItem(title: "Conversar", action: #selector(openChat), keyEquivalent: " ")
        chat.keyEquivalentModifierMask = [.control, .option]
        chat.target = self
        menu.addItem(chat)
        let ask = NSMenuItem(title: "Pedir melhoria…", action: #selector(askImprovement), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)
        let bed = NSMenuItem(title: "Colocar para dormir", action: #selector(putToBed), keyEquivalent: "")
        bed.target = self
        menu.addItem(bed)
        let factory = NSMenuItem(title: "Fábrica de agentes…", action: #selector(openFactory), keyEquivalent: "")
        factory.target = self
        menu.addItem(factory)
        let personalize = NSMenuItem(title: "Personalizar…", action: #selector(openPersonalize), keyEquivalent: "")
        personalize.target = self
        menu.addItem(personalize)
        let mind = NSMenuItem(title: "Mente de \(core.settings.name)…", action: #selector(openMind), keyEquivalent: "")
        mind.target = self
        menu.addItem(mind)
        let suggest = NSMenuItem(title: "Me sugere algo", action: #selector(suggestNow), keyEquivalent: "")
        suggest.target = self
        menu.addItem(suggest)
        let dockItem = NSMenuItem(title: "Dock", action: nil, keyEquivalent: "")
        let dockMenu = NSMenu()
        let showDock = NSMenuItem(title: "Mostrar Dock", action: #selector(toggleDock), keyEquivalent: "")
        showDock.target = self
        showDock.state = dock.enabled ? .on : .off
        dockMenu.addItem(showDock)
        let replace = NSMenuItem(title: "Substituir a Dock do macOS", action: #selector(toggleReplace), keyEquivalent: "")
        replace.target = self
        replace.state = dock.replacingSystemDock ? .on : .off
        dockMenu.addItem(replace)
        dockMenu.addItem(.separator())
        for (i, env) in dock.store.envs.enumerated() {
            let item = NSMenuItem(title: env.name, action: #selector(pickEnvironment(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
            item.tag = i
            item.state = i == dock.store.active ? .on : .off
            dockMenu.addItem(item)
        }
        dockItem.submenu = dockMenu
        menu.addItem(dockItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sair da Oficina", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
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
        alert.addButton(withTitle: "Cancelar")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = "Nome do ambiente"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { done(String(name.prefix(24))) }
    }

    @objc private func openChat() {
        if !panel.isVisible { togglePanel() }
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
                    if id == 1 { d.togglePanel() } else if id >= 11 { d.dock.store.switchTo(id - 11) }
                }
            }
            return noErr
        }, 1, &spec, me, nil)
        let signature = OSType(0x4F46_4943)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
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
