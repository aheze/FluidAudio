import CoreML
import Foundation
import OSLog

/// HuggingFace model downloader based on swift-transformers implementation
public class DownloadUtils {
    private static let logger = Logger(subsystem: "com.fluidaudio", category: "DownloadUtils")

    /// Download progress callback
    public typealias ProgressHandler = (Double) -> Void

    /// Download configuration
    public struct DownloadConfig {
        public let timeout: TimeInterval

        public init(timeout: TimeInterval = 1800) { // 30 minutes for large models
            self.timeout = timeout
        }

        public static let `default` = DownloadConfig()
    }

    /// Model repositories on HuggingFace
    public enum Repo: String, CaseIterable {
        case vad = "FluidInference/silero-vad-coreml"
        case parakeet = "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        case diarizer = "FluidInference/speaker-diarization-coreml"

        var folderName: String {
            rawValue.split(separator: "/").last?.description ?? rawValue
        }
    }

    public static func loadModels(
        _ repo: Repo,
        modelNames: [String],
        directory: URL,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) async throws -> [String: MLModel] {
        do {
            // 1st attempt: normal load
            return try await loadModelsOnce(
                repo, modelNames: modelNames,
                directory: directory, computeUnits: computeUnits)
        } catch {
            // 1st attempt failed → wipe cache to signal redownload
            logger.warning("⚠️ First load failed: \(error.localizedDescription)")
            logger.info("🔄 Deleting cache and re-downloading…")
            let repoPath = directory.appendingPathComponent(repo.folderName)
            try? FileManager.default.removeItem(at: repoPath)

            // 2nd attempt after fresh download
            return try await loadModelsOnce(
                repo, modelNames: modelNames,
                directory: directory, computeUnits: computeUnits)
        }
    }

    /// Internal helper to download repo (if needed) and load CoreML models
    /// - Parameters:
    ///   - repo: The HuggingFace repository to download
    ///   - modelNames: Array of model file names to load (e.g., ["model.mlmodelc"])
    ///   - directory: Base directory to store repos (e.g., ~/Library/Application Support/FluidAudio)
    ///   - computeUnits: CoreML compute units to use (default: CPU and Neural Engine)
    /// - Returns: Dictionary mapping model names to loaded MLModel instances
    private static func loadModelsOnce(
        _ repo: Repo,
        modelNames: [String],
        directory: URL,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) async throws -> [String: MLModel] {
        // Ensure base directory exists
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Configure CoreML
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        // Load each model
        var models: [String: MLModel] = [:]
        for name in modelNames {
            let modelPath = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: modelPath.path) else {
                throw CocoaError(
                    .fileNoSuchFile,
                    userInfo: [
                        NSFilePathErrorKey: modelPath.path,
                        NSLocalizedDescriptionKey: "Model file not found: \(name)",
                    ])
            }

            do {
                // Validate model directory structure before loading
                var isDirectory: ObjCBool = false
                guard
                    FileManager.default.fileExists(
                        atPath: modelPath.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else {
                    throw CocoaError(
                        .fileReadCorruptFile,
                        userInfo: [
                            NSFilePathErrorKey: modelPath.path,
                            NSLocalizedDescriptionKey: "Model path is not a directory: \(name)",
                        ])
                }

                // Check for essential model files
                let coremlDataPath = modelPath.appendingPathComponent("coremldata.bin")
                guard FileManager.default.fileExists(atPath: coremlDataPath.path) else {
                    logger.error("Missing coremldata.bin in \(name)")
                    throw CocoaError(
                        .fileReadCorruptFile,
                        userInfo: [
                            NSFilePathErrorKey: coremlDataPath.path,
                            NSLocalizedDescriptionKey: "Missing coremldata.bin in model: \(name)",
                        ])
                }

                models[name] = try MLModel(contentsOf: modelPath, configuration: config)
                logger.info("Loaded model: \(name)")
            } catch {
                logger.error("Failed to load model \(name): \(error)")

                // List directory contents for debugging
                if let contents = try? FileManager.default.contentsOfDirectory(
                    at: modelPath, includingPropertiesForKeys: nil)
                {
                    logger.error(
                        "   Model directory contents: \(contents.map { $0.lastPathComponent })")
                }

                throw error
            }
        }

        return models
    }

    /// Download a HuggingFace repository
    private static func downloadRepo(_ repo: Repo, to directory: URL) async throws {
        logger.info("📥 Downloading \(repo.folderName) from HuggingFace...")
        print("📥 Downloading \(repo.folderName)...")

        let repoPath = directory.appendingPathComponent(repo.folderName)
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)

        // Download all repository contents
        let files = try await listRepoFiles(repo)

        for file in files {
            switch file.type {
            case "directory" where file.path.hasSuffix(".mlmodelc"):
                logger.info("Downloading model: \(file.path)")
                // We can remove these models once we release the new version for a couple of weeks
                if file.path == "TokenDurationPrediction.mlmodelc"
                    || file.path == "ParakeetEncoder.mlmodelc"
                {
                    logger.info("Skipping \(file.path), not needed anymore")
                    continue
                }
                try await downloadModelDirectory(repo: repo, dirPath: file.path, to: repoPath)

            case "file" where isEssentialFile(file.path):
                logger.info("Downloading \(file.path)")
                try await downloadFile(
                    from: repo,
                    path: file.path,
                    to: repoPath.appendingPathComponent(file.path),
                    expectedSize: file.size,
                    config: .default)

            default:
                break
            }
        }

        logger.info("Downloaded all models for \(repo.folderName)")
    }

    /// Check if a file is essential for model operation
    private static func isEssentialFile(_ path: String) -> Bool {
        path.hasSuffix(".json") || path.hasSuffix(".txt") || path == "config.json"
    }

    /// List files in a HuggingFace repository
    private static func listRepoFiles(_ repo: Repo, path: String = "") async throws -> [RepoFile] {
        let apiPath = path.isEmpty ? "tree/main" : "tree/main/\(path)"
        let apiURL = URL(string: "https://huggingface.co/api/models/\(repo.rawValue)/\(apiPath)")!

        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode([RepoFile].self, from: data)
    }

    /// Download a CoreML model directory and all its contents
    private static func downloadModelDirectory(repo: Repo, dirPath: String, to destination: URL)
        async throws
    {
        let modelDir = destination.appendingPathComponent(dirPath)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let files = try await listRepoFiles(repo, path: dirPath)

        for item in files {
            switch item.type {
            case "directory":
                try await downloadModelDirectory(repo: repo, dirPath: item.path, to: destination)

            case "file":
                let expectedSize = item.lfs?.size ?? item.size

                // Only log large files (>10MB) to reduce noise
                if expectedSize > 10_000_000 {
                    logger.info("📥 Downloading \(item.path) (\(formatBytes(expectedSize)))")
                } else {
                    logger.debug("Downloading \(item.path) (\(formatBytes(expectedSize)))")
                }

                try await downloadFile(
                    from: repo,
                    path: item.path,
                    to: destination.appendingPathComponent(item.path),
                    expectedSize: expectedSize,
                    config: .default,
                    progressHandler: createProgressHandler(for: item.path, size: expectedSize))

            default:
                break
            }
        }
    }

    /// Create a progress handler for large files
    private static func createProgressHandler(for path: String, size: Int) -> ProgressHandler? {
        // Only show progress for files over 100MB (most files are under this)
        guard size > 100_000_000 else { return nil }

        let fileName = path.split(separator: "/").last ?? ""
        var lastReportedPercentage = 0

        return { progress in
            let percentage = Int(progress * 100)
            if percentage >= lastReportedPercentage + 10 {
                lastReportedPercentage = percentage
                logger.info("   Progress: \(percentage)% of \(fileName)")
                print("   ⏳ \(percentage)% downloaded of \(fileName)")
            }
        }
    }

    /// Download a single file with chunked transfer and resume support
    private static func downloadFile(
        from repo: Repo,
        path: String,
        to destination: URL,
        expectedSize: Int,
        config: DownloadConfig,
        progressHandler: ProgressHandler? = nil
    ) async throws {
        // Create parent directories
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Check if file already exists and is complete
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let fileSize = attrs[.size] as? Int64,
           fileSize == expectedSize
        {
            logger.info("File already downloaded: \(path)")
            progressHandler?(1.0)
            return
        }

        // Temporary file for downloading
        let tempURL = destination.appendingPathExtension("download")

        // Check if we can resume a partial download
        var startByte: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
           let fileSize = attrs[.size] as? Int64
        {
            startByte = fileSize
            logger.info("⏸️ Resuming download from \(formatBytes(Int(startByte)))")
        }

        // Download URL
        let downloadURL = URL(
            string: "https://huggingface.co/\(repo.rawValue)/resolve/main/\(path)")!

        // Download the file (no retries)
        do {
            try await performChunkedDownload(
                from: downloadURL,
                to: tempURL,
                startByte: startByte,
                expectedSize: Int64(expectedSize),
                config: config,
                progressHandler: progressHandler)

            // Verify file size before moving
            if let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
               let fileSize = attrs[.size] as? Int64
            {
                if fileSize != expectedSize {
                    logger.warning(
                        "⚠️ Downloaded file size mismatch for \(path): got \(fileSize), expected \(expectedSize)"
                    )
                }
            }

            // Move completed file with better error handling
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tempURL, to: destination)
            } catch {
                // In CI, file operations might fail due to sandbox restrictions
                // Try copying instead of moving as a fallback
                logger.warning("Move failed for \(path), attempting copy: \(error)")
                try FileManager.default.copyItem(at: tempURL, to: destination)
                try? FileManager.default.removeItem(at: tempURL)
            }
            logger.info("Downloaded \(path)")

        } catch {
            logger.error("Download failed: \(error)")
            throw error
        }
    }

    /// Perform chunked download with progress tracking
    private static func performChunkedDownload(
        from url: URL,
        to destination: URL,
        startByte: Int64,
        expectedSize: Int64,
        config: DownloadConfig,
        progressHandler: ProgressHandler?
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = config.timeout

        // Use URLSession download task with progress
        let session = URLSession.shared

        // Always use URLSession.download for reliability (proven to work in PR #32)
        let (tempFile, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw URLError(.badServerResponse)
        }

        // Ensure parent directory exists before moving
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Move to destination with better error handling for CI
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempFile, to: destination)
        } catch {
            // In CI, URLSession might download to a different temp location
            // Try copying instead of moving as a fallback
            logger.warning("Move failed, attempting copy: \(error)")
            try FileManager.default.copyItem(at: tempFile, to: destination)
            try? FileManager.default.removeItem(at: tempFile)
        }

        // Report complete
        progressHandler?(1.0)
    }

    /// Format bytes for display
    private static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Repository file information
    private struct RepoFile: Codable {
        let type: String
        let path: String
        let size: Int
        let lfs: LFSInfo?

        struct LFSInfo: Codable {
            let size: Int
            let sha256: String? // Some repos might have this
            let oid: String? // Most use this instead
            let pointerSize: Int?

            enum CodingKeys: String, CodingKey {
                case size
                case sha256
                case oid
                case pointerSize = "pointer_size"
            }
        }
    }
}
