import Foundation
import Combine

@MainActor
class PromptManagementViewModel: ObservableObject {
    private let store: SettingsStore

    @Published var showingNewPromptDialog: Bool = false
    @Published var newPromptLabel: String = ""
    @Published var newPromptContent: String = ""
    @Published var editingPromptId: String? = nil
    @Published var editingPromptLabel: String = ""
    @Published var editingPromptContent: String = ""

    init(store: SettingsStore = .shared) {
        self.store = store
    }

    func createNewPrompt() {
        guard !newPromptLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        _ = store.createPrompt(label: newPromptLabel, content: newPromptContent)

        newPromptLabel = ""
        newPromptContent = ""
        showingNewPromptDialog = false
    }

    func cancelNewPrompt() {
        newPromptLabel = ""
        newPromptContent = ""
        showingNewPromptDialog = false
    }

    func startEditing(_ prompt: Prompt) {
        editingPromptId = prompt.id
        editingPromptLabel = prompt.label
        editingPromptContent = prompt.content
    }

    func savePromptEdits(_ promptId: String) {
        store.updatePrompt(
            id: promptId,
            label: editingPromptLabel,
            content: editingPromptContent
        )
        cancelEditing()
    }

    func cancelEditing() {
        editingPromptId = nil
        editingPromptLabel = ""
        editingPromptContent = ""
    }

    func deletePrompt(_ promptId: String) {
        store.deletePrompt(id: promptId)
    }
}
