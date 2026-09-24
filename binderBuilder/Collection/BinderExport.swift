//
//  BinderExport.swift
//  binderBuilder
//
//  Exports a binder as a printable record: one page per physical sheet side
//  (3x3 pocket grid), either as a multi-page PDF or as one PNG per side.
//
//  Card art is pre-fetched through the existing ImageCache at .high quality
//  (six at a time) and drawn into a clean, letter-sized SwiftUI page which
//  ImageRenderer rasterizes at 2x.
//
//  Memory: a 20-sheet binder is 360 pockets, and holding every decoded
//  600x825 .high image for the whole export (~2 MB each) could run a phone
//  out of memory. Each image is instead shrunk to the size a pocket actually
//  prints at and kept JPEG-encoded (tens of KB); pixels are decoded only
//  while their own page renders, so at most one page's art is in memory. Unlike the 3D binder, an export is always
//  full color — it is the user's record of their own binder, so unowned cards
//  are not grayed out.
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

nonisolated enum BinderExportFormat: Sendable {
    case pdf
    case pngs
    case jpegs

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .pngs: return "png"
        case .jpegs: return "jpg"
        }
    }
}

/// Which part of the binder an export covers. `.all` trims trailing empty
/// sides; explicit scopes export exactly what was asked (a deliberately
/// empty side is a valid print target).
nonisolated enum BinderExportScope: Equatable, Sendable {
    case all
    /// One side of one sheet.
    case side(pageIndex: Int, side: PageSide)
    /// Both sides of one sheet.
    case sheet(pageIndex: Int)
    /// What an open 3D spread shows: sheet (s-1)'s back + sheet s's front.
    case spread(spreadIndex: Int)
}

/// One card in an exported pocket.
nonisolated struct BinderExportSlot: Equatable, Sendable {
    let ref: CardRef
    let name: String
    let localNumber: String
    let setName: String
    let imageBase: String?
}

/// One printable page: a single side of one physical sheet.
nonisolated struct BinderExportPage: Equatable, Sendable {
    /// 0-based physical sheet.
    let pageIndex: Int
    let side: PageSide
    /// Exactly 9 entries (3x3, row-major); nil is an empty pocket.
    let slots: [BinderExportSlot?]

    var isEmpty: Bool { slots.allSatisfy { $0 == nil } }
}

/// Everything the renderers need, gathered once so PDF and PNG output stay
/// pixel-identical. Held on the main actor (CGImage art + ImageRenderer).
@MainActor
struct BinderExportJob {
    let binderName: String
    /// Already trimmed to the printable pages.
    let pages: [BinderExportPage]
    /// Card art by card id, downsampled and JPEG-encoded (see `exportArt`);
    /// decoded per page while rendering. A missing entry renders as a titled
    /// placeholder.
    let art: [String: Data]
}

enum BinderExport {

    /// US Letter at 72 dpi — the PDF page box, and the PNG size before scale.
    nonisolated static let pageSize = CGSize(width: 612, height: 792)
    /// Rasterization scale (2x -> 1224x1584 PNGs).
    nonisolated static let renderScale: CGFloat = 2
    /// Matches ImageCache.prefetch: enough to saturate the CDN, few enough to
    /// keep decoded 600x825 images from piling up.
    nonisolated static let maxConcurrentFetches = 6
    /// Longest side, in pixels, of the art kept per card. A pocket prints
    /// ~146x205 pt, i.e. ~292x410 px at `renderScale`; 480 leaves headroom.
    nonisolated static let artMaxPixelSize = 480
    nonisolated static let artJPEGQuality: CGFloat = 0.85

    /// Shrinks a fetched card image to export size and JPEG-encodes it,
    /// flattening the transparent card corners onto the page's white. Runs in
    /// the fetch task, so the full-size decode is dropped straight away.
    nonisolated static func exportArt(from image: CGImage) -> Data? {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > 0 else { return nil }
        let scale = min(1, CGFloat(artMaxPixelSize) / longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let small = context.makeImage() else { return nil }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, small,
            [kCGImageDestinationLossyCompressionQuality: artJPEGQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Decodes one pocket's art at render time.
    nonisolated static func decodeArt(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Pure helpers

    /// Drops the trailing empty sides: a 10-sheet binder holding four cards
    /// exports one page, not twenty. Interior empty sides are kept so the
    /// printout still matches the physical binder page for page.
    nonisolated static func printablePages(_ pages: [BinderExportPage]) -> [BinderExportPage] {
        guard let last = pages.lastIndex(where: { !$0.isEmpty }) else { return [] }
        return Array(pages[...last])
    }

    /// One PDF page per printable side.
    nonisolated static func pdfPageCount(for pages: [BinderExportPage]) -> Int {
        printablePages(pages).count
    }

    /// Applies an export scope to the full page list (see BinderExportScope).
    nonisolated static func scoped(
        _ pages: [BinderExportPage], scope: BinderExportScope
    ) -> [BinderExportPage] {
        switch scope {
        case .all:
            return printablePages(pages)
        case .side(let pageIndex, let side):
            return pages.filter { $0.pageIndex == pageIndex && $0.side == side }
        case .sheet(let pageIndex):
            return pages.filter { $0.pageIndex == pageIndex }
        case .spread(let spreadIndex):
            return pages.filter {
                ($0.pageIndex == spreadIndex - 1 && $0.side == .back)
                    || ($0.pageIndex == spreadIndex && $0.side == .front)
            }
        }
    }

    /// Filename-safe stem for a binder: "Chase & Grails!" -> "Chase-Grails".
    /// Never empty, so a file can always be written.
    nonisolated static func fileStem(_ binderName: String) -> String {
        let mapped = String(binderName.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
        })
        let collapsed = mapped.split(separator: "-").joined(separator: "-")
        let trimmed = String(collapsed.prefix(48))
        return trimmed.isEmpty ? "binder" : trimmed
    }

    /// "Chase-Grails-p03-back.png" — sheet numbers are 1-based for humans.
    nonisolated static func pngFileName(binderName: String, page: BinderExportPage) -> String {
        imageFileName(binderName: binderName, page: page, fileExtension: "png")
    }

    nonisolated static func imageFileName(
        binderName: String, page: BinderExportPage, fileExtension: String
    ) -> String {
        let side = page.side == .front ? "front" : "back"
        return String(format: "%@-p%02d-%@.%@",
                      fileStem(binderName), page.pageIndex + 1, side, fileExtension)
    }

    /// Page header, e.g. "Chase & Grails — Page 3 (back)".
    nonisolated static func pageTitle(binderName: String, page: BinderExportPage) -> String {
        "\(binderName) — Page \(page.pageIndex + 1) (\(page.side == .front ? "front" : "back"))"
    }

    // MARK: - Gathering

    /// Reads the binder's pages and pre-fetches their art. `progress` is called
    /// on the main actor with 0...1 while the images download.
    @MainActor
    static func prepare(
        binder: Binder,
        store: BinderStore,
        cache: ImageCache,
        scope: BinderExportScope = .all,
        progress: (Double) -> Void
    ) async -> BinderExportJob {
        // Narrow scopes shrink the art prefetch too — a single page shares
        // near-instantly instead of fetching the whole binder's art.
        let pages = scoped(await self.pages(binderID: binder.id, store: store), scope: scope)
        progress(0.05)

        // One fetch per card id, even when a card sits in several pockets.
        var wanted: [String: String?] = [:]
        for slot in pages.flatMap({ $0.slots.compactMap { $0 } }) where wanted[slot.ref.cardID] == nil {
            wanted[slot.ref.cardID] = slot.imageBase
        }

        var art: [String: Data] = [:]
        var remaining = Array(wanted)[...]
        let total = max(1, wanted.count)
        var done = 0
        await withTaskGroup(of: (String, Data?).self) { group in
            func addNext() {
                guard let (cardID, imageBase) = remaining.popFirst() else { return }
                group.addTask {
                    // Only the small encoded copy leaves the task.
                    let image = try? await cache.image(
                        for: cardID, imageBase: imageBase, quality: .high, pinned: true)
                    return (cardID, image.flatMap(BinderExport.exportArt(from:)))
                }
            }
            for _ in 0..<min(maxConcurrentFetches, remaining.count) { addNext() }
            while let (cardID, data) = await group.next() {
                if let data { art[cardID] = data }
                done += 1
                progress(0.05 + 0.9 * Double(done) / Double(total))
                addNext()
            }
        }
        progress(0.95)
        return BinderExportJob(binderName: binder.name, pages: pages, art: art)
    }

    /// Every side of the binder in reading order (sheet 0 front, sheet 0 back,
    /// sheet 1 front, …), read through the existing spread API.
    @MainActor
    static func pages(binderID: String, store: BinderStore) async -> [BinderExportPage] {
        let sheetCount = max(0, store.spreadCount(binderID: binderID) - 1)
        guard sheetCount > 0 else { return [] }

        let empty = [BinderExportSlot?](repeating: nil, count: SpreadModel.slotsPerPage)
        var fronts = Array(repeating: empty, count: sheetCount)
        var backs = Array(repeating: empty, count: sheetCount)
        for spread in 0...sheetCount {
            guard let model = try? await store.spread(spread, in: binderID) else { continue }
            if spread < sheetCount { fronts[spread] = model.right.map(exportSlot) }
            let backSheet = spread - 1
            if backSheet >= 0, backSheet < sheetCount { backs[backSheet] = model.left.map(exportSlot) }
        }
        return (0..<sheetCount).flatMap { sheet in
            [BinderExportPage(pageIndex: sheet, side: .front, slots: fronts[sheet]),
             BinderExportPage(pageIndex: sheet, side: .back, slots: backs[sheet])]
        }
    }

    nonisolated private static func exportSlot(_ content: SlotContent?) -> BinderExportSlot? {
        guard let content else { return nil }
        return BinderExportSlot(
            ref: CardRef(cardID: content.card.id, variant: content.variant),
            name: content.card.name,
            localNumber: content.card.localNumber,
            setName: content.card.setName,
            imageBase: content.card.imageBase)
    }

    // MARK: - Rendering

    /// Multi-page PDF, one page per binder side. Stays synchronous: the
    /// `pdfData` closure is a non-async drawing callback, so there is nowhere
    /// to yield between pages (unlike the image writers below).
    @MainActor
    static func pdfData(_ job: BinderExportJob) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return renderer.pdfData { context in
            for page in job.pages {
                context.beginPage()
                let image = ImageRenderer(content: pageView(page, job: job))
                image.scale = renderScale
                image.render { _, draw in draw(context.cgContext) }
            }
        }
    }

    /// JPEG output quality (0.9 keeps card text crisp at ~1/4 the PNG size).
    nonisolated static let jpegQuality: CGFloat = 0.9

    /// Writes one PNG per binder side into a fresh temporary folder and
    /// returns the files, ready to hand to a share sheet.
    @MainActor
    static func writePNGs(_ job: BinderExportJob) throws -> [URL] {
        try writeImages(job, format: .pngs)
    }

    /// Writes one image per binder side (PNG or JPEG) into a fresh temporary
    /// folder and returns the files, ready to hand to a share sheet.
    @MainActor
    static func writeImages(_ job: BinderExportJob, format: BinderExportFormat) throws -> [URL] {
        let folder = try makeExportFolder()
        var urls: [URL] = []
        for page in job.pages {
            guard let data = renderImageData(page, job: job, format: format) else { continue }
            let url = imageURL(in: folder, job: job, page: page, format: format)
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    /// Same output as the synchronous `writeImages`, but yields between pages
    /// so the progress ring keeps turning instead of the UI freezing for the
    /// whole render phase. `progress` continues where `prepare` left off: the
    /// render is the last 5% of an export.
    @MainActor
    static func writeImages(
        _ job: BinderExportJob,
        format: BinderExportFormat,
        progress: (Double) -> Void
    ) async throws -> [URL] {
        let folder = try makeExportFolder()
        var urls: [URL] = []
        for (index, page) in job.pages.enumerated() {
            if let data = renderImageData(page, job: job, format: format) {
                let url = imageURL(in: folder, job: job, page: page, format: format)
                try data.write(to: url, options: .atomic)
                urls.append(url)
            }
            progress(0.95 + 0.05 * Double(index + 1) / Double(job.pages.count))
            await Task.yield()
        }
        return urls
    }

    /// A fresh temporary folder per export, so repeated exports of the same
    /// binder never collide on file names.
    private static func makeExportFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinderExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Rasterizes one page at `renderScale` and encodes it. nil when
    /// ImageRenderer produced nothing — that page is simply skipped.
    @MainActor
    private static func renderImageData(
        _ page: BinderExportPage, job: BinderExportJob, format: BinderExportFormat
    ) -> Data? {
        let renderer = ImageRenderer(content: pageView(page, job: job))
        renderer.scale = renderScale
        switch format {
        case .jpegs: return renderer.uiImage?.jpegData(compressionQuality: jpegQuality)
        case .pngs, .pdf: return renderer.uiImage?.pngData()
        }
    }

    @MainActor
    private static func imageURL(
        in folder: URL, job: BinderExportJob, page: BinderExportPage, format: BinderExportFormat
    ) -> URL {
        folder.appendingPathComponent(
            imageFileName(binderName: job.binderName, page: page,
                          fileExtension: format == .jpegs ? "jpg" : "png"),
            isDirectory: false)
    }

    /// Renders the job as a PDF file on disk (for share sheets; the
    /// fileExporter path uses `pdfData` directly).
    @MainActor
    static func writePDF(_ job: BinderExportJob) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(fileStem(job.binderName)).pdf", isDirectory: false)
        try pdfData(job).write(to: url, options: .atomic)
        return url
    }

    @MainActor
    private static func pageView(_ page: BinderExportPage, job: BinderExportJob) -> some View {
        BinderExportPageView(
            title: pageTitle(binderName: job.binderName, page: page),
            slots: page.slots,
            art: job.art,
            size: pageSize)
    }
}

/// The printable page: white, a 3x3 pocket grid with thin borders, a header
/// naming the binder and page, and the app-name footer. Colors are explicit so
/// the render never picks up the viewer's dark appearance.
private struct BinderExportPageView: View {
    let title: String
    let slots: [BinderExportSlot?]
    let art: [String: Data]
    let size: CGSize

    /// Standard trading-card aspect (2.5" x 3.5").
    private let cardAspect: CGFloat = 2.5 / 3.5

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.bottom, 16)

            BinderPageGridView(slots: slots) { _, slot in
                pocket(slot)
            }

            Spacer(minLength: 0)

            Text("Binder Builder")
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.55))
                .padding(.top, 12)
        }
        .padding(32)
        .frame(width: size.width, height: size.height)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func pocket(_ slot: BinderExportSlot?) -> some View {
        ZStack {
            if let slot {
                // Decoded here, during this page's render only.
                if let data = art[slot.ref.cardID], let image = BinderExport.decodeArt(data) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    // No art (offline, or the CDN has none): name the card so
                    // the page is still a usable record.
                    VStack(spacing: 4) {
                        Text(slot.name)
                            .font(.system(size: 12, weight: .medium))
                        Text("\(slot.setName) · \(slot.localNumber)")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(white: 0.45))
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.black)
                    .padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(cardAspect, contentMode: .fit)
        .overlay {
            if slot == nil {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(white: 0.75),
                                  style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(white: 0.6), lineWidth: 0.8)
            }
        }
    }
}

/// Wraps the rendered PDF for `.fileExporter`.
struct BinderPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The rendered PNG files, presented in the system share sheet — a ShareLink
/// can't be built after the fact from an async render.
struct BinderPNGShare: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Runs an export end-to-end for a view: prepare (with progress) -> render ->
/// hand the files to a share sheet. One instance per hosting view; the view
/// observes `isRunning`/`progress` and presents `share` when it arrives.
@MainActor @Observable final class BinderExportRunner {
    private(set) var isRunning = false
    private(set) var progress: Double = 0
    var share: BinderPNGShare?

    /// Returns false when there was nothing to export or rendering failed.
    @discardableResult
    func run(
        binder: Binder,
        store: BinderStore,
        cache: ImageCache,
        scope: BinderExportScope,
        format: BinderExportFormat
    ) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        progress = 0
        defer { isRunning = false }

        let job = await BinderExport.prepare(
            binder: binder, store: store, cache: cache, scope: scope
        ) { progress = $0 }
        guard !job.pages.isEmpty else { return false }
        do {
            switch format {
            case .pdf:
                share = BinderPNGShare(urls: [try BinderExport.writePDF(job)])
            case .pngs, .jpegs:
                share = BinderPNGShare(urls: try await BinderExport.writeImages(
                    job, format: format) { progress = $0 })
            }
            return true
        } catch {
            return false
        }
    }
}

struct ExportShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
