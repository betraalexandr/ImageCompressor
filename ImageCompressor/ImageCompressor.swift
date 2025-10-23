import SwiftUI
import Foundation
import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

class ImageCompressor: ObservableObject {
    // User options
    @AppStorage("deleteOriginals") private var deleteOriginals: Bool = true
    @AppStorage("convertPNGsToJPEG") private var convertPNGsToJPEG: Bool = true

    // Persistence keys
    private let processedFilesKey = "processedFiles"
    private let lastScanDateKey = "lastScanDate"

    // Monitor only the Downloads folder
    private let downloadsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

    private var folderMonitors: [DispatchSourceFileSystemObject] = []

    @Published var logs: [String] = []

    // Persisted state
    private var processedFiles: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: processedFilesKey) ?? []
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: processedFilesKey)
        }
    }

    private var lastScanDate: Date {
        get { UserDefaults.standard.object(forKey: lastScanDateKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: lastScanDateKey) }
    }

    init() {
        createFolderIfNeeded()
        startMonitoring()
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.logs.append("🕓 \(Self.timestamp())  \(message)")
            if self.logs.count > 500 {
                self.logs.removeFirst()
            }
        }
        print(message)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    // Downloads usually exists, but keep the check
    private func createFolderIfNeeded() {
        if !FileManager.default.fileExists(atPath: downloadsFolder.path) {
            do {
                try FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
                log("Created folder: \(downloadsFolder.lastPathComponent)")
            } catch {
                log("❌ Failed to create Downloads folder: \(error.localizedDescription)")
            }
        }
    }

    private func startMonitoring() {
        let folder = downloadsFolder

        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor != -1 else {
            log("❌ Failed to open folder: \(folder.path)")
            return
        }

        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: DispatchQueue.global()
        )

        monitor.setEventHandler { [weak self] in
            self?.checkForNewImages(in: folder)
        }

        monitor.setCancelHandler {
            close(descriptor)
        }

        monitor.resume()
        folderMonitors.append(monitor)
        log("👀 Monitoring enabled: \(folder.lastPathComponent)")
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func checkForNewImages(in folder: URL) {
        // Capture current time to move the watermark only after we finish processing
        let scanStart = Date()

        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            log("⚠️ Failed to read folder contents")
            return
        }

        let supported = Set(["png", "jpg", "jpeg", "heic", "webp", "tiff", "tif"])

        // Consider only candidates that are:
        // - supported type
        // - not already processed
        // - modified at or after lastScanDate
        let candidates: [URL] = files.compactMap { url in
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name.hasPrefix("~") { return nil }

            let ext = url.pathExtension.lowercased()
            if !supported.contains(ext) { return nil }

            let baseName = url.deletingPathExtension().lastPathComponent
            if baseName.hasSuffix("_lite") { return nil }

            if processedFiles.contains(url.path) { return nil }

            guard let mdate = fileModificationDate(url), mdate >= lastScanDate else { return nil }

            return url
        }

        guard !candidates.isEmpty else { return }

        for file in candidates {
            log("📥 New file: \(file.lastPathComponent)")
            compressImageKeepingFormat(at: file, originalExtension: file.pathExtension.lowercased())
        }

        // Move watermark forward only after we attempted to process new files
        lastScanDate = scanStart
    }

    // Check if writing to a given UTI type is supported
    private func supportsWriting(type: CFString) -> Bool {
        guard let ids = CGImageDestinationCopyTypeIdentifiers() as? [CFString] else { return false }
        return ids.contains { $0 as String == (type as String) }
    }

    // Detect if CGImage has alpha
    private func hasAlpha(_ image: CGImage) -> Bool {
        let alpha = image.alphaInfo
        switch alpha {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        default:
            return false
        }
    }

    // Route by format: try to preserve original format, or convert PNG->JPEG if enabled and safe
    private func compressImageKeepingFormat(at url: URL, originalExtension: String) {
        // Load via CGImageSource (no downsampling)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            log("❌ Failed to create CGImageSource: \(url.lastPathComponent)")
            return
        }

        // Read first image (full size)
        guard let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            log("❌ Failed to read image: \(url.lastPathComponent)")
            return
        }

        // Determine source UTI
        let sourceType = CGImageSourceGetType(src)

        // Prepare output URL (same folder, name + _lite + extension)
        let baseName = url.deletingPathExtension().lastPathComponent

        // Destination format selection
        let jpegUTI = UTType.jpeg.identifier as CFString
        let pngUTI = UTType.png.identifier as CFString
        let tiffUTI = UTType.tiff.identifier as CFString
        let heicUTI: CFString = (UTType.heic.identifier as CFString? ) ?? "public.heic" as CFString
        let webpUTI: CFString = "public.webp" as CFString

        // If it's PNG and user allows conversion, and there's no alpha — convert to JPEG
        var forceJPEGForPNG = false
        if originalExtension == "png", convertPNGsToJPEG, !hasAlpha(cgImage) {
            forceJPEGForPNG = true
        }

        let preferredType: CFString? = sourceType
        let destinationType: CFString = {
            if forceJPEGForPNG { return jpegUTI }
            if let t = preferredType, supportsWriting(type: t) {
                return t
            }
            switch originalExtension {
            case "jpg", "jpeg": return jpegUTI
            case "png": return pngUTI
            case "tiff", "tif": return tiffUTI
            case "heic": return supportsWriting(type: heicUTI) ? heicUTI : jpegUTI
            case "webp": return supportsWriting(type: webpUTI) ? webpUTI : jpegUTI
            default: return jpegUTI
            }
        }()

        // Output URL depends on destinationType
        let outExt: String = {
            let s = destinationType as String
            if s == (jpegUTI as String) { return "jpeg" }
            if s == (pngUTI as String) { return "png" }
            if s == (tiffUTI as String) { return "tiff" }
            if s == (heicUTI as String) { return "heic" }
            if s == (webpUTI as String) { return "webp" }
            return originalExtension // fallback
        }()
        let outURL = url.deletingLastPathComponent().appendingPathComponent("\(baseName)_lite.\(outExt)")

        // Overwrite if exists
        if FileManager.default.fileExists(atPath: outURL.path) {
            do { try FileManager.default.removeItem(at: outURL) } catch { /* ignore */ }
        }

        // Compression properties — keep size, just adjust quality for lossy formats
        var props: [CFString: Any] = [:]
        let lossyQuality: CGFloat = 0.7 // немного выше для лучшего качества/размера

        let destTypeString = destinationType as String
        if destTypeString == (jpegUTI as String) ||
            destTypeString == (heicUTI as String) ||
            destTypeString == (webpUTI as String) {
            props[kCGImageDestinationLossyCompressionQuality] = lossyQuality
        }

        // Copy ALL metadata/properties from source (DPI/EXIF/Orientation/Profiles)
        let metadata = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        var addProps = metadata ?? [:]
        addProps[kCGImageDestinationEmbedThumbnail] = false
        for (k, v) in props { addProps[k] = v }

        // Create destination
        guard let dst = CGImageDestinationCreateWithURL(outURL as CFURL, destinationType, 1, nil) else {
            log("❌ Failed to create CGImageDestination: \(outURL.lastPathComponent)")
            return
        }

        CGImageDestinationAddImage(dst, cgImage, addProps as CFDictionary)

        if CGImageDestinationFinalize(dst) {
            // Mark as processed
            var set = processedFiles
            set.insert(url.path)
            processedFiles = set

            if deleteOriginals {
                try? FileManager.default.removeItem(at: url)
                log("✅ Compressed: \(url.lastPathComponent) → \(outURL.lastPathComponent); original removed")
            } else {
                log("✅ Compressed: \(url.lastPathComponent) → \(outURL.lastPathComponent); original kept")
            }
        } else {
            // Fallback: try JPEG if finalize failed
            log("⚠️ Failed to save with chosen format. Trying JPEG…")
            compressToJPEGFallback(cgImage: cgImage, originalURL: url, baseName: baseName)
        }
    }

    private func compressToJPEGFallback(cgImage: CGImage, originalURL: URL, baseName: String) {
        let outURL = originalURL.deletingLastPathComponent().appendingPathComponent("\(baseName)_lite.jpeg")

        if FileManager.default.fileExists(atPath: outURL.path) {
            do { try FileManager.default.removeItem(at: outURL) } catch { /* ignore */ }
        }

        guard let dst = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            log("❌ Fallback: failed to create CGImageDestination for JPEG")
            return
        }

        // Keep size; set only quality; no downsampling
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: CGFloat(0.7),
            kCGImageDestinationEmbedThumbnail: false
        ]

        // Try to copy metadata from source file
        if let src = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
           let metadata = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for (k, v) in metadata { props[k] = v }
        }

        CGImageDestinationAddImage(dst, cgImage, props as CFDictionary)

        if CGImageDestinationFinalize(dst) {
            var set = processedFiles
            set.insert(originalURL.path)
            processedFiles = set

            if deleteOriginals {
                try? FileManager.default.removeItem(at: originalURL)
                log("✅ Fallback JPEG: \(originalURL.lastPathComponent) → \(outURL.lastPathComponent); original removed")
            } else {
                log("✅ Fallback JPEG: \(originalURL.lastPathComponent) → \(outURL.lastPathComponent); original kept")
            }
        } else {
            log("❌ Fallback: failed to save JPEG for \(originalURL.lastPathComponent)")
        }
    }

    // MARK: - Variant B (NSOpenPanel)

    // Public method to call from UI (button/menu)
    public func presentOpenPanel() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.title = "Select images or folders"
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.canCreateDirectories = false
            // Restrict visible file types to supported ones
            panel.allowedContentTypes = [
                .png, .jpeg, .heic, .tiff
            ]
            // WebP might be missing in UTType on older systems; allow others so it can be selected
            panel.allowsOtherFileTypes = true

            // Present as sheet if we have a window, otherwise modally
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window) { [weak self] response in
                    guard response == .OK else { return }
                    self?.handlePickedURLs(panel.urls)
                }
            } else {
                let response = panel.runModal()
                if response == .OK {
                    self.handlePickedURLs(panel.urls)
                }
            }
        }
    }

    private func handlePickedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        log("🗂️ Selected items: \(urls.count)")
        let supported = Set(["png", "jpg", "jpeg", "heic", "webp", "tiff", "tif"])

        for url in urls {
            handlePickedURL(url, supported: supported)
        }
        // After manual selection, also advance watermark
        lastScanDate = Date()
    }

    private func handlePickedURL(_ url: URL, supported: Set<String>) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            log("📁 Selected folder: \(url.lastPathComponent)")
            // Process only new images inside the folder
            checkForNewImages(in: url)
        } else {
            // Process single file if it's new and not processed yet
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name.hasPrefix("~") {
                log("⛔ Skipped hidden/temp file: \(name)")
                return
            }
            let ext = url.pathExtension.lowercased()
            guard supported.contains(ext) else {
                log("⛔ Skipped (unsupported format): \(name)")
                return
            }
            let baseName = url.deletingPathExtension().lastPathComponent
            guard !baseName.hasSuffix("_lite") else {
                log("↩️ Skipped (already _lite): \(name)")
                return
            }
            guard !processedFiles.contains(url.path),
                  let mdate = fileModificationDate(url),
                  mdate >= lastScanDate else {
                log("↩️ Skipped (already processed or old): \(name)")
                return
            }

            log("📥 Processing file: \(name)")
            compressImageKeepingFormat(at: url, originalExtension: ext)
        }
    }
}
