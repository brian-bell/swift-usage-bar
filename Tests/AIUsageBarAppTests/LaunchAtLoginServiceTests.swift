import Testing

@testable import AIUsageBarApp

@Test
func systemLaunchAtLoginManagerRegistersOnlyWhenDisabled() throws {
    let client = RecordingLaunchServiceClient(isEnabled: false)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    try manager.setEnabled(true)

    #expect(client.events == [.register])
}

@Test
func systemLaunchAtLoginManagerSkipsRegisterWhenAlreadyEnabled() throws {
    let client = RecordingLaunchServiceClient(isEnabled: true)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    try manager.setEnabled(true)

    #expect(client.events.isEmpty)
}

@Test
func systemLaunchAtLoginManagerUnregistersOnlyWhenEnabled() throws {
    let client = RecordingLaunchServiceClient(isEnabled: true)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    try manager.setEnabled(false)

    #expect(client.events == [.unregister])
}

@Test
func systemLaunchAtLoginManagerSkipsUnregisterWhenAlreadyDisabled() throws {
    let client = RecordingLaunchServiceClient(isEnabled: false)
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    try manager.setEnabled(false)

    #expect(client.events.isEmpty)
}

@Test
func systemLaunchAtLoginManagerPropagatesRegisterError() {
    let client = RecordingLaunchServiceClient(
        isEnabled: false,
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
        isEnabled: true,
        unregisterError: LaunchServiceTestError.failed
    )
    let manager = SystemLaunchAtLoginManager(serviceClient: client)

    #expect(throws: LaunchServiceTestError.failed) {
        try manager.setEnabled(false)
    }
}

private final class RecordingLaunchServiceClient: LaunchAtLoginServiceClient {
    private(set) var isEnabled: Bool
    private let registerError: (any Error)?
    private let unregisterError: (any Error)?
    private(set) var events: [LaunchServiceEvent] = []

    init(
        isEnabled: Bool,
        registerError: (any Error)? = nil,
        unregisterError: (any Error)? = nil
    ) {
        self.isEnabled = isEnabled
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func register() throws {
        if let registerError {
            throw registerError
        }

        events.append(.register)
        isEnabled = true
    }

    func unregister() throws {
        if let unregisterError {
            throw unregisterError
        }

        events.append(.unregister)
        isEnabled = false
    }
}

private enum LaunchServiceEvent: Equatable {
    case register
    case unregister
}

private enum LaunchServiceTestError: Error, Equatable {
    case failed
}
