import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct JXLDropApp: App {
    init() {
        let defaults = UserDefaults.standard
        let versionKey = "jxl.settingsMigrationVersion"
        if defaults.integer(forKey: versionKey) < 2 {
            defaults.set(90, forKey: "jxl.quality")
            defaults.set(true, forKey: "jxl.transparencyLossy")
            defaults.set(100, forKey: "jxl.transparencyQuality")
            defaults.set(2, forKey: versionKey)
        }
    }

    var body: some Scene {
        WindowGroup("JXL Drop") {
            ContentView()
                .frame(minWidth: 520, minHeight: 430)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
struct ContentView: View {
    @State private var items: [ConversionItem] = []
    @State private var pending: [ConversionItem] = []
    @State private var queuedPaths = Set<String>()
    @State private var isTargeted = false
    @State private var isProcessing = false
    @State private var scansInProgress = 0
    @State private var showSettings = false
    @AppStorage("jxl.lossy") private var lossy = true
    @AppStorage("jxl.quality") private var quality = 90
    @AppStorage("jxl.transparencyLossy") private var transparencyLossy = true
    @AppStorage("jxl.transparencyQuality") private var transparencyQuality = 100
    @AppStorage("jxl.speed") private var speed = SpeedPreset.medium.rawValue
    @AppStorage("jxl.includeExif") private var includeExif = false
    @AppStorage("jxl.includeXmp") private var includeXmp = false
    @AppStorage("jxl.includePhotoshopExtras") private var includePhotoshopExtras = false

    private var isBusy: Bool { isProcessing || scansInProgress > 0 }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button { showSettings = true } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
            }

            VStack(spacing: 5) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("JXL Drop")
                    .font(.system(size: 25, weight: .semibold))
                Text("Drop files or folders to convert and replace source images")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isTargeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.45))
                VStack(spacing: 8) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 27))
                    Text(isTargeted ? "Release to scan and convert" : "Drop files or folders here")
                        .font(.headline)
                    Text("Folders are scanned recursively; non-image files are skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            }
            .frame(height: 132)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted, perform: acceptDrop)

            HStack {
                Spacer()
                Button(action: chooseFilesOrFolders) {
                    Label("Add Files or Folders…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(compressionSummary, systemImage: "slider.horizontal.3")
                Label(metadataSummary, systemImage: "tag.slash")
                Label("Original moved to Trash after the JXL is validated", systemImage: "checkmark.shield")
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)

            if !items.isEmpty {
                List(items) { item in
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .foregroundStyle(item.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(1)
                            if let detail = item.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(item.status.label)
                            .font(.caption)
                            .foregroundStyle(item.tint)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .frame(minHeight: 80, maxHeight: 160)
            }

            HStack {
                Text("Local processing. Existing .jxl files are never overwritten.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if isBusy {
                    Text(scansInProgress > 0 ? "Scanning…" : "Converting…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView().controlSize(.small)
                }
                if !items.isEmpty {
                    Button("Clear List", systemImage: "xmark.circle") { items.removeAll() }
                        .buttonStyle(.borderless)
                        .disabled(isBusy)
                        .help("Clear result rows. This does not change any files.")
                }
            }
        }
        .padding(22)
        .sheet(isPresented: $showSettings) { settingsPanel }
    }

    private var compressionSummary: String {
        let colourMode = lossy ? "Colour Lossy · \(quality)" : "Colour Lossless"
        let alphaMode: String
        if !lossy || quality == 100 || !transparencyLossy || transparencyQuality == 100 {
            alphaMode = "Transparency Lossless (when present)"
        } else {
            alphaMode = "Transparency Lossy · \(transparencyQuality) (when present)"
        }
        let selectedSpeed = SpeedPreset(rawValue: speed) ?? .medium
        return "\(colourMode) · \(alphaMode) · \(selectedSpeed.label)"
    }

    private func qualityLabel(_ value: Int) -> String {
        switch value {
        case 100: "Maximum"
        case 90...99: "Very High"
        case 75...89: "High"
        case 50...74: "Medium"
        default: "Low"
        }
    }

    private var metadataSummary: String {
        let included: [String] = [
            includeExif ? "EXIF" : nil,
            includeXmp ? "XMP" : nil,
            includePhotoshopExtras ? "Photoshop extras" : nil
        ].compactMap { $0 }
        return included.isEmpty ? "No EXIF, XMP or JUMBF metadata" : "Include \(included.joined(separator: ", "))"
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("JPEG XL Settings")
                .font(.title2.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    compressionSection(
                        title: "Color Compression",
                        lossy: $lossy,
                        quality: $quality,
                        qualityDescription: "Passed directly to cjxl as --quality \(quality). Libjxl quality 100 is mathematically lossless."
                    )

                    compressionSection(
                        title: "Transparency Compression",
                        lossy: $transparencyLossy,
                        quality: $transparencyQuality,
                        qualityDescription: transparencyDescription,
                        isEnabled: lossy && quality < 100
                    )
                    if !lossy || quality == 100 {
                        Text("Libjxl's lossless colour path also encodes transparency losslessly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Metadata").font(.headline)
                        Toggle("Include EXIF Metadata", isOn: $includeExif)
                        Toggle("Include XMP Metadata", isOn: $includeXmp)
                        Toggle("Include Photoshop Extras (JUMBF)", isOn: $includePhotoshopExtras)
                    }

                    Picker("Speed", selection: $speed) {
                        ForEach(SpeedPreset.allCases) { preset in
                            Text(preset.label).tag(preset.rawValue)
                        }
                    }

                    Text("Color quality \(quality) is passed directly to libjxl. Transparency quality \(transparencyQuality) uses alpha distance \(String(format: "%.2f", ConversionSettings.alphaDistance(forQuality: transparencyQuality))). Adobe's exact mappings are unpublished. Transparency settings apply only to images with alpha.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Done") { showSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 470, height: 650)
    }

    private var transparencyDescription: String {
        let distance = ConversionSettings.alphaDistance(forQuality: transparencyQuality)
        return "Quality \(transparencyQuality) uses alpha distance \(String(format: "%.2f", distance)); 0 is lossless."
    }

    private func compressionSection(title: String, lossy: Binding<Bool>, quality: Binding<Int>, qualityDescription: String, isEnabled: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            Picker("Mode", selection: lossy) {
                Text("Lossy").tag(true)
                Text("Lossless").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(!isEnabled)

            if lossy.wrappedValue {
                HStack {
                    Text("Quality")
                    Spacer()
                    TextField("Quality", value: Binding(
                        get: { quality.wrappedValue },
                        set: { quality.wrappedValue = min(100, max(1, $0)) }
                    ), format: .number)
                        .frame(width: 54)
                        .multilineTextAlignment(.trailing)
                        .disabled(!isEnabled)
                    Text(qualityLabel(quality.wrappedValue))
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .leading)
                }
                Slider(value: Binding(
                    get: { Double(quality.wrappedValue) },
                    set: { quality.wrappedValue = Int($0.rounded()) }
                ), in: 1...100, step: 1)
                .disabled(!isEnabled)
                Text(qualityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let settingsSnapshot = currentSettings
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        var issues: [DiscoveryIssue] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let suggestedName = provider.suggestedName ?? "Dropped item"
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { item, error in
                defer { group.leave() }
                if let url = item {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                } else if let error {
                    lock.lock()
                    issues.append(DiscoveryIssue(name: suggestedName, message: "Could not read the dropped item: \(error.localizedDescription)"))
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            Task { @MainActor in self.enqueue(urls, settings: settingsSnapshot, providerIssues: issues) }
        }
        return true
    }

    private func chooseFilesOrFolders() {
        let settingsSnapshot = currentSettings
        let panel = NSOpenPanel()
        panel.title = "Add Images or Folders"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK {
            enqueue(panel.urls, settings: settingsSnapshot)
        }
    }

    private func enqueue(_ urls: [URL], settings: ConversionSettings, providerIssues: [DiscoveryIssue] = []) {
        guard !urls.isEmpty || !providerIssues.isEmpty else { return }
        scansInProgress += 1
        Task {
            let discovery = await Task.detached(priority: .userInitiated) {
                InputDiscovery.imageFiles(in: urls)
            }.value
            scansInProgress = max(0, scansInProgress - 1)
            for issue in (providerIssues + discovery.issues).prefix(25) {
                items.insert(ConversionItem(url: URL(fileURLWithPath: issue.name), settings: settings, status: .skipped, detail: issue.message), at: 0)
            }
            guard !discovery.files.isEmpty else {
                if providerIssues.isEmpty && discovery.issues.isEmpty {
                    let name = urls.first?.lastPathComponent ?? "Selection"
                    items.insert(ConversionItem(url: URL(fileURLWithPath: name), settings: settings, status: .skipped, detail: "No supported images found. Existing JXL files and non-image files are skipped."), at: 0)
                }
                return
            }
            enqueueImages(discovery.files, settings: settings)
        }
    }

    private func enqueueImages(_ urls: [URL], settings: ConversionSettings) {
        let newURLs = urls.filter { queuedPaths.insert($0.standardizedFileURL.path).inserted }
        for duplicate in urls where !newURLs.contains(where: { $0.standardizedFileURL.path == duplicate.standardizedFileURL.path }) {
            items.insert(ConversionItem(url: duplicate, settings: settings, status: .skipped, detail: "Already queued in this batch."), at: 0)
        }
        let newItems = newURLs.map { ConversionItem(url: $0, settings: settings) }
        items.insert(contentsOf: newItems, at: 0)
        pending.append(contentsOf: newItems)
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            while !pending.isEmpty {
                let item = pending.removeFirst()
                update(item.id, status: .working, detail: "Preparing image…")
                do {
                    let message = try await Task.detached(priority: .userInitiated) {
                        try JXLConverter.convert(item.url, settings: item.settings)
                    }.value
                    update(item.id, status: .done, detail: message)
                } catch {
                    update(item.id, status: .failed, detail: error.localizedDescription)
                }
                queuedPaths.remove(item.url.standardizedFileURL.path)
            }
            isProcessing = false
        }
    }

    private func update(_ id: UUID, status: ItemStatus, detail: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].detail = detail
    }

    private var currentSettings: ConversionSettings {
        ConversionSettings(
            lossy: lossy,
            quality: quality,
            transparencyLossy: transparencyLossy && lossy && quality < 100,
            transparencyQuality: transparencyQuality,
            effort: (SpeedPreset(rawValue: speed) ?? .medium).effort,
            includeExif: includeExif,
            includeXmp: includeXmp,
            includePhotoshopExtras: includePhotoshopExtras
        )
    }
}

private struct ConversionItem: Identifiable {
    let id = UUID()
    let url: URL
    let settings: ConversionSettings
    var status: ItemStatus = .queued
    var detail: String? = "Waiting"
    var name: String { url.lastPathComponent }
    var symbol: String {
        switch status {
        case .queued: "clock"
        case .working: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .skipped: "minus.circle"
        }
    }
    var tint: Color {
        switch status {
        case .queued: .secondary
        case .working: .accentColor
        case .done: .green
        case .failed: .orange
        case .skipped: .secondary
        }
    }
}

private struct ConversionSettings: Sendable {
    let lossy: Bool
    let quality: Int
    let transparencyLossy: Bool
    let transparencyQuality: Int
    let effort: Int
    let includeExif: Bool
    let includeXmp: Bool
    let includePhotoshopExtras: Bool

    var libjxlQuality: Int { max(1, min(100, quality)) }

    var libjxlAlphaDistance: Double {
        transparencyLossy ? Self.alphaDistance(forQuality: transparencyQuality) : 0
    }

    static func alphaDistance(forQuality quality: Int) -> Double {
        let value = Double(max(0, min(100, quality)))
        if value >= 100 { return 0 }
        if value >= 30 { return 0.1 + (100 - value) * 0.09 }
        return (53.0 / 3000.0) * value * value - (23.0 / 20.0) * value + 25.0
    }
}

private enum SpeedPreset: String, CaseIterable, Identifiable {
    case fastest, fast, medium, slow, slowest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fastest: "Fastest (Largest)"
        case .fast: "Fast (Larger)"
        case .medium: "Medium (Good Size)"
        case .slow: "Slow (Smaller)"
        case .slowest: "Slowest (Smallest)"
        }
    }
    var effort: Int {
        switch self {
        case .fastest: 1
        case .fast: 3
        case .medium: 6
        case .slow: 8
        case .slowest: 10
        }
    }
}

private enum ItemStatus {
    case queued, working, done, failed, skipped
    var label: String {
        switch self {
        case .queued: "Queued"
        case .working: "Converting"
        case .done: "Replaced"
        case .failed: "Kept original"
        case .skipped: "Skipped"
        }
    }
}

private enum JXLConverter {
    static func convert(_ source: URL, settings: ConversionSettings) throws -> String {
        let source = source.standardizedFileURL
        guard source.isFileURL else { throw ConversionError("This drop is not a local file.") }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
        guard values.isRegularFile == true else { throw ConversionError("This item is not a regular image file.") }
        guard values.isPackage != true else { throw ConversionError("Application and document packages are not scanned as image folders.") }
        guard source.pathExtension.lowercased() != "jxl" else { throw ConversionError("This file is already JPEG XL.") }

        let output = source.deletingPathExtension().appendingPathExtension("jxl")
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError("A file named \(output.lastPathComponent) already exists. Nothing was changed.")
        }
        let sourceVersion = try SourceVersion.capture(source)
        let sourceAlpha = try readAlphaPlane(source)

        let cjxl = try findTool("cjxl")
        let djxl = try findTool("djxl")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jxl-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let encoderInput: URL
        let fileExtension = source.pathExtension.lowercased()
        if ImageFormats.direct.contains(fileExtension) {
            encoderInput = source
        } else {
            guard ImageFormats.singleFrameStaging.contains(fileExtension) else {
                throw ConversionError("This format cannot be safely flattened for replacement. Convert it to a single-frame raster image first; the original was kept.")
            }
            let staged = work.appendingPathComponent("staged-input.png")
            let sips = URL(fileURLWithPath: "/usr/bin/sips")
            let result = try run(sips, ["-s", "format", "png", source.path, "--out", staged.path])
            guard result.status == 0, FileManager.default.fileExists(atPath: staged.path) else {
                throw ConversionError("macOS could not read this image format. \(result.message)")
            }
            let stagedAlpha = try readAlphaPlane(staged)
            if let sourceAlpha {
                guard stagedAlpha == sourceAlpha else {
                    throw ConversionError("The staged image did not preserve the source transparency. The original was kept.")
                }
            } else if let stagedAlpha, stagedAlpha.samples.contains(where: { $0 < 255 }) {
                throw ConversionError("The staged image introduced transparency. The original was kept.")
            }
            encoderInput = staged
        }

        let encoded = source.deletingLastPathComponent().appendingPathComponent(".jxl-drop-\(UUID().uuidString).jxl")
        defer { try? FileManager.default.removeItem(at: encoded) }
        var arguments = ["--quiet", "-e", String(settings.effort)]
        if settings.lossy {
            arguments += ["-j", "0", "-q", String(settings.libjxlQuality)]
        } else {
            arguments += ["-j", "0", "-d", "0"]
        }
        if sourceAlpha != nil {
            arguments += ["--ec_resampling=1", "--resampling=1", "--keep_invisible=1"]
            if settings.lossy {
                arguments += ["-a", String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), settings.libjxlAlphaDistance)]
            }
        }
        if !settings.includeExif { arguments += ["-x", "strip=exif"] }
        if !settings.includeXmp { arguments += ["-x", "strip=xmp"] }
        if !settings.includePhotoshopExtras { arguments += ["-x", "strip=jumbf"] }
        arguments += [encoderInput.path, encoded.path]
        let encode = try run(cjxl, arguments)
        guard encode.status == 0, try isJXL(encoded) else {
            throw ConversionError("JPEG XL encoding failed. \(encode.message)")
        }

        let decoded = work.appendingPathComponent("validation.png")
        let validation = try run(djxl, [encoded.path, decoded.path])
        guard validation.status == 0, FileManager.default.fileExists(atPath: decoded.path) else {
            throw ConversionError("The new JXL did not pass a decode check. The original was kept. \(validation.message)")
        }
        let decodedAlpha = try readAlphaPlane(decoded)
        if let sourceAlpha {
            guard let decodedAlpha,
                  decodedAlpha.width == sourceAlpha.width,
                  decodedAlpha.height == sourceAlpha.height else {
                throw ConversionError("The encoded image lost the source transparency channel or changed its dimensions. The original was kept.")
            }
            if settings.libjxlAlphaDistance == 0 {
                guard decodedAlpha == sourceAlpha else {
                    throw ConversionError("The lossless alpha setting did not preserve the source transparency. The original was kept.")
                }
            } else if sourceAlpha.samples.contains(where: { $0 < 255 }) && !decodedAlpha.samples.contains(where: { $0 < 255 }) {
                throw ConversionError("The encoded image flattened the source transparency. The original was kept.")
            }
        } else if let decodedAlpha, decodedAlpha.samples.contains(where: { $0 != 255 }) {
            throw ConversionError("The encoded image introduced transparency that was not present in the source. The original was kept.")
        }

        guard try SourceVersion.capture(source) == sourceVersion else {
            throw ConversionError("The source changed while it was being converted. The original was kept; try again.")
        }

        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError("The output name appeared during conversion. The original was kept.")
        }
        try FileManager.default.moveItem(at: encoded, to: output)

        guard try SourceVersion.capture(source) == sourceVersion else {
            throw ConversionError("The source changed during replacement. The JXL was saved as \(output.lastPathComponent), and the source was kept.")
        }

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &trashedURL)
        } catch {
            throw ConversionError("JXL saved as \(output.lastPathComponent), but the original was kept because macOS could not move it to Trash: \(error.localizedDescription)")
        }
        return "Saved \(output.lastPathComponent); original moved to Trash."
    }

    private static func readAlphaPlane(_ source: URL) throws -> AlphaPlane? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionError("macOS cannot inspect this image safely. The original was kept.")
        }
        guard CGImageSourceGetCount(imageSource) == 1 else {
            throw ConversionError("Multi-frame or multi-page images are not flattened for replacement. The original was kept.")
        }
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError("macOS could not inspect this image's transparency. The original was kept.")
        }
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            break
        case .alphaOnly:
            throw ConversionError("Alpha-only images cannot be safely inspected for replacement. The original was kept.")
        default:
            return nil
        }
        let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow, pixelCount > 0, pixelCount <= Int.max / 4 else {
            throw ConversionError("This image is too large to verify its transparency safely. The original was kept.")
        }
        let rowBytes = image.width * 4
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let context = rgba.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue)
        }
        guard let context else {
            throw ConversionError("macOS could not inspect this image's transparency. The original was kept.")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let samples = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        return AlphaPlane(width: image.width, height: image.height, samples: samples)
    }

    private static func findTool(_ name: String) throws -> URL {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw ConversionError("JPEG XL tools are missing. Install them in Terminal with: brew install jpeg-xl")
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, message: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, message)
    }

    private static func isJXL(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = [UInt8](try handle.read(upToCount: 12) ?? Data())
        guard bytes.count >= 2 else { return false }
        // JPEG XL codestream signature FF 0A; container signature 00 00 00 0C JXL 0D 0A 87 0A.
        return (bytes[0] == 0xFF && bytes[1] == 0x0A) ||
            (bytes.count >= 12 && Array(bytes[4...11]) == [0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A])
    }
}

private struct AlphaPlane: Equatable {
    let width: Int
    let height: Int
    let samples: [UInt8]
}

private enum ImageFormats {
    static let direct: Set<String> = [
        "jpg", "jpeg", "png", "gif", "apng", "exr", "ppm", "pnm", "pgm", "pam", "pfm", "pgx"
    ]
    static let singleFrameStaging: Set<String> = ["heic", "heif", "tif", "tiff", "bmp", "webp", "jp2", "j2k"]
    static let supported = direct.union(singleFrameStaging)
}

private struct SourceVersion: Equatable {
    let device: UInt64
    let fileNumber: UInt64
    let size: UInt64
    let modificationTime: TimeInterval

    static func capture(_ url: URL) throws -> SourceVersion {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            throw ConversionError("Could not record the source file identity and version. The original was kept.")
        }
        return SourceVersion(device: device, fileNumber: fileNumber, size: size, modificationTime: modificationTime)
    }
}

private enum InputDiscovery {
    static func imageFiles(in roots: [URL]) -> DiscoveryResult {
        var result = DiscoveryResult()
        var seen = Set<String>()
        let fileManager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        func addIfImage(_ url: URL) {
            let normalized = url.standardizedFileURL
            let ext = normalized.pathExtension.lowercased()
            guard ext != "jxl", ImageFormats.supported.contains(ext),
                  let values = try? normalized.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  seen.insert(normalized.path).inserted else { return }
            result.files.append(normalized)
        }

        for root in roots {
            guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey]) else {
                result.issues.append(DiscoveryIssue(name: root.lastPathComponent, message: "Cannot read this item or its permissions."))
                continue
            }
            if values.isPackage == true {
                result.issues.append(DiscoveryIssue(name: root.lastPathComponent, message: "Packages are skipped; drop a folder containing image files instead."))
                continue
            }
            if values.isDirectory == true {
                guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey], options: options, errorHandler: { failedURL, error in
                    result.issues.append(DiscoveryIssue(name: failedURL.lastPathComponent, message: "Could not scan this folder: \(error.localizedDescription)"))
                    return true
                }) else {
                    result.issues.append(DiscoveryIssue(name: root.lastPathComponent, message: "Could not scan this folder."))
                    continue
                }
                for case let url as URL in enumerator { addIfImage(url) }
            } else if values.isRegularFile == true {
                let before = result.files.count
                addIfImage(root)
                if result.files.count == before && root.pathExtension.lowercased() != "jxl" {
                    result.issues.append(DiscoveryIssue(name: root.lastPathComponent, message: "Unsupported image format or not a readable image."))
                }
            } else {
                result.issues.append(DiscoveryIssue(name: root.lastPathComponent, message: "Only image files and folders can be added."))
            }
        }
        return result
    }
}

private struct DiscoveryResult {
    var files: [URL] = []
    var issues: [DiscoveryIssue] = []
}

private struct DiscoveryIssue: Sendable {
    let name: String
    let message: String
}

private struct ConversionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
