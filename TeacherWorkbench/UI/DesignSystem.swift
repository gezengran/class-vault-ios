import SwiftUI

enum AppTheme {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let secondarySurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let accent = Color(red: 0.08, green: 0.40, blue: 0.78)
    static let accentDark = Color(red: 0.04, green: 0.25, blue: 0.55)
    static let success = Color(red: 0.12, green: 0.55, blue: 0.36)
    static let warning = Color(red: 0.85, green: 0.48, blue: 0.08)
    static let cornerRadius: CGFloat = 22

    static let heroGradient = LinearGradient(
        colors: [accentDark, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

enum StudentGenderAppearance: String, Equatable {
    case male
    case female
    case other

    init(gender: String?) {
        let normalized = gender?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["男", "男生", "男性", "male", "m"].contains(normalized) {
            self = .male
        } else if ["女", "女生", "女性", "female", "f"].contains(normalized) {
            self = .female
        } else {
            self = .other
        }
    }

    var accent: Color {
        switch self {
        case .male: Color(red: 0.16, green: 0.43, blue: 0.78)
        case .female: Color(red: 0.79, green: 0.30, blue: 0.46)
        case .other: Color(red: 0.40, green: 0.38, blue: 0.66)
        }
    }

    var surface: Color {
        switch self {
        case .male: Color(red: 0.93, green: 0.96, blue: 1.0)
        case .female: Color(red: 1.0, green: 0.94, blue: 0.96)
        case .other: Color(red: 0.95, green: 0.94, blue: 1.0)
        }
    }

    var heroGradient: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.92), accent.opacity(0.66)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct AppCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

struct SectionHeading: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.bold))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct InitialBadge: View {
    let text: String
    let size: CGFloat
    let color: Color

    init(text: String, size: CGFloat = 52, color: Color = AppTheme.accent) {
        self.text = String(text.prefix(1))
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

struct InfoChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppTheme.accent.opacity(0.10), in: Capsule())
    }
}

struct EmptyStateIllustration: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 42, weight: .medium))
            .foregroundStyle(AppTheme.accent)
            .frame(width: 84, height: 84)
            .background(AppTheme.accent.opacity(0.10), in: Circle())
            .accessibilityHidden(true)
    }
}
