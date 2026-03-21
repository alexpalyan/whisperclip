import SwiftUI

struct PromptsSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @StateObject var vm = PromptManagementViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header with Create button
                        HStack {
                            Text("Enhancement Prompts")
                                .font(.headline)
                                .foregroundColor(.white)

                            Spacer()

                            Button("New Prompt") {
                                vm.showingNewPromptDialog = true
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if settings.prompts.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 48))
                                    .foregroundColor(.gray)

                                Text("No prompts created yet")
                                    .font(.title2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)

                                Text("Create prompts to enhance or modify transcribed text with AI")
                                    .font(.body)
                                    .foregroundColor(.gray)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                        } else {
                            // Selected prompt indicator
                            if let selectedId = settings.selectedPromptId,
                               let selectedPrompt = settings.prompts.first(where: { $0.id == selectedId }) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Active: \(selectedPrompt.label)")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                            }

                            // Prompts list
                            LazyVStack(spacing: 8) {
                                ForEach(settings.prompts) { prompt in
                                    PromptRowView(
                                        prompt: prompt,
                                        isSelected: settings.selectedPromptId == prompt.id,
                                        isEditing: vm.editingPromptId == prompt.id,
                                        editingLabel: $vm.editingPromptLabel,
                                        editingContent: $vm.editingPromptContent,
                                        onSelect: { settings.selectPrompt(id: prompt.id) },
                                        onEdit: { vm.startEditing(prompt) },
                                        onSave: { vm.savePromptEdits(prompt.id) },
                                        onCancel: { vm.cancelEditing() },
                                        onDelete: { vm.deletePrompt(prompt.id) }
                                    )
                                }
                            }
                        }

                        Text("Create and manage prompts to enhance transcribed text with AI. Select one to make it active.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                }
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
            }
            .padding()
        }
        .sheet(isPresented: $vm.showingNewPromptDialog) {
            NewPromptDialog(
                label: $vm.newPromptLabel,
                content: $vm.newPromptContent,
                onCreate: { vm.createNewPrompt() },
                onCancel: { vm.cancelNewPrompt() }
            )
        }
        .background(Color.black)
        .tabItem {
            Label("Prompts", systemImage: "text.bubble")
        }
    }

}

struct PromptRowView: View {
    let prompt: Prompt
    let isSelected: Bool
    let isEditing: Bool
    @Binding var editingLabel: String
    @Binding var editingContent: String
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                // Editing mode
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Prompt name", text: $editingLabel)
                        .textFieldStyle(.roundedBorder)

                    TextEditor(text: $editingContent)
                        .frame(minHeight: 80)
                        .padding(8)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(6)

                    HStack {
                        Button("Cancel") {
                            onCancel()
                        }
                        .buttonStyle(.bordered)

                        Button("Save") {
                            onSave()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(editingLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                // Display mode
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(prompt.label)
                                .font(.headline)
                                .foregroundColor(.white)

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                        }

                        if !prompt.content.isEmpty {
                            Text(prompt.content)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(3)
                        } else {
                            Text("Empty prompt")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .italic()
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if !isSelected {
                            Button("Select") {
                                onSelect()
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("Edit") {
                            onEdit()
                        }
                        .buttonStyle(.bordered)

                        Button("Delete") {
                            onDelete()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                }
            }
        }
        .padding()
        .background(isSelected ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3))
        .cornerRadius(8)
    }
}

struct NewPromptDialog: View {
    @Binding var label: String
    @Binding var content: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create New Prompt")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt Name")
                    .font(.headline)
                    .foregroundColor(.white)
                TextField("Enter prompt name", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt Content")
                    .font(.headline)
                    .foregroundColor(.white)
                TextEditor(text: $content)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Color.gray.opacity(0.3))
                    .cornerRadius(6)

                Text("Optional: Provide instructions to enhance or modify transcribed text with AI.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Create") {
                    onCreate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 450, height: 350)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
