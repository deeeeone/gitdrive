import GitDriveCore
import MapKit
import SwiftUI

/// A photo timeline, map and albums for chosen top-level folders. Built from saved thumbnails and
/// EXIF data, so browsing downloads nothing; opening a photo downloads it.
struct PhotosView: View {
    let model: AppModel
    @State private var photos: [Photo] = []
    @State private var tab = 0
    @State private var loading = true
    @State private var message: String?

    struct Photo: Identifiable, Hashable {
        let item: ItemRecord
        let date: Date
        let coordinate: CLLocationCoordinate2D?
        var id: String { item.id }
        var album: String { parentPath(of: item.path).isEmpty ? "Unsorted" : parentPath(of: item.path) }
        static func == (a: Photo, b: Photo) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Timeline").tag(0)
                Text("Map").tag(1)
                Text("Albums").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .padding(10)
            Divider()
            if loading {
                ProgressView("Gathering photos").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if photos.isEmpty {
                ContentUnavailableView(
                    "No photos", systemImage: "photo.on.rectangle",
                    description: Text(message ?? "Choose photo folders in Settings → Extras → Photos.")
                )
            } else {
                switch tab {
                case 0: timeline
                case 1: map
                default: albums
                }
            }
        }
        .task { await load() }
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: .sectionHeaders) {
                let months = Dictionary(grouping: photos) { Calendar.current.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
                ForEach(months.keys.sorted(by: >), id: \.self) { month in
                    Section {
                        grid(months[month]!.sorted { $0.date > $1.date })
                    } header: {
                        Text(month.formatted(.dateTime.month(.wide).year()))
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .background(.background)
                    }
                }
            }
            .padding()
        }
    }

    private var map: some View {
        Map {
            ForEach(photos.filter { $0.coordinate != nil }) { photo in
                Annotation("", coordinate: photo.coordinate!) {
                    Thumb(model: model, item: photo.item, size: 44).onTapGesture { open(photo) }
                }
            }
        }
    }

    private var albums: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                let groups = Dictionary(grouping: photos, by: \.album)
                ForEach(groups.keys.sorted(), id: \.self) { album in
                    Text(album).font(.title3.weight(.semibold))
                    grid(groups[album]!.sorted { $0.date > $1.date })
                }
            }
            .padding()
        }
    }

    private func grid(_ items: [Photo]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
            ForEach(items) { photo in
                Thumb(model: model, item: photo.item, size: 110)
                    .onTapGesture(count: 2) { open(photo) }
                    .help("\(photo.item.filename), \(photo.date.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    private func open(_ photo: Photo) {
        Task {
            if let (url, item) = try? await model.readyEngine().download(id: photo.id) {
                NSWorkspace.shared.open(Tools.named(url, item.filename))
            }
        }
    }

    private func load() async {
        defer { loading = false }
        do {
            let engine = try await model.readyEngine()
            try await engine.syncAll()
            let chosen = AppConfig.photoRepos
            var out: [Photo] = []
            for item in try engine.store.allItems() where chosen.contains(item.repo) && !item.isDirectory && Thumbnailer.isMedia(item.filename) {
                let info = await engine.mediaInfo(id: item.id)
                let coordinate = info?.latitude.flatMap { lat in info?.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } }
                out.append(Photo(item: item, date: info?.taken ?? item.modified, coordinate: coordinate))
            }
            photos = out
        } catch {
            message = String(describing: error)
        }
    }
}

/// One thumbnail, loaded from the saved preview.
private struct Thumb: View {
    let model: AppModel
    let item: ItemRecord
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: item.id) {
            if let data = await (try? model.readyEngine())?.thumbnail(id: item.id) { image = NSImage(data: data) }
        }
    }
}

extension AppConfig {
    /// Top-level folders shown in Photos.
    static var photoRepos: Set<String> {
        get { Set(sharedDefaults?.stringArray(forKey: "photoRepos") ?? []) }
        set { sharedDefaults?.set(Array(newValue).sorted(), forKey: "photoRepos") }
    }
}
