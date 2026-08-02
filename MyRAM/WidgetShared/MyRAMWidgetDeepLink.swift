import Foundation

enum MyRAMWidgetPlatform: Sendable {
    case iOS
    case macOS

    var scheme: String {
        switch self {
        case .iOS: "myram"
        case .macOS: "myram-mac"
        }
    }
}

struct MyRAMWidgetDeepLink: Sendable {
    static func url(noteID: UUID, platform: MyRAMWidgetPlatform) -> URL? {
        var components = URLComponents()
        components.scheme = platform.scheme
        components.host = "note"
        components.path = "/\(noteID.uuidString)"
        return components.url
    }

    static func noteID(from url: URL, platform: MyRAMWidgetPlatform) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == platform.scheme,
              components.host == "note",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        let pathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
        guard pathComponents.count == 1 else { return nil }
        return UUID(uuidString: String(pathComponents[0]))
    }
}
