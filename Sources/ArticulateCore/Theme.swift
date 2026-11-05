import AppKit
import SwiftUI

/// Articulate's look: ink on warm paper (charcoal in dark mode), one violet accent for data and highlights, content on
/// rounded cards. Every color follows light and dark mode.
enum Theme {
    static let canvas = dynamic(0xF7F6F3, dark: 0x161616)
    static let sidebar = dynamic(0xEFEDE8, dark: 0x1C1C1C)
    static let card = dynamic(0xFFFFFF, dark: 0x232323)
    static let cardHover = dynamic(0xFAF9F6, dark: 0x292929)
    /// The selected sidebar item.
    static let selection = dynamic(0xFFFFFF, dark: 0x2F2F2F)
    static let border = dynamic(0x000000, 0.07, dark: 0xFFFFFF, 0.08)
    /// Divider lines. Opaque: a 1-point shape filled with a translucent dynamic color can lose its alpha.
    static let separator = dynamic(0xE4E2DD, dark: 0x2B2B2B)
    /// Inputs, segmented controls, empty heatmap cells.
    static let fill = dynamic(0x000000, 0.045, dark: 0xFFFFFF, 0.06)
    static let ink = dynamic(0x1C1B19, dark: 0xEDEDEC)
    static let secondaryInk = dynamic(0x6F6C66, dark: 0xA3A19D)
    static let tertiaryInk = dynamic(0xA19E98, dark: 0x6E6C69)
    static let accent = dynamic(0x6E56CF, dark: 0x9D8CF5)
    static let accentSoft = dynamic(0x6E56CF, 0.10, dark: 0x9D8CF5, 0.16)
    static let cardShadow = Color.black.opacity(0.04)

    static let cornerRadius: CGFloat = 16
    /// Pages keep a readable width on large windows.
    static let pageWidth: CGFloat = 920

    // Type scale matched to Typeless (its stylesheet: titles 30/34 semibold, card titles 16/20 semibold, body and
    // controls 14/22, captions 12/18, tiny labels 10/14).
    static func pageTitle() -> Font { .system(size: 30, weight: .semibold) }
    static func cardTitle() -> Font { .system(size: 16, weight: .semibold) }
    static func body() -> Font { .system(size: 14) }
    static func caption() -> Font { .system(size: 12) }
    /// Extra space between lines so 14-point text sits on Typeless's 22-point lines.
    static let bodyLineSpacing: CGFloat = 5

    private static func dynamic(_ light: UInt32, _ lightAlpha: CGFloat = 1, dark: UInt32, _ darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Building blocks

extension View {
    /// Content on a rounded card.
    func card(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.border))
            .shadow(color: Theme.cardShadow, radius: 3, y: 1)
    }

    /// A page's column: readable width, centered, clear of the window's title bar.
    func page() -> some View {
        self.padding(.horizontal, 36)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: Theme.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.pageTitle()).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.secondaryInk)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A key drawn like a physical keycap.
struct KeyCap: View {
    var label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            .fixedSize()
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.canvas)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// Segmented filter: the selected option sits on a small raised card.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.ink : Theme.secondaryInk)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.card)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill))
        .fixedSize()
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.tertiaryInk)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 14))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiaryInk)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill))
    }
}

/// A small tinted label (mode, status).
struct Tag: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// Lays children out left to right and wraps to the next row when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// An empty page or list: a quiet icon, a line of text, and an optional hint.
struct EmptyState: View {
    var symbol: String
    var title: String
    var hint: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.accentSoft))
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
            if let hint {
                Text(hint).font(.system(size: 14)).foregroundStyle(Theme.secondaryInk).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}
