import Foundation
import SwiftData

enum SettingsDataContainer {
    static func create(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema([Prompt.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }
}
