import Foundation
import SwiftUI

@MainActor
public final class AppContainer: ObservableObject {
    @Published public private(set) var repository: SQLiteStudentRepository?
    public let authenticationService: AuthenticationService

    @Published public private(set) var isUnlocked: Bool
    @Published public private(set) var startupError: String?

    private let repositoryFactory: () throws -> SQLiteStudentRepository
    private var lastAuthenticatedAt: Date? = nil
    private let lockTimeout: TimeInterval = 300

    public init(
        repository: SQLiteStudentRepository? = nil,
        authenticationService: AuthenticationService = LocalAuthenticationService(),
        repositoryFactory: @escaping () throws -> SQLiteStudentRepository = { try SQLiteStudentRepository() }
    ) {
        self.authenticationService = authenticationService
        self.repositoryFactory = repositoryFactory
        self.repository = repository
        self.startupError = nil
        self.isUnlocked = false

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-unlocked") && !arguments.contains("--ui-testing-lock") {
            do {
                if self.repository == nil {
                    self.repository = try repositoryFactory()
                }
                if let repository = self.repository {
                    if arguments.contains("--ui-testing-demo-data") {
                        try? repository.seedSyntheticData()
                    }
                    self.isUnlocked = true
                    self.lastAuthenticatedAt = Date()
                }
            } catch {
                    self.startupError = "本地加密数据库无法初始化。"
            }
        }
        #endif
    }

    public func unlock() async {
        guard await authenticationService.authenticate() else { return }
        do {
            if repository == nil {
                repository = try repositoryFactory()
            }
            guard repository != nil else { throw DatabaseError.openFailed(-1) }
            startupError = nil
            isUnlocked = true
            lastAuthenticatedAt = Date()
        } catch {
            startupError = "本地加密数据库无法初始化。"
            isUnlocked = false
        }
    }

    public func lock() {
        isUnlocked = false
        lastAuthenticatedAt = nil
        repository = nil
    }

    public func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if let lastAuthenticatedAt, Date().timeIntervalSince(lastAuthenticatedAt) >= lockTimeout {
                lock()
            }
        case .active:
            if let lastAuthenticatedAt, Date().timeIntervalSince(lastAuthenticatedAt) >= lockTimeout {
                lock()
            }
        default:
            break
        }
    }
}
