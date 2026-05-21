// MyRAMSchema.swift
import SwiftData

enum MyRAMMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = []
    static var stages: [MigrationStage] = []
}
