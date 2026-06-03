#if DEBUG
import Foundation
import SwiftData

@MainActor
enum DebugDemoDataGenerator {
    static let demoNoteIDs: Set<UUID> = Set(demoNotes.map(\.id))

    @discardableResult
    static func generateDemoNotes(in context: ModelContext) -> [Note] {
        clearDemoNotes(in: context)

        let notes = demoNotes.map { seed in
            let note = Note(title: seed.title, content: seed.body)
            note.id = seed.id
            note.createdAt = seed.date
            note.modifiedAt = seed.date
            note.deletedAt = nil
            note.isPinned = false

            context.insert(note)

            for (index, thoughtText) in seed.pinnedThoughts.enumerated() {
                let thought = PinnedThought(text: thoughtText, order: index, note: note)
                thought.createdAt = seed.date
                thought.modifiedAt = seed.date
                context.insert(thought)
                note.pinnedThoughts.append(thought)
            }

            return note
        }

        try? context.save()
        return notes
    }

    static func clearDemoNotes(in context: ModelContext) {
        let descriptor = FetchDescriptor<Note>()
        let notes = (try? context.fetch(descriptor)) ?? []
        for note in notes where demoNoteIDs.contains(note.id) {
            context.delete(note)
        }
        try? context.save()
    }

    private static let demoNotes: [DemoNoteSeed] = [
        DemoNoteSeed(
            id: UUID(uuidString: "61A00000-0000-0000-0000-000000000001")!,
            title: "TODAY - Jun 3, 2026",
            date: makeDate(year: 2026, month: 6, day: 3),
            pinnedThoughts: ["Ask landlord about garage opener"],
            bodyLines: [
                "Need to remember to move the laundry before bed.",
                "The garage door sounded weird again.",
                "Need cat food.",
                "It only seems to happen when closing, not opening.",
                "That conversation about memory was interesting.",
                "Maybe I should spray the rollers before calling someone.",
                "Remember to ask about insurance.",
                "The problem isn't forgetting things, it's losing track of them.",
                "I don't remember hearing the garage door make that noise last winter.",
                "Wonder if most people actually reread their notes."
            ]
        ),
        DemoNoteSeed(
            id: UUID(uuidString: "61A00000-0000-0000-0000-000000000002")!,
            title: "TODAY - Jun 2, 2026",
            date: makeDate(year: 2026, month: 6, day: 2),
            pinnedThoughts: ["Renew passport this month"],
            bodyLines: [
                "The coffee shop by the grocery store closed.",
                "Need paper towels.",
                "I still haven't watched that documentary.",
                "Wonder if the passport process is still mostly online now.",
                "The line at the gas station was ridiculous today.",
                "Need to stop leaving receipts in the center console.",
                "Maybe the kitchen light bulb is finally dying.",
                "I wonder how long that bulb has been in there.",
                "Forgot to move the package inside before it rained."
            ]
        ),
        DemoNoteSeed(
            id: UUID(uuidString: "61A00000-0000-0000-0000-000000000003")!,
            title: "TODAY - Jun 1, 2026",
            date: makeDate(year: 2026, month: 6, day: 1),
            pinnedThoughts: [
                "Call insurance tomorrow",
                "Bring passport to appointment"
            ],
            bodyLines: [
                "The passenger side tire looked low this morning.",
                "Wonder if that was the place with the weird hold music.",
                "Probably should check the tire pressure before driving too much.",
                "That movie was way longer than it needed to be.",
                "Need to find where I put the registration paperwork.",
                "Might have moved the passport when cleaning a few weeks ago.",
                "I think the tire looked fine yesterday.",
                "Still haven't finished that article I started reading last week."
            ]
        ),
        DemoNoteSeed(
            id: UUID(uuidString: "61A00000-0000-0000-0000-000000000004")!,
            title: "MyRAM",
            date: makeDate(year: 2026, month: 5, day: 31),
            pinnedThoughts: [
                "The problem is that important information gets buried",
                "Storage is not the problem",
                "Users lose track of information, not notes"
            ],
            bodyLines: [
                "Maybe the real issue is visibility.",
                "I found that article from six months ago almost immediately.",
                "Need to revisit the onboarding flow.",
                "People can usually find old notes if they search for them.",
                "Wonder if users immediately understand pinning.",
                "The thing that disappears is attention.",
                "Maybe \"Pinned Highlights\" explains itself better than \"Pinned Text\".",
                "Need screenshots before launch."
            ]
        ),
        DemoNoteSeed(
            id: UUID(uuidString: "61A00000-0000-0000-0000-000000000005")!,
            title: "Things To Buy Eventually",
            date: makeDate(year: 2026, month: 5, day: 30),
            pinnedThoughts: [
                "Office chair",
                "Better desk lighting"
            ],
            bodyLines: [
                "The chair starts hurting after a few hours.",
                "Need to measure the desk before buying anything.",
                "Wonder if Costco still carries that lamp.",
                "Could probably get away with a smaller chair.",
                "Need to check how much room is left in the office.",
                "That standing desk converter looked interesting.",
                "The lighting over the desk is worse than I realized."
            ]
        ),
        DemoNoteSeed(
            id: UUID(uuidString: "61A00000-0000-0000-0000-000000000006")!,
            title: "Stuff To Figure Out",
            date: makeDate(year: 2026, month: 5, day: 29),
            pinnedThoughts: [],
            bodyLines: [
                "Why does the bathroom fan make that noise sometimes?",
                "Need to look up furnace filter sizes again.",
                "I wonder if that noise only happens when it's humid.",
                "Could probably replace the weather stripping this summer.",
                "The fan didn't do it yesterday.",
                "Need to figure out what size batteries that flashlight uses.",
                "Maybe I should actually write down when it happens."
            ]
        ),
        DemoNoteSeed(
            id: UUID(uuidString: "61A00000-0000-0000-0000-000000000007")!,
            title: "Ideas Worth Revisiting",
            date: makeDate(year: 2026, month: 5, day: 28),
            pinnedThoughts: [
                "Stay connected to what matters",
                "Pinned Highlights are signal",
                "Home screen widget",
                "Cross-note highlights",
                "AI organization"
            ],
            bodyLines: [
                "The phrase still feels right.",
                "People don't usually lose notes.",
                "Need to look up widget limitations on iOS.",
                "They lose track of information.",
                "Cross-note highlights could be useful someday.",
                "The signal idea keeps coming back.",
                "Need to remember to send that email.",
                "AI organization should help surface useful information without assigning priorities.",
                "The wording probably still needs work.",
                "Home screen widgets would be useful for recurring information."
            ]
        ),
        DemoNoteSeed(
            id: UUID(uuidString: "61A00000-0000-0000-0000-000000000008")!,
            title: "Home Projects",
            date: makeDate(year: 2026, month: 5, day: 27),
            pinnedThoughts: ["Replace furnace filter"],
            bodyLines: [
                "The kitchen light flickered again.",
                "Need paper towels.",
                "Wonder if LED bulbs actually last as long as they claim.",
                "The neighbor finally finished that deck.",
                "Forgot where I put the tape measure.",
                "Need to stop leaving tools in random places.",
                "The garage is somehow messy again.",
                "Maybe that loose cabinet handle is finally getting worse.",
                "Need more batteries."
            ]
        )
    ]

    private static func makeDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: 9,
            minute: 0
        )) ?? .now
    }
}

private struct DemoNoteSeed {
    let id: UUID
    let title: String
    let date: Date
    let pinnedThoughts: [String]
    let bodyLines: [String]

    var body: String {
        bodyLines.joined(separator: "\n\n")
    }
}
#endif
