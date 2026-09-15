import Foundation
import Testing
import UsageCore

@Test
func xaiTeamIDNormalizerAcceptsUUIDAndLowercases() {
    #expect(
        XAITeamID.normalizedID(from: "  65C1E471-205F-4566-9C5A-07198BCDF4CE  ")
            == "65c1e471-205f-4566-9c5a-07198bcdf4ce"
    )
}

@Test
func xaiTeamIDNormalizerRejectsEmptyAndNonUUID() {
    #expect(XAITeamID.normalizedID(from: nil) == nil)
    #expect(XAITeamID.normalizedID(from: "") == nil)
    #expect(XAITeamID.normalizedID(from: "   ") == nil)
    #expect(XAITeamID.normalizedID(from: "not-a-uuid") == nil)
    #expect(XAITeamID.normalizedID(from: "xai-zk-inference") == nil)
}

@Test
func xaiManagementCredentialReaderReturnsKeyAndTeamID() throws {
    let store = InMemoryXAIManagementKeyStore(key: "xai-mgmt")
    let reader = XAIManagementCredentialReader(
        keyStore: store,
        teamID: { "00000000-0000-4000-8000-000000000001" }
    )

    #expect(
        try reader.read(mode: .background)
            == .fresh(XAIManagementCredential(
                key: "xai-mgmt",
                teamID: "00000000-0000-4000-8000-000000000001"
            ))
    )
}

@Test
func xaiManagementCredentialReaderIsUnavailableWithoutTeamID() throws {
    let reader = XAIManagementCredentialReader(
        keyStore: InMemoryXAIManagementKeyStore(key: "xai-mgmt"),
        teamID: { nil }
    )

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func xaiManagementCredentialReaderIsUnavailableWithoutKey() throws {
    let reader = XAIManagementCredentialReader(
        keyStore: InMemoryXAIManagementKeyStore(),
        teamID: { "00000000-0000-4000-8000-000000000001" }
    )

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func xaiManagementCredentialReaderRejectsNonUUIDTeamID() throws {
    let reader = XAIManagementCredentialReader(
        keyStore: InMemoryXAIManagementKeyStore(key: "xai-mgmt"),
        teamID: { "org-not-a-team" }
    )

    #expect(try reader.read(mode: .background) == .stale(reason: .credentialUnavailable))
}

@Test
func xaiManagementCredentialReaderDoesNotOpenOpenCodeAuthFile() throws {
    // Product pin: OpenCode's `xai` entry is an inference key. This reader
    // has no file URL and cannot borrow that credential.
    let reader = XAIManagementCredentialReader(
        keyStore: InMemoryXAIManagementKeyStore(),
        teamID: { nil }
    )

    #expect(try reader.read(mode: .interactive) == .stale(reason: .credentialUnavailable))
}

@Test
func inMemoryXAIManagementKeyStoreRoundTrips() throws {
    let store = InMemoryXAIManagementKeyStore()
    try store.write("  xai-mgmt  ")
    #expect(try store.read(mode: .background) == "  xai-mgmt  ")
    try store.delete()
    #expect(try store.read(mode: .background) == nil)
}

@Test
func keychainXAIManagementKeyStoreReadsInjectedItem() throws {
    let data = Data("xai-mgmt".utf8) as CFData
    let store = KeychainXAIManagementKeyStore(
        copyMatching: { _, result in
            result?.pointee = data
            return errSecSuccess
        },
        addItem: { _, _ in errSecSuccess },
        updateItem: { _, _ in errSecSuccess },
        deleteItem: { _ in errSecSuccess }
    )

    #expect(try store.read(mode: .background) == "xai-mgmt")
}

@Test
func keychainXAIManagementKeyStoreTreatsMissingItemAsNil() throws {
    let store = KeychainXAIManagementKeyStore(
        copyMatching: { _, _ in errSecItemNotFound },
        addItem: { _, _ in errSecSuccess },
        updateItem: { _, _ in errSecSuccess },
        deleteItem: { _ in errSecSuccess }
    )

    #expect(try store.read(mode: .background) == nil)
}

@Test
func keychainXAIManagementKeyStoreWritesThenUpdatesOnDuplicate() throws {
    var added = false
    var updated = false
    let store = KeychainXAIManagementKeyStore(
        copyMatching: { _, _ in errSecItemNotFound },
        addItem: { _, _ in
            if added {
                return errSecDuplicateItem
            }
            added = true
            return errSecSuccess
        },
        updateItem: { _, _ in
            updated = true
            return errSecSuccess
        },
        deleteItem: { _ in errSecSuccess }
    )

    try store.write("first")
    try store.write("second")
    #expect(added)
    #expect(updated)
}
