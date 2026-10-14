import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small preview and the photo facts Photos mode needs, saved when a file is uploaded.
public struct MediaInfo: Codable, Sendable, Equatable {
    /// JPEG, at most 256 pixels on the long side.
    public var thumb: Data?
    /// When the photo or video was taken, from EXIF or the video's metadata.
    public var taken: Date?
    public var latitude: Double?
    public var longitude: Double?

    public init(thumb: Data? = nil, taken: Date? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.thumb = thumb
        self.taken = taken
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Thumbnailer {
    public static let maxPixels = 256

    public static func isMedia(_ filename: String) -> Bool {
        guard let type = UTType(filenameExtension: (filename as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// Reads a thumbnail and photo metadata. Returns nil for anything that isn't an image or video.
    public static func info(for file: URL, name: String) async -> MediaInfo? {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return nil }
        if type.conforms(to: .image) { return image(file) }
        if type.conforms(to: .movie) { return await video(file) }
        return nil
    }

    private static func image(_ file: URL) -> MediaInfo? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        var info = MediaInfo()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { info.thumb = jpeg(thumb) }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
                info.taken = fmt.date(from: text)
            }
            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                info.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
                info.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            }
        }
        return info.thumb == nil ? nil : info
    }

    private static func video(_ file: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        var still: CGImage?
        if let result = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
            still = result.image
        } else if let result = try? await generator.image(at: .zero) {
            still = result.image
        }
        guard let frame = still else { return nil }
        var info = MediaInfo(thumb: jpeg(frame))
        if let date = try? await asset.load(.creationDate), let value = try? await date.load(.dateValue) { info.taken = value }
        return info
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

extension Reserved {
    static func thumbPath(_ content: String) -> String { "\(metaFolder)/thumbs/\(content.prefix(2))/\(content).jpg" }
}

extension SyncEngine {
    /// Makes a thumbnail for a media file being uploaded, if the setting is on.
    func recordMedia(_ file: URL, name: String, repo: String, key: String) async {
        guard makeThumbnails(), Thumbnailer.isMedia(name), let info = await Thumbnailer.info(for: file, name: name) else { return }
        pendingMedia[repo, default: [:]][key] = info
        if isVault(repo), let thumb = info.thumb, let state = vaults[repo] {
            // Encrypted folders seal the thumbnail as its own chunk.
            if let (id, sealed) = try? state.key.sealChunk(thumb) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("GitDriveStaging/\(repo)/\(id)")
                if (try? sealed.write(to: url)) != nil { stagedChunks[repo, default: [:]][id] = url }
                pendingMedia[repo]?[key]?.thumb = Data(id.utf8)
            }
        }
    }

    /// Photo facts for an item, without its thumbnail.
    public func mediaInfo(id: String) -> MediaInfo? {
        guard let item = try? store.item(id: id), let sha = item.sha else { return nil }
        if let state = vaults[item.repo], let file = state.index.files[item.path] {
            guard file.t != nil || file.d != nil else { return nil }
            return MediaInfo(taken: file.d.map(Date.init(timeIntervalSince1970:)), latitude: file.g?.first, longitude: file.g?.last)
        }
        guard let ref = currentMeta[item.repo]?.media[sha] else { return nil }
        return MediaInfo(taken: ref.taken, latitude: ref.latitude, longitude: ref.longitude)
    }

    /// The saved thumbnail for an item, or nil if none was made.
    public func thumbnail(id: String) async -> Data? {
        guard let item = try? store.item(id: id), let sha = item.sha, let rec = try? store.repo(named: item.repo) else { return nil }
        if let state = vaults[item.repo] {
            guard let chunk = state.index.files[item.path]?.t, let location = state.index.chunks[chunk] else { return nil }
            if let cached = thumbCache.get(chunk) { return cached }
            guard let packSHA = state.packBlobs[location.p] else { return nil }
            let pack: Data
            if let cached = packCache.get(location.p) {
                pack = cached
            } else {
                guard let data = try? await client.blobData(owner: rec.owner, repo: rec.name, sha: packSHA) else { return nil }
                packCache.put(location.p, data)
                pack = data
            }
            guard location.o + location.l <= pack.count,
                  let thumb = try? state.key.openChunk(pack.subdata(in: location.o..<(location.o + location.l)), id: chunk) else { return nil }
            thumbCache.put(chunk, thumb)
            return thumb
        }
        guard let blob = currentMeta[item.repo]?.media[sha]?.thumb else { return nil }
        if let cached = thumbCache.get(blob) { return cached }
        let data = try? await client.blobData(owner: rec.owner, repo: rec.name, sha: blob)
        if let data { thumbCache.put(blob, data) }
        return data
    }
}
