import AppKit
import SwiftUI

// MARK: - Themes

struct AppTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let primary: Color
    let secondary: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// App glyph used in the library header, welcome screen, and About panel.
    func glyph(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "video.fill")
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: primary.opacity(0.35), radius: size * 0.12, y: size * 0.05)
    }
}

enum Themes {
    static let all: [AppTheme] = [
        AppTheme(
            id: "sentry", name: "Sentry",
            primary: Color(red: 0.05, green: 0.52, blue: 1.00),
            secondary: Color(red: 0.11, green: 0.31, blue: 0.85)
        ),
        AppTheme(
            id: "midnight", name: "Midnight",
            primary: Color(red: 0.27, green: 0.35, blue: 0.72),
            secondary: Color(red: 0.10, green: 0.14, blue: 0.36)
        ),
        AppTheme(
            id: "ember", name: "Ember",
            primary: Color(red: 0.93, green: 0.28, blue: 0.24),
            secondary: Color(red: 0.86, green: 0.44, blue: 0.10)
        ),
        AppTheme(
            id: "aurora", name: "Aurora",
            primary: Color(red: 0.10, green: 0.72, blue: 0.62),
            secondary: Color(red: 0.16, green: 0.48, blue: 0.86)
        ),
        AppTheme(
            id: "violet", name: "Violet",
            primary: Color(red: 0.55, green: 0.27, blue: 0.90),
            secondary: Color(red: 0.88, green: 0.33, blue: 0.66)
        ),
        AppTheme(
            id: "graphite", name: "Graphite",
            primary: Color(red: 0.36, green: 0.39, blue: 0.45),
            secondary: Color(red: 0.56, green: 0.60, blue: 0.66)
        )
    ]

    static func theme(id: String) -> AppTheme {
        all.first { $0.id == id } ?? all[0]
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: "themeID") }
    }
    @Published var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    var theme: AppTheme {
        Themes.theme(id: themeID)
    }

    private init() {
        themeID = UserDefaults.standard.string(forKey: "themeID") ?? "sentry"
        appearance = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? ""
        ) ?? .system
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = Themes.all[0]
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - Shared components

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 14, padding: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

/// Small uppercase caption used above sections ("CLIP GALLERY").
struct SectionCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(.tertiary)
    }
}

/// Rounded search field matching the library control row.
struct SearchField: View {
    @Binding var text: String
    var prompt: String = "Search"

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// Capsule segmented control used throughout the library and player chrome.
struct CapsuleSegments<T: Hashable>: View {
    let options: [(value: T, label: String, symbol: String?)]
    @Binding var selection: T
    var showLabels = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        selection = option.value
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .medium))
                        }
                        if showLabels {
                            Text(option.label)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .padding(.horizontal, showLabels ? 11 : 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(
                            selection == option.value
                                ? AnyShapeStyle(.background)
                                : AnyShapeStyle(Color.clear)
                        )
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            selection == option.value
                                ? Color.primary.opacity(0.12)
                                : Color.clear,
                            lineWidth: 1
                        )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == option.value ? .primary : .secondary)
                .help(option.label)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.55), in: Capsule())
    }
}

/// Filter chip with a trailing count badge, as used by the library's
/// All / Sentry / Saved / Recent row.
struct CountChip: View {
    let label: String
    let symbol: String
    let count: Int
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            isSelected ? tint.opacity(0.28) : Color.primary.opacity(0.07)
                        )
                    )
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? tint.opacity(0.16) : Color.primary.opacity(0.04))
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? tint.opacity(0.65) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
    }
}

extension Date {
    var briefFormatted: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}
