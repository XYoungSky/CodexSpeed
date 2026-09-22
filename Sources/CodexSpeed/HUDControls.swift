import SwiftUI

// Disambiguate the property wrapper from the macOS 27 SDK macro, whose
// compiler plugin is absent from the command-line toolchain.
private typealias ViewState<Value> = SwiftUI.State<Value>

/// A shared visual treatment for both toolbar buttons and menu labels.
struct HUDControlIcon: View {
    let symbol: String
    @ViewState private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(width: 24, height: 24)
            .background(.primary.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }
}

struct HUDIconButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { HUDControlIcon(symbol: symbol) }
            .buttonStyle(.plain)
            .background(WindowControlArea())
            .help(title)
            .accessibilityLabel(title)
    }
}
