import Foundation
import MLXLLM
import MLXLMCommon
import MLX

class LLM: LLMProtocol {
    static let shared = LLM()
    private var modelContainer: ModelContainer?
    private var modelID: String

    private init() {
        modelContainer = nil
        modelID = ""
    }

    func load() async throws {
        let selectedModelName = SettingsStore.shared.selectedLLMModelName
        let newModelID = "\(CurrentLLMModelRepo)/\(selectedModelName)"

        if self.modelContainer == nil || self.modelID != newModelID {
            self.modelContainer = try await LocalLLM.loadModel(modelRepo: newModelID, modelName: "")
            if self.modelContainer != nil {
                self.modelID = newModelID
            }
        }

        if self.modelContainer == nil {
            throw NSError(domain: "TextAI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to load text-enhancing model. Please try again later."])
        }
    }

    func execute(systemPrompt: String, userPrompt: String) async throws -> String {
        let ts = TimeSpenter()
        try await load()

        var systemPrompt = systemPrompt
        var userPrompt = userPrompt

        switch modelID {
        case MlxCommunityRepo + "/" + Gemma_2_9b_it_4bit,
             MlxCommunityRepo + "/" + Gemma_2_2b_it_4bit,
             MlxCommunityRepo + "/" + Mistral_7B_Instruct_v0_3_4bit:
            userPrompt = "\(systemPrompt)\n\(userPrompt)"
            systemPrompt = ""
        default:
            break
        }

        let result = try await LocalLLM.generate(modelContainer: modelContainer!,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt)
        if GenericHelper.logSensitiveData() {
            Logger.log("Text enhanced in \(ts.getDelay()) us", log: Logger.general)
        }

        switch modelID {
        case MlxCommunityRepo + "/" + Gemma_2_9b_it_4bit,
             MlxCommunityRepo + "/" + Gemma_2_2b_it_4bit:
            if result.hasSuffix("<end_of_turn>") {
                return String(result.dropLast("<end_of_turn>".count))
            }
            return result
        default:
            return result
        }
    }

    func process(prompt: String, text: String) async throws -> String {
        let systemPrompt = "You are a helpful assistant that improves text while preserving its original meaning."
        let userPrompt = "\(prompt)\n\nOriginal text:\n\(text)"

        return try await execute(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    func isReady() async throws -> Bool {
        let selectedModelName = SettingsStore.shared.selectedLLMModelName
        let modelID = "\(CurrentLLMModelRepo)/\(selectedModelName)"
        let exists = ModelStorage.shared.modelExists(modelRepo: modelID, modelName: "")
        if !exists {
            let modelDir = ModelStorage.shared.getModelDir(modelRepo: modelID, modelName: "")
            let folderExists = GenericHelper.folderExists(folder: modelDir)
            Logger.log("LLM not ready for modelID: \(modelID). folderExists=\(folderExists)", log: Logger.general, type: .debug)
        }
        return exists
    }
}
