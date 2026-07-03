import Testing

@testable import AIUsageBarApp

@Test
func systemLaunchAtLoginManagerRegistersOnlyWhenDisabled() throws {
    let client = RecordingLaunchServiceClient(status: .disabled)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    try manager.setEnabled(true)

    #expect(client.events == [.register])
}

@Test
func systemLaunchAtLoginManagerSkipsRegisterWhenAlreadyEnabled() throws {
    let client = RecordingLaunchServiceClient(status: .enabled)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    try manager.setEnabled(true)

    #expect(client.events.isEmpty)
}

@Test
func systemLaunchAtLoginManagerUnregistersOnlyWhenEnabled() throws {
    let client = RecordingLaunchServiceClient(status: .enabled)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    try manager.setEnabled(false)

    #expect(client.events == [.unregister])
}

@Test
func systemLaunchAtLoginManagerSkipsUnregisterWhenAlreadyDisabled() throws {
    let client = RecordingLaunchServiceClient(status: .disabled)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    try manager.setEnabled(false)

    #expect(client.events.isEmpty)
}

@Test
func systemLaunchAtLoginManagerPropagatesRegisterError() {
    let client = RecordingLaunchServiceClient(
        status: .disabled,
        registerError: LaunchServiceTestError.failed
    )
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    #expect(throws: LaunchServiceTestError.failed) {
        try manager.setEnabled(true)
    }
}

@Test
func systemLaunchAtLoginManagerPropagatesUnregisterError() {
    let client = RecordingLaunchServiceClient(
        status: .enabled,
        unregisterError: LaunchServiceTestError.failed
    )
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    #expect(throws: LaunchServiceTestError.failed) {
        try manager.setEnabled(false)
    }
}

@Test
func systemLaunchAtLoginManagerReportsApprovalRequiredStatus() {
    let client = RecordingLaunchServiceClient(status: .requiresApproval)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    #expect(manager.status == .requiresApproval)
}

@Test
func systemLaunchAtLoginManagerDoesNotReregisterWhenApprovalIsRequired() {
    let client = RecordingLaunchServiceClient(status: .requiresApproval)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    #expect(throws: LaunchAtLoginError.requiresApproval) {
        try manager.setEnabled(true)
    }
    #expect(client.events.isEmpty)
}

@Test
func systemLaunchAtLoginManagerUnregistersWhenApprovalIsRequired() throws {
    let client = RecordingLaunchServiceClient(status: .requiresApproval)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    try manager.setEnabled(false)

    #expect(client.events == [.unregister])
    #expect(client.status == .disabled)
}

private final class RecordingLaunchServiceClient: LaunchAtLoginServiceClient {
    private(set) var status: LaunchAtLoginStatus
    private let registerError: (any Error)?
    private let unregisterError: (any Error)?
    private(set) var events: [LaunchServiceEvent] = []

    init(
        status: LaunchAtLoginStatus,
        registerError: (any Error)? = nil,
        unregisterError: (any Error)? = nil
    ) {
        self.status = status
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func register() throws {
        if let registerError {
            throw registerError
        }

        events.append(.register)
        status = .enabled
    }

    func unregister() throws {
        if let unregisterError {
            throw unregisterError
        }

        events.append(.unregister)
        status = .disabled
    }
}

private enum LaunchServiceEvent: Equatable {
    case register
    case unregister
}

private enum LaunchServiceTestError: Error, Equatable {
    case failed
}
