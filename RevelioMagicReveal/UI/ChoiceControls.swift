import SwiftUI

/// Les deux rangées de choix : le geste et le masque.
struct ChoiceControls: View {
    let engine: RevealEngine

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                ChoiceRow(title: "Geste", items: RevealGesture.allCases, selection: engine.gesture,
                          label: { ($0.title, $0.symbol) }) { engine.gesture = $0 }
                ChoiceRow(title: "Masque", items: MaskKind.allCases, selection: engine.mask,
                          label: { ($0.title, $0.symbol) }) { engine.mask = $0 }
            }
        }
        .sensoryFeedback(.selection, trigger: engine.gesture)
        .sensoryFeedback(.selection, trigger: engine.mask)
    }
}

private struct ChoiceRow<Item: Hashable>: View {
    let title: String
    let items: [Item]
    let selection: Item
    let label: (Item) -> (title: String, symbol: String)
    let select: (Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(Palette.cream.opacity(0.55))
                .padding(.leading, 6)
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    let content = label(item)
                    let selected = item == selection
                    Button {
                        select(item)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: content.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .frame(height: 20)
                            Text(content.title)
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(selected ? Palette.night : Palette.cream)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .contentShape(.rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(selected ? .regular.tint(Palette.gold).interactive() : .regular.interactive(),
                                 in: .rect(cornerRadius: 18))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}
