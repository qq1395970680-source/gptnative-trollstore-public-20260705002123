import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.05, green: 0.48, blue: 0.39)
    static let userBubble = Color(red: 0.04, green: 0.43, blue: 0.35)
    static let assistantBubble = Color(.secondarySystemGroupedBackground)
    static let hairline = Color(.separator).opacity(0.45)
}

struct GlassToolbarBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color(.systemBackground))
            .ignoresSafeArea(edges: .top)
    }
}
