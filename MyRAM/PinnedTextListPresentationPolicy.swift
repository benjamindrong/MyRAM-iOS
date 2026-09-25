import Foundation

struct PinnedTextListPresentationPlan: Equatable {
    static let countAccessibilityIdentifier = "myram.noteRow.pinnedTextCount"

    let firstPinnedTextPreview: String?
    let secondPinnedTextPreview: String?
    let firstPinnedTextLineLimit: Int
    let secondPinnedTextLineLimit: Int
    let bodyPreview: String?
    let bodyIsEligible: Bool
    let bodyLineLimit: Int
    let totalPinnedTextCount: Int
    let remainingPinnedTextCount: Int
    let visibleCountText: String?
    let accessibilityCountText: String?
    let countAccessibilityIdentifier: String?
    let countOccupiesAuxiliarySlot: Bool

    var pinnedTextPreviews: [String] {
        [firstPinnedTextPreview, secondPinnedTextPreview].compactMap { $0 }
    }
}

struct PinnedTextListPresentationPolicy {
    func plan(
        pinnedTexts: [PinnedThought],
        bodyPreview: String
    ) -> PinnedTextListPresentationPlan {
        let displayEligiblePinnedTexts = pinnedTexts
            .sorted {
                if $0.order != $1.order {
                    return $0.order < $1.order
                }
                return $0.createdAt < $1.createdAt
            }
            .compactMap { pinnedText -> String? in
                let trimmed = pinnedText.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

        let totalCount = displayEligiblePinnedTexts.count
        let firstPreview = displayEligiblePinnedTexts.first
        let secondPreview = totalCount > 1 ? displayEligiblePinnedTexts[1] : nil
        let nonemptyBodyPreview = bodyPreview.isEmpty ? nil : bodyPreview

        switch totalCount {
        case 0:
            return PinnedTextListPresentationPlan(
                firstPinnedTextPreview: nil,
                secondPinnedTextPreview: nil,
                firstPinnedTextLineLimit: 1,
                secondPinnedTextLineLimit: 1,
                bodyPreview: nonemptyBodyPreview,
                bodyIsEligible: nonemptyBodyPreview != nil,
                bodyLineLimit: 2,
                totalPinnedTextCount: 0,
                remainingPinnedTextCount: 0,
                visibleCountText: nil,
                accessibilityCountText: nil,
                countAccessibilityIdentifier: nil,
                countOccupiesAuxiliarySlot: false
            )
        case 1:
            return PinnedTextListPresentationPlan(
                firstPinnedTextPreview: firstPreview,
                secondPinnedTextPreview: nil,
                firstPinnedTextLineLimit: 1,
                secondPinnedTextLineLimit: 1,
                bodyPreview: nonemptyBodyPreview,
                bodyIsEligible: nonemptyBodyPreview != nil,
                bodyLineLimit: 1,
                totalPinnedTextCount: 1,
                remainingPinnedTextCount: 0,
                visibleCountText: nil,
                accessibilityCountText: nil,
                countAccessibilityIdentifier: nil,
                countOccupiesAuxiliarySlot: false
            )
        case 2:
            return PinnedTextListPresentationPlan(
                firstPinnedTextPreview: firstPreview,
                secondPinnedTextPreview: secondPreview,
                firstPinnedTextLineLimit: 1,
                secondPinnedTextLineLimit: 1,
                bodyPreview: nil,
                bodyIsEligible: false,
                bodyLineLimit: 0,
                totalPinnedTextCount: 2,
                remainingPinnedTextCount: 0,
                visibleCountText: "2 pinned texts",
                accessibilityCountText: "2 pinned texts",
                countAccessibilityIdentifier: PinnedTextListPresentationPlan.countAccessibilityIdentifier,
                countOccupiesAuxiliarySlot: true
            )
        default:
            let remainingCount = totalCount - 2
            return PinnedTextListPresentationPlan(
                firstPinnedTextPreview: firstPreview,
                secondPinnedTextPreview: secondPreview,
                firstPinnedTextLineLimit: 1,
                secondPinnedTextLineLimit: 1,
                bodyPreview: nil,
                bodyIsEligible: false,
                bodyLineLimit: 0,
                totalPinnedTextCount: totalCount,
                remainingPinnedTextCount: remainingCount,
                visibleCountText: "\(totalCount) pinned texts · +\(remainingCount) more",
                accessibilityCountText: "\(totalCount) pinned texts, \(remainingCount) more not shown",
                countAccessibilityIdentifier: PinnedTextListPresentationPlan.countAccessibilityIdentifier,
                countOccupiesAuxiliarySlot: true
            )
        }
    }
}
