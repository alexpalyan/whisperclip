import Foundation
import WhisperKit

class LocalWhisperKit {
    private static let tokenizerFiles = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "chat_template.json",
    ]

    private static func tokenizerRepoID(for modelName: String) -> String? {
        switch modelName {
        case let name where name.contains("large-v3"):
            return "openai/whisper-large-v3"
        case let name where name.contains("large-v2"):
            return "openai/whisper-large-v2"
        case let name where name.contains("large"):
            return "openai/whisper-large"
        case let name where name.contains("small"):
            return "openai/whisper-small"
        default:
            return nil
        }
    }

    private static func cleanupHubMetadataIfNeeded(in repoRoot: URL, modelName: String) {
        let cacheRoot = repoRoot
            .appendingPathComponent(".cache/huggingface/download", isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return
        }

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "metadata" {
            do {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                try fileManager.removeItem(at: fileURL)
                Logger.log("Removed cached WhisperKit metadata file at \(fileURL.path)", log: Logger.general)
            } catch {
                Logger.log("Could not remove WhisperKit metadata file at \(fileURL.path): \(error.localizedDescription)", log: Logger.general, type: .error)
            }
        }
    }

    private static func hasRequiredTokenizerFiles(in tokenizerRepoDir: URL) -> Bool {
        let fileManager = FileManager.default
        let requiredFiles = ["config.json", "tokenizer.json"]
        return requiredFiles.allSatisfy { filename in
            fileManager.fileExists(atPath: tokenizerRepoDir.appendingPathComponent(filename).path)
        }
    }

    private static func downloadTokenizerRepo(into tokenizerBase: URL, tokenizerRepoID: String) async throws {
        let downloader = ModelDownloader(downloadBase: tokenizerBase)
        _ = try await downloader.download(
            modelID: tokenizerRepoID,
            filePatterns: tokenizerFiles
        )
    }

    private static func prepareLocalTokenizerCache(from modelPath: URL, modelName: String) async throws -> URL? {
        guard let tokenizerRepoID = tokenizerRepoID(for: modelName) else {
            Logger.log("No local tokenizer mapping for WhisperKit model \(modelName)", log: Logger.general, type: .error)
            return nil
        }

        let tokenizerBase = GenericHelper.getAppSupportDirectory()
            .appendingPathComponent("tokenizers", isDirectory: true)
        let tokenizerRepoDir = tokenizerBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(tokenizerRepoID, isDirectory: true)
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: tokenizerRepoDir, withIntermediateDirectories: true)

        var copiedAnyFiles = false
        for filename in tokenizerFiles {
            let sourceURL = modelPath.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }

            let destinationURL = tokenizerRepoDir.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            copiedAnyFiles = true
        }

        guard copiedAnyFiles else {
            Logger.log(
                "WhisperKit model \(modelName) does not contain tokenizer files for local cache",
                log: Logger.general,
                type: .error
            )
            return nil
        }

        if !hasRequiredTokenizerFiles(in: tokenizerRepoDir) {
            Logger.log(
                "WhisperKit model \(modelName) is missing tokenizer files locally; downloading tokenizer repo \(tokenizerRepoID)",
                log: Logger.general
            )
            try await downloadTokenizerRepo(into: tokenizerBase, tokenizerRepoID: tokenizerRepoID)
        }

        guard hasRequiredTokenizerFiles(in: tokenizerRepoDir) else {
            Logger.log(
                "Tokenizer repo \(tokenizerRepoID) is still missing required files after download",
                log: Logger.general,
                type: .error
            )
            return nil
        }

        return tokenizerBase
    }

    static func loadModel(modelRepo: String, modelName: String) async throws -> WhisperKit {
        Logger.log("Loading WhisperKit model", log: Logger.general)
        let modelPath = try await ModelStorage.shared.getModelPath(modelRepo: modelRepo, modelName: modelName)
        let repoRoot = ModelStorage.shared.getModelDir(modelRepo: modelRepo, modelName: "")
        cleanupHubMetadataIfNeeded(in: repoRoot, modelName: modelName)
        let tokenizerBase = try await prepareLocalTokenizerCache(from: modelPath, modelName: modelName)

        Logger.log("Loading WhisperKit model from \(modelPath.path)", log: Logger.general)
        let pipe = try await WhisperKit(WhisperKitConfig(
            model: modelName,
            modelFolder: modelPath.path,
            tokenizerFolder: tokenizerBase,
            prewarm: true
        ))
        Logger.log("WhisperKit model loaded", log: Logger.general)
        return pipe
    }
}
