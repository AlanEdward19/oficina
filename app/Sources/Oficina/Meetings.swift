import AppKit
import SwiftUI

// MARK: Modelos

struct MeetingItem: Decodable, Identifiable, Equatable {
    let id: String
    let app: String
    let title: String
    let started: UInt64
    let ended: UInt64?
    let words: Int
    let summarized: Bool
}

struct MeetingSegment: Decodable, Equatable {
    let who: String
    let text: String
    let at: UInt64
}

struct MeetingData: Decodable, Equatable {
    let id: String
    let app: String
    let title: String
    let started: UInt64
    let ended: UInt64?
    let segments: [MeetingSegment]
    let summary: String?
}

/// Texto em Markdown simples, com quebras de linha preservadas.
func markdownText(_ text: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let a = try? AttributedString(markdown: text, options: options) { return Text(a) }
    return Text(text)
}

// MARK: Tela

/// Reuniões que a Faísca ouviu com a sua permissão. Fica tudo no Mac;
/// só o resumo, se você pedir, passa pelo Claude.
struct MeetingsView: View {
    @ObservedObject var core: Core
    var tint: Color
    @State private var list: [MeetingItem] = []
    @State private var selected: String?
    @State private var detail: MeetingData?
    @State private var summarizing = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 260)
            Rectangle().fill(Bench.line).frame(width: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Bench.canvas)
        .ignoresSafeArea()
        .task {
            while !Task.isCancelled {
                list = await core.meetings()
                if selected == nil { selected = list.first?.id }
                if let id = selected { detail = await core.meeting(id) }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: selected) { _, id in
            detail = nil
            guard let id else { return }
            Task { detail = await core.meeting(id) }
        }
        .confirmationDialog("Apagar esta reunião?", isPresented: $confirmDelete) {
            Button("Apagar", role: .destructive) {
                guard let id = selected else { return }
                Task {
                    await core.deleteMeeting(id)
                    selected = nil
                    list = await core.meetings()
                    selected = list.first?.id
                }
            }
        } message: {
            Text("A transcrição e o resumo somem deste Mac. Não dá para desfazer.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reuniões").font(Bench.display(22)).padding(.horizontal, 20).padding(.top, 44).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(list) { m in
                        HoverRow(keepTrailing: selected == m.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).font(.system(size: 13, weight: selected == m.id ? .semibold : .regular)).lineLimit(1)
                                Text("\(date(m.started)) · \(m.app)\(m.ended == nil ? " · ao vivo" : "")")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } trailing: {
                            Circle().fill(selected == m.id ? tint : .clear).frame(width: 6, height: 6)
                        }
                        .onTapGesture { selected = m.id }
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, 12)
            }
            if list.isEmpty {
                Text("Quando você entrar numa chamada, a Faísca pergunta se pode ouvir. As anotações aparecem aqui.")
                    .font(.callout).foregroundStyle(.secondary).padding(20)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var content: some View {
        if let m = detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(m.title).font(Bench.display(26))
                        Text("\(m.app) · \(date(m.started))\(duration(m))").font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 18) {
                        if m.summary == nil {
                            Button(summarizing ? "Resumindo…" : "Resumir decisões e tarefas") { summarize(m.id) }
                                .buttonStyle(SolidStyle())
                                .disabled(summarizing || m.segments.isEmpty || m.ended == nil)
                        }
                        Button("Copiar transcrição") { copy(m) }.buttonStyle(QuietStyle(tint: tint))
                        Button("Apagar…") { confirmDelete = true }.buttonStyle(QuietStyle(tint: tint))
                    }
                    if m.summary == nil {
                        Text("O resumo gasta alguns tokens do Claude. A transcrição foi feita no Mac, sem internet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let s = m.summary {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Resumo").font(.system(size: 13, weight: .semibold))
                            markdownText(s).font(.callout).textSelection(.enabled)
                        }
                        Rectangle().fill(Bench.line).frame(height: 1)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcrição").font(.system(size: 13, weight: .semibold))
                        if m.segments.isEmpty {
                            Text(m.ended == nil ? "Ouvindo… as falas aparecem aqui a cada pausa." : "Nada foi transcrito.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(Array(m.segments.enumerated()), id: \.offset) { _, s in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(s.who).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(s.who == "Você" ? tint : Color.secondary)
                                    .frame(width: 52, alignment: .leading)
                                Text(s.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 48)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(list.isEmpty ? "" : "Escolha uma reunião.").foregroundStyle(.secondary)
        }
    }

    private func summarize(_ id: String) {
        summarizing = true
        Task {
            _ = await core.summarizeMeeting(id)
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                if let d = await core.meeting(id), d.summary != nil {
                    detail = d
                    break
                }
            }
            summarizing = false
        }
    }

    private func copy(_ m: MeetingData) {
        let text = m.segments.map { "\($0.who): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func date(_ ts: UInt64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .shortened)
    }

    private func duration(_ m: MeetingData) -> String {
        guard let end = m.ended, end > m.started else { return "" }
        let min = Int((end - m.started) / 60)
        return " · \(min) min"
    }
}
