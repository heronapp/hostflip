import Foundation
@testable import HostflipXPC

/// Scriptable fake of the SMAppService surface: presets the status register lands on and the error it throws,
/// and records call order; the status can be rewritten mid-test to simulate user actions in System Settings.
final class FakeDaemonManager: DaemonServiceManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var current: DaemonRegistrationStatus
    private let afterRegister: DaemonRegistrationStatus
    private let registerError: Error?
    /// The first N register calls throw and leave the status unchanged — simulating an unregister that has not yet settled in BTM.
    private var failingRegisterAttempts: Int
    /// unregister throws and leaves the status unchanged — simulating a failed unregister.
    private let unregisterError: Error?
    private var calls: [String] = []

    init(
        status: DaemonRegistrationStatus,
        afterRegister: DaemonRegistrationStatus? = nil,
        registerError: Error? = nil,
        failingRegisterAttempts: Int = 0,
        unregisterError: Error? = nil
    ) {
        self.current = status
        self.afterRegister = afterRegister ?? status
        self.registerError = registerError
        self.failingRegisterAttempts = failingRegisterAttempts
        self.unregisterError = unregisterError
    }

    func status() -> DaemonRegistrationStatus {
        lock.withLock { current }
    }

    func setStatus(_ status: DaemonRegistrationStatus) {
        lock.withLock { current = status }
    }

    func register() throws {
        try lock.withLock {
            calls.append("register")
            if failingRegisterAttempts > 0 {
                failingRegisterAttempts -= 1
                throw NSError(domain: "SMAppServiceErrorDomain", code: 78)
            }
            current = afterRegister
            if let registerError { throw registerError }
        }
    }

    func unregister() async throws {
        try lock.withLock {
            calls.append("unregister")
            if let unregisterError { throw unregisterError }
            current = .notRegistered
        }
    }

    func openApprovalSettings() {
        lock.withLock { calls.append("openApprovalSettings") }
    }

    var recordedCalls: [String] {
        lock.withLock { calls }
    }
}

/// Thread-safe stub for the recorded registered version, standing in for UserDefaults.
final class VersionRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) {
        self.value = value
    }

    var current: String? {
        lock.withLock { value }
    }

    func set(_ newValue: String?) {
        lock.withLock { value = newValue }
    }
}
