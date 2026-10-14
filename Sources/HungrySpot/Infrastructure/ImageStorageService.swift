import AppKit
import ImageIO
import UniformTypeIdentifiers
import HungrySpotCore

final class ImageStorageService {
    let paths: AppPaths
    init(paths: AppPaths) { self.paths = paths }

    func importImage(from source: URL) throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let attrs = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attrs.isRegularFile == true, (attrs.fileSize ?? 0) <= 50 * 1024 * 1024 else {
            throw SpotError.validation("Choose an image file smaller than 50 MB.")
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1000,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw SpotError.validation("This image could not be opened. Choose JPG, PNG, HEIC, or a supported WebP file.")
        }
        let relative = "products/\(UUID().uuidString).jpg"
        let destinationURL = paths.images.appendingPathComponent(relative)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SpotError.validation("The image encoder is unavailable.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SpotError.validation("Could not optimize this image.") }
        try (data as Data).write(to: destinationURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        return relative
    }

    func url(for relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains("..") else { return nil }
        let root = paths.images.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }
}
