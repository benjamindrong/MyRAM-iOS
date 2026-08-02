import Combine
import Foundation

struct MyRAMExternalOpenRequest: Equatable, Identifiable {
    enum Kind: Equatable {
        case widgetNote(UUID)
        case file(URL)
    }

    let id: UUID
    let kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

@MainActor
final class MyRAMExternalOpenDispatcher: ObservableObject {
    private var queue: [MyRAMExternalOpenRequest] = []
    private var activeRequestID: UUID?

    var pendingCount: Int { queue.count }
    var hasActiveRequest: Bool { activeRequestID != nil }

    @discardableResult
    func enqueue(url: URL, platform: MyRAMWidgetPlatform) -> UUID? {
        let kind: MyRAMExternalOpenRequest.Kind
        if url.scheme == platform.scheme {
            guard let noteID = MyRAMWidgetDeepLink.noteID(from: url, platform: platform) else {
                return nil
            }
            kind = .widgetNote(noteID)
        } else {
            kind = .file(url)
        }

        let request = MyRAMExternalOpenRequest(kind: kind)
        queue.append(request)
        return request.id
    }

    func claimNextIfReady(
        startupIsReady: Bool,
        externalOperationIsAvailable: Bool
    ) -> MyRAMExternalOpenRequest? {
        guard startupIsReady,
              externalOperationIsAvailable,
              activeRequestID == nil,
              let request = queue.first else {
            return nil
        }

        activeRequestID = request.id
        return request
    }

    func complete(requestID: UUID) {
        guard activeRequestID == requestID,
              queue.first?.id == requestID else {
            return
        }
        queue.removeFirst()
        activeRequestID = nil
    }

    func retainForRetry(requestID: UUID) {
        guard activeRequestID == requestID,
              queue.first?.id == requestID else {
            return
        }
        activeRequestID = nil
    }

    func cancelAll() {
        queue.removeAll()
        activeRequestID = nil
    }
}
