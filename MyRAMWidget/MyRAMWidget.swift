import SwiftUI
import WidgetKit

private struct MyRAMWidgetEntry: TimelineEntry {
    let date: Date
    let model: MyRAMWidgetRenderModel
}

private struct MyRAMWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MyRAMWidgetEntry {
        MyRAMWidgetEntry(
            date: .now,
            model: MyRAMWidgetRenderModel(
                title: "Pinned Text",
                pinnedTexts: ["Your most important text"],
                bodyText: "Additional note text appears when space remains.",
                bodyLineLimit: context.family == .systemMedium ? 3 : 2,
                state: .content,
                noteURL: nil
            )
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (MyRAMWidgetEntry) -> Void
    ) {
        completion(entry(for: context.family))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<MyRAMWidgetEntry>) -> Void
    ) {
        completion(Timeline(entries: [entry(for: context.family)], policy: .never))
    }

    private func entry(for family: WidgetFamily) -> MyRAMWidgetEntry {
        let readResult: MyRAMWidgetSnapshotReadResult
        if let configuration = MyRAMWidgetRuntimeConfiguration() {
            readResult = MyRAMWidgetSnapshotStore(
                containerURLProvider: { configuration.containerURL() }
            ).read()
        } else {
            readResult = .inaccessible
        }

        let model = MyRAMWidgetContentSelectionPolicy().renderModel(
            from: readResult,
            family: family == .systemMedium ? .medium : .small,
            platform: .iOS
        )
        return MyRAMWidgetEntry(date: .now, model: model)
    }
}

private struct MyRAMWidgetEntryView: View {
    let entry: MyRAMWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.model.title.isEmpty {
                Text(entry.model.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            ForEach(Array(entry.model.pinnedTexts.enumerated()), id: \.offset) { _, text in
                HStack(spacing: 5) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if let bodyText = entry.model.bodyText, entry.model.bodyLineLimit > 0 {
                Text(bodyText)
                    .font(.footnote)
                    .foregroundStyle(entry.model.state == .content ? .secondary : .primary)
                    .lineLimit(entry.model.bodyLineLimit)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(entry.model.noteURL)
        .containerBackground(.background, for: .widget)
    }
}

struct MyRAMWidget: Widget {
    static let kind = "com.northsignalstudio.myram.priority-widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: MyRAMWidgetProvider()) { entry in
            MyRAMWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pinned Text")
        .description("Keeps your selected note and its most important text visible.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    MyRAMWidget()
} timeline: {
    MyRAMWidgetEntry(
        date: .now,
        model: MyRAMWidgetRenderModel(
            title: "Project Notes",
            pinnedTexts: ["Review the release checklist"],
            bodyText: "Confirm the remaining verification items before publishing.",
            bodyLineLimit: 2,
            state: .content,
            noteURL: nil
        )
    )
}
