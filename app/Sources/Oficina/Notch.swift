import AppKit
import SwiftUI

/// Só muda quando há algo novo para mostrar: texto em streaming não passa
/// por aqui, então o notch não redesenha a cada token.
@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var tasks: [TaskItem] = []
    @Published var usage: UsageData?
    var act: (String, String) -> Void = { _, _ in }
    var openChat: () -> Void = {}
}

struct NotchMetrics {
    var notchWidth: CGFloat
    var height: CGFloat
    var wing: CGFloat = 54
    var shoulder: CGFloat = 8
    var collapsedWidth: CGFloat { notchWidth + wing * 2 + shoulder * 2 }
    static let expanded = CGSize(width: 520, height: 262)
}

private struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { (top, bottom) = (newValue.first, newValue.second) }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let (w, h) = (r.width, r.height)
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: top, y: top), control: CGPoint(x: top, y: 0))
        p.addLine(to: CGPoint(x: top, y: h - bottom))
        p.addQuadCurve(to: CGPoint(x: top + bottom, y: h), control: CGPoint(x: top, y: h))
        p.addLine(to: CGPoint(x: w - top - bottom, y: h))
        p.addQuadCurve(to: CGPoint(x: w - top, y: h - bottom), control: CGPoint(x: w - top, y: h))
        p.addLine(to: CGPoint(x: w - top, y: top))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - top, y: 0))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    let metrics: NotchMetrics

    var body: some View {
        let open = model.expanded
        ZStack(alignment: .top) {
            NotchShape(top: open ? 14 : metrics.shoulder, bottom: open ? 20 : 10)
                .fill(Color.black)
                .frame(
                    width: open ? NotchMetrics.expanded.width : metrics.collapsedWidth,
                    height: open ? NotchMetrics.expanded.height : metrics.height
                )
            if open {
                ExpandedNotch(model: model)
                    .padding(.top, metrics.height + 8)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
                    .frame(width: NotchMetrics.expanded.width, height: NotchMetrics.expanded.height, alignment: .top)
                    .transition(.opacity)
            } else {
                wings.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: open)
        .environment(\.colorScheme, .dark)
    }

    private var wings: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(activity.color).frame(width: 8, height: 8)
                if activity.count > 0 {
                    Text("\(activity.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
            }
            .frame(width: metrics.wing)
            .accessibilityLabel(activity.label)
            Color.clear.frame(width: metrics.notchWidth)
            Text(sessionText)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(usageColor(sessionPercent ?? 0))
                .frame(width: metrics.wing)
                .accessibilityLabel("Uso da sessão: \(sessionText)")
        }
        .foregroundStyle(.white)
        .frame(height: metrics.height)
    }

    private var sessionPercent: Double? {
        model.usage?.limits.first { $0.kind == "session" }?.percent
    }

    private var sessionText: String {
        sessionPercent.map { "\(Int($0.rounded()))%" } ?? "–"
    }

    private var activity: (color: Color, count: Int, label: String) {
        let waiting = model.tasks.filter { $0.status == "awaiting_approval" }.count
        if waiting > 0 { return (.yellow, waiting, "Aguardando sua aprovação") }
        let active = model.tasks.filter(\.isActive).count
        if active > 0 { return (.cyan, active, "Tarefas em andamento") }
        return (.orange, 0, "Faísca parada")
    }
}

private func usageColor(_ percent: Double) -> Color {
    percent >= 90 ? .red : percent >= 70 ? .orange : .white
}

private struct ExpandedNotch: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            usageColumn.frame(width: 216, alignment: .leading)
            tasksColumn.frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
    }

    // MARK: Uso

    private var usageColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Uso do Claude")
            if let usage = model.usage {
                ForEach(Array(usage.limits.enumerated()), id: \.offset) { _, limit in
                    LimitBar(limit: limit)
                }
                if let note = usage.limitsNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 16) {
                    stat("Hoje", formatTokens(usage.today))
                    stat("7 dias", formatTokens(usage.week))
                    stat("Ativas", "\(usage.activeSessions)")
                }
                Text(modelsLine(usage)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Lendo o uso…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func modelsLine(_ usage: UsageData) -> String {
        let total = usage.models.reduce(0) { $0 + $1.tokens }
        guard total > 0 else { return "Sem uso local nos últimos dias" }
        return usage.models
            .map { ($0.model, Int((Double($0.tokens) / Double(total) * 100).rounded())) }
            .filter { $0.1 >= 1 }
            .prefix(3)
            .map { "\($0.0) \($0.1)%" }
            .joined(separator: " · ")
    }

    // MARK: Tarefas

    private var tasksColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Tarefas")
                Spacer()
                Button("Conversar", action: model.openChat).controlSize(.small)
            }
            if model.tasks.isEmpty {
                Text("Nada em andamento.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.tasks) { task in
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.status == "awaiting_approval" ? (task.prompt ?? task.text) : task.text)
                        .font(.callout)
                        .lineLimit(2)
                    if task.status == "awaiting_approval" {
                        HStack {
                            Button("Executar neste Mac") { model.act(task.id, "approve") }
                            Button("Recusar") { model.act(task.id, "cancel") }
                        }
                        .controlSize(.small)
                    } else {
                        Text(statusWord(task.status)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func statusWord(_ status: String) -> String {
        switch status {
        case "queued": return "Na fila"
        case "running": return "Trabalhando"
        case "done": return "Feita"
        case "failed": return "Falhou"
        case "cancelled": return "Cancelada"
        default: return status
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
    }
}

private struct LimitBar: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%").font(.callout).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(limit.percent >= 90 ? Color.red : limit.percent >= 70 ? Color.orange : Color.cyan)
                        .frame(width: geo.size.width * min(max(limit.percent, 0), 100) / 100)
                }
            }
            .frame(height: 4)
            if let reset = resetText {
                Text(reset).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch limit.kind {
        case "session": return "Sessão de 5 horas"
        case "weekly_all": return "Semana"
        case "weekly_scoped": return "Semana · \(limit.scope ?? "modelo")"
        default: return limit.kind
        }
    }

    private var resetText: String? {
        guard let raw = limit.resetsAt, let date = parseISODate(raw) else { return nil }
        let secs = Int(date.timeIntervalSinceNow)
        guard secs > 0 else { return "Renovando" }
        let (d, h, m) = (secs / 86_400, secs % 86_400 / 3600, secs % 3600 / 60)
        if d > 0 { return "Renova em \(d) d \(h) h" }
        if h > 0 { return "Renova em \(h) h \(m) min" }
        return "Renova em \(max(m, 1)) min"
    }
}

private func parseISODate(_ raw: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: raw) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: raw)
}

private func formatTokens(_ n: UInt64) -> String {
    let v = Double(n)
    if v >= 1_000_000 { return String(format: "%.1f M", v / 1_000_000) }
    if v >= 1_000 { return String(format: "%.0f mil", v / 1_000) }
    return "\(n)"
}

private final class HoverHost: NSHostingView<NotchView> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    let model = NotchModel()
    var onExpand: () -> Void = {}
    private let panel: NSPanel
    private var host: HoverHost?
    private var metrics = NotchMetrics(notchWidth: 180, height: 28)
    private var anchorX: CGFloat = 0
    private var topY: CGFloat = 0
    private var pending: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        layout()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    /// Usa a tela com notch; sem ela, fica no topo central da tela principal.
    private func layout() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            metrics.notchWidth = r.minX - l.maxX
            metrics.height = screen.safeAreaInsets.top
            anchorX = screen.frame.minX + (l.maxX + r.minX) / 2
        } else {
            metrics.notchWidth = 120
            metrics.height = max(NSStatusBar.system.thickness, 24)
            anchorX = screen.frame.midX
        }
        topY = screen.frame.maxY
        let view = HoverHost(rootView: NotchView(model: model, metrics: metrics))
        view.onHover = { [weak self] inside in self?.hover(inside) }
        panel.contentView = view
        host = view
        applyFrame(expanded: model.expanded)
    }

    private func applyFrame(expanded: Bool) {
        let size = expanded
            ? NotchMetrics.expanded
            : CGSize(width: metrics.collapsedWidth, height: metrics.height)
        panel.setFrame(
            NSRect(x: anchorX - size.width / 2, y: topY - size.height, width: size.width, height: size.height),
            display: true
        )
    }

    private func hover(_ inside: Bool) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setExpanded(inside) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.12 : 0.28), execute: work)
    }

    func setExpanded(_ open: Bool) {
        guard model.expanded != open else { return }
        if open {
            applyFrame(expanded: true)
            model.expanded = true
            onExpand()
        } else {
            model.expanded = false
            // A janela só encolhe quando a animação termina.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.model.expanded else { return }
                    self.applyFrame(expanded: false)
                }
            }
        }
    }
}
