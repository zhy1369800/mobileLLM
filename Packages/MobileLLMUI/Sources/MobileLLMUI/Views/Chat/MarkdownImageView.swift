// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import CryptoKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Identifies the resolved location of an image in Markdown text.
public enum MarkdownImageSource: Equatable, Hashable {
    case remote(URL)
    case file(URL)
    case data(Data)

    /// Safely resolves a raw Markdown destination string into an image source.
    /// Handles http(s), file://, absolute filesystem paths, sandbox relative paths, and data URIs.
    public static func resolve(_ raw: String) -> MarkdownImageSource? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Data URI (Base64)
        if trimmed.hasPrefix("data:image/") || trimmed.hasPrefix("data:application/octet-stream;base64,") {
            guard let markerRange = trimmed.range(of: ";base64,") else { return nil }
            let payload = String(trimmed[markerRange.upperBound...])
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
                return nil
            }
            return .data(data)
        }

        // 2. Remote URL (http / https)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            if let url = URL(string: trimmed) {
                return .remote(url)
            } else if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(.urlPathAllowed)),
                      let url = URL(string: encoded) {
                return .remote(url)
            }
            return nil
        }

        // 3. File URL (file://)
        if trimmed.hasPrefix("file://") {
            if let url = URL(string: trimmed) {
                return .file(url)
            } else if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let url = URL(string: encoded) {
                return .file(url)
            }
            return nil
        }

        // 4. Virtual App Sandbox Scheme (mobilellm://)
        if trimmed.hasPrefix("mobilellm://") {
            var rest = String(trimmed.dropFirst("mobilellm://".count))
            while rest.hasPrefix("/") {
                rest.removeFirst()
            }
            let cleanPath = (rest.components(separatedBy: "?").first ?? rest)
                .removingPercentEncoding ?? rest
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let fileURL = cleanPath.isEmpty ? docs : docs.appendingPathComponent(cleanPath)
                return .file(fileURL)
            }
            return nil
        }

        // 5. Local Absolute Path (Unix /... or Windows C:\...)
        let isUnixAbs = trimmed.hasPrefix("/")
        let isWindowsAbs = trimmed.range(of: #"^[a-zA-Z]:[\\/]"#, options: .regularExpression) != nil
        if isUnixAbs || isWindowsAbs {
            let url = URL(fileURLWithPath: trimmed)
            return .file(url)
        }

        // 6. App sandbox relative path (e.g. "attachments/img.png")
        let ext = (trimmed as NSString).pathExtension.lowercased()
        let knownImageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "tiff"]
        if knownImageExts.contains(ext) {
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let fileURL = docs.appendingPathComponent(trimmed)
                return .file(fileURL)
            }
        }

        return nil
    }

    var cacheKey: String {
        switch self {
        case .remote(let url): return "remote:\(url.absoluteString)"
        case .file(let url): return "file:\(url.path)"
        case .data(let data): return "data:\(data.count)_\(data.prefix(32).hashValue)"
        }
    }
}

/// Manages on-disk persistence for markdown images in the user-visible `Documents/images` folder.
/// Matches Kelivo's architecture so all generated/remote images can be browsed in iOS Files ("My iPhone/mobileLLM/images").
public enum MarkdownImageDiskStore {
    public static var imagesDirectory: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs.appendingPathComponent("images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func hashString(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func hashData(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func extFor(data: Data) -> String {
        if data.count >= 4 {
            let header = [UInt8](data.prefix(4))
            if header == [0x89, 0x50, 0x4E, 0x47] { return "png" }
            if header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF { return "jpg" }
            if header[0] == 0x47 && header[1] == 0x49 && header[2] == 0x46 { return "gif" }
            if header == [0x52, 0x49, 0x46, 0x46] { return "webp" }
        }
        return "png"
    }

    @discardableResult
    public static func persistBase64(data: Data) -> URL? {
        guard let dir = imagesDirectory else { return nil }
        let ext = extFor(data: data)
        let hash = hashData(data)
        let fileURL = dir.appendingPathComponent("img_\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return fileURL
    }

    public static func localURLForRemote(url: URL) -> URL? {
        guard let dir = imagesDirectory else { return nil }
        let hash = hashString(url.absoluteString)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let fileURL = dir.appendingPathComponent("net_\(hash).\(ext)")
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    @discardableResult
    public static func persistRemote(url: URL, data: Data) -> URL? {
        guard let dir = imagesDirectory else { return nil }
        let hash = hashString(url.absoluteString)
        let ext = url.pathExtension.isEmpty ? extFor(data: data) : url.pathExtension.lowercased()
        let fileURL = dir.appendingPathComponent("net_\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return fileURL
    }
}

/// In-memory cache for downscaled, ready-to-render platform images.
final class MarkdownImageCache: @unchecked Sendable {
    static let shared = MarkdownImageCache()
    private let cache = NSCache<NSString, PlatformImage>()

    init() {
        cache.countLimit = 120
    }

    func image(forKey key: String) -> PlatformImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: PlatformImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// State holder for asynchronous downsampling and rendering of markdown images.
@MainActor
final class MarkdownImageLoader: ObservableObject {
    enum State: Equatable {
        case loading
        case success(image: PlatformImage, rawData: Data)
        case failure

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): return true
            case (.failure, .failure): return true
            case (.success(_, let d1), .success(_, let d2)): return d1 == d2
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .loading
    private let source: MarkdownImageSource
    private var loadTask: Task<Void, Never>?

    init(source: MarkdownImageSource) {
        self.source = source
    }

    func load() {
        let key = source.cacheKey
        if let cached = MarkdownImageCache.shared.image(forKey: key) {
            // Instant memory cache hit (0ms UI render)
            switch source {
            case .data(let data):
                state = .success(image: cached, rawData: data)
                return
            case .remote(let url):
                if let localURL = MarkdownImageDiskStore.localURLForRemote(url: url),
                   let localData = try? Data(contentsOf: localURL), !localData.isEmpty {
                    state = .success(image: cached, rawData: localData)
                    return
                }
            case .file(let url):
                if let localData = try? Data(contentsOf: url), !localData.isEmpty {
                    state = .success(image: cached, rawData: localData)
                    return
                }
            }
        }

        state = .loading
        loadTask?.cancel()

        loadTask = Task { [source] in
            let rawData: Data?
            switch source {
            case .remote(let url):
                // 1. Check local Documents/images persistent cache first for instant offline hits
                if let localURL = MarkdownImageDiskStore.localURLForRemote(url: url),
                   let localData = try? Data(contentsOf: localURL), !localData.isEmpty {
                    rawData = localData
                } else {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 15
                    if let downloaded = try? await URLSession.shared.data(for: request).0, !downloaded.isEmpty {
                        rawData = downloaded
                        // Asynchronously persist to Documents/images for Files app visibility & offline access
                        MarkdownImageDiskStore.persistRemote(url: url, data: downloaded)
                    } else {
                        rawData = nil
                    }
                }
            case .file(let url):
                rawData = try? Data(contentsOf: url)
            case .data(let data):
                rawData = data
                // Asynchronously persist base64 data to Documents/images/img_<hash>.<ext>
                MarkdownImageDiskStore.persistBase64(data: data)
            }

            guard !Task.isCancelled, let rawData, !rawData.isEmpty else {
                if !Task.isCancelled {
                    self.state = .failure
                }
                return
            }

            // Downsample and decode in background to keep UI thread silky smooth.
            let downscaled = ImageAttachment.downscaledJPEG(from: rawData, maxLongEdge: 1568) ?? rawData
            let decoded: PlatformImage?
            #if canImport(UIKit)
            decoded = UIImage(data: downscaled)
            #elseif canImport(AppKit)
            decoded = NSImage(data: downscaled)
            #else
            decoded = nil
            #endif

            guard !Task.isCancelled, let image = decoded else {
                if !Task.isCancelled {
                    self.state = .failure
                }
                return
            }

            MarkdownImageCache.shared.insert(image, forKey: key)
            if !Task.isCancelled {
                self.state = .success(image: image, rawData: rawData)
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }
}

/// Renders a responsive, downscaled image within assistant markdown responses.
struct MarkdownImageView: View {
    let source: MarkdownImageSource
    let alt: String?

    @StateObject private var loader: MarkdownImageLoader
    @State private var showingFullScreen = false

    init(source: MarkdownImageSource, alt: String?) {
        self.source = source
        self.alt = alt
        _loader = StateObject(wrappedValue: MarkdownImageLoader(source: source))
    }

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                placeholderView
            case let .success(image, rawData):
                successView(image: image, rawData: rawData)
            case .failure:
                failureView
            }
        }
        .onAppear { loader.load() }
        .onDisappear { loader.cancel() }
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            .fill(Theme.surface2)
            .frame(height: 180)
            .frame(maxWidth: .infinity)
            .overlay(
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .accessibilityLabel(alt ?? "Loading image")
    }

    private func successView(image: PlatformImage, rawData: Data) -> some View {
        Button {
            showingFullScreen = true
        } label: {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(alt ?? "Image")
        .accessibilityHint("Double-tap to open full screen")
        .sheet(isPresented: $showingFullScreen) {
            MarkdownImageViewerSheet(image: image, rawData: rawData, alt: alt)
        }
    }

    private var failureView: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't load image")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                if let alt, !alt.isEmpty {
                    Text(alt)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                loader.load()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry loading image")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

/// Fullscreen gallery sheet for high-resolution inspection, sharing, and saving.
struct MarkdownImageViewerSheet: View {
    let image: PlatformImage
    let rawData: Data
    let alt: String?

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var saved = false
    @State private var saveErrorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(Theme.Space.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(alt ?? "Image")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Clipboard.copyImage(rawData)
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }

                    #if os(iOS)
                    Button {
                        saveToPhotos()
                    } label: {
                        Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark.circle" : "arrow.down.circle")
                    }
                    #endif
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    #if os(iOS)
    private func saveToPhotos() {
        let uiImage = UIImage(data: rawData) ?? image
        let helper = PhotoSaveHelper { success in
            if success {
                saved = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    saved = false
                }
            }
        }
        UIImageWriteToSavedPhotosAlbum(uiImage, helper, #selector(PhotoSaveHelper.image(_:didFinishSavingWithError:contextInfo:)), nil)
    }
    #endif
}

#if os(iOS)
private final class PhotoSaveHelper: NSObject {
    let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        completion(error == nil)
    }
}
#endif
