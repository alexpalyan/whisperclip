import Foundation
import SwiftData

@Model
final class PromptEntity {
    @Attribute(.unique) var id: String
    var label: String
    var content: String
    var createdAt: Date

    init(id: String = UUID().uuidString, label: String, content: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.content = content
        self.createdAt = createdAt
    }
}
