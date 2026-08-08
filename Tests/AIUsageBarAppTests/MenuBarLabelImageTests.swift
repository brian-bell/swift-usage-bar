import AppKit
import Testing
import UsageCore

@testable import AIUsageBarApp

@Test
func accessibilityValueIsAIUsageWhenSegmentsAreEmpty() {
    #expect(MenuBarLabelImage.accessibilityValue(for: []) == "AI Usage")
}

@Test
func accessibilityValueJoinsSingleProviderRowLabel() {
    let segments = [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false),
    ]
    #expect(MenuBarLabelImage.accessibilityValue(for: segments) == "Cl 62/81")
}

@Test
func accessibilityValueJoinsTwoProvidersWithPipe() {
    let segments = [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ]
    #expect(MenuBarLabelImage.accessibilityValue(for: segments) == "Cl 62/81 | Cx 90")
}

@Test
func accessibilityValuePreservesStaleTildePrefix() {
    let segments = [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: true),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ]
    #expect(MenuBarLabelImage.accessibilityValue(for: segments) == "Cl ~62/81 | Cx 90")
}

@Test
func accessibilityValueFlattensThreeProviderPartitionInDisplayOrder() {
    let segments = [
        MenuBarTitleSegment(provider: .claude, value: "100/100", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "100", isStale: true),
        MenuBarTitleSegment(provider: .openCodeGo, value: "100/--/100", isStale: false),
    ]
    #expect(
        MenuBarLabelImage.accessibilityValue(for: segments)
            == "Cl 100/100  Cx ~100 | Go 100/--/100"
    )
}

@Test
func rowLabelPrefixesProviderAbbreviation() {
    #expect(
        MenuBarLabelImage.rowLabel(
            for: MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false)
        ) == "Cl 62/81"
    )
    #expect(
        MenuBarLabelImage.rowLabel(
            for: MenuBarTitleSegment(provider: .codex, value: "90", isStale: false)
        ) == "Cx 90"
    )
}

@Test
func rowLabelRendersCreditsWithOcAbbreviation() {
    #expect(
        MenuBarLabelImage.rowLabel(
            for: MenuBarTitleSegment(provider: .openCodeCredits, value: "$47", isStale: false)
        ) == "Oc $47"
    )
    #expect(
        MenuBarLabelImage.rowLabel(
            for: MenuBarTitleSegment(provider: .openCodeCredits, value: "$47", isStale: true)
        ) == "Oc ~$47"
    )
}

@Test
func rowLabelMarksStaleValuesWithTilde() {
    #expect(
        MenuBarLabelImage.rowLabel(
            for: MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: true)
        ) == "Cl ~62/81"
    )
}

@Test
func rowLabelRendersMissingDataPlaceholder() {
    #expect(
        MenuBarLabelImage.rowLabel(
            for: MenuBarTitleSegment(provider: .codex, value: "--", isStale: false)
        ) == "Cx --"
    )
}

@Test
@MainActor
func menuBarLabelImageStacksTwoProvidersVertically() throws {
    let segments = [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ]
    let image = try #require(MenuBarLabelImage.image(for: segments))

    #expect(image.isTemplate)
    #expect(image.size.height == MenuBarLabelImage.rowHeight * 2)
    #expect(image.size.height <= 22)
    #expect(image.size.width == expectedWidth(for: segments))
}

@Test
@MainActor
func menuBarLabelImageSizesStaleAndMissingRowsFromTheirLabels() throws {
    let segments = [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: true),
        MenuBarTitleSegment(provider: .codex, value: "--", isStale: false),
    ]
    let image = try #require(MenuBarLabelImage.image(for: segments))

    #expect(image.isTemplate)
    #expect(image.size.height == MenuBarLabelImage.rowHeight * 2)
    #expect(image.size.width == expectedWidth(for: segments))
}

@Test
@MainActor
func menuBarLabelImageRendersSingleProviderAtReadableMenuBarHeight() throws {
    let segments = [
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ]
    let image = try #require(MenuBarLabelImage.image(for: segments))

    #expect(image.isTemplate)
    #expect(image.size.height == 18)
}

@Test(arguments: ProviderID.allCases)
@MainActor
func menuBarLabelImageUsesReadableFontForSingleProvider(provider: ProviderID) throws {
    let value: String
    switch provider {
    case .claude, .miniMax:
        value = "62/81"
    case .codex, .openCodeGo:
        value = "90"
    case .openCodeCredits:
        value = "$47"
    }
    let segment = MenuBarTitleSegment(provider: provider, value: value, isStale: false)
    let image = try #require(MenuBarLabelImage.image(for: [segment]))
    let readableAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
    let expectedWidth = ceil(
        (MenuBarLabelImage.rowLabel(for: segment) as NSString)
            .size(withAttributes: readableAttributes)
            .width
    )

    #expect(image.size.width == expectedWidth)
}

@Test
@MainActor
func menuBarLabelImageIsNilWhenAllProvidersAreHidden() {
    #expect(MenuBarLabelImage.image(for: []) == nil)
    #expect(MenuBarLabelImage.layout(for: []) == nil)
}

@Test
@MainActor
func menuBarLabelImagePartitionsFourProvidersAcrossTwoRows() throws {
    // The first time all four providers can be visible simultaneously,
    // MenuBarLabelImage.layout must still produce exactly two rows whose
    // widest row is no wider than the widest row of any other contiguous
    // split (in original order). Pin the partition invariant — a
    // regression in the comparator (e.g. inverting `lhsWidth < rhsWidth`)
    // would pick a needlessly wide split and still pass a height-only test.
    let segments = [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
        MenuBarTitleSegment(provider: .openCodeGo, value: "88/74/92", isStale: false),
        MenuBarTitleSegment(provider: .miniMax, value: "76/55", isStale: false),
    ]
    let labels = segments.map(MenuBarLabelImage.rowLabel(for:))
    let rowAttributes = MenuBarLabelImage.rowAttributes
    func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: rowAttributes).width
    }

    let candidateSplits: [(top: String, bottom: String, max: CGFloat)] =
        (1..<labels.count).map { split in
            let top = labels[..<split].joined(separator: "  ")
            let bottom = labels[split...].joined(separator: "  ")
            return (top, bottom, max(width(of: top), width(of: bottom)))
        }

    let image = try #require(MenuBarLabelImage.image(for: segments))
    let layout = try #require(MenuBarLabelImage.layout(for: segments))

    #expect(image.isTemplate)
    #expect(image.size.height == MenuBarLabelImage.rowHeight * 2)
    #expect(image.size.height <= 22)
    #expect(layout.rows.count == 2)
    // The two rendered rows must concatenate to the segment labels in
    // original order — the partition must preserve order.
    #expect(
        layout.rows.map(\.text).joined(separator: "  ")
            == labels.joined(separator: "  ")
    )
    // The chosen split's widest row is no wider than any other candidate's.
    let chosen = layout.rows.map(\.text)
    let chosenMax = chosen.map(width).max() ?? 0
    for candidate in candidateSplits {
        #expect(chosenMax <= candidate.max)
    }
}

@Test
@MainActor
func menuBarLabelImagePartitionsFiveProvidersAcrossTwoRows() throws {
    // With the credits provider on, all five segments must still land in
    // exactly two rows, in order, at the same two-row height budget.
    let segments = [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
        MenuBarTitleSegment(provider: .openCodeGo, value: "88/74/92", isStale: false),
        MenuBarTitleSegment(provider: .openCodeCredits, value: "$47", isStale: false),
        MenuBarTitleSegment(provider: .miniMax, value: "76/55", isStale: false),
    ]
    let labels = segments.map(MenuBarLabelImage.rowLabel(for:))

    let image = try #require(MenuBarLabelImage.image(for: segments))
    let layout = try #require(MenuBarLabelImage.layout(for: segments))

    #expect(image.size.height == MenuBarLabelImage.rowHeight * 2)
    #expect(layout.rows.count == 2)
    #expect(
        layout.rows.map(\.text).joined(separator: "  ")
            == labels.joined(separator: "  ")
    )
    #expect(layout.rows.map(\.text).joined(separator: "  ").contains("Oc $47"))
}

@Test
func menuBarLabelLayoutPlacesFirstSegmentInTopRow() throws {
    let layout = try #require(MenuBarLabelImage.layout(for: [
        MenuBarTitleSegment(provider: .claude, value: "62/81", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "90", isStale: false),
    ]))

    let rows = layout.rows
    #expect(rows.map(\.text) == ["Cl 62/81", "Cx 90"])
    // Non-flipped image coordinates: the first segment's row sits above the second's.
    #expect(rows[0].textOrigin.y == rows[1].textOrigin.y + MenuBarLabelImage.rowHeight)
    #expect(rows[1].textOrigin.y >= 0)
    #expect(layout.size.height == MenuBarLabelImage.rowHeight * 2)
}

@Test
func menuBarLabelLayoutPartitionsThreeProvidersAcrossTwoRows() throws {
    let layout = try #require(MenuBarLabelImage.layout(for: [
        MenuBarTitleSegment(provider: .claude, value: "100/100", isStale: false),
        MenuBarTitleSegment(provider: .codex, value: "100", isStale: true),
        MenuBarTitleSegment(provider: .openCodeGo, value: "100/--/100", isStale: false),
    ]))

    #expect(layout.rows.map(\.text) == ["Cl 100/100  Cx ~100", "Go 100/--/100"])
    #expect(layout.size.height == 22)
}

@MainActor
private func expectedWidth(for segments: [MenuBarTitleSegment]) -> CGFloat {
    let widest = segments
        .map { segment in
            (MenuBarLabelImage.rowLabel(for: segment) as NSString)
                .size(withAttributes: MenuBarLabelImage.rowAttributes)
                .width
        }
        .max() ?? 0
    return ceil(widest)
}
