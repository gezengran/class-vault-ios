import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let startupError = container.startupError {
                StartupErrorView(message: startupError)
            } else if !container.isUnlocked {
                LockView()
            } else if let repository = container.repository {
                StudentListView(repository: repository)
            } else {
                StartupErrorView(message: "本地加密存储无法初始化。")
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .tint(AppTheme.accent)
        .onChange(of: scenePhase) { _, newPhase in
            container.handleScenePhase(newPhase)
        }
    }
}

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                EmptyStateIllustration(systemImage: "lock.trianglebadge.exclamationmark")
                Text("本地存储不可用")
                    .font(.title2.weight(.bold))
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: 520)
            .padding(24)
        }
    }
}

struct LockView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            AppTheme.heroGradient.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 88, height: 88)
                            .background(.white.opacity(0.16), in: Circle())

                        Text("班匣")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("本地加密保存，安心管理学生联系人")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                    }

                    AppCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("隐私保护")
                                .font(.headline.weight(.bold))
                            PrivacyRow(systemImage: "lock.fill", text: "数据只保存在本机")
                            PrivacyRow(systemImage: "key.fill", text: "数据库使用 SQLCipher 加密")
                            PrivacyRow(systemImage: "faceid", text: "通过 Face ID 或设备密码解锁")
                        }
                    }

                    Button {
                        isAuthenticating = true
                        Task {
                            await container.unlock()
                            isAuthenticating = false
                        }
                    } label: {
                        Label("使用 Face ID 或设备密码解锁", systemImage: "faceid")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(AppTheme.accentDark)
                    .disabled(isAuthenticating)
                    .accessibilityIdentifier("unlock-button")

                    if isAuthenticating {
                        ProgressView("正在验证…")
                            .tint(.white)
                            .foregroundStyle(.white)
                            .accessibilityLabel("正在验证")
                    }

                    Text("解锁后才能查看学生姓名、学号和联系方式。")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.76))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 44)
            }
        }
        .accessibilityIdentifier("lock-screen")
    }
}

private struct PrivacyRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.primary)
    }
}
