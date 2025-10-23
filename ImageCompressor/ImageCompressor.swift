import SwiftUI
import Foundation
import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

class ImageCompressor: ObservableObject {
    // Monitor only the Downloads folder
    private let downloadsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

    private var folderMonitors: [DispatchSourceFileSystemObject] = []

    @Published var logs: [String] = []

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

    private func checkForNewImages(in folder: URL) {
        log("📂 Scanning folder: \(folder.lastPathComponent)")
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            log("⚠️ Failed to read folder contents")
            return
        }

        for file in files {
            // Filter hidden/temp files
            let name = file.lastPathComponent
            if name.hasPrefix(".") || name.hasPrefix("~") {
                continue
            }

            // Extension and supported formats
            let ext = file.pathExtension.lowercased()
            let supported = ["png", "jpg", "jpeg", "heic", "webp", "tiff"]
            guard supported.contains(ext) else {
                log("⛔ Skipped (unsupported format): \(file.lastPathComponent)")
                continue
            }

            // Skip files already having _lite suffix
            let baseName = file.deletingPathExtension().lastPathComponent
            if baseName.hasSuffix("_lite") {
                log("↩️ Skipped (already _lite): \(file.lastPathComponent)")
                continue
            }

            log("📥 Found file: \(file.lastPathComponent)")
            compressImageKeepingFormat(at: file, originalExtension: ext)
        }
    }

    // Check if writing to a given UTI type is supported
    private func supportsWriting(type: CFString) -> Bool {
        guard let ids = CGImageDestinationCopyTypeIdentifiers() as? [CFString] else { return false }
        return ids.contains { $0 as String == (type as String) }
    }

    // Route by format: try to preserve original format, fallback to JPEG
    private func compressImageKeepingFormat(at url: URL, originalExtension: String) {
        // Load via CGImageSource
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            log("❌ Failed to create CGImageSource: \(url.lastPathComponent)")
            return
        }

        // Read first image
        guard let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            log("❌ Failed to read image: \(url.lastPathComponent)")
            return
        }

        // Determine source UTI
        let sourceType = CGImageSourceGetType(src)

        // Prepare output URL (same folder, name + _lite + original extension)
        let baseName = url.deletingPathExtension().lastPathComponent
        let outURL = url.deletingLastPathComponent().appendingPathComponent("\(baseName)_lite.\(originalExtension)")

        // Overwrite if exists
        if FileManager.default.fileExists(atPath: outURL.path) {
            do { try FileManager.default.removeItem(at: outURL) } catch { /* ignore */ }
        }

        // Determine destinationType: if source is write-supported — keep it, else JPEG
        let jpegUTI = UTType.jpeg.identifier as CFString
        let pngUTI = UTType.png.identifier as CFString
        let tiffUTI = UTType.tiff.identifier as CFString
        // HEIC and WebP might be missing in UTType on some systems, use string UTIs
        let heicUTI: CFString = (UTType.heic.identifier as CFString? ) ?? "public.heic" as CFString
        let webpUTI: CFString = "public.webp" as CFString

        let preferredType: CFString? = sourceType
        let destinationType: CFString = {
            if let t = preferredType, supportsWriting(type: t) {
                return t
            }
            // If source not supported for writing, map by extension if possible
            switch originalExtension {
            case "jpg", "jpeg": return jpegUTI
            case "png": return pngUTI
            case "tiff", "tif": return tiffUTI
            case "heic": return supportsWriting(type: heicUTI) ? heicUTI : jpegUTI
            case "webp": return supportsWriting(type: webpUTI) ? webpUTI : jpegUTI
            default: return jpegUTI
            }
        }()

        // Compression properties (where applicable)
        var props: [CFString: Any] = [:]
        let lossyQuality: CGFloat = 0.6

        let destTypeString = destinationType as String
        if destTypeString == (jpegUTI as String) ||
            destTypeString == (heicUTI as String) ||
            destTypeString == (webpUTI as String) {
            props[kCGImageDestinationLossyCompressionQuality] = lossyQuality
        } else if destTypeString == (pngUTI as String) {
            // PNG — lossless (keep default)
        } else if destTypeString == (tiffUTI as String) {
            // TIFF — keep default
        }

        // Create destination
        guard let dst = CGImageDestinationCreateWithURL(outURL as CFURL, destinationType, 1, nil) else {
            log("❌ Failed to create CGImageDestination: \(outURL.lastPathComponent)")
            return
        }

        // Copy basic metadata
        let metadata = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let addProps = metadata != nil ? props.merging(metadata!) { current, _ in current } : props

        CGImageDestinationAddImage(dst, cgImage, addProps as CFDictionary)

        if CGImageDestinationFinalize(dst) {
            // Remove original file
            try? FileManager.default.removeItem(at: url)
            log("✅ Compressed (format preserved): \(url.lastPathComponent) → \(outURL.lastPathComponent); original removed")
        } else {
            // Fallback: try JPEG if finalize failed
            log("⚠️ Failed to save with original format. Trying JPEG…")
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

        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: CGFloat(0.6)
        ]
        CGImageDestinationAddImage(dst, cgImage, props as CFDictionary)

        if CGImageDestinationFinalize(dst) {
            try? FileManager.default.removeItem(at: originalURL)
            log("✅ Fallback JPEG: \(originalURL.lastPathComponent) → \(outURL.lastPathComponent); original removed")
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
    }

    private func handlePickedURL(_ url: URL, supported: Set<String>) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            log("📁 Selected folder: \(url.lastPathComponent)")
            // Process folder same as monitoring
            checkForNewImages(in: url)
        } else {
            // Process single file
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
            log("📥 Processing file: \(name)")
            compressImageKeepingFormat(at: url, originalExtension: ext)
        }
    }
}
