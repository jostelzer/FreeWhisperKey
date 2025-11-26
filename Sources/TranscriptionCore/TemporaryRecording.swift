import Foundation

public struct TemporaryRecording: Sendable {
    public let url: URL
    private let directoryURL: URL
    private let secureOverwrite: Bool

    public init(prefix: String = "recording", fileExtension: String = "wav", secureOverwrite: Bool = true, fileManager: FileManager = .default) throws {
        self.secureOverwrite = secureOverwrite

        let identifier = UUID().uuidString
        directoryURL = fileManager.temporaryDirectory.appendingPathComponent("freewhisperkey-recording-\(identifier)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        url = directoryURL.appendingPathComponent("\(prefix)-\(identifier).\(fileExtension)")
    }

    public func cleanup(fileManager: FileManager = .default) {
        secureEraseIfNeeded(fileManager: fileManager)
        try? fileManager.removeItem(at: directoryURL)
    }

    private func secureEraseIfNeeded(fileManager: FileManager = .default) {
        guard secureOverwrite, fileManager.fileExists(atPath: url.path) else {
            return
        }

        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let sizeValue = attributes[.size] as? NSNumber
        else {
            return
        }

        let chunkSize = 64 * 1024
        let zeroChunk = Data(repeating: 0, count: chunkSize)
        var remaining = sizeValue.uint64Value

        guard let handle = try? FileHandle(forWritingTo: url) else {
            return
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: 0)
        } catch {
            return
        }

        while remaining > 0 {
            let toWrite = Int(min(UInt64(chunkSize), remaining))
            if toWrite == chunkSize {
                handle.write(zeroChunk)
            } else if toWrite > 0 {
                handle.write(Data(repeating: 0, count: toWrite))
            }
            remaining -= UInt64(toWrite)
        }

        handle.synchronizeFile()
    }
}
