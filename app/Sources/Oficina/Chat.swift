import SwiftUI

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ChatView: View {
    @ObservedObject var core: Core
    let close: () -> Void
    @State private var draft = ""
    @State private var target = "auto"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            composer
        }
        .frame(width: 400, height: 520)
        .background(.regularMaterial)
        .onAppear { focused = true }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(core.connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .accessibilityLabel(core.connected ? "Core conectado" : "Core desconectado")
            Text("Faísca").font(.headline)
            Spacer()
            Picker("Onde executar", selection: $target) {
                Text("Auto").tag("auto")
                Text("Nuvem").tag("cloud")
                Text("Este Mac").tag("machine")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
        .padding(12)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let problem = core.problem {
                        Text(problem).font(.callout).foregroundStyle(.red)
                    }
                    if core.tasks.isEmpty {
                        Text("Pode pedir. Use /nuvem ou /pc para escolher onde roda.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(core.tasks.suffix(40)) { task in
                        TaskRow(task: task, core: core).id(task.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onChange(of: core.tasks) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var composer: some View {
        TextField("Pedir alguma coisa…", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($focused)
            .padding(12)
            .onSubmit(send)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        core.send(text, target: target)
        draft = ""
    }
}

private struct TaskRow: View {
    let task: TaskItem
    @ObservedObject var core: Core

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 40)
                Text(task.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            }
            if !task.output.isEmpty {
                Text(task.output).textSelection(.enabled)
            }
            if let label = statusLabel {
                Label(label, systemImage: statusIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = task.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let raw = task.url, let url = URL(string: raw), url.scheme == "https" {
                Link("Abrir sessão na nuvem", destination: url).font(.callout)
            }
            if task.status == "awaiting_approval" {
                if let prompt = task.prompt {
                    Text(prompt)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Button("Executar neste Mac") { core.act(task.id, "approve") }
                        .keyboardShortcut(.defaultAction)
                    Button("Recusar") { core.act(task.id, "cancel") }
                }
            } else if task.isActive {
                Button("Cancelar") { core.act(task.id, "cancel") }.controlSize(.small)
            }
        }
    }

    private var statusLabel: String? {
        switch task.status {
        case "queued": return "Na fila"
        case "running":
            switch task.target {
            case "cloud": return "Abrindo agente na nuvem…"
            case "machine": return "Trabalhando em \(task.machine ?? "uma máquina")…"
            default: return task.output.isEmpty ? "Pensando…" : nil
            }
        case "awaiting_approval": return "Quer usar seu computador. Posso?"
        case "cancelled": return "Cancelada"
        default: return nil
        }
    }

    private var statusIcon: String {
        switch task.target {
        case "cloud": return "cloud"
        case "machine": return "desktopcomputer"
        default: return "sparkle"
        }
    }
}
