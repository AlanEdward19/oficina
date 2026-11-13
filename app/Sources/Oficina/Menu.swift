import AppKit
import SwiftUI

/// O topo do menu: ela mesma, como está e onde está.
struct MenuHeader: View {
    let name: String
    let mood: String
    let sleeping: Bool
    let place: String
    let status: String?
    let listening: Bool
    let tint: Color

    private var moodText: String {
        if sleeping { return "dormindo" }
        return ["feliz": "feliz", "curiosa": "curiosa", "entediada": "entediada", "cansada": "cansada",
                "carente": "carente", "focada": "focada"][mood] ?? "tranquila"
    }

    var body: some View {
        HStack(spacing: 12) {
            FaiscaAvatar(size: 36, mood: sleeping ? .sleeping : .idle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text(moodText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle().fill(listening ? Color.red : tint).frame(width: 6, height: 6)
                    Text(status ?? place).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 270, alignment: .leading)
    }
}

/// Um item com ícone, ação e (se quiser) estado e atalho.
@MainActor
func menuItem(_ title: String, _ symbol: String, _ target: AnyObject, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [], on: Bool? = nil, tag: Int = 0) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = target
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
    if let on { item.state = on ? .on : .off }
    item.tag = tag
    return item
}

/// Título de seção, no estilo do macOS 14.
@MainActor
func menuSection(_ title: String) -> NSMenuItem {
    NSMenuItem.sectionHeader(title: title)
}

@MainActor
func menuHeader(_ view: MenuHeader) -> NSMenuItem {
    let item = NSMenuItem()
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    item.view = host
    return item
}
