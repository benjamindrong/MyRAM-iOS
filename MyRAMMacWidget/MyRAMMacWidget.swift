import SwiftUI
import WidgetKit

private extension MyRAMWidgetFamily {
    init(widgetFamily: WidgetFamily) {
        switch widgetFamily {
        case .systemMedium:
            self = .medium
        case .systemSmall:
            self = .small
        default:
            self = .small
        }
    }
}

private struct MyRAMMacWidgetEntry: TimelineEntry {
    let date: Date
    let model: MyRAMWidgetRenderModel
}

private struct MyRAMMacWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MyRAMMacWidgetEntry {
        MyRAMMacWidgetEntry(
            date: .now,
            model: MyRAMWidgetRenderModel(
                title: "Pinned Text",
                pinnedTexts: ["Your most important text"],
                bodyText: "Additional note text appears when space remains.",
                state: .content,
                noteURL: nil
            )
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (MyRAMMacWidgetEntry) -> Void
    ) {
        completion(entry(for: context.family))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<MyRAMMacWidgetEntry>) -> Void
    ) {
        completion(Timeline(entries: [entry(for: context.family)], policy: .never))
    }

    private func entry(for family: WidgetFamily) -> MyRAMMacWidgetEntry {
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
            family: MyRAMWidgetFamily(widgetFamily: family),
            platform: .macOS
        )
        return MyRAMMacWidgetEntry(date: .now, model: model)
    }
}

private struct MyRAMMacWidgetEntryView: View {
    let entry: MyRAMMacWidgetEntry
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetContentMargins) private var widgetContentMargins

    private var layoutPolicy: MyRAMWidgetLayoutPolicy {
        MyRAMWidgetLayoutPolicy(
            family: MyRAMWidgetFamily(widgetFamily: widgetFamily),
            platform: .macOS
        )
    }

    private var contentInsets: EdgeInsets {
        let scale = layoutPolicy.contentMarginScale
        return EdgeInsets(
            top: widgetContentMargins.top * scale,
            leading: widgetContentMargins.leading * scale,
            bottom: widgetContentMargins.bottom * scale,
            trailing: widgetContentMargins.trailing * scale
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layoutPolicy.rootSpacing) {
            if !entry.model.title.isEmpty {
                Text(entry.model.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            ForEach(Array(entry.model.pinnedTexts.enumerated()), id: \.offset) { _, text in
                HStack(spacing: layoutPolicy.pinSpacing) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
            }

            if let bodyText = entry.model.bodyText {
                Text(bodyText)
                    .font(.footnote)
                    .foregroundStyle(entry.model.state == .content ? .secondary : .primary)
                    .truncationMode(.tail)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                    .layoutPriority(0)
            }
        }
        .padding(contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(entry.model.noteURL)
        .containerBackground(.background, for: .widget)
    }
}

struct MyRAMMacWidget: Widget {
    static let kind = "com.northsignalstudio.myram.mac.priority-widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: MyRAMMacWidgetProvider()) { entry in
            MyRAMMacWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pinned Text")
        .description("Keeps your selected note and its most important text visible.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
