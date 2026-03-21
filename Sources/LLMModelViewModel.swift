import Foundation

@MainActor
class LLMModelViewModel: ObservableObject {
    private let store: SettingsStore

    @Published var llmDownloadInProgress: Bool = false
    @Published var llmDownloadModelName: String? = nil
    @Published var llmDownloadProgress: Double = 0
    @Published var totalModelsSize: Int64 = 0

    init(store: SettingsStore = .shared) {
        self.store = store
    }

    func downloadLLMModel(modelName: String) {
        llmDownloadInProgress = true
        llmDownloadModelName = modelName
        llmDownloadProgress = 0

        Task {
            let modelID = "\(CurrentLLMModelRepo)/\(modelName)"
            do {
                let _ = try await ModelStorage.shared.downloadModel(
                    modelRepo: modelID,
                    modelName: "",
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            self?.llmDownloadProgress = progress
                        }
                    }
                )
                try await ModelStorage.shared.preLoadModel(modelRepo: modelID, modelName: "")
                await MainActor.run {
                    store.selectedLLMModelName = modelName
                    llmDownloadInProgress = false
                    llmDownloadModelName = nil
                    llmDownloadProgress = 0
                    refreshModelsSize()
                }
            } catch {
                Logger.log("Failed to download LLM model: \(error)", log: Logger.general, type: .error)
                await MainActor.run {
                    llmDownloadInProgress = false
                    llmDownloadModelName = nil
                    llmDownloadProgress = 0
                }
            }
        }
    }

    func deleteLLMModel(modelName: String) {
        let modelID = "\(CurrentLLMModelRepo)/\(modelName)"
        do {
            try ModelStorage.shared.deleteModel(modelRepo: modelID, modelName: "")
            Logger.log("Deleted LLM model: \(modelName)", log: Logger.general)
        } catch {
            Logger.log("Failed to delete LLM model: \(error)", log: Logger.general, type: .error)
        }

        if store.selectedLLMModelName == modelName {
            let fallback = ModelStorage.shared.getDownloadedLLMModelNames().first(where: { $0 != modelName }) ?? CurrentLLMModelName
            store.selectedLLMModelName = fallback
        }

        refreshModelsSize()
    }

    func deleteAllModels() {
        ModelStorage.shared.deleteAllModels()
        Logger.log("All models deleted by user", log: Logger.general)
        refreshModelsSize()
    }

    func refreshModelsSize() {
        totalModelsSize = ModelStorage.shared.getTotalModelsSize()
    }
}
