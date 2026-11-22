import SwiftUI

/// Colori e stili comuni (presi dall'icona: viola e blu).
enum Theme {
    static let accent = Color(red: 0.45, green: 0.28, blue: 0.90)
    static let accent2 = Color(red: 0.20, green: 0.34, blue: 0.95)
    static let danger = Color(red: 0.92, green: 0.27, blue: 0.32)
    static let warn = Color.orange
    static let gradient = LinearGradient(colors: [accent2, accent],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Pulsante pieno, alto e uniforme.
struct FilledButtonStyle: ButtonStyle {
    var fill: AnyShapeStyle

    func makeBody(configuration: Configuration) -> some View {
        FilledBody(configuration: configuration, fill: fill)
    }

    struct FilledBody: View {
        let configuration: ButtonStyleConfiguration
        let fill: AnyShapeStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(.white)
                .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Pulsante secondario, tenue.
struct TonalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .foregroundStyle(Theme.accent)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

extension View {
    /// Riquadro arrotondato per raggruppare controlli.
    func panel() -> some View {
        self.padding(12)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
