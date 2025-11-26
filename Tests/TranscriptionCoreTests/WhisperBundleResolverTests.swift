import CryptoKit
import XCTest
@testable import TranscriptionCore

final class WhisperBundleResolverTests: XCTestCase {
    private var tempRoot: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory.appendingPathComponent("BundleResolver-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try? fileManager.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testResolveSucceedsWithValidManifest() throws {
        let bundleURL = try makeMockBundle()
        XCTAssertNoThrow(try WhisperBundleResolver.resolve(relativeTo: tempRoot))
        XCTAssertTrue(fileManager.fileExists(atPath: bundleURL.path))
    }

    func testResolveFailsWhenManifestMissing() throws {
        let bundleURL = try makeMockBundle(includeManifest: false)
        XCTAssertThrowsError(try WhisperBundleResolver.resolve(relativeTo: tempRoot)) { error in
            XCTAssertTrue("\(error)".contains("manifest"))
        }
        XCTAssertTrue(fileManager.fileExists(atPath: bundleURL.path))
    }

    func testResolveFailsOnChecksumMismatch() throws {
        _ = try makeMockBundle(tamperModel: true)
        XCTAssertThrowsError(try WhisperBundleResolver.resolve(relativeTo: tempRoot)) { error in
            XCTAssertTrue("\(error)".contains("Integrity"))
        }
    }

    @discardableResult
    private func makeMockBundle(includeManifest: Bool = true, tamperModel: Bool = false) throws -> URL {
        let bundleURL = tempRoot.appendingPathComponent("dist/whisper-bundle", isDirectory: true)
        let binDir = bundleURL.appendingPathComponent("bin", isDirectory: true)
        let modelsDir = bundleURL.appendingPathComponent("models", isDirectory: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let binary = binDir.appendingPathComponent("whisper-cli")
        fileManager.createFile(atPath: binary.path, contents: Data("binary".utf8), attributes: nil)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: binary.path)

        let model = modelsDir.appendingPathComponent("ggml-base.bin")
        fileManager.createFile(atPath: model.path, contents: Data("model".utf8), attributes: nil)

        if includeManifest {
            if tamperModel {
                try Data("mismatch".utf8).write(to: model)
            }
            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            let manifest = [
                "files": [
                    "bin/whisper-cli": sha256(of: binary),
                    "models/ggml-base.bin": sha256(of: model) + (tamperModel ? "0" : "")
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: manifestURL)
        }

        return bundleURL
    }

    private func sha256(of url: URL) -> String {
        let data = try! Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02hhx", $0) }.joined()
    }
}
