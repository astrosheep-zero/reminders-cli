import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import ReminderCore
import CryptoKit

/// Files belong to the worker, never to a frontend path. A lease survives an
/// uncertain save; deleting then could race the system's attachment consumption.
final class ImageStaging {
    let directory: URL
    let images: [[String: Any]]
    private var released = false

    init(_ input: [ImageInput], temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        var template = Array(temporaryRoot.appendingPathComponent("reminder-images-XXXXXX").path.utf8CString)
        guard let pointer = mkdtemp(&template) else { throw Failure(.io, "Cannot create private image staging directory") }
        directory = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        var staged: [[String: Any]] = []
        do {
            guard chmod(directory.path, 0o700) == 0 else { throw Failure(.io, "Cannot restrict image staging directory") }
            var total = 0
            for (index, image) in input.enumerated() {
                total += image.bytes.count
                guard total <= 16 * 1024 * 1024 else { throw Failure(.invalidInput, "Image bytes exceed the 16 MiB request limit") }
                let dimensions = try Self.validate(image)
                let type = UTType(image.contentType) ?? UTType(mimeType: image.contentType)
                let url = directory.appendingPathComponent("\(index).\(type?.preferredFilenameExtension ?? "image")")
                let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw Failure(.io, "Cannot create restricted image staging file") }
                do {
                    try image.bytes.withUnsafeBytes { buffer in
                        var written = 0
                        while written < buffer.count {
                            let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                            if count < 0, errno == EINTR { continue }
                            guard count > 0 else { throw Failure(.io, "Cannot write staged image bytes") }
                            written += count
                        }
                    }
                    guard fsync(fd) == 0 else { throw Failure(.io, "Cannot flush staged image") }
                    close(fd)
                } catch { close(fd); throw error }
                staged.append(["url": url, "width": dimensions.0, "height": dimensions.1])
            }
            images = staged
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    static func validate(_ image: ImageInput) throws -> (Int, Int) {
        guard !image.bytes.isEmpty, image.bytes.count <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(image.bytes as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), let detected = UTType(type as String), detected.conforms(to: .image),
              let declared = UTType(image.contentType) ?? UTType(mimeType: image.contentType), declared == detected,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 40_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
            throw Failure(.invalidInput, "Image must be a decodable single-frame image with matching content type and bounded dimensions")
        }
        return (width, height)
    }
    /// Every attachment must be independent of the lease, and each input needs a
    /// distinct newly added attachment receipt. An old identical image cannot
    /// mask a newly added attachment that still points to staging.
    static func verifyConsumed(_ inputs: [ImageInput], nativeImages: [[String: Any]], existingIDs: Set<String>, directory: URL) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        var available: [String] = []
        for image in nativeImages {
            let source: URL = try Translation.value(image, "sourceURL")
            let path = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard source.isFileURL, path != root, !path.hasPrefix(root + "/") else {
                throw Failure(.backend, "Native attachment still aliases staging; private lease retained")
            }
            let id: String = try Translation.value(image, "id")
            if existingIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) { continue }
            let data: Data = try Translation.value(image, "data")
            available.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        for image in inputs {
            let hash = SHA256.hash(data: image.bytes).map { String(format: "%02x", $0) }.joined()
            guard let index = available.firstIndex(of: hash) else {
                throw Failure(.backend, "New native image receipt is not yet independently readable; private lease retained")
            }
            available.remove(at: index)
        }
    }
    func release() throws {
        guard !released else { return }
        do { try FileManager.default.removeItem(at: directory); released = true }
        catch { throw Failure(.io, "Native save completed but private image staging cleanup failed: \(error.localizedDescription)") }
    }
    // No deinit cleanup: an uncertain save intentionally retains its lease until
    // the one-shot worker exits. The private directory may require manual cleanup.
}
