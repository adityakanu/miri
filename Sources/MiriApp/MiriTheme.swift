import SwiftUI

/// The visual language for Miri's windows: a serif display face for headings
/// paired with the system UI face for controls and data.
///
/// Kept as tokens rather than styling each view so panes stay consistent and a
/// change lands in one place. Sizes use `relativeTo:` so everything still
/// tracks the user's Dynamic Type setting.
enum MiriTheme {
    /// New York — Apple's system serif. Shipped with macOS, so it needs no
    /// bundled font file and inherits full localization coverage.
    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: size, weight: .regular, design: .serif).leading(.tight)
    }

    /// Window-level title, e.g. the name of the selected pane.
    static var displayTitle: Font { serif(28) }
    /// Section heading inside a pane.
    static var sectionTitle: Font { serif(17) }
    /// Supporting sentence under a title. Sentence case, never all-caps.
    static var subtitle: Font { .system(size: 12) }

    enum Metrics {
        /// Outer padding for pane content.
        static let panePadding: CGFloat = 28
        /// Vertical rhythm between sections.
        static let sectionSpacing: CGFloat = 26
        /// Spacing between a heading and its content.
        static let headingSpacing: CGFloat = 10
        static let cardCornerRadius: CGFloat = 10
        static let sidebarWidth: CGFloat = 208
    }
}

/// A titled group of related controls.
///
/// Replaces `Section` inside `Form`, whose grouped style renders the boxed,
/// grey, all-caps look the redesign is moving away from.
struct MiriSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MiriTheme.Metrics.headingSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MiriTheme.sectionTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(MiriTheme.subtitle)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The heading and its controls are one unit to VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Standard pane scaffold: serif title, optional subtitle, scrolling body.
struct MiriPane<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MiriTheme.Metrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(MiriTheme.displayTitle)
                    if let subtitle {
                        Text(subtitle)
                            .font(MiriTheme.subtitle)
                            .foregroundStyle(.secondary)
                    }
                }
                content
            }
            .padding(MiriTheme.Metrics.panePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A quietly outlined container. Used for rows that need grouping without the
/// heavy inset-grouped background.
struct MiriCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MiriTheme.Metrics.cardCornerRadius)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MiriTheme.Metrics.cardCornerRadius)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}
