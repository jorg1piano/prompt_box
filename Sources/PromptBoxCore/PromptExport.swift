import AppKit
import CryptoKit

/// Turns a prompt into text a terminal can take: the text, then one line per image giving the
/// path of a PNG on disk, numbered to match the thumbnails so the text can say "see image 2".
public enum PromptExport {
    public static func plainText(from prompt: Prompt, imageDirectory: URL) throws -> String {
        var parts: [String] = []
        let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(text) }
        if !prompt.images.isEmpty {
            let lines = try prompt.images.enumerated().map { i, png in
                "Image \(i + 1): \(try store(png: png, in: imageDirectory).path)"
            }
            parts.append(lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Writes the PNG under a name taken from its hash, so sending the same image twice reuses one file.
    public static func store(png: Data, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: png).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("\(hash).png")
        if !FileManager.default.fileExists(atPath: url.path) {
            try png.write(to: url, options: .atomic)
        }
        return url
    }

    public static func pngData(of attachment: NSTextAttachment) -> Data? {
        if let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents {
            return pngData(from: data)
        }
        if let tiff = attachment.image?.tiffRepresentation {
            return pngData(from: tiff)
        }
        return nil
    }

    /// Converts any image data NSBitmapImageRep reads (PNG, TIFF, JPEG, HEIC, ...) to PNG.
    public static func pngData(from data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
