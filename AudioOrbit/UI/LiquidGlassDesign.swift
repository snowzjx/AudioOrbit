import AppKit
import SwiftUI

/// Shared visual language for AudioOrbit's translucent surfaces. The native
/// Liquid Glass treatment is used on macOS 26 and gracefully falls back to
/// material on earlier supported systems.
struct LiquidGlassBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct LiquidGlassGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .liquidGlassPanel(cornerRadius: 18)
    }
}

extension View {
    func popupContentCard(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.32))
            }
    }

    @ViewBuilder
    func liquidGlassPanel(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        castsShadow: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(
                    .regular.tint(tint.opacity(0.16)),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .shadow(
                    color: castsShadow ? .black.opacity(0.10) : .clear,
                    radius: castsShadow ? 16 : 0,
                    y: castsShadow ? 7 : 0
                )
            } else {
                self.glassEffect(
                    .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
                .shadow(
                    color: castsShadow ? .black.opacity(0.10) : .clear,
                    radius: castsShadow ? 16 : 0,
                    y: castsShadow ? 7 : 0
                )
            }
        } else {
            self
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.16))
                }
                .shadow(
                    color: castsShadow ? .black.opacity(0.10) : .clear,
                    radius: castsShadow ? 16 : 0,
                    y: castsShadow ? 7 : 0
                )
        }
    }
}
