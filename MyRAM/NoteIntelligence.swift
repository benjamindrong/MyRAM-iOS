import Foundation
import NaturalLanguage

struct NoteIntelligenceCanonicalInput {
    struct Features {
        let lemmas: [String]
        let tokens: [String]
        let posTags: [String]
        let openCount30d: Int
        let editCount7d: Int
        let firstPersonRatio: Double
    }

    struct Entities {
        let datetimes: [String]
        let emails: [String]
        let phones: [String]
        let urls: [String]
        let addresses: [String]
    }

    let noteID: String
    let text: String
    let language: String
    let createdAt: String
    let modifiedAt: String
    let features: Features
    let entities: Entities
    let similarNoteIDs: [String]
}

struct NoteIntelligenceSuggestion {
    let label: String
    let ruleID: String
    let score: Double
    let explanations: [String]
}

struct NoteIntelligenceRuleSpec: Decodable {
    struct Rule: Decodable {
        let id: String
        let label: String
        let priority: Int
        let conditions: [String: [String]]
        let rationale: String
    }

    let specVersion: Int
    let specName: String
    let labels: [String]
    let rules: [Rule]
}

struct NoteIntelligenceExtraction {
    struct Entities {
        var datetimes: [String] = []
        var emails: [String] = []
        var phones: [String] = []
        var urls: [String] = []
        var addresses: [String] = []
    }

    let language: String
    let tokens: [String]
    let lemmas: [String]
    let posTags: [String]
    let firstPersonRatio: Double
    let entities: Entities
    let topicKeywords: Set<String>
}

protocol NoteIntelligenceExtracting {
    func extract(text: String) -> NoteIntelligenceExtraction
}

struct NLTaggerNoteIntelligenceExtractor: NoteIntelligenceExtracting {
    func extract(text: String) -> NoteIntelligenceExtraction {
        let fullRange = text.startIndex..<text.endIndex
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = text

        var tokens: [String] = []
        var lemmas: [String] = []
        var posTags: [String] = []

        tagger.enumerateTags(
            in: fullRange,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { lexicalClass, tokenRange in
            let token = String(text[tokenRange])
            tokens.append(token)

            let lemmaTag = tagger.tag(at: tokenRange.lowerBound, unit: .word, scheme: .lemma).0
            if let lemma = lemmaTag?.rawValue, !lemma.isEmpty {
                lemmas.append(lemma.lowercased())
            } else {
                lemmas.append(token.lowercased())
            }

            if let lexicalClass {
                posTags.append(lexicalClass.rawValue)
            }

            return true
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage?.rawValue ?? "und"

        let entities = detectEntities(in: text)

        let firstPersonPronouns: Set<String> = [
            "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves"
        ]
        let firstPersonCount = tokens.reduce(into: 0) { count, token in
            if firstPersonPronouns.contains(token.lowercased()) {
                count += 1
            }
        }
        let firstPersonRatio = tokens.isEmpty ? 0 : Double(firstPersonCount) / Double(tokens.count)

        let topicKeywords = Set(lemmas.filter(Self.isTopicKeyword))

        return NoteIntelligenceExtraction(
            language: language,
            tokens: tokens,
            lemmas: lemmas,
            posTags: posTags,
            firstPersonRatio: firstPersonRatio,
            entities: entities,
            topicKeywords: topicKeywords
        )
    }

    private static func isTopicKeyword(_ lemma: String) -> Bool {
        let stopwords: Set<String> = [
            "a", "an", "and", "the", "to", "of", "for", "in", "on", "at", "with", "by", "is",
            "are", "was", "were", "be", "it", "this", "that", "from", "as", "or", "about", "after",
            "before", "into", "up", "down", "out", "off", "over", "under", "then", "than"
        ]
        return lemma.count >= 3 && !stopwords.contains(lemma)
    }

    private func detectEntities(in text: String) -> NoteIntelligenceExtraction.Entities {
        guard !text.isEmpty else { return .init() }

        let types: NSTextCheckingResult.CheckingType = [
            .date,
            .link,
            .phoneNumber,
            .address
        ]

        guard let detector = try? NSDataDetector(types: types.rawValue) else {
            return .init()
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: nsRange)
        var entities = NoteIntelligenceExtraction.Entities()

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let rawText = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)

            switch match.resultType {
            case .date:
                if !rawText.isEmpty {
                    entities.datetimes.append(rawText)
                }
            case .phoneNumber:
                if let phoneNumber = match.phoneNumber, !phoneNumber.isEmpty {
                    entities.phones.append(phoneNumber)
                }
            case .link:
                if let url = match.url {
                    if url.scheme?.lowercased() == "mailto",
                       let resource = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
                       !resource.isEmpty {
                        entities.emails.append(resource)
                    } else {
                        entities.urls.append(url.absoluteString)
                    }
                }
            case .address:
                if !rawText.isEmpty {
                    entities.addresses.append(rawText)
                }
            default:
                continue
            }
        }

        return NoteIntelligenceExtraction.Entities(
            datetimes: Array(Set(entities.datetimes)).sorted(),
            emails: Array(Set(entities.emails)).sorted(),
            phones: Array(Set(entities.phones)).sorted(),
            urls: Array(Set(entities.urls)).sorted(),
            addresses: Array(Set(entities.addresses)).sorted()
        )
    }
}

final class NoteIntelligenceActivityTracker {
    private struct Store: Codable {
        var opensByNoteID: [String: [Date]] = [:]
        var editsByNoteID: [String: [Date]] = [:]
    }

    private let userDefaults: UserDefaults
    private let key = "note_intelligence_activity.v1"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func recordOpen(noteID: String, now: Date = .now) {
        var store = loadStore()
        var values = store.opensByNoteID[noteID] ?? []
        values.append(now)
        store.opensByNoteID[noteID] = values
        pruneAndSave(&store, now: now)
    }

    func recordEdit(noteID: String, now: Date = .now) {
        var store = loadStore()
        var values = store.editsByNoteID[noteID] ?? []
        if let mostRecentEdit = values.last,
           now.timeIntervalSince(mostRecentEdit) < 120 {
            pruneAndSave(&store, now: now)
            return
        }
        values.append(now)
        store.editsByNoteID[noteID] = values
        pruneAndSave(&store, now: now)
    }

    func metrics(for noteID: String, now: Date = .now) -> (openCount30d: Int, editCount7d: Int) {
        let store = loadStore()
        let openCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let editCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)

        let openCount = (store.opensByNoteID[noteID] ?? []).filter { $0 >= openCutoff }.count
        let editCount = (store.editsByNoteID[noteID] ?? []).filter { $0 >= editCutoff }.count

        return (openCount, editCount)
    }

    private func loadStore() -> Store {
        guard let data = userDefaults.data(forKey: key),
              let store = try? JSONDecoder().decode(Store.self, from: data) else {
            return Store()
        }

        return store
    }

    private func pruneAndSave(_ store: inout Store, now: Date) {
        let openCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let editCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)

        store.opensByNoteID = store.opensByNoteID.reduce(into: [:]) { result, item in
            let filtered = item.value.filter { $0 >= openCutoff }
            if !filtered.isEmpty {
                result[item.key] = filtered
            }
        }

        store.editsByNoteID = store.editsByNoteID.reduce(into: [:]) { result, item in
            let filtered = item.value.filter { $0 >= editCutoff }
            if !filtered.isEmpty {
                result[item.key] = filtered
            }
        }

        if let encoded = try? JSONEncoder().encode(store) {
            userDefaults.set(encoded, forKey: key)
        }
    }
}

final class NoteIntelligenceRuleSpecProvider {
    private static let fallbackRulesJSON = """
    {
      "spec_version": 1,
      "spec_name": "note_intelligence_rules",
      "labels": [
        "possible_task",
        "possible_event",
        "reminder_candidate",
        "idea",
        "journal_entry",
        "high_revisit_value",
        "merge_candidate"
      ],
      "rules": [
        {
          "id": "task_verbs_with_due_entity",
          "label": "possible_task",
          "priority": 90,
          "conditions": {
            "all": [
              "contains_action_verb",
              "has_datetime_entity"
            ]
          },
          "rationale": "Action language paired with a date/time entity likely represents a task."
        },
        {
          "id": "calendar_phrase_or_datetime",
          "label": "possible_event",
          "priority": 85,
          "conditions": {
            "any": [
              "contains_event_phrase",
              "has_datetime_entity"
            ]
          },
          "rationale": "Event-oriented phrases or date/time entities indicate a possible event."
        },
        {
          "id": "followup_with_date_or_contact",
          "label": "reminder_candidate",
          "priority": 80,
          "conditions": {
            "all": [
              "contains_followup_phrase",
              "has_datetime_or_contact_entity"
            ]
          },
          "rationale": "Follow-up language with scheduling/contact signals suggests a reminder candidate."
        },
        {
          "id": "idea_language_without_task_signals",
          "label": "idea",
          "priority": 65,
          "conditions": {
            "all": [
              "contains_idea_phrase",
              "not_contains_action_verb"
            ]
          },
          "rationale": "Idea language without action intent maps to idea classification."
        },
        {
          "id": "reflective_first_person_text",
          "label": "journal_entry",
          "priority": 60,
          "conditions": {
            "all": [
              "contains_reflective_phrase",
              "first_person_ratio_high"
            ]
          },
          "rationale": "Reflective first-person language indicates journaling content."
        },
        {
          "id": "note_high_access_or_recent_edits",
          "label": "high_revisit_value",
          "priority": 70,
          "conditions": {
            "any": [
              "open_count_above_threshold",
              "edited_recently_multiple_times"
            ]
          },
          "rationale": "Frequently revisited notes may deserve easier access."
        },
        {
          "id": "high_similarity_to_existing_note",
          "label": "merge_candidate",
          "priority": 75,
          "conditions": {
            "all": [
              "text_similarity_above_threshold",
              "shares_topic_keywords"
            ]
          },
          "rationale": "Strong textual/topic overlap suggests merge consideration."
        }
      ]
    }
    """

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load() throws -> NoteIntelligenceRuleSpec {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for url in candidateURLs() {
            if let data = try? Data(contentsOf: url),
               let spec = try? decoder.decode(NoteIntelligenceRuleSpec.self, from: data) {
                return spec
            }
        }

        let fallbackData = Data(Self.fallbackRulesJSON.utf8)
        return try decoder.decode(NoteIntelligenceRuleSpec.self, from: fallbackData)
    }

    private func candidateURLs() -> [URL] {
        var urls: [URL] = []

        if let bundledURL = Bundle.main.url(
            forResource: "note_intelligence_rules.v1",
            withExtension: "json"
        ) {
            urls.append(bundledURL)
        }

        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../docs/note-intelligence/note_intelligence_rules.v1.json")
            .standardizedFileURL

        if fileManager.fileExists(atPath: repositoryURL.path) {
            urls.append(repositoryURL)
        }

        return urls
    }
}

struct NoteIntelligenceRuleEvaluator {
    private let spec: NoteIntelligenceRuleSpec

    init(spec: NoteIntelligenceRuleSpec) {
        self.spec = spec
    }

    func evaluate(input: NoteIntelligenceCanonicalInput) -> [NoteIntelligenceSuggestion] {
        var suggestions: [NoteIntelligenceSuggestion] = []

        for rule in spec.rules {
            if ruleMatches(rule, input: input) {
                suggestions.append(
                    NoteIntelligenceSuggestion(
                        label: rule.label,
                        ruleID: rule.id,
                        score: min(1, max(0, Double(rule.priority) / 100.0)),
                        explanations: [rule.rationale]
                    )
                )
            }
        }

        suggestions = applyEventOverlapGuardIfNeeded(suggestions: suggestions, input: input)

        let deduped = suggestions.reduce(into: [String: NoteIntelligenceSuggestion]()) { result, suggestion in
            let existing = result[suggestion.label]
            if existing == nil || existing!.score < suggestion.score {
                result[suggestion.label] = suggestion
            }
        }

        return deduped.values.sorted {
            if $0.score == $1.score {
                return $0.label < $1.label
            }
            return $0.score > $1.score
        }
    }

    private func applyEventOverlapGuardIfNeeded(
        suggestions: [NoteIntelligenceSuggestion],
        input: NoteIntelligenceCanonicalInput
    ) -> [NoteIntelligenceSuggestion] {
        let labels = Set(suggestions.map(\.label))
        guard labels.contains("possible_event") else { return suggestions }

        let hasTaskOrReminder = labels.contains("possible_task") || labels.contains("reminder_candidate")
        let hasEventPhrase = condition(named: "contains_event_phrase", input: input)

        guard hasTaskOrReminder && !hasEventPhrase else { return suggestions }

        return suggestions.filter { $0.label != "possible_event" }
    }

    private func ruleMatches(_ rule: NoteIntelligenceRuleSpec.Rule, input: NoteIntelligenceCanonicalInput) -> Bool {
        let all = rule.conditions["all"] ?? []
        let any = rule.conditions["any"] ?? []

        let allMatch = all.allSatisfy { condition(named: $0, input: input) }
        let anyMatch = any.isEmpty || any.contains { condition(named: $0, input: input) }

        return allMatch && anyMatch
    }

    private func condition(named name: String, input: NoteIntelligenceCanonicalInput) -> Bool {
        switch name {
        case "contains_action_verb":
            let actionVerbs: Set<String> = [
                "call", "email", "send", "schedule", "book", "confirm", "submit", "pay", "finish",
                "complete", "review", "prepare", "plan"
            ]
            return Set(input.features.lemmas.map { $0.lowercased() }).intersection(actionVerbs).isEmpty == false

        case "not_contains_action_verb":
            return !condition(named: "contains_action_verb", input: input)

        case "has_datetime_entity":
            return !input.entities.datetimes.isEmpty

        case "contains_event_phrase":
            let text = input.text.lowercased()
            let phrases = [
                "meeting", "sync", "appointment", "calendar", "event", "standup", "call with", "demo"
            ]
            return phrases.contains(where: { text.contains($0) })

        case "contains_followup_phrase":
            let text = input.text.lowercased()
            let phrases = [
                "follow up", "follow-up", "check in", "remind", "email", "circle back", "ping"
            ]
            return phrases.contains(where: { text.contains($0) })

        case "has_datetime_or_contact_entity":
            return !input.entities.datetimes.isEmpty ||
                !input.entities.emails.isEmpty ||
                !input.entities.phones.isEmpty

        case "contains_idea_phrase":
            let text = input.text.lowercased()
            let phrases = ["idea", "brainstorm", "concept", "what if", "maybe build", "proposal"]
            return phrases.contains(where: { text.contains($0) })

        case "contains_reflective_phrase":
            let text = input.text.lowercased()
            let phrases = [
                "i felt", "i feel", "i realized", "i learned", "i noticed", "today i", "tonight"
            ]
            return phrases.contains(where: { text.contains($0) })

        case "first_person_ratio_high":
            return input.features.firstPersonRatio >= 0.25

        case "open_count_above_threshold":
            return input.features.openCount30d >= 10

        case "edited_recently_multiple_times":
            return input.features.editCount7d >= 3

        case "text_similarity_above_threshold":
            return !input.similarNoteIDs.isEmpty

        case "shares_topic_keywords":
            return !input.features.lemmas.isEmpty && !input.similarNoteIDs.isEmpty

        default:
            return false
        }
    }
}

final class NoteIntelligenceService {
    private let extractor: NoteIntelligenceExtracting
    private let specProvider: NoteIntelligenceRuleSpecProvider
    private let activityTracker: NoteIntelligenceActivityTracker
    private let iso8601Formatter: ISO8601DateFormatter
    private var evaluator: NoteIntelligenceRuleEvaluator?

    init(
        extractor: NoteIntelligenceExtracting = NLTaggerNoteIntelligenceExtractor(),
        specProvider: NoteIntelligenceRuleSpecProvider = NoteIntelligenceRuleSpecProvider(),
        activityTracker: NoteIntelligenceActivityTracker = NoteIntelligenceActivityTracker()
    ) {
        self.extractor = extractor
        self.specProvider = specProvider
        self.activityTracker = activityTracker

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601Formatter = formatter
    }

    func recordNoteOpened(_ note: Note) {
        activityTracker.recordOpen(noteID: note.id.uuidString)
    }

    func recordNoteEdited(_ note: Note) {
        activityTracker.recordEdit(noteID: note.id.uuidString)
    }

    func suggestionLabels(for note: Note, among allActiveNotes: [Note]) -> [String] {
        guard !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
              !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        guard let evaluator = makeEvaluator() else { return [] }

        let fullText = combinedText(for: note)
        let extraction = extractor.extract(text: fullText)
        let metrics = activityTracker.metrics(for: note.id.uuidString)

        let currentKeywords = extraction.topicKeywords
        let similarNoteIDs = findSimilarNoteIDs(
            for: note,
            among: allActiveNotes,
            currentKeywords: currentKeywords
        )

        let input = NoteIntelligenceCanonicalInput(
            noteID: note.id.uuidString,
            text: fullText,
            language: extraction.language,
            createdAt: iso8601Formatter.string(from: note.createdAt),
            modifiedAt: iso8601Formatter.string(from: note.modifiedAt),
            features: .init(
                lemmas: extraction.lemmas,
                tokens: extraction.tokens,
                posTags: extraction.posTags,
                openCount30d: metrics.openCount30d,
                editCount7d: metrics.editCount7d,
                firstPersonRatio: extraction.firstPersonRatio
            ),
            entities: .init(
                datetimes: extraction.entities.datetimes,
                emails: extraction.entities.emails,
                phones: extraction.entities.phones,
                urls: extraction.entities.urls,
                addresses: extraction.entities.addresses
            ),
            similarNoteIDs: similarNoteIDs
        )

        return evaluator.evaluate(input: input).map(\.label)
    }

    func evaluateCanonicalInput(_ input: NoteIntelligenceCanonicalInput) -> [String] {
        guard let evaluator = makeEvaluator() else { return [] }
        return evaluator.evaluate(input: input).map(\.label)
    }

    private func makeEvaluator() -> NoteIntelligenceRuleEvaluator? {
        if let evaluator {
            return evaluator
        }

        guard let loadedSpec = try? specProvider.load() else {
            return nil
        }

        let newEvaluator = NoteIntelligenceRuleEvaluator(spec: loadedSpec)
        self.evaluator = newEvaluator
        return newEvaluator
    }

    private func combinedText(for note: Note) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = note.content.trimmingCharacters(in: .whitespacesAndNewlines)

        if title.isEmpty { return content }
        if content.isEmpty { return title }
        return "\(title). \(content)"
    }

    private func findSimilarNoteIDs(
        for note: Note,
        among allActiveNotes: [Note],
        currentKeywords: Set<String>
    ) -> [String] {
        guard !currentKeywords.isEmpty else { return [] }

        var ids: [String] = []

        for candidate in allActiveNotes where candidate.id != note.id {
            let keywords = keywordSet(for: candidate)
            guard !keywords.isEmpty else { continue }

            let overlap = currentKeywords.intersection(keywords)
            let unionCount = currentKeywords.union(keywords).count
            guard unionCount > 0 else { continue }

            let similarity = Double(overlap.count) / Double(unionCount)
            if similarity >= 0.55 && overlap.count >= 2 {
                ids.append(candidate.id.uuidString)
            }
        }

        return ids.sorted()
    }

    private func keywordSet(for note: Note) -> Set<String> {
        let text = combinedText(for: note).lowercased()
        let rawTokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        let stopwords: Set<String> = [
            "a", "an", "and", "the", "to", "of", "for", "in", "on", "at", "with", "by", "is",
            "are", "was", "were", "be", "it", "this", "that", "from", "as", "or", "about", "after",
            "before", "into", "up", "down", "out", "off", "over", "under", "then", "than"
        ]

        return Set(rawTokens.filter { $0.count >= 3 && !stopwords.contains($0) })
    }
}
