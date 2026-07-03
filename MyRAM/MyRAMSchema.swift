// MyRAMSchema.swift
import SwiftData

enum MyRAMMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = []
    static var stages: [MigrationStage] = []
}

enum MyRAMModelRegistry {
    static let models: [any PersistentModel.Type] = [
        Folder.self,
        Note.self,
        NotePhotoAttachment.self,
        PinnedThought.self,
        NoteContentSnapshot.self,
        RetainedBodyOperation.self,
        IncorporatedSyncBatch.self,
        IncorporatedBatchTombstone.self,
        IncorporatedBatchNoteEffect.self,
        IncorporatedBatchOperationIdentity.self,
        IncorporatedBatchResultEvidence.self,
        IncorporationBlockingReference.self,
        IncorporationContradictionDiagnostic.self,
        NoteTitleWinner.self,
        NoteHistoryCompactionState.self,
        ConvergenceNoteDiagnosticState.self,
        ConvergenceBlockingBatchReference.self,
        ReconciliationEpisode.self,
        ReconciliationCandidateRecord.self,
        ReconciliationCompletionEvidenceRecord.self
    ]
}
