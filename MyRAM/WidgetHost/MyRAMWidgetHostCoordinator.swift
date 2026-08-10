import Combine
import Foundation
import SwiftData
import WidgetKit

@MainActor
final class MyRAMWidgetNoteSelectionStore: ObservableObject {
    static let key = "widgetSelectedNoteID"

    @Published private(set) var selectedNoteID: UUID?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedNoteID = defaults.string(forKey: Self.key).flatMap(UUID.init(uuidString:))
    }

    func select(_ noteID: UUID) {
        guard selectedNoteID != noteID else { return }
        selectedNoteID = noteID
        defaults.set(noteID.uuidString, forKey: Self.key)
    }

    func clear() {
        guard selectedNoteID != nil else { return }
        selectedNoteID = nil
        defaults.removeObject(forKey: Self.key)
    }
}

@MainActor
final class MyRAMWidgetHostCoordinator: ObservableObject {
    enum Platform {
        case iOS
        case macOS

        var kind: String {
            switch self {
            case .iOS:
                return "com.northsignalstudio.myram.priority-widget"
            case .macOS:
                return "com.northsignalstudio.myram.mac.priority-widget"
            }
        }
    }

    @Published private(set) var selectedNoteID: UUID?

    let selectionStore: MyRAMWidgetNoteSelectionStore

    private let observedContext: ModelContext
    private let snapshotStore: MyRAMWidgetSnapshotStore?
    private let platform: Platform
    private let notificationCenter: NotificationCenter
    private let pinnedHighlightColorRawProvider: @MainActor () -> String?
    private let reloadTimelines: @MainActor (String) -> Void
    private let debounceNanoseconds: UInt64

    private var didSaveObserver: NSObjectProtocol?
    private var pendingRefreshTask: Task<Void, Never>?
    private var selectionCancellable: AnyCancellable?

    init(
        container: ModelContainer,
        observedContext: ModelContext,
        platform: Platform,
        selectionStore: MyRAMWidgetNoteSelectionStore? = nil,
        snapshotStore: MyRAMWidgetSnapshotStore? = nil,
        bundle: Bundle = .main,
        notificationCenter: NotificationCenter = .default,
        debounceNanoseconds: UInt64 = 150_000_000,
        pinnedHighlightColorRawProvider: @escaping @MainActor () -> String? = {
            UserDefaults.standard.string(forKey: "pinnedHighlightColor")
        },
        reloadTimelines: @escaping @MainActor (String) -> Void = { kind in
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    ) {
        let resolvedSelectionStore = selectionStore ?? MyRAMWidgetNoteSelectionStore()
        _ = container
        self.observedContext = observedContext
        self.platform = platform
        self.selectionStore = resolvedSelectionStore
        self.notificationCenter = notificationCenter
        self.debounceNanoseconds = debounceNanoseconds
        self.pinnedHighlightColorRawProvider = pinnedHighlightColorRawProvider
        self.reloadTimelines = reloadTimelines
        selectedNoteID = resolvedSelectionStore.selectedNoteID

        if let snapshotStore {
            self.snapshotStore = snapshotStore
        } else if let configuration = MyRAMWidgetRuntimeConfiguration(bundle: bundle) {
            self.snapshotStore = MyRAMWidgetSnapshotStore(
                containerURLProvider: { configuration.containerURL() }
            )
        } else {
            self.snapshotStore = nil
        }

        selectionCancellable = resolvedSelectionStore.$selectedNoteID
            .sink { [weak self] noteID in
                self?.selectedNoteID = noteID
            }
    }

    deinit {
        pendingRefreshTask?.cancel()
        if let didSaveObserver {
            notificationCenter.removeObserver(didSaveObserver)
        }
    }

    func start() {
        guard didSaveObserver == nil else { return }
        didSaveObserver = notificationCenter.addObserver(
            forName: ModelContext.didSave,
            object: observedContext,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.schedulePublication()
            }
        }
    }

    func select(noteID: UUID) {
        selectionStore.select(noteID)
        publishNow()
    }

    func removeSelection() {
        selectionStore.clear()
        publishNow()
    }

    func isSelected(noteID: UUID) -> Bool {
        selectedNoteID == noteID
    }

    @discardableResult
    func publishNow() -> WidgetSnapshotPublicationOutcome {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil

        guard let snapshotStore else { return .failed }

        let envelope: MyRAMWidgetSnapshotEnvelope
        if let selectedNoteID = selectionStore.selectedNoteID {
            let descriptor = FetchDescriptor<Note>(
                predicate: #Predicate { note in
                    note.id == selectedNoteID && note.deletedAt == nil
                }
            )

            guard let note = try? observedContext.fetch(descriptor).first else {
                selectionStore.clear()
                envelope = MyRAMWidgetSnapshotEnvelope(generatedAt: .now, note: nil)
                return publish(envelope, through: snapshotStore)
            }

            let orderedPinnedTexts = note.pinnedThoughts
                .sorted { lhs, rhs in
                    if lhs.order != rhs.order {
                        return lhs.order < rhs.order
                    }
                    if lhs.createdAt != rhs.createdAt {
                        return lhs.createdAt < rhs.createdAt
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                .map(\.text)

            envelope = MyRAMWidgetSnapshotEnvelope(
                generatedAt: .now,
                note: MyRAMWidgetSnapshotBounds.makeNoteSnapshot(
                    id: note.id,
                    title: note.title,
                    orderedPinnedTexts: orderedPinnedTexts,
                    bodyPreviewSource: note.content,
                    pinnedHighlightColorRaw: pinnedHighlightColorRawProvider()
                )
            )
        } else {
            envelope = MyRAMWidgetSnapshotEnvelope(generatedAt: .now, note: nil)
        }

        return publish(envelope, through: snapshotStore)
    }

    private func schedulePublication() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            publishNow()
        }
    }

    private func publish(
        _ envelope: MyRAMWidgetSnapshotEnvelope,
        through store: MyRAMWidgetSnapshotStore
    ) -> WidgetSnapshotPublicationOutcome {
        let outcome = store.publish(envelope)
        if outcome == .published {
            reloadTimelines(platform.kind)
        }
        return outcome
    }
}
