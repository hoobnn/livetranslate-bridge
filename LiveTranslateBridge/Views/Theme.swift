import AppKit
import SwiftUI

/// Shared type, spacing and semantic colors for a quiet native interface.
enum Theme {

    // MARK: - shape

    /// Outer container radius. macOS 26 windows are rounded far more than the
    /// 8–10 pt that used to read as "card".
    static let cardRadius: CGFloat = 16

    /// Subtitle cards are smaller than the diagnostics cards this radius was
    /// set for, and a 16 pt corner on a two-line bubble reads as a lozenge.
    /// macOS keeps the corner proportional to the box.
    static let bubbleRadius: CGFloat = 13
    static let innerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8

    /// A radius that stays concentric with `outer` when inset by `inset`.
    static func concentric(inner outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(4, outer - inset)
    }

    // MARK: - measure

    /// The comfortable measure for a line of subtitle, at a given text size.
    ///
    /// Typography puts easy reading at roughly 45–75 characters per line, and
    /// a measure is therefore a multiple of the type size, not a constant: a
    /// line that holds a comfortable 13 pt sentence holds a cramped 24 pt
    /// one. Scaling it with the text is what keeps the largest size readable
    /// instead of merely large.
    ///
    /// The multiplier targets the upper end of that range — Latin text at
    /// roughly 70 characters. CJK sets about twice as wide per character, so
    /// the same line runs to a comfortable 35 or so, which is the right
    /// measure for a script with no word spaces to break on.
    static func transcriptMeasure(for pointSize: CGFloat) -> CGFloat {
        pointSize * 36
    }

    /// The widest the board grows before it stops following the window.
    ///
    /// The board is wider than one measure by design: the two sides sit on
    /// opposite margins, so the board needs room for a turn on each side
    /// plus the space between them that makes the split legible.
    ///
    /// The cap is there for large displays, where past a point the eye has to
    /// travel too far between one side of the exchange and the other — and
    /// the turns stop reading as replies to each other.
    static let boardMaxWidth: CGFloat = 1100

    /// The board's side margin, which opens up with the window.
    ///
    /// `pageInset` is the floor — right at the minimum window size — and the
    /// margin grows from there, so a wide board does not run its first turn
    /// into the window frame.
    static func gutter(boardWidth: CGFloat) -> CGFloat {
        min(56, max(pageInset, boardWidth * 0.035))
    }

    // MARK: - spacing

    /// One 4 pt rhythm, named. Views that reach for a number reach for one of
    /// these, so the whole app breathes at the same rate.
    static let spacing2: CGFloat = 2
    static let spacing4: CGFloat = 4
    static let spacing6: CGFloat = 6
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing28: CGFloat = 28

    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 10
    static let pageInset: CGFloat = 20

    // MARK: - colour

    /// Lane position and speaker labels supplement the restrained colors.
    static func lane(_ isLocal: Bool) -> Color {
        isLocal ? localLane : remoteLane
    }

    static let localLane = Color(
        light: Color(red: 0.11, green: 0.36, blue: 0.62),
        dark: Color(red: 0.42, green: 0.66, blue: 0.94)
    )

    static let remoteLane = Color(
        light: Color(red: 0.18, green: 0.43, blue: 0.40),
        dark: Color(red: 0.48, green: 0.72, blue: 0.67)
    )

    /// Status hues. Named rather than taken from `.green`/`.orange` so that a
    /// running session is the same green everywhere it is drawn, and so the
    /// dark-appearance variants are actually legible on a dark surface.
    static let live = Color(
        light: Color(red: 0.13, green: 0.52, blue: 0.29),
        dark: Color(red: 0.36, green: 0.82, blue: 0.53)
    )

    static let pending = Color(
        light: Color(red: 0.71, green: 0.45, blue: 0.06),
        dark: Color(red: 0.97, green: 0.73, blue: 0.33)
    )

    static let failure = Color(
        light: Color(red: 0.71, green: 0.19, blue: 0.19),
        dark: Color(red: 0.98, green: 0.51, blue: 0.48)
    )

    // MARK: - motion

    /// The default: critically damped, no overshoot. Used for anything that
    /// simply moves from one state to another.
    static let settle = Animation.spring(response: 0.34, dampingFraction: 1)

    /// For things that arrive — a card landing on the board, a control
    /// appearing. A little bounce, because they carry momentum.
    static let arrive = Animation.spring(response: 0.36, dampingFraction: 0.82)

    /// Fast state flips: a tint changing, a label swapping.
    static let quick = Animation.spring(response: 0.22, dampingFraction: 1)
}

// MARK: - appearance-aware colour

extension Color {
    /// A colour with a different value per appearance.
    ///
    /// SwiftUI has no literal for this, and asset catalogue entries put the
    /// value a long way from the code that reasons about it. The palette above
    /// is the app's argument about itself, so it stays in the source.
    init(light: Color, dark: Color) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(
                from: [.aqua, .darkAqua]
            ) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

// MARK: - type

extension Font {
    /// The type scale, named for the job rather than the size.
    ///
    /// Tracking travels with the size because it has to: a single
    /// `letter-spacing` is wrong at one end of any scale. Large text is
    /// tightened, small text is opened up, and body sits near zero.
    enum App {
        /// Screen titles.
        static let title = Font.system(size: 19, weight: .semibold)
        /// Card and section headers.
        static let heading = Font.system(size: 14, weight: .semibold)
        /// The primary readout of a control group.
        static let body = Font.system(size: 13, weight: .regular)
        /// Field labels and secondary rows.
        static let label = Font.system(size: 12, weight: .medium)
        /// The smallest text that is still prose.
        static let caption = Font.system(size: 11, weight: .regular)
        /// Eyebrow labels over a control: small, and set in caps.
        static let eyebrow = Font.system(size: 10, weight: .semibold)
        /// Numbers that must not jitter as they change.
        static let numeric = Font.system(size: 11, weight: .medium).monospacedDigit()
        /// Log lines and machine readouts.
        static let mono = Font.system(size: 11, design: .monospaced)
    }
}

extension View {
    /// An eyebrow label: small, spaced, quiet, upper-case.
    ///
    /// The tracking is the point — at 10 pt, caps set solid are a smear, and
    /// this is the one place in the app where letter-spacing does real work.
    func eyebrow() -> some View {
        font(.App.eyebrow)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - canvas

/// A neutral reading surface; system colors adapt to light and dark appearance.
struct AppCanvas: View {
    var body: some View {
        Color(nsColor: .textBackgroundColor)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

// MARK: - card

/// A titled card: the repeated unit of the diagnostics pane.
struct Card<Content: View>: View {
    private let title: String
    private let subtitle: String?
    @ViewBuilder private let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowSpacing) {
            Text(title)
                .font(.App.heading)

            if let subtitle {
                Text(subtitle)
                    .font(.App.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .contentCard()
    }
}

// MARK: - surfaces

/// The raised surface, as a modifier rather than an inline branch, so that
/// "Reduce transparency" can be read from the environment — a plain
/// `@ViewBuilder` on `View` has no environment of its own to read it from.
///
/// Turning that setting on is a request to stop sampling what is behind a
/// surface, which is the whole of what `glassEffect` does. Honouring it here
/// covers every raised surface in the app at once, because they all come
/// through this modifier.
private struct GlassCard: ViewModifier {
    let radius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            content.glassEffect(.regular, in: shape)
        } else {
            // Opaque, and with a border that is actually a border at
            // increased contrast rather than a hairline hint of one.
            content
                .background(.background.secondary, in: shape)
                .overlay {
                    shape.strokeBorder(
                        .separator.opacity(contrast == .increased ? 1 : 0.5),
                        lineWidth: 1
                    )
                }
        }
    }
}

/// The repeated content surface. A modifier for the same reason `GlassCard`
/// is one: the fill and the border it draws are exactly what the two
/// accessibility settings adjust, and both live in the environment.
private struct ContentCard: ViewModifier {
    let radius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let isIncreased = contrast == .increased
        return content
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay {
                shape.strokeBorder(
                    .separator.opacity(isIncreased ? 1 : 0.35), lineWidth: 1
                )
            }
    }
}

/// The recessed well. `.quinary` is the faintest fill AppKit offers — the
/// point of a well — which also makes it the one that disappears first when
/// the user has asked for more contrast.
private struct Well: ViewModifier {
    let radius: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let isIncreased = contrast == .increased
        return content
            .background(isIncreased ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary),
                        in: shape)
            .overlay {
                shape.strokeBorder(
                    .separator.opacity(isIncreased ? 1 : 0.35),
                    lineWidth: 1
                )
            }
    }
}

extension View {
    /// The standard raised surface. `glassEffect` carries the macOS 26 look;
    /// the fallback keeps the app buildable and legible on older systems, and
    /// serves "Reduce transparency" on new ones.
    func glassCard(radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(GlassCard(radius: radius))
    }

    /// A content surface rather than another glass layer. Liquid Glass is
    /// reserved for navigation and floating controls; repeated transcript and
    /// diagnostics cards stay quiet, opaque enough to read, and clearly below
    /// that control layer.
    func contentCard(
        radius: CGFloat = Theme.cardRadius
    ) -> some View {
        modifier(ContentCard(radius: radius))
    }

    /// A recessed well for content that sits *inside* a card — a log, a
    /// readout — so it reads as contained rather than as another raised layer.
    func well(radius: CGFloat = Theme.innerRadius) -> some View {
        modifier(Well(radius: radius))
    }
}
