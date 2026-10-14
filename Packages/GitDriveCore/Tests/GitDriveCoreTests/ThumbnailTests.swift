import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GitDriveCore

/// A 1200 x 800 JPEG with an EXIF date and GPS position.
func samplePhoto() throws -> URL {
    let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:07:04 12:30:00"],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W",
        ],
    ]
    CGImageDestinationAddImage(dest, context.makeImage()!, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return url
}

@Suite("Thumbnails", .serialized)
struct ThumbnailTests {
    let fake = FakeGitHub()
    let client: GitHubClient

    init() {
        client = GitHubClient(token: "test", session: FakeProtocol.session(for: fake))
    }

    @Test func photoInfoIsRead() async throws {
        let info = try #require(await Thumbnailer.info(for: try samplePhoto(), name: "a.jpg"))
        let thumb = try #require(info.thumb)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(thumb as CFData, nil)!, 0, nil)!
        #expect(max(image.width, image.height) <= Thumbnailer.maxPixels)
        #expect(abs((info.latitude ?? 0) - 51.5) < 1e-4 && abs((info.longitude ?? 0) + 0.12) < 1e-4)
        #expect(info.taken != nil)
        #expect(await Thumbnailer.info(for: try samplePhoto(), name: "notes.txt") == nil)
    }

    @Test func plainFoldersStoreThumbnailsBySHA() async throws {
        fake.seed(repo: "drive-pics", files: [".gitdrive-keep": ""])
        let store = try ItemStore(url: nil)
        let engine = SyncEngine(client: client, store: store, makeThumbnails: { true })
        try await engine.syncAll()
        let folder = try #require(try store.item(repo: "drive-pics", path: ""))
        let photo = try await engine.createFile(parentID: folder.id, name: "beach.jpg", contents: try samplePhoto())
        #expect(fake.files(repo: "drive-pics").keys.contains { $0.hasPrefix(".gitdrive/thumbs/") })
        #expect(await engine.thumbnail(id: photo.id) != nil)
        #expect(abs((await engine.mediaInfo(id: photo.id)?.latitude ?? 0) - 51.5) < 1e-4)

        _ = try await engine.modify(id: photo.id, newName: "sea.jpg", newParentID: nil, contents: nil)
        #expect(await engine.thumbnail(id: photo.id) != nil)
        try await engine.delete(id: photo.id)
        #expect(!fake.files(repo: "drive-pics").keys.contains { $0.hasPrefix(".gitdrive/thumbs/") })
    }

    @Test func encryptedFoldersSealThumbnailsInTheirOwnPacks() async throws {
        let identity = try VaultIdentity.generate()
        let store = try ItemStore(url: nil)
        let engine = SyncEngine(client: client, store: store, identity: { identity }, encryptNewFolders: { true }, makeThumbnails: { true })
        try await engine.syncAll()
        let folder = try await engine.createFolder(parentID: ItemStore.rootID, name: "Pics")
        let photo = try await engine.createFile(parentID: folder.id, name: "beach.jpg", contents: try samplePhoto())
        let thumb = try #require(await engine.thumbnail(id: photo.id))
        #expect(CGImageSourceCreateWithData(thumb as CFData, nil) != nil)
        #expect(abs((await engine.mediaInfo(id: photo.id)?.longitude ?? 0) + 0.12) < 1e-4)
        let packs = fake.rawBlobs(repo: folder.repo).filter { $0.key.hasPrefix("p/") }
        #expect(packs.count == 2)
        #expect(!fake.rawBlobs(repo: folder.repo).keys.contains { $0.contains("thumbs") })
    }
}
