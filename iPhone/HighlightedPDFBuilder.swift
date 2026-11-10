import Foundation
import PDFKit
import SwiftUI
import UIKit

struct HighlightedPDFSource: Identifiable, Sendable {
    let id: UUID
    let filename: String
    let data: Data

    init(id: UUID = UUID(), filename: String, data: Data) {
        self.id = id
        self.filename = filename
        self.data = data
    }
}

struct HighlightedPDFSection: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceID: UUID
    let sourceFilename: String
    let pageIndex: Int
    let annotationIndex: Int
    let cropBounds: CGRect
    let previewData: Data

    init(
        id: UUID = UUID(),
        sourceID: UUID,
        sourceFilename: String,
        pageIndex: Int,
        annotationIndex: Int,
        cropBounds: CGRect,
        previewData: Data
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceFilename = sourceFilename
        self.pageIndex = pageIndex
        self.annotationIndex = annotationIndex
        self.cropBounds = cropBounds
        self.previewData = previewData
    }

    var pageNumber: Int { pageIndex + 1 }
}

struct GeneratedHighlightedPDF: Identifiable {
    let id = UUID()
    let url: URL
    let pageCount: Int
}

enum HighlightedPDFError: LocalizedError {
    case unreadableFile(String)
    case invalidPDF(String)
    case noHighlights
    case noSelectedSections
    case missingSource(String)
    case missingPage(String, Int)
    case couldNotCreatePreview
    case couldNotCreateOutput

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let filename):
            "The app could not read \(filename)."
        case .invalidPDF(let filename):
            "\(filename) could not be opened as a PDF."
        case .noHighlights:
            "No large highlighted Stamp annotations were found. Use the same broad Apple Markup highlighting style as the supported class-plan PDFs."
        case .noSelectedSections:
            "Select at least one highlighted portion before generating the PDF."
        case .missingSource(let filename):
            "The source data for \(filename) is no longer available."
        case .missingPage(let filename, let page):
            "Page \(page) could not be reopened from \(filename)."
        case .couldNotCreatePreview:
            "A highlighted portion could not be rendered for preview."
        case .couldNotCreateOutput:
            "The resulting PDF could not be created."
        }
    }
}

enum HighlightedPDFExtractor {
    private static let detectionScale: CGFloat = 2
    private static let previewScale: CGFloat = 1.25
    private static let outputScale: CGFloat = 3
    private static let differenceThreshold: UInt8 = 6
    private static let highlightedLineCoverage = 0.15
    private static let outputPageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let outputMargin: CGFloat = 18

    static func loadSources(from urls: [URL]) throws -> [HighlightedPDFSource] {
        try urls.map { url in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                return HighlightedPDFSource(
                    filename: url.lastPathComponent,
                    data: try Data(contentsOf: url, options: [.mappedIfSafe])
                )
            } catch {
                throw HighlightedPDFError.unreadableFile(url.lastPathComponent)
            }
        }
    }

    static func extract(
        from sources: [HighlightedPDFSource],
        minimumAreaRatio: CGFloat = 0.08,
        padding: CGFloat = 8
    ) throws -> [HighlightedPDFSection] {
        var sections: [HighlightedPDFSection] = []

        for source in sources {
            guard let document = PDFDocument(data: source.data) else {
                throw HighlightedPDFError.invalidPDF(source.filename)
            }

            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let pageBounds = page.bounds(for: .mediaBox)
                let pageArea = pageBounds.width * pageBounds.height
                guard pageArea > 0 else { continue }

                let candidates = page.annotations.enumerated()
                    .filter { _, annotation in
                        annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Stamp"
                            && annotation.bounds.width * annotation.bounds.height / pageArea >= minimumAreaRatio
                    }
                    .sorted { lhs, rhs in
                        if lhs.element.bounds.maxY == rhs.element.bounds.maxY {
                            return lhs.element.bounds.minX < rhs.element.bounds.minX
                        }
                        return lhs.element.bounds.maxY > rhs.element.bounds.maxY
                    }
                guard !candidates.isEmpty else { continue }

                let shown = render(page: page, crop: pageBounds, scale: detectionScale, includeAnnotations: true)
                let hidden = render(page: page, crop: pageBounds, scale: detectionScale, includeAnnotations: false)
                let mask = differenceMask(shown: shown, hidden: hidden)

                for (annotationIndex, annotation) in candidates {
                    var crops = [annotation.bounds.intersection(pageBounds)]
                    if let visible = visibleBounds(
                        for: annotation.bounds,
                        on: pageBounds,
                        mask: mask,
                        pixelWidth: shown.cgImage?.width ?? 0,
                        pixelHeight: shown.cgImage?.height ?? 0
                    ) {
                        crops = tightenedHighlightedRegions(
                            visibleBounds: visible,
                            annotationBounds: annotation.bounds,
                            page: page,
                            pageBounds: pageBounds,
                            mask: mask,
                            pixelWidth: shown.cgImage?.width ?? 0,
                            pixelHeight: shown.cgImage?.height ?? 0
                        )
                    }

                    for cropBounds in crops {
                        let crop = cropBounds
                            .insetBy(dx: -padding, dy: -padding)
                            .intersection(pageBounds)
                        guard crop.width > 1, crop.height > 1 else { continue }

                        let preview = render(
                            page: page,
                            crop: crop,
                            scale: previewScale,
                            includeAnnotations: true
                        )
                        guard let previewData = preview.jpegData(compressionQuality: 0.82) else {
                            throw HighlightedPDFError.couldNotCreatePreview
                        }
                        sections.append(
                            HighlightedPDFSection(
                                sourceID: source.id,
                                sourceFilename: source.filename,
                                pageIndex: pageIndex,
                                annotationIndex: annotationIndex,
                                cropBounds: crop,
                                previewData: previewData
                            )
                        )
                    }
                }
            }
        }

        guard !sections.isEmpty else { throw HighlightedPDFError.noHighlights }
        return sections
    }

    static func generatePDF(
        title: String,
        sources: [HighlightedPDFSource],
        sections: [HighlightedPDFSection],
        keepHighlighting: Bool
    ) throws -> Data {
        guard !sections.isEmpty else { throw HighlightedPDFError.noSelectedSections }
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var documents: [UUID: PDFDocument] = [:]
        for source in sources {
            guard let document = PDFDocument(data: source.data) else {
                throw HighlightedPDFError.invalidPDF(source.filename)
            }
            documents[source.id] = document
        }
        for section in sections {
            guard sourcesByID[section.sourceID] != nil else {
                throw HighlightedPDFError.missingSource(section.sourceFilename)
            }
            guard documents[section.sourceID]?.page(at: section.pageIndex) != nil else {
                throw HighlightedPDFError.missingPage(section.sourceFilename, section.pageNumber)
            }
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextSubject as String: "Ordered highlighted PDF portions stitched onto standard white pages; outside page data removed"
        ]
        let contentWidth = outputPageBounds.width - outputMargin * 2
        let contentBottom = outputPageBounds.height - outputMargin
        let renderer = UIGraphicsPDFRenderer(bounds: outputPageBounds, format: format)
        let data = renderer.pdfData { context in
            var cursorY = outputMargin

            func beginOutputPage() {
                context.beginPage(withBounds: outputPageBounds, pageInfo: [:])
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(outputPageBounds)
                cursorY = outputMargin
            }

            beginOutputPage()
            for section in sections {
                guard let page = documents[section.sourceID]?.page(at: section.pageIndex) else { continue }
                let image = render(
                    page: page,
                    crop: section.cropBounds,
                    scale: outputScale,
                    includeAnnotations: keepHighlighting
                )
                guard let imageRef = image.cgImage else { continue }
                let sectionHeight = CGFloat(imageRef.height) * contentWidth / CGFloat(imageRef.width)
                var consumedHeight: CGFloat = 0

                while consumedHeight < sectionHeight - 0.01 {
                    if cursorY >= contentBottom - 0.01 {
                        beginOutputPage()
                    }
                    let availableHeight = contentBottom - cursorY
                    let chunkHeight = min(sectionHeight - consumedHeight, availableHeight)
                    guard chunkHeight > 0 else { break }

                    let chunkTop = cursorY
                    let fullImageTop = chunkTop - consumedHeight
                    let clipRect = CGRect(
                        x: outputMargin,
                        y: outputPageBounds.height - chunkTop - chunkHeight,
                        width: contentWidth,
                        height: chunkHeight
                    )
                    let pdfContext = context.cgContext
                    pdfContext.saveGState()
                    pdfContext.clip(to: clipRect)
                    pdfContext.translateBy(
                        x: outputMargin,
                        y: outputPageBounds.height - fullImageTop
                    )
                    pdfContext.scaleBy(x: 1, y: -1)
                    pdfContext.draw(
                        imageRef,
                        in: CGRect(x: 0, y: 0, width: contentWidth, height: sectionHeight)
                    )
                    pdfContext.restoreGState()

                    cursorY += chunkHeight
                    consumedHeight += chunkHeight
                }
            }
        }

        guard let result = PDFDocument(data: data), result.pageCount > 0 else {
            throw HighlightedPDFError.couldNotCreateOutput
        }
        return data
    }

    static func outputURL(title: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarreHighlightedPDFs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(sanitizedFilename(title: title))
    }

    static func sanitizedFilename(title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.controlCharacters)
        let components = title.components(separatedBy: invalid)
        let cleaned = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? "Highlighted Class Plan" : cleaned
        return base.lowercased().hasSuffix(".pdf") ? base : "\(base).pdf"
    }

    private static func render(
        page: PDFPage,
        crop: CGRect,
        scale: CGFloat,
        includeAnnotations: Bool
    ) -> UIImage {
        let pixelSize = CGSize(
            width: max(1, ceil(crop.width * scale)),
            height: max(1, ceil(crop.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let previousDisplaySetting = page.displaysAnnotations
        page.displaysAnnotations = includeAnnotations
        defer { page.displaysAnnotations = previousDisplaySetting }

        return renderer.image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: pixelSize))
            let context = rendererContext.cgContext
            context.saveGState()
            context.translateBy(x: -crop.minX * scale, y: crop.maxY * scale)
            context.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
    }

    private static func differenceMask(shown: UIImage, hidden: UIImage) -> [UInt8] {
        guard let shownImage = shown.cgImage,
              let hiddenImage = hidden.cgImage,
              shownImage.width == hiddenImage.width,
              shownImage.height == hiddenImage.height,
              let shownBytes = rgbaBytes(from: shownImage),
              let hiddenBytes = rgbaBytes(from: hiddenImage) else { return [] }

        let pixelCount = shownImage.width * shownImage.height
        var mask = [UInt8](repeating: 0, count: pixelCount)
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            let red = abs(Int(shownBytes[offset]) - Int(hiddenBytes[offset]))
            let green = abs(Int(shownBytes[offset + 1]) - Int(hiddenBytes[offset + 1]))
            let blue = abs(Int(shownBytes[offset + 2]) - Int(hiddenBytes[offset + 2]))
            if max(red, green, blue) > Int(differenceThreshold) {
                mask[pixel] = 1
            }
        }
        return mask
    }

    private static func rgbaBytes(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private static func visibleBounds(
        for annotationBounds: CGRect,
        on pageBounds: CGRect,
        mask: [UInt8],
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGRect? {
        guard pixelWidth > 0, pixelHeight > 0, mask.count == pixelWidth * pixelHeight else { return nil }
        let window = pixelRect(
            for: annotationBounds.intersection(pageBounds),
            pageBounds: pageBounds,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        let minX = max(0, Int(floor(window.minX)))
        let maxX = min(pixelWidth - 1, Int(ceil(window.maxX)))
        let minY = max(0, Int(floor(window.minY)))
        let maxY = min(pixelHeight - 1, Int(ceil(window.maxY)))
        guard minX <= maxX, minY <= maxY else { return nil }

        var foundMinX = pixelWidth
        var foundMaxX = -1
        var foundMinY = pixelHeight
        var foundMaxY = -1
        for y in minY...maxY {
            for x in minX...maxX where mask[y * pixelWidth + x] != 0 {
                foundMinX = min(foundMinX, x)
                foundMaxX = max(foundMaxX, x)
                foundMinY = min(foundMinY, y)
                foundMaxY = max(foundMaxY, y)
            }
        }
        guard foundMaxX >= foundMinX, foundMaxY >= foundMinY else { return nil }
        return pageRect(
            for: CGRect(
                x: foundMinX,
                y: foundMinY,
                width: foundMaxX - foundMinX + 1,
                height: foundMaxY - foundMinY + 1
            ),
            pageBounds: pageBounds,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    private static func tightenedHighlightedRegions(
        visibleBounds: CGRect,
        annotationBounds: CGRect,
        page: PDFPage,
        pageBounds: CGRect,
        mask: [UInt8],
        pixelWidth: Int,
        pixelHeight: Int
    ) -> [CGRect] {
        guard let selection = page.selection(for: annotationBounds.intersection(pageBounds)) else {
            return [visibleBounds]
        }
        let selectedLineBounds = selection.selectionsByLine()
            .map { $0.bounds(for: page).intersection(annotationBounds) }
            .filter { lineBounds in
                guard lineBounds.width > 0, lineBounds.height > 0 else { return false }
                let pixels = pixelRect(
                    for: lineBounds,
                    pageBounds: pageBounds,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                )
                let minX = max(0, Int(floor(pixels.minX)))
                let maxX = min(pixelWidth - 1, Int(ceil(pixels.maxX)))
                let minY = max(0, Int(floor(pixels.minY)))
                let maxY = min(pixelHeight - 1, Int(ceil(pixels.maxY)))
                guard minX <= maxX, minY <= maxY else { return false }
                var highlightedPixels = 0
                var totalPixels = 0
                for y in minY...maxY {
                    for x in minX...maxX {
                        totalPixels += 1
                        highlightedPixels += Int(mask[y * pixelWidth + x])
                    }
                }
                return totalPixels > 0
                    && Double(highlightedPixels) / Double(totalPixels) >= highlightedLineCoverage
            }
        let regions = clusteredHighlightedLineRegions(
            selectedLineBounds,
            horizontalBounds: visibleBounds
        )
        return regions.isEmpty ? [visibleBounds] : regions
    }

    static func clusteredHighlightedLineRegions(
        _ lineBounds: [CGRect],
        horizontalBounds: CGRect
    ) -> [CGRect] {
        let lines = lineBounds
            .filter { $0.width > 0 && $0.height > 0 }
            .sorted { $0.maxY > $1.maxY }
        guard !lines.isEmpty else { return [] }

        let heights = lines.map(\.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let maximumContinuousGap = max(18, medianHeight * 1.75)
        var groups: [[CGRect]] = []
        var currentGroup: [CGRect] = []
        var previousLine: CGRect?

        for line in lines {
            if let previousLine,
               previousLine.minY - line.maxY > maximumContinuousGap {
                groups.append(currentGroup)
                currentGroup = []
            }
            currentGroup.append(line)
            previousLine = line
        }
        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }

        return groups.compactMap { group in
            guard let minY = group.map(\.minY).min(),
                  let maxY = group.map(\.maxY).max(),
                  maxY > minY else { return nil }
            return CGRect(
                x: horizontalBounds.minX,
                y: minY,
                width: horizontalBounds.width,
                height: maxY - minY
            )
        }
    }

    private static func pixelRect(
        for pageRect: CGRect,
        pageBounds: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGRect {
        let scaleX = CGFloat(pixelWidth) / pageBounds.width
        let scaleY = CGFloat(pixelHeight) / pageBounds.height
        return CGRect(
            x: (pageRect.minX - pageBounds.minX) * scaleX,
            y: (pageBounds.maxY - pageRect.maxY) * scaleY,
            width: pageRect.width * scaleX,
            height: pageRect.height * scaleY
        )
    }

    private static func pageRect(
        for pixelRect: CGRect,
        pageBounds: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGRect {
        let scaleX = CGFloat(pixelWidth) / pageBounds.width
        let scaleY = CGFloat(pixelHeight) / pageBounds.height
        return CGRect(
            x: pageBounds.minX + pixelRect.minX / scaleX,
            y: pageBounds.maxY - pixelRect.maxY / scaleY,
            width: pixelRect.width / scaleX,
            height: pixelRect.height / scaleY
        )
    }
}

@MainActor
final class HighlightedPDFBuilderModel: ObservableObject {
    @Published var sections: [HighlightedPDFSection] = []
    @Published var selectedSectionIDs: Set<UUID> = []
    @Published var outputTitle = "Highlighted Class Plan"
    @Published var keepHighlighting = true
    @Published var isLoading = false
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var generatedPDF: GeneratedHighlightedPDF?

    private var sources: [HighlightedPDFSource] = []

    var selectedCount: Int { sections.filter { selectedSectionIDs.contains($0.id) }.count }

    func load(urls: [URL]) async {
        guard !urls.isEmpty, !isLoading, sections.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let sources = try HighlightedPDFExtractor.loadSources(from: urls)
                let sections = try HighlightedPDFExtractor.extract(from: sources)
                return (sources, sections)
            }.value
            sources = result.0
            sections = result.1
            selectedSectionIDs = Set(result.1.map(\.id))
            if urls.count == 1 {
                outputTitle = urls[0].deletingPathExtension().lastPathComponent + " - Highlights"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ section: HighlightedPDFSection) {
        if selectedSectionIDs.contains(section.id) {
            selectedSectionIDs.remove(section.id)
        } else {
            selectedSectionIDs.insert(section.id)
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        sections.move(fromOffsets: offsets, toOffset: destination)
    }

    func generate() async {
        guard !isGenerating else { return }
        let selected = sections.filter { selectedSectionIDs.contains($0.id) }
        guard !selected.isEmpty else {
            errorMessage = HighlightedPDFError.noSelectedSections.localizedDescription
            return
        }
        isGenerating = true
        defer { isGenerating = false }
        let title = outputTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = title.isEmpty ? "Highlighted Class Plan" : title
        let sourceSnapshot = sources
        let keepHighlighting = keepHighlighting
        do {
            generatedPDF = try await Task.detached(priority: .userInitiated) {
                let data = try HighlightedPDFExtractor.generatePDF(
                    title: effectiveTitle,
                    sources: sourceSnapshot,
                    sections: selected,
                    keepHighlighting: keepHighlighting
                )
                let url = try HighlightedPDFExtractor.outputURL(title: effectiveTitle)
                try data.write(to: url, options: .atomic)
                let pageCount = PDFDocument(data: data)?.pageCount ?? 0
                return GeneratedHighlightedPDF(url: url, pageCount: pageCount)
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct HighlightedPDFBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = HighlightedPDFBuilderModel()
    @State private var previewSection: HighlightedPDFSection?
    let urls: [URL]

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("Finding highlighted portions...")
                } else if model.sections.isEmpty {
                    ContentUnavailableView(
                        "No Highlighted Portions",
                        systemImage: "highlighter",
                        description: Text("Choose PDFs containing broad Apple Markup highlights saved as Stamp annotations.")
                    )
                } else {
                    List {
                        Section("Output PDF") {
                            TextField("PDF Name", text: $model.outputTitle)
                                .textInputAutocapitalization(.words)
                            Toggle("Keep visible highlighting", isOn: $model.keepHighlighting)
                        }

                        Section {
                            ForEach(model.sections) { section in
                                HighlightedPDFSectionRow(
                                    section: section,
                                    isSelected: model.selectedSectionIDs.contains(section.id),
                                    onToggle: { model.toggle(section) },
                                    onPreview: { previewSection = section }
                                )
                            }
                            .onMove(perform: model.move)
                        } header: {
                            Text("Highlighted Portions")
                        } footer: {
                            Text("\(model.selectedCount) of \(model.sections.count) selected. Drag the handles to set the final PDF order.")
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Build Highlighted PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        Task { await model.generate() }
                    }
                    .disabled(model.isLoading || model.isGenerating || model.selectedCount == 0)
                }
            }
            .overlay {
                if model.isGenerating {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView("Creating PDF...")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
        .task { await model.load(urls: urls) }
        .sheet(item: $previewSection) { section in
            HighlightedPDFSectionPreview(section: section)
        }
        .sheet(item: $model.generatedPDF) { result in
            GeneratedHighlightedPDFView(result: result)
        }
        .alert("Highlighted PDF Problem", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }
}

private struct HighlightedPDFSectionRow: View {
    let section: HighlightedPDFSection
    let isSelected: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.pink : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Exclude portion" : "Include portion")

            Button(action: onPreview) {
                HStack(spacing: 12) {
                    if let image = UIImage(data: section.previewData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 74, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.secondary.opacity(0.25))
                            }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.sourceFilename)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text("Page \(section.pageNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "eye")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview portion from \(section.sourceFilename), page \(section.pageNumber)")
        }
        .opacity(isSelected ? 1 : 0.55)
    }
}

private struct HighlightedPDFSectionPreview: View {
    @Environment(\.dismiss) private var dismiss
    let section: HighlightedPDFSection

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                if let image = UIImage(data: section.previewData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(minWidth: 320)
                        .padding()
                }
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .navigationTitle("Page \(section.pageNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct GeneratedHighlightedPDFView: View {
    @Environment(\.dismiss) private var dismiss
    let result: GeneratedHighlightedPDF

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PDFDocumentView(url: result.url)
                ShareLink(item: result.url) {
                    Label("Save or Share PDF", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.pink, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .padding()
            }
            .navigationTitle("PDF Ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
