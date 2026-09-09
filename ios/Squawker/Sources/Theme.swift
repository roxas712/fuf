import SwiftUI

/// The companion web app's palette, carried over so the two read as one
/// product. Values are that site's CSS custom properties verbatim -- if it
/// changes, change them here rather than eyeballing a match.
enum Theme {
    // Surfaces, darkest first.
    static let void   = Color(hex: 0x04060B)
    static let bg0    = Color(hex: 0x070A12)
    static let bg1    = Color(hex: 0x0B0F1A)
    static let bg2    = Color(hex: 0x111726)
    static let bg3    = Color(hex: 0x171F31)

    // Text.
    static let ink    = Color(hex: 0xEAF0FB)
    static let muted  = Color(hex: 0x9AA6BD)
    static let faint  = Color(hex: 0x6B7689)

    // Accents.
    static let accent  = Color(hex: 0x7AC6FF)
    static let accent2 = Color(hex: 0x9FB4FF)
    static let violet  = Color(hex: 0xB89AFF)

    // Semantic.
    static let gold  = Color(hex: 0xE6CB7E)
    static let green = Color(hex: 0x3FCF8E)
    static let heart = Color(hex: 0xE0566B)

    static let line  = Color.white.opacity(0.085)
    static let glow  = Color(hex: 0x7AC6FF).opacity(0.45)

    // The site's radius scale.
    enum R {
        static let sm: CGFloat = 11
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 30
    }

    /// The site sets a near-black ground and lifts panels off it. A flat fill
    /// would read as cheap next to glass, which needs something behind it to
    /// refract.
    static var background: some View {
        ZStack {
            LinearGradient(colors: [bg1, void], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.10), .clear],
                           center: .init(x: 0.5, y: -0.1),
                           startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Liquid Glass where the OS has it, the site's own glass recipe where it does
/// not. The deployment target is iOS 17, so the effect cannot simply be called;
/// the fallback mirrors what the web app does in CSS --
/// `rgba(9,12,20,.62)` over a blur, a hairline border, and an inset highlight.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = Theme.R.lg
    var tinted: Bool = false
    /// Makes the glass respond to touch -- it flexes and brightens under a
    /// finger. Only worth setting on something actually tappable; on a static
    /// panel it is motion for its own sake.
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass: Glass = {
                var g: Glass = .regular
                if tinted { g = g.tint(Theme.accent.opacity(0.22)) }
                if interactive { g = g.interactive() }
                return g
            }()
            content.glassEffect(glass, in: .rect(cornerRadius: radius))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(Color(hex: 0x090C14).opacity(0.62)))
                        .overlay(
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(Theme.line, lineWidth: 1))
                        .shadow(color: .black.opacity(0.85), radius: 30, y: 24))
        }
    }
}

extension View {
    func glassPanel(radius: CGFloat = Theme.R.lg,
                    tinted: Bool = false,
                    interactive: Bool = false) -> some View {
        modifier(GlassPanel(radius: radius, tinted: tinted, interactive: interactive))
    }

    /// Groups sibling glass so the system can blend and morph between the
    /// pieces rather than compositing each one independently. Below iOS 26 it
    /// is a plain passthrough.
    @ViewBuilder
    func glassGroup() -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { self }
        } else {
            self
        }
    }

    /// The web app's display face is Clash Display, which is not on iOS and is
    /// not bundled here. Rounded SF with tightened tracking is the nearest
    /// system equivalent -- geometric, slightly condensed -- and costs no
    /// download.
    func displayFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight, design: .rounded))
            .tracking(-0.4)
    }
}

/// The primary action. Uses the system's prominent glass on iOS 26 so it picks
/// up the real material and its interaction behaviour, and falls back to a
/// filled accent capsule below that.
struct PrimaryActionStyle: ButtonStyle {
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(enabled ? Theme.void : Theme.faint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                // Glass goes BEHIND the label, not around it. Applied as a
                // wrapper it sits between the finger and the button, and an
                // .interactive() glass runs its own touch handling -- which can
                // eat the tap before the Button ever sees it.
                if #available(iOS 26.0, *) {
                    Color.clear.glassEffect(
                        enabled ? .regular.tint(Theme.accent) : .regular,
                        in: .rect(cornerRadius: Theme.R.md))
                } else {
                    RoundedRectangle(cornerRadius: Theme.R.md, style: .continuous)
                        .fill(enabled ? Theme.accent : Theme.bg3)
                        .shadow(color: enabled ? Theme.glow.opacity(0.5) : .clear,
                                radius: 16, y: 6)
                }
            }
            // Explicit hit area. Without it the tappable region is whatever the
            // background happens to draw, which is exactly the ambiguity that
            // made this fail silently.
            .contentShape(.rect(cornerRadius: Theme.R.md))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
