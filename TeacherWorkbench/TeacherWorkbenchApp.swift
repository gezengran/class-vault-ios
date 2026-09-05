import SwiftUI

@main
struct TeacherWorkbenchApp: App {
    @StateObject private var container: AppContainer

    init() {
        _container = StateObject(wrappedValue: AppContainer())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .tint(AppTheme.accent)
        }
    }
}
