import Foundation
import LocalAuthentication

// Authentication services are passed into async authentication calls from the
// main-actor app container. Conforming implementations must be safe to cross
// that actor boundary; LocalAuthenticationService is stateless and creates a
// fresh LAContext for each request.
public protocol AuthenticationService: AnyObject, Sendable {
    func authenticate() async -> Bool
}

public final class LocalAuthenticationService: AuthenticationService, @unchecked Sendable {
    public init() {}

    public func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "解锁保存在本机的学生联系人。"
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
