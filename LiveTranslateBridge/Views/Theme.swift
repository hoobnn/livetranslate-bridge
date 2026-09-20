import SwiftUI

/// Shared shapes, spacing and surfaces.
///
/// macOS 26 leans on layered glass over flat filled boxes, and on concentric
/// corners — an inner radius that trails its container's by the padding
/// between them, so nested rounded rectangles stay parallel instead of
/// pinching at the corners. Both are easy to get subtly wrong by hand, so the
/// numbers live here rather than being retyped per view.
enum Theme {
    /// Outer container radius. macOS 26 windows are rounded far more than the
    /// 8–10 pt that used to read as "card".
    static let cardRadius: CGFloat = 16

    /// Subtitle cards are smaller than the diagnostics cards this radius was
    /// set for, and a 16 pt corner on a two-line bubble reads as a lozenge.
    /// macOS keeps the corner proportional to the box.
    static let bubbleRadius: CGFloat = 12
    static let innerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8

    /// The widest a subtitle card is allowed to grow.
    ///
    /// A line running the full width of a maximised window is hard to read
    /// back to: the eye loses the start of the next line on the return sweep.
    /// Typography puts the comfortable measure at roughly 45–75 characters,
    /// and this is that measure at the board's larger text sizes — wide enough
    /// that ordinary sentences still take one or two lines, narrow enough that
    /// none of them crosses the window.
    static let transcriptMeasure: CGFloat = 620

    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 10

    /// A radius that stays concentric with `outer` when inset by `inset`.
    static func concentric(inner outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(4, outer - inset)
    }
}

/// A titled card: the repeated unit of the diagnostics pane.
///
/// Header and body sit in one glass surface rather than a heading floating
/// above a filled box, which is what macOS 26 sheets and inspectors do.
struct Card<Content: View>: View {
    private let title: String
    private let systemImage: String
    private let subtitle: String?
    @ViewBuilder private let content: Content

    init(
        _ title: String,
        systemImage: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowSpacing) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .glassCard()
    }
}

extension View {
    /// The standard raised surface. `glassEffect` carries the macOS 26 look;
    /// the fallback keeps the app buildable and legible on older systems.
    @ViewBuilder
    func glassCard(radius: CGFloat = Theme.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.background.secondary, in: shape)
                .overlay {
                    shape.strokeBorder(.separator.opacity(0.5), lineWidth: 1)
                }
        }
    }

    /// A recessed well for content that sits *inside* a card — a log, a
    /// readout — so it reads as contained rather than as another raised layer.
    func well(radius: CGFloat = Theme.innerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(.quinary, in: shape)
            .overlay { shape.strokeBorder(.separator.opacity(0.35), lineWidth: 1) }
    }
}
