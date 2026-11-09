import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let core = Core()
    private var pet: PetController!
    private var notch: NotchController!
    private var usageTimer: Timer?
    private var panel: KeyPanel!
    private var status: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    private var lastStatus: [String: String] = [:]
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ note: Notification) {
        pet = PetController()
        pet.view.onClick = { [weak self] in self?.togglePanel() }
        pet.view.onMenu = { [weak self] event in self?.showMenu(event) }
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
            .sink { [weak self] usage in MainActor.assumeIsolated { self?.notch.model.usage = usage } }
            .store(in: &bag)
        // Mantém o percentual do notch vivo sem acordar o Mac à toa.
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.core.loadUsage(fresh: false) }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer
        core.start()
        if CommandLine.arguments.contains("--abrir-notch") { notch.setExpanded(true) }
        if CommandLine.arguments.contains("--abrir-conversa") { togglePanel() }
    }

    func applicationWillTerminate(_ note: Notification) {
        core.stop()
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

    private func hidePanel() {
        panel.orderOut(nil)
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
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
        let host = NSHostingView(rootView: ChatView(core: core) { [weak self] in self?.hidePanel() })
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.masksToBounds = true
        panel.contentView = host
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
        let pf = pet.window.frame
        let screen = pet.window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? pf
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
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sair da Oficina", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func showMenu(_ event: NSEvent) {
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: pet.view)
    }

    @objc private func openChat() {
        if !panel.isVisible { togglePanel() }
    }

    /// ⌃⌥Espaço abre e fecha a conversa de qualquer lugar.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data -> OSStatus in
            guard let data else { return noErr }
            let d = Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { d.togglePanel() } }
            return noErr
        }, 1, &spec, me, nil)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            EventHotKeyID(signature: OSType(0x4F46_4943), id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
