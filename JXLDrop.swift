import AppKit
import Combine
import CoreGraphics
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct JXLDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var dropInbox = DropInbox()

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
            ContentView(dropInbox: dropInbox)
                .frame(minWidth: 520, minHeight: 560)
                .onAppear { appDelegate.attach(dropInbox) }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class DropInbox: ObservableObject {
    @Published private(set) var requests: [DropRequest] = []

    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        requests.append(DropRequest(urls: urls))
    }

    func removeAll() { requests.removeAll() }
}

private struct DropRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var inbox: DropInbox?
    private var pendingURLs: [URL] = []

    func attach(_ inbox: DropInbox) {
        self.inbox = inbox
        inbox.enqueue(pendingURLs)
        pendingURLs.removeAll()
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let inbox {
            inbox.enqueue(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
        application.reply(toOpenOrPrint: .success)
    }
}

@MainActor
struct ContentView: View {
    @ObservedObject fileprivate var dropInbox: DropInbox
    @State private var items: [ConversionItem] = []
    @State private var pending: [ConversionItem] = []
    @State private var knownPaths = Set<String>()
    @State private var itemIndexByID: [UUID: Int] = [:]
    @State private var itemIndexByPath: [String: Int] = [:]
    @State private var orderedItemIDs: [UUID] = []
    @State private var resultPage = 0
    @State private var sortGeneration = 0
    @State private var activeBatchID: UUID?
    @State private var summaryBatchID: UUID?
    @State private var isTargeted = false
    @State private var activeConversionCount = 0
    @State private var nextPendingIndex = 0
    @State private var batchConcurrencyLimit = 1
    @State private var scansInProgress = 0
    @State private var summaryTotal = 0
    @State private var summaryFinished = 0
    @State private var summaryReplaced = 0
    @State private var processedItemCount = 0
    @State private var summaryInputBytes: UInt64 = 0
    @State private var summaryOutputBytes: UInt64 = 0
    @AppStorage("jxl.dashboardSort") private var dashboardSort = DashboardSort.name.rawValue
    @AppStorage("jxl.maxConcurrentConversions") private var maxConcurrentConversions = 1
    @AppStorage("jxl.settingsPanelVisible") private var settingsPanelVisible = true
    @AppStorage("jxl.lossy") private var lossy = true
    @AppStorage("jxl.quality") private var quality = 90
    @AppStorage("jxl.transparencyLossy") private var transparencyLossy = true
    @AppStorage("jxl.transparencyQuality") private var transparencyQuality = 90
    @AppStorage("jxl.speed") private var speed = SpeedPreset.medium.rawValue
    @AppStorage("jxl.fullImageBuffering") private var fullImageBuffering = false
    @AppStorage("jxl.keepOriginalIfJXLNotSmaller") private var keepOriginalIfJXLNotSmaller = true
    @AppStorage("jxl.includeExif") private var includeExif = false
    @AppStorage("jxl.includeXmp") private var includeXmp = false
    @AppStorage("jxl.includePhotoshopExtras") private var includePhotoshopExtras = false

    private let resultsPerPage = 100
    private var isProcessing: Bool { activeConversionCount > 0 || nextPendingIndex < pending.count }
    private var isBusy: Bool { isProcessing || scansInProgress > 0 }
    private var resultPageCount: Int { max(1, (orderedItemIDs.count + resultsPerPage - 1) / resultsPerPage) }
    private var currentResultPage: Int { min(max(0, resultPage), resultPageCount - 1) }
    private var currentResultRange: Range<Int> {
        let start = min(currentResultPage * resultsPerPage, orderedItemIDs.count)
        return start..<min(start + resultsPerPage, orderedItemIDs.count)
    }
    private var colourIsEffectivelyLossless: Bool { !lossy || quality >= 100 }
    private var transparencyIsEffectivelyLossless: Bool {
        colourIsEffectivelyLossless || !transparencyLossy || transparencyQuality >= 100
    }
    private var visibleItemIDs: [UUID] {
        Array(orderedItemIDs[currentResultRange])
    }

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
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted, perform: acceptDrop)
        .onChange(of: dashboardSort) { _ in
            resultPage = 0
            sortVisibleItems()
        }
        .onChange(of: dropInbox.requests.count) { _ in consumeAppIconDrops() }
        .onAppear { consumeAppIconDrops() }
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
                Label(keepOriginalIfJXLNotSmaller
                      ? "For new drops: Trash original only when JXL is smaller and validated"
                      : "For new drops: larger JXLs may replace the original after validation",
                      systemImage: "checkmark.shield")
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)

            if !items.isEmpty {
                HStack {
                    Spacer()
                    Text("Sort:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Sort by", selection: $dashboardSort) {
                        ForEach(DashboardSort.allCases) { sort in
                            Text(sort.label).tag(sort.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .help("Sort results by name, when they were added, file size or savings")
                }
                List(visibleItemIDs, id: \.self) { id in
                    if let index = itemIndexByID[id] {
                        let item = items[index]
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
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(item.status.label)
                                    .font(.caption)
                                    .foregroundStyle(item.tint)
                                if let savings = item.savingsLabel {
                                    Text(savings)
                                        .font(.caption2)
                                        .foregroundStyle(item.savingsBytes.map { $0 >= 0 ? Color.green : Color.orange } ?? .secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 80, maxHeight: 160)

                HStack(spacing: 8) {
                    Text("Showing \(orderedItemIDs.isEmpty ? 0 : currentResultRange.lowerBound + 1)–\(currentResultRange.upperBound) of \(orderedItemIDs.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        resultPage = max(0, currentResultPage - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(currentResultPage == 0)
                    .help("Previous 100 results")
                    Text("\(currentResultPage + 1) / \(resultPageCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        resultPage = min(currentResultPage + 1, resultPageCount - 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(currentResultPage + 1 >= resultPageCount)
                    .help("Next 100 results")
                }
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
                        knownPaths.removeAll()
                        itemIndexByID.removeAll()
                        itemIndexByPath.removeAll()
                        orderedItemIDs.removeAll()
                        resultPage = 0
                        sortGeneration += 1
                        processedItemCount = 0
                        summaryBatchID = nil
                        resetSummary()
                    }
                        .buttonStyle(.borderless)
                        .disabled(isBusy)
                        .help("Clear result rows. This does not change any files.")
                }
                if processedItemCount > 0 {
                    Button("Clear Processed", systemImage: "checkmark.circle") {
                        clearProcessedItems()
                    }
                    .buttonStyle(.borderless)
                    .help("Remove completed, kept and skipped rows while preserving work in progress.")
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
                    Text(isProcessing ? "Scanning folders while conversion continues…" : "Scanning folders…")
                        .font(.caption.weight(.medium))
                }
            } else if isProcessing {
                HStack {
                    Text("Converting images · \(summaryFinished) of \(summaryTotal) complete")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(Int(Double(summaryFinished) / Double(max(summaryTotal, 1)) * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(summaryFinished), total: Double(max(summaryTotal, 1)))
                    .progressViewStyle(.linear)
            } else if summaryTotal > 0 {
                let kept = summaryTotal - summaryReplaced
                Label("Complete · \(summaryReplaced) replaced · \(kept) kept", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Label("No images were converted", systemImage: "info.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if summaryReplaced > 0 {
                let input = summaryInputBytes
                let output = summaryOutputBytes
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

    private func sortVisibleItems() {
        let sort = DashboardSort(rawValue: dashboardSort) ?? .name
        sortGeneration += 1
        let generation = sortGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard generation == sortGeneration else { return }
            let keys = items.map { ItemSortKey(id: $0.id, name: $0.name, addedAt: $0.addedAt, size: $0.inputBytes, saving: $0.savingsBytes) }
            let sortedIDs = await Task.detached(priority: .utility) {
                keys.sorted { lhs, rhs in lhs.precedes(rhs, by: sort) }.map(\.id)
            }.value
            guard generation == sortGeneration else { return }
            orderedItemIDs = sortedIDs
            clampResultPage()
        }
    }

    fileprivate static func fileSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private var compressionSummary: String {
        let colourMode = colourIsEffectivelyLossless ? "Colour Lossless" : "Colour Lossy · \(quality)"
        let alphaMode = transparencyIsEffectivelyLossless
            ? "Transparency Lossless (when present)"
            : "Transparency Lossy · \(transparencyQuality) (when present)"
        let selectedSpeed = SpeedPreset(rawValue: speed) ?? .medium
        let buffering = fullImageBuffering ? "Full image buffer" : "Automatic buffer"
        return "\(colourMode) · \(alphaMode) · \(selectedSpeed.label) · \(buffering)"
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

                    Picker("Images at a time", selection: $maxConcurrentConversions) {
                        Text("One (recommended)").tag(1)
                        Text("Two").tag(2)
                    }
                    Text("Two conversions can finish sooner on some Macs, but use more memory. Each encoder and validator is limited to a share of the available processor threads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Use full image buffering", isOn: $fullImageBuffering)
                    Text("Passes --buffering=0 to cjxl. Uses more memory and may improve compression.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Keep original if JXL is not smaller", isOn: $keepOriginalIfJXLNotSmaller)
                    Text("When enabled, the original is kept and no JXL is saved if the validated JXL is the same size or larger. Enabled by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Settings are captured when each drop is submitted; changing this toggle affects new drops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
        scansInProgress += 1
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
            Task { @MainActor in
                self.scansInProgress = max(0, self.scansInProgress - 1)
                self.enqueue(urls, settings: settingsSnapshot, providerIssues: issues)
            }
        }
        return true
    }

    private func consumeAppIconDrops() {
        let requests = dropInbox.requests
        guard !requests.isEmpty else { return }
        dropInbox.removeAll()
        for request in requests { enqueue(request.urls, settings: currentSettings) }
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
        let proposedBatchID = UUID()
        scansInProgress += 1
        Task {
            let stream = InputDiscovery.imageFileBatches(in: urls)
            var discoveredAny = false
            var sawIssue = false
            var issueCount = 0
            for await event in stream {
                switch event.payload {
                case .files(let discoveredFiles):
                    discoveredAny = discoveredAny || !discoveredFiles.isEmpty
                    enqueueImages(discoveredFiles, settings: settings, proposedBatchID: proposedBatchID)
                case .issues(let issues):
                    sawIssue = sawIssue || !issues.isEmpty
                    issueCount += appendIssues(issues, remaining: 25 - issueCount, settings: settings, proposedBatchID: proposedBatchID)
                }
                event.acknowledge()
            }
            scansInProgress = max(0, scansInProgress - 1)
            if !providerIssues.isEmpty {
                sawIssue = true
                issueCount += appendIssues(providerIssues, remaining: 25 - issueCount, settings: settings, proposedBatchID: proposedBatchID)
            }
            if !discoveredAny {
                if !sawIssue {
                    let name = urls.first?.lastPathComponent ?? "Selection"
                    _ = appendIssues([DiscoveryIssue(name: name, message: "No supported images found. Existing JXL files and non-image files are skipped.", url: urls.first)], remaining: 1, settings: settings, proposedBatchID: proposedBatchID)
                }
            }
            if scansInProgress == 0 { sortVisibleItems() }
            closeBatchIfIdle()
        }
    }

    private func ensureBatch(_ proposedBatchID: UUID, settings: ConversionSettings) -> UUID {
        if let activeBatchID { return activeBatchID }
        activeBatchID = proposedBatchID
        summaryBatchID = proposedBatchID
        batchConcurrencyLimit = settings.maxConcurrentConversions
        resetSummary()
        return proposedBatchID
    }

    private func appendIssues(_ issues: [DiscoveryIssue], remaining: Int, settings: ConversionSettings, proposedBatchID: UUID) -> Int {
        let limited = Array(issues.prefix(max(0, remaining))).filter { issue in
            guard let path = issue.url?.standardizedFileURL.path else { return true }
            return !knownPaths.contains(path)
        }
        guard !limited.isEmpty else { return 0 }
        let batchID = ensureBatch(proposedBatchID, settings: settings)
        for issue in limited {
            let url = issue.url ?? URL(fileURLWithPath: issue.name)
            let item = ConversionItem(url: url, settings: settings, batchID: batchID, trackedPath: issue.url?.standardizedFileURL.path, status: .skipped, detail: issue.message)
            appendVisibleItem(item)
        }
        return limited.count
    }

    private func enqueueImages(_ files: [DiscoveredImage], settings: ConversionSettings, proposedBatchID: UUID) {
        var candidates: [(DiscoveredImage, Int?)] = []
        for file in files {
            let path = file.url.standardizedFileURL.path
            guard knownPaths.insert(path).inserted else {
                guard let index = itemIndexByPath[path] else { continue }
                let existing = items[index]
                guard !existing.isInFlight, existing.queuedSourceVersion != file.sourceVersion else { continue }
                candidates.append((file, index))
                continue
            }
            candidates.append((file, nil))
        }
        guard !candidates.isEmpty else { return }
        let batchID = ensureBatch(proposedBatchID, settings: settings)
        var addedItems: [ConversionItem] = []
        for (file, existingIndex) in candidates {
            let item = ConversionItem(url: file.url, settings: settings, batchID: batchID, queuedSourceVersion: file.sourceVersion, inputBytes: file.size)
            if let existingIndex {
                sortGeneration += 1
                if items[existingIndex].isProcessed { processedItemCount = max(0, processedItemCount - 1) }
                let oldID = items[existingIndex].id
                itemIndexByID[oldID] = nil
                if let orderIndex = orderedItemIDs.firstIndex(of: oldID) { orderedItemIDs[orderIndex] = item.id }
                items[existingIndex] = item
                itemIndexByID[item.id] = existingIndex
                itemIndexByPath[file.url.standardizedFileURL.path] = existingIndex
            } else {
                appendVisibleItem(item)
            }
            addedItems.append(item)
        }
        summaryTotal += addedItems.count
        pending.append(contentsOf: addedItems)
        startConversions()
    }

    private func appendVisibleItem(_ item: ConversionItem) {
        sortGeneration += 1
        let index = items.count
        items.append(item)
        if item.isProcessed { processedItemCount += 1 }
        itemIndexByID[item.id] = index
        if let path = item.trackedPath {
            knownPaths.insert(path)
            itemIndexByPath[path] = index
        }
        orderedItemIDs.append(item.id)
    }

    private func startConversions() {
        let limit = batchConcurrencyLimit
        while activeConversionCount < limit && nextPendingIndex < pending.count {
            let item = pending[nextPendingIndex]
            nextPendingIndex += 1
            activeConversionCount += 1
            update(item.id, status: .working, detail: "Preparing image…")
            Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try JXLConverter.convert(item.url, settings: item.settings, queuedSourceVersion: item.queuedSourceVersion)
                    }.value
                    complete(item.id, result: result)
                } catch {
                    complete(item.id, error: error)
                }
                activeConversionCount = max(0, activeConversionCount - 1)
                if nextPendingIndex == pending.count {
                    pending.removeAll(keepingCapacity: true)
                    nextPendingIndex = 0
                }
                startConversions()
                if dashboardSort == DashboardSort.saving.rawValue,
                   scansInProgress == 0,
                   activeConversionCount == 0,
                   nextPendingIndex >= pending.count {
                    sortVisibleItems()
                }
                closeBatchIfIdle()
            }
        }
    }

    private func closeBatchIfIdle() {
        if scansInProgress == 0 && activeConversionCount == 0 && nextPendingIndex >= pending.count {
            activeBatchID = nil
        }
    }

    private func update(_ id: UUID, status: ItemStatus, detail: String?, inputBytes: UInt64? = nil, outputBytes: UInt64? = nil) {
        guard let index = itemIndexByID[id] else { return }
        let wasProcessed = items[index].isProcessed
        items[index].status = status
        items[index].detail = detail
        if let inputBytes { items[index].inputBytes = inputBytes }
        items[index].outputBytes = outputBytes
        if !wasProcessed && items[index].isProcessed { processedItemCount += 1 }
        if wasProcessed && !items[index].isProcessed { processedItemCount = max(0, processedItemCount - 1) }
        if !wasProcessed && items[index].isProcessed { summaryFinished += 1 }
    }

    private func complete(_ id: UUID, result: ConversionResult) {
        update(id, status: result.status, detail: result.message, inputBytes: result.inputBytes, outputBytes: result.outputBytes)
        if result.status == .done, let outputBytes = result.outputBytes {
            summaryReplaced += 1
            summaryInputBytes += result.inputBytes
            summaryOutputBytes += outputBytes
        }
    }

    private func complete(_ id: UUID, error: Error) {
        update(id, status: .failed, detail: error.localizedDescription)
    }

    private func resetSummary() {
        summaryTotal = 0
        summaryFinished = 0
        summaryReplaced = 0
        summaryInputBytes = 0
        summaryOutputBytes = 0
    }

    private func clearProcessedItems() {
        items.removeAll(where: \.isProcessed)
        processedItemCount = 0
        rebuildItemIndexes()
        clampResultPage()
        sortVisibleItems()
    }

    private func clampResultPage() {
        resultPage = min(max(0, resultPage), resultPageCount - 1)
    }

    private func rebuildItemIndexes() {
        itemIndexByID.removeAll(keepingCapacity: true)
        itemIndexByPath.removeAll(keepingCapacity: true)
        knownPaths.removeAll(keepingCapacity: true)
        orderedItemIDs.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            itemIndexByID[item.id] = index
            if item.isProcessed { processedItemCount += 1 }
            if let path = item.trackedPath {
                knownPaths.insert(path)
                itemIndexByPath[path] = index
            }
            orderedItemIDs.append(item.id)
        }
    }

    private var currentSettings: ConversionSettings {
        let concurrencyLimit = min(2, max(1, maxConcurrentConversions))
        return ConversionSettings(
            lossy: lossy,
            quality: quality,
            transparencyLossy: transparencyLossy && lossy && quality < 100,
            transparencyQuality: transparencyQuality,
            effort: (SpeedPreset(rawValue: speed) ?? .medium).effort,
            maxConcurrentConversions: concurrencyLimit,
            workerThreads: max(1, ProcessInfo.processInfo.activeProcessorCount / concurrencyLimit),
            fullImageBuffering: fullImageBuffering,
            keepOriginalIfJXLNotSmaller: keepOriginalIfJXLNotSmaller,
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
    let queuedSourceVersion: SourceVersion?
    let trackedPath: String?
    let addedAt: Date
    var inputBytes: UInt64?
    var outputBytes: UInt64?
    var status: ItemStatus = .queued
    var detail: String? = "Waiting"
    init(url: URL, settings: ConversionSettings, batchID: UUID? = nil, queuedSourceVersion: SourceVersion? = nil, inputBytes: UInt64? = nil, trackedPath: String? = nil, status: ItemStatus = .queued, detail: String? = "Waiting") {
        self.url = url
        self.settings = settings
        self.batchID = batchID
        self.queuedSourceVersion = queuedSourceVersion
        self.trackedPath = trackedPath ?? (status == .queued ? url.standardizedFileURL.path : nil)
        self.addedAt = Date()
        self.status = status
        self.detail = detail
        self.inputBytes = inputBytes
    }
    var name: String { url.lastPathComponent }
    var isProcessed: Bool { status == .done || status == .failed || status == .kept || status == .skipped }
    var isInFlight: Bool { status == .queued || status == .working }
    var savingsBytes: Int64? {
        guard status == .done, let inputBytes, let outputBytes else { return nil }
        if inputBytes >= outputBytes { return Int64(clamping: inputBytes - outputBytes) }
        return -Int64(clamping: outputBytes - inputBytes)
    }
    var savingsLabel: String? {
        guard let savingsBytes, let inputBytes, inputBytes > 0 else { return nil }
        let amount = UInt64(savingsBytes.magnitude)
        let percentage = Double(amount) / Double(inputBytes) * 100
        let value = String(format: "%.1f", percentage)
        let amountText = ByteCountFormatter.string(fromByteCount: Int64(clamping: amount), countStyle: .file)
        return savingsBytes >= 0 ? "Saved \(amountText) (\(value)%)" : "Larger by \(amountText) (\(value)%)"
    }
    var symbol: String {
        switch status {
        case .queued: "clock"
        case .working: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .kept: "checkmark.circle"
        case .skipped: "minus.circle"
        }
    }
    var tint: Color {
        switch status {
        case .queued: .secondary
        case .working: .accentColor
        case .done: .green
        case .failed: .orange
        case .kept: .orange
        case .skipped: .secondary
        }
    }
}

private enum DashboardSort: String, CaseIterable, Identifiable, Sendable {
    case name, added, size, saving
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: "Name"
        case .added: "Added"
        case .size: "Size"
        case .saving: "Saving"
        }
    }
}

private struct ItemSortKey: Sendable {
    let id: UUID
    let name: String
    let addedAt: Date
    let size: UInt64?
    let saving: Int64?

    func precedes(_ other: ItemSortKey, by sort: DashboardSort) -> Bool {
        switch sort {
        case .name:
            let comparison = name.localizedStandardCompare(other.name)
            return comparison == .orderedSame ? addedAt > other.addedAt : comparison == .orderedAscending
        case .added:
            return addedAt > other.addedAt
        case .size:
            switch (size, other.size) {
            case let (left?, right?): return left == right ? addedAt > other.addedAt : left > right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return addedAt > other.addedAt
            }
        case .saving:
            switch (saving, other.saving) {
            case let (left?, right?): return left == right ? addedAt > other.addedAt : left > right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return addedAt > other.addedAt
            }
        }
    }
}

private struct ConversionSettings: Sendable {
    let lossy: Bool
    let quality: Int
    let transparencyLossy: Bool
    let transparencyQuality: Int
    let effort: Int
    let maxConcurrentConversions: Int
    let workerThreads: Int
    let fullImageBuffering: Bool
    let keepOriginalIfJXLNotSmaller: Bool
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
        case .fastest: "Fastest (Effort 1)"
        case .fast: "Fast (Effort 3)"
        case .medium: "Medium (Good Size)"
        case .slow: "Slow (Effort 8)"
        case .slowest: "Slowest (Effort 10)"
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

private enum ItemStatus: Equatable, Sendable {
    case queued, working, done, failed, kept, skipped
    var label: String {
        switch self {
        case .queued: "Queued"
        case .working: "Converting"
        case .done: "Replaced"
        case .failed: "Kept original"
        case .kept: "Kept original"
        case .skipped: "Skipped"
        }
    }
}

private enum JXLConverter {
    private static let stripAlphaSupportCache = NSCache<NSString, NSNumber>()

    static func convert(_ source: URL, settings: ConversionSettings, queuedSourceVersion: SourceVersion?) throws -> ConversionResult {
        let source = source.standardizedFileURL
        guard source.isFileURL else { throw ConversionError("This drop is not a local file.") }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
        guard values.isRegularFile == true else { throw ConversionError("This item is not a regular image file.") }
        guard values.isPackage != true else { throw ConversionError("Application and document packages are not scanned as image folders.") }
        guard source.pathExtension.lowercased() != "jxl" else { throw ConversionError("This file is already JPEG XL.") }

        guard let queuedSourceVersion else {
            throw ConversionError("Could not record the image when it was queued. The original was kept.")
        }
        let sourceVersion = try SourceVersion.capture(source)
        guard sourceVersion == queuedSourceVersion else {
            throw ConversionError("The source changed after it was queued. The original was kept; add it again to convert the latest version.")
        }
        let sourceDimensions = try readDimensions(source)
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
        var arguments = ["--quiet", "--num_threads=\(settings.workerThreads)", "-e", String(settings.effort)]
        if settings.fullImageBuffering { arguments += ["--buffering=0"] }
        if settings.lossy {
            arguments += ["-j", "0", "-q", String(settings.libjxlQuality)]
        } else {
            arguments += ["-j", "0", "-d", "0"]
        }
        if sourceAlpha != nil {
            arguments += ["--ec_resampling=1", "--resampling=1", "--keep_invisible=1"]
            if Self.supportsStripAlpha(cjxl) { arguments += ["--strip_alpha=0"] }
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
        let validation = try run(djxl, ["--num_threads=\(settings.workerThreads)", encoded.path, decoded.path])
        guard validation.status == 0, FileManager.default.fileExists(atPath: decoded.path) else {
            throw ConversionError("The new JXL did not pass a decode check. The original was kept. \(validation.message)")
        }
        guard try readDimensions(decoded) == sourceDimensions else {
            throw ConversionError("The encoded image changed the source dimensions. The original was kept.")
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

        let encodedAttributes = try FileManager.default.attributesOfItem(atPath: encoded.path)
        guard let encodedSize = (encodedAttributes[.size] as? NSNumber)?.uint64Value else {
            throw ConversionError("Could not verify the new JXL size. The original was kept.")
        }
        if settings.keepOriginalIfJXLNotSmaller && encodedSize >= sourceVersion.size {
            return ConversionResult(
                message: "Kept original; no JXL saved because the validated JXL was the same size or larger.",
                inputBytes: sourceVersion.size,
                outputBytes: nil,
                status: .kept
            )
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
        return ConversionResult(message: "Saved as \(output.lastPathComponent); original moved to Trash.", inputBytes: sourceVersion.size, outputBytes: outputSize, status: .done)
    }

    private static func hasJPEGPair(for source: URL) -> Bool {
        guard source.pathExtension.lowercased() == "png",
              let entries = try? FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path) else { return false }
        let stem = source.deletingPathExtension().lastPathComponent.lowercased()
        return entries.contains { name in
            let candidate = URL(fileURLWithPath: name)
            return ["jpg", "jpeg"].contains(candidate.pathExtension.lowercased()) &&
                candidate.deletingPathExtension().lastPathComponent.lowercased() == stem
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

            // Copy to a hidden staging file, then atomically publish without replacing.
            let staging = directory.appendingPathComponent(".jxl-drop-publish-\(UUID().uuidString).tmp")
            var destinationFD = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o666))
            if destinationFD < 0 {
                if errno == EEXIST {
                    suffix += 1
                    continue
                }
                throw ConversionError("Could not create a unique JXL output beside the original: \(String(cString: strerror(errno)))")
            }
            do {
                try copyFileContents(from: encoded, to: destinationFD)
                guard close(destinationFD) == 0 else {
                    destinationFD = -1
                    throw ConversionError("Could not close the JXL output: \(String(cString: strerror(errno)))")
                }
                destinationFD = -1
                guard try isJXL(staging) else {
                    throw ConversionError("The copied JXL output did not pass its file check. The original was kept.")
                }
                guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, candidate.path, UInt32(RENAME_EXCL)) == 0 else {
                    let publishError = errno
                    _ = unlink(staging.path)
                    if publishError == EEXIST {
                        suffix += 1
                        continue
                    }
                    throw ConversionError("Could not safely publish the JXL on this volume; the original was kept. \(String(cString: strerror(publishError)))")
                }
                return candidate
            } catch {
                if destinationFD >= 0 { _ = close(destinationFD) }
                _ = unlink(staging.path)
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

    private static func readDimensions(_ source: URL) throws -> ImageDimensions {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw ConversionError("macOS could not verify this image's dimensions. The original was kept.")
        }
        return ImageDimensions(width: width, height: height)
    }

    private static func findTool(_ name: String) throws -> URL {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw ConversionError("JPEG XL tools are missing. Install them in Terminal with: brew install jpeg-xl")
    }

    private static func supportsStripAlpha(_ cjxl: URL) -> Bool {
        let key = cjxl.path as NSString
        if let cached = stripAlphaSupportCache.object(forKey: key) { return cached.boolValue }
        let supported = ((try? run(cjxl, ["-v", "--help"]))?.message.contains("--strip_alpha")) ?? false
        stripAlphaSupportCache.setObject(NSNumber(value: supported), forKey: key)
        return supported
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, message: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = .userInitiated
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

private struct ImageDimensions: Equatable {
    let width: Int
    let height: Int
}

private struct ConversionResult: Sendable {
    let message: String
    let inputBytes: UInt64
    let outputBytes: UInt64?
    let status: ItemStatus
}

private enum ImageFormats {
    static let direct: Set<String> = [
        "jpg", "jpeg", "png", "gif", "apng", "exr", "ppm", "pnm", "pgm", "pam", "pfm", "pgx"
    ]
    static let singleFrameStaging: Set<String> = ["heic", "heif", "tif", "tiff", "bmp", "webp", "jp2", "j2k"]
    static let supported = direct.union(singleFrameStaging)
}

private struct SourceVersion: Equatable, Sendable {
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
    static func imageFileBatches(in roots: [URL]) -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            Task.detached(priority: .utility) {
                InputDiscovery.scan(in: roots) { payload in
                    let event = DiscoveryEvent(payload: payload)
                    continuation.yield(event)
                    event.waitForAcknowledgement()
                }
                continuation.finish()
            }
        }
    }

    private static func scan(in roots: [URL], yield: (DiscoveryPayload) -> Void) {
        var seen = Set<String>()
        var files: [DiscoveredImage] = []
        var issues: [DiscoveryIssue] = []
        let fileManager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        func recordIssue(_ issue: DiscoveryIssue) {
            if issues.count < 25 { issues.append(issue) }
        }

        func flushFiles() {
            guard !files.isEmpty else { return }
            yield(.files(files))
            files.removeAll(keepingCapacity: true)
        }

        func addIfImage(_ url: URL) {
            let normalized = url.standardizedFileURL
            let ext = normalized.pathExtension.lowercased()
            guard ext != "jxl", ImageFormats.supported.contains(ext), seen.insert(normalized.path).inserted,
                  let values = try? normalized.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return }
            if ext == "gif", let source = CGImageSourceCreateWithURL(normalized as CFURL, nil), CGImageSourceGetCount(source) > 1 {
                recordIssue(DiscoveryIssue(name: normalized.lastPathComponent, message: "Animated GIF skipped. JPEG XL supports animation, but this app safely replaces single-frame images only.", url: normalized))
                return
            }
            let sourceVersion = try? SourceVersion.capture(normalized)
            let size = sourceVersion?.size ?? values.fileSize.map { UInt64(max(0, $0)) }
            files.append(DiscoveredImage(url: normalized, sourceVersion: sourceVersion, size: size))
            if files.count >= 64 { flushFiles() }
        }

        var visitedRoots = 0
        for root in roots {
            visitedRoots += 1
            guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey]) else {
                recordIssue(DiscoveryIssue(name: root.lastPathComponent, message: "Cannot read this item or its permissions.", url: root))
                continue
            }
            if values.isPackage == true {
                recordIssue(DiscoveryIssue(name: root.lastPathComponent, message: "Packages are skipped; drop a folder containing image files instead.", url: root))
                continue
            }
            if values.isDirectory == true {
                guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey, .fileSizeKey], options: options, errorHandler: { failedURL, error in
                    recordIssue(DiscoveryIssue(name: failedURL.lastPathComponent, message: "Could not scan this folder: \(error.localizedDescription)", url: failedURL))
                    return true
                }) else {
                    recordIssue(DiscoveryIssue(name: root.lastPathComponent, message: "Could not scan this folder.", url: root))
                    continue
                }
                var visited = 0
                for case let url as URL in enumerator {
                    visited += 1
                    addIfImage(url)
                    if visited.isMultiple(of: 128) { flushFiles() }
                }
            } else if values.isRegularFile == true {
                let wasSeen = seen.contains(root.standardizedFileURL.path)
                addIfImage(root)
                if !wasSeen && !seen.contains(root.standardizedFileURL.path) && root.pathExtension.lowercased() != "jxl" {
                    recordIssue(DiscoveryIssue(name: root.lastPathComponent, message: "Unsupported image format or not a readable image.", url: root))
                }
            } else {
                recordIssue(DiscoveryIssue(name: root.lastPathComponent, message: "Only image files and folders can be added.", url: root))
            }
            if visitedRoots.isMultiple(of: 64) { flushFiles() }
        }
        flushFiles()
        if !issues.isEmpty { yield(.issues(issues)) }
    }
}

private enum DiscoveryPayload: Sendable {
    case files([DiscoveredImage])
    case issues([DiscoveryIssue])
}

private final class DiscoveryAcknowledgement: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait() { semaphore.wait() }
}

private struct DiscoveryEvent: Sendable {
    let payload: DiscoveryPayload
    private let acknowledgement = DiscoveryAcknowledgement()
    func acknowledge() { acknowledgement.signal() }
    func waitForAcknowledgement() { acknowledgement.wait() }
}

private struct DiscoveredImage: Sendable {
    let url: URL
    let sourceVersion: SourceVersion?
    let size: UInt64?
}

private struct DiscoveryIssue: Sendable {
    let name: String
    let message: String
    let url: URL?

    init(name: String, message: String, url: URL? = nil) {
        self.name = name
        self.message = message
        self.url = url
    }
}

private struct ConversionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
