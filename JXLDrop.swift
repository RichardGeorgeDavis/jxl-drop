import AppKit
import CoreGraphics
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct JXLDropApp: App {
    init() {
        let defaults = UserDefaults.standard
        let versionKey = "jxl.settingsMigrationVersion"
        if defaults.integer(forKey: versionKey) < 2 {
            if defaults.object(forKey: "jxl.quality") == nil { defaults.set(90, forKey: "jxl.quality") }
            if defaults.object(forKey: "jxl.transparencyLossy") == nil { defaults.set(true, forKey: "jxl.transparencyLossy") }
            if defaults.object(forKey: "jxl.transparencyQuality") == nil { defaults.set(90, forKey: "jxl.transparencyQuality") }
            defaults.set(2, forKey: versionKey)
        }
        if defaults.integer(forKey: versionKey) < 3 {
            if defaults.object(forKey: "jxl.transparencyLossy") == nil { defaults.set(true, forKey: "jxl.transparencyLossy") }
            if defaults.object(forKey: "jxl.transparencyQuality") == nil { defaults.set(90, forKey: "jxl.transparencyQuality") }
            if defaults.object(forKey: "jxl.settingsPanelVisible") == nil { defaults.set(true, forKey: "jxl.settingsPanelVisible") }
            defaults.set(3, forKey: versionKey)
        }
    }

    var body: some Scene {
        Window("JXL Drop", id: "main") {
            ContentView()
                .frame(minWidth: 520, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
struct ContentView: View {
    @State private var items: [ConversionItem] = []
    @State private var pending: [ConversionItem] = []
    @State private var queuedPaths = Set<String>()
    @State private var activeBatchID: UUID?
    @State private var summaryBatchID: UUID?
    @State private var isTargeted = false
    @State private var isProcessing = false
    @State private var scansInProgress = 0
    @AppStorage("jxl.settingsPanelVisible") private var settingsPanelVisible = true
    @AppStorage("jxl.lossy") private var lossy = true
    @AppStorage("jxl.quality") private var quality = 90
    @AppStorage("jxl.transparencyLossy") private var transparencyLossy = true
    @AppStorage("jxl.transparencyQuality") private var transparencyQuality = 90
    @AppStorage("jxl.speed") private var speed = SpeedPreset.medium.rawValue
    @AppStorage("jxl.includeExif") private var includeExif = false
    @AppStorage("jxl.includeXmp") private var includeXmp = false
    @AppStorage("jxl.includePhotoshopExtras") private var includePhotoshopExtras = false

    private var isBusy: Bool { isProcessing || scansInProgress > 0 }
    private var colourIsEffectivelyLossless: Bool { !lossy || quality >= 100 }
    private var transparencyIsEffectivelyLossless: Bool {
        colourIsEffectivelyLossless || !transparencyLossy || transparencyQuality >= 100
    }
    private var batchItems: [ConversionItem] { items.filter { $0.batchID == summaryBatchID } }
    private var conversionItems: [ConversionItem] { batchItems.filter { $0.status != .skipped } }
    private var finishedItems: [ConversionItem] { conversionItems.filter { $0.status == .done || $0.status == .failed } }
    private var successfulItems: [ConversionItem] { conversionItems.filter { $0.status == .done && $0.inputBytes != nil && $0.outputBytes != nil } }

    var body: some View {
        HStack(spacing: 0) {
            mainPanel
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            if settingsPanelVisible {
                Divider()
                settingsPanel
                    .frame(width: 320)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: settingsPanelVisible ? 850 : 520, minHeight: 560)
    }

    private var mainPanel: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button { settingsPanelVisible.toggle() } label: {
                    Label(settingsPanelVisible ? "Hide Settings" : "Show Settings", systemImage: "gearshape")
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
                    Text("Multiple files and folders work; folders are scanned recursively")
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

            if !items.isEmpty || isBusy {
                batchSummary
            }

            HStack {
                Text("Local processing. Existing .jxl files are ignored.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if !items.isEmpty {
                    Button("Clear List", systemImage: "xmark.circle") {
                        items.removeAll()
                        summaryBatchID = nil
                    }
                        .buttonStyle(.borderless)
                        .disabled(isBusy)
                        .help("Clear result rows. This does not change any files.")
                }
            }
        }
        .padding(22)
    }

    private var batchSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if scansInProgress > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(isProcessing
                         ? "Scanning folders · \(conversionItems.count) images found so far"
                         : "Scanning folders…")
                        .font(.caption.weight(.medium))
                }
            } else if isProcessing {
                let total = conversionItems.count
                let finished = finishedItems.count
                HStack {
                    Text("Converting image \(min(finished + 1, total)) of \(total) · \(finished) complete")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(Int((Double(finished) / Double(max(total, 1)) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(finished), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
            } else if !conversionItems.isEmpty {
                let replaced = successfulItems.count
                let failed = conversionItems.filter { $0.status == .failed }.count
                Label("Complete · \(replaced) replaced · \(failed) kept", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Label("No images were converted", systemImage: "info.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if !successfulItems.isEmpty {
                let input = successfulItems.compactMap(\.inputBytes).reduce(UInt64(0), +)
                let output = successfulItems.compactMap(\.outputBytes).reduce(UInt64(0), +)
                let delta = input >= output ? input - output : output - input
                let percentage = input == 0 ? 0 : Double(delta) / Double(input) * 100
                let percentageText = String(format: "%.1f", percentage)
                let sizeText = output <= input
                    ? "saved \(Self.fileSize(delta)) (\(percentageText)%)"
                    : "JXL is \(Self.fileSize(delta)) larger (\(percentageText)%)"
                Text("Replaced images: \(Self.fileSize(input)) → \(Self.fileSize(output)) · \(sizeText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    private static func fileSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private var compressionSummary: String {
        let colourMode = colourIsEffectivelyLossless ? "Colour Lossless" : "Colour Lossy · \(quality)"
        let alphaMode = transparencyIsEffectivelyLossless
            ? "Transparency Lossless (when present)"
            : "Transparency Lossy · \(transparencyQuality) (when present)"
        let selectedSpeed = SpeedPreset(rawValue: speed) ?? .medium
        return "\(colourMode) · \(alphaMode) · \(selectedSpeed.label)"
    }

    private func qualityLabel(_ value: Int) -> String {
        switch value {
        case 100: "Lossless"
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
                        title: "Colour Compression",
                        lossy: $lossy,
                        quality: $quality,
                        qualityDescription: lossy
                            ? "Passed directly to cjxl as --quality \(quality). Quality 100 is lossless."
                            : "The colour channel is encoded losslessly."
                    )

                    compressionSection(
                        title: "Transparency Compression",
                        lossy: $transparencyLossy,
                        quality: $transparencyQuality,
                        qualityDescription: transparencyDescription,
                        isEnabled: lossy && quality < 100
                    )
                    if colourIsEffectivelyLossless {
                        Text("Effective transparency: Lossless. Saved transparency preference (\(transparencyPreferenceSummary)) is retained and resumes when colour is lossy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if transparencyIsEffectivelyLossless {
                        Text("Effective transparency: Lossless at quality 100 or in Lossless mode.")
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

                    Text("Current encoder behaviour: \(compressionSummary). Quality 100 is lossless for colour or transparency. The exact Adobe slider mapping is unpublished; transparency settings apply only to images with alpha.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        }
        .padding(18)
    }

    private var transparencyDescription: String {
        let distance = ConversionSettings.alphaDistance(forQuality: transparencyQuality)
        return "Saved quality \(transparencyQuality) maps to alpha distance \(String(format: "%.2f", distance)); 100 / distance 0 is lossless."
    }

    private var transparencyPreferenceSummary: String {
        transparencyLossy ? "Lossy · \(transparencyQuality)" : "Lossless"
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
        if activeBatchID == nil {
            activeBatchID = UUID()
            summaryBatchID = activeBatchID
        }
        guard let batchID = activeBatchID else { return }
        scansInProgress += 1
        Task {
            let discovery = await Task.detached(priority: .userInitiated) {
                InputDiscovery.imageFiles(in: urls)
            }.value
            scansInProgress = max(0, scansInProgress - 1)
            for issue in (providerIssues + discovery.issues).prefix(25) {
                items.insert(ConversionItem(url: URL(fileURLWithPath: issue.name), settings: settings, batchID: batchID, status: .skipped, detail: issue.message), at: 0)
            }
            guard !discovery.files.isEmpty else {
                if providerIssues.isEmpty && discovery.issues.isEmpty {
                    let name = urls.first?.lastPathComponent ?? "Selection"
                    items.insert(ConversionItem(url: URL(fileURLWithPath: name), settings: settings, batchID: batchID, status: .skipped, detail: "No supported images found. Existing JXL files and non-image files are skipped."), at: 0)
                }
                closeBatchIfIdle()
                return
            }
            enqueueImages(discovery.files, settings: settings, batchID: batchID)
        }
    }

    private func enqueueImages(_ urls: [URL], settings: ConversionSettings, batchID: UUID) {
        let newURLs = urls.filter { queuedPaths.insert($0.standardizedFileURL.path).inserted }
        for duplicate in urls where !newURLs.contains(where: { $0.standardizedFileURL.path == duplicate.standardizedFileURL.path }) {
            items.insert(ConversionItem(url: duplicate, settings: settings, batchID: batchID, status: .skipped, detail: "Already queued in this batch."), at: 0)
        }
        let newItems = newURLs.map { ConversionItem(url: $0, settings: settings, batchID: batchID) }
        items.insert(contentsOf: newItems, at: 0)
        pending.append(contentsOf: newItems)
        guard !pending.isEmpty, !isProcessing else {
            closeBatchIfIdle()
            return
        }
        isProcessing = true
        Task {
            while !pending.isEmpty {
                let item = pending.removeFirst()
                update(item.id, status: .working, detail: "Preparing image…")
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try JXLConverter.convert(item.url, settings: item.settings)
                    }.value
                    update(item.id, status: .done, detail: result.message, outputBytes: result.outputBytes)
                } catch {
                    update(item.id, status: .failed, detail: error.localizedDescription)
                }
                queuedPaths.remove(item.url.standardizedFileURL.path)
            }
            isProcessing = false
            closeBatchIfIdle()
        }
    }

    private func closeBatchIfIdle() {
        if scansInProgress == 0 && !isProcessing && pending.isEmpty {
            activeBatchID = nil
        }
    }

    private func update(_ id: UUID, status: ItemStatus, detail: String?, outputBytes: UInt64? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].detail = detail
        items[index].outputBytes = outputBytes
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
    let batchID: UUID?
    let inputBytes: UInt64?
    var outputBytes: UInt64?
    var status: ItemStatus = .queued
    var detail: String? = "Waiting"
    init(url: URL, settings: ConversionSettings, batchID: UUID? = nil, status: ItemStatus = .queued, detail: String? = "Waiting") {
        self.url = url
        self.settings = settings
        self.batchID = batchID
        self.status = status
        self.detail = detail
        self.inputBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64(max(0, $0)) }
    }
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

private enum ItemStatus: Equatable {
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
    static func convert(_ source: URL, settings: ConversionSettings) throws -> ConversionResult {
        let source = source.standardizedFileURL
        guard source.isFileURL else { throw ConversionError("This drop is not a local file.") }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
        guard values.isRegularFile == true else { throw ConversionError("This item is not a regular image file.") }
        guard values.isPackage != true else { throw ConversionError("Application and document packages are not scanned as image folders.") }
        guard source.pathExtension.lowercased() != "jxl" else { throw ConversionError("This file is already JPEG XL.") }

        let sourceVersion = try SourceVersion.capture(source)
        let sourceAlpha = try readAlphaPlane(source)
        let hasTransparentPixels = sourceAlpha?.samples.contains(where: { $0 < UInt16.max }) == true
        let pairedJPEGExists = hasTransparentPixels && Self.hasJPEGPair(for: source)

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
            } else if let stagedAlpha, stagedAlpha.samples.contains(where: { $0 < UInt16.max }) {
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
            } else {
                let sourceHasTransparentPixels = sourceAlpha.samples.contains(where: { $0 < UInt16.max })
                let sourceHasVisiblePixels = sourceAlpha.samples.contains(where: { $0 > 0 })
                let decodedHasTransparentPixels = decodedAlpha.samples.contains(where: { $0 < UInt16.max })
                let decodedHasVisiblePixels = decodedAlpha.samples.contains(where: { $0 > 0 })
                if sourceHasTransparentPixels && !decodedHasTransparentPixels {
                    throw ConversionError("The encoded image flattened the source transparency. The original was kept.")
                }
                if !sourceHasTransparentPixels && decodedHasTransparentPixels {
                    throw ConversionError("The encoded image introduced transparency. The original was kept.")
                }
                if sourceHasVisiblePixels && !decodedHasVisiblePixels {
                    throw ConversionError("The encoded image removed all visible content. The original was kept.")
                }
                if !sourceHasVisiblePixels && decodedHasVisiblePixels {
                    throw ConversionError("The encoded image introduced visible content into a fully transparent source. The original was kept.")
                }
            }
        } else if let decodedAlpha, decodedAlpha.samples.contains(where: { $0 != UInt16.max }) {
            throw ConversionError("The encoded image introduced transparency that was not present in the source. The original was kept.")
        }

        guard try SourceVersion.capture(source) == sourceVersion else {
            throw ConversionError("The source changed while it was being converted. The original was kept; try again.")
        }

        let output = try Self.publishWithoutOverwrite(encoded, beside: source, preferTransparentName: pairedJPEGExists || (hasTransparentPixels && FileManager.default.fileExists(atPath: source.deletingPathExtension().appendingPathExtension("jxl").path)))
        let outputAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
        guard let outputSize = (outputAttributes[.size] as? NSNumber)?.uint64Value else {
            throw ConversionError("The JXL was saved as \(output.lastPathComponent), but its size could not be verified. The original was kept.")
        }

        guard try SourceVersion.capture(source) == sourceVersion else {
            throw ConversionError("The source changed during replacement. The JXL was saved as \(output.lastPathComponent), and the source was kept.")
        }

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &trashedURL)
        } catch {
            throw ConversionError("JXL saved as \(output.lastPathComponent), but the original was kept because macOS could not move it to Trash: \(error.localizedDescription)")
        }
        return ConversionResult(message: "Saved as \(output.lastPathComponent); original moved to Trash.", outputBytes: outputSize)
    }

    private static func hasJPEGPair(for source: URL) -> Bool {
        guard source.pathExtension.lowercased() == "png",
              let entries = try? FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path) else { return false }
        let stem = source.deletingPathExtension().lastPathComponent
        return entries.contains { name in
            let candidate = URL(fileURLWithPath: name)
            return ["jpg", "jpeg"].contains(candidate.pathExtension.lowercased()) &&
                candidate.deletingPathExtension().lastPathComponent == stem
        }
    }

    private static func publishWithoutOverwrite(_ encoded: URL, beside source: URL, preferTransparentName: Bool) throws -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let primary = preferTransparentName ? "\(stem)-transparent" : stem
        var suffix = 1
        while true {
            let name = suffix == 1 ? primary : "\(primary)-\(suffix)"
            let candidate = directory.appendingPathComponent(name).appendingPathExtension("jxl")
            let result = link(encoded.path, candidate.path)
            if result == 0 {
                _ = unlink(encoded.path)
                return candidate
            }
            if errno == EEXIST {
                suffix += 1
                continue
            }

            // Some synced volumes do not support hard links. O_EXCL still claims
            // the destination atomically before copying, so an existing file can
            // never be replaced.
            let destinationFD = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            if destinationFD < 0 {
                if errno == EEXIST {
                    suffix += 1
                    continue
                }
                throw ConversionError("Could not create a unique JXL output beside the original: \(String(cString: strerror(errno)))")
            }
            do {
                try copyFileContents(from: encoded, to: destinationFD)
                guard try isJXL(candidate) else {
                    throw ConversionError("The copied JXL output did not pass its file check. The original was kept.")
                }
                return candidate
            } catch {
                _ = close(destinationFD)
                _ = unlink(candidate.path)
                throw error
            }
        }
    }

    private static func copyFileContents(from source: URL, to destinationFD: Int32) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(destinationFD, base.advanced(by: offset), bytes.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw ConversionError("Could not write the JXL output: \(String(cString: strerror(errno)))")
                    }
                    offset += written
                }
            }
        }
        guard fsync(destinationFD) == 0 else {
            throw ConversionError("Could not finish writing the JXL output: \(String(cString: strerror(errno)))")
        }
        guard close(destinationFD) == 0 else {
            throw ConversionError("Could not close the JXL output: \(String(cString: strerror(errno)))")
        }
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
        guard (1...16).contains(image.bitsPerComponent),
              !image.bitmapInfo.contains(.floatComponents) else {
            throw ConversionError("This image's alpha precision cannot be verified without conversion. The original was kept.")
        }
        let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow, pixelCount > 0, pixelCount <= Int.max / 8 else {
            throw ConversionError("This image is too large to verify its transparency safely. The original was kept.")
        }
        let rowBytes = image.width * 8
        var rgba = [UInt16](repeating: 0, count: pixelCount * 4)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        let drewImage = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue) else {
                return false
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drewImage else {
            throw ConversionError("macOS could not inspect this image's transparency. The original was kept.")
        }
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
    let samples: [UInt16]
}

private struct ConversionResult: Sendable {
    let message: String
    let outputBytes: UInt64
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
                let wasDiscoveredThroughFolder = seen.contains(root.standardizedFileURL.path)
                addIfImage(root)
                if result.files.count == before && !wasDiscoveredThroughFolder && root.pathExtension.lowercased() != "jxl" {
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
