import Foundation
import os

enum EditorSelectionProfiling {
    static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.apexcoretechs.myram",
        category: .pointsOfInterest
    )

    static let disablesFormattingUpdates = isEnabled("MYR_PROFILE_DISABLE_FORMATTING_UPDATES")
    static let disablesSearchHighlights = isEnabled("MYR_PROFILE_DISABLE_SEARCH_HIGHLIGHTS")
    static let disablesChecklistRendering = isEnabled("MYR_PROFILE_DISABLE_CHECKLIST_RENDERING")
    static let disablesCustomGestures = isEnabled("MYR_PROFILE_DISABLE_CUSTOM_GESTURES")
    static let forcesTextKit1 = isEnabled("MYR_PROFILE_FORCE_TEXTKIT1")

    private static func isEnabled(_ name: String) -> Bool {
        let processInfo = ProcessInfo.processInfo
        if processInfo.arguments.contains(name) {
            return true
        }

        guard let value = processInfo.environment[name]?.lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }
}
