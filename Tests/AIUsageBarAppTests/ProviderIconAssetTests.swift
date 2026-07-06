import Testing
import UsageCore

@testable import AIUsageBarApp

@Test
@MainActor
func providerIconAssetsLoadForAllProviders() throws {
    for provider in ProviderID.allCases {
        let image = try #require(ProviderIconAsset.image(for: provider))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}
