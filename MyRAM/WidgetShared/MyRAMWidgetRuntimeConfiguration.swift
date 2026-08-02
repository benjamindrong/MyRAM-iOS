import Foundation

struct MyRAMWidgetRuntimeConfiguration: Equatable, Sendable {
    static let appGroupInfoPlistKey = "MyRAMWidgetAppGroupIdentifier"

    let appGroupIdentifier: String

    init?(bundle: Bundle = .main) {
        guard let value = bundle.object(
            forInfoDictionaryKey: Self.appGroupInfoPlistKey
        ) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        appGroupIdentifier = trimmed
    }

    init?(appGroupIdentifier: String) {
        let trimmed = appGroupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.appGroupIdentifier = trimmed
    }

    func containerURL(fileManager: FileManager = .default) -> URL? {
#if os(iOS) || os(macOS)
        fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
#else
        nil
#endif
    }
}
