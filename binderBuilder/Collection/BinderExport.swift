//
//  BinderExport.swift
//  binderBuilder
//
//  Exports a binder as a printable record: one page per physical sheet side
//  (3x3 pocket grid), either as a multi-page PDF or as one PNG per side.
//
//  Card art is pre-fetched through the existing ImageCache at .high quality
//  (six at a time) and drawn into a clean, letter-sized SwiftUI page which
//  ImageRenderer rasterizes at 2x. Unlike the 3D binder, an export is always
//  full color — it is the user's record of their own binder, so unowned cards
//  are not grayed out.
//

import CoreGraphics
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

nonisolated enum BinderExportFormat: Sendable {
    case pdf
    case pngs
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
    /// Card art by card id; a missing entry renders as a titled placeholder.
    let images: [String: CGImage]
}

enum BinderExport {

    /// US Letter at 72 dpi — the PDF page box, and the PNG size before scale.
    nonisolated static let pageSize = CGSize(width: 612, height: 792)
    /// Rasterization scale (2x -> 1224x1584 PNGs).
    nonisolated static let renderScale: CGFloat = 2
    /// Matches ImageCache.prefetch: enough to saturate the CDN, few enough to
    /// keep decoded 600x825 images from piling up.
    nonisolated static let maxConcurrentFetches = 6

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
        let side = page.side == .front ? "front" : "back"
        return String(format: "%@-p%02d-%@.png", fileStem(binderName), page.pageIndex + 1, side)
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
        progress: (Double) -> Void
    ) async -> BinderExportJob {
        let pages = printablePages(await self.pages(binderID: binder.id, store: store))
        progress(0.05)

        // One fetch per card id, even when a card sits in several pockets.
        var wanted: [String: String?] = [:]
        for slot in pages.flatMap({ $0.slots.compactMap { $0 } }) where wanted[slot.ref.cardID] == nil {
            wanted[slot.ref.cardID] = slot.imageBase
        }

        var images: [String: CGImage] = [:]
        var remaining = Array(wanted)[...]
        let total = max(1, wanted.count)
        var done = 0
        await withTaskGroup(of: (String, CGImage?).self) { group in
            func addNext() {
                guard let (cardID, imageBase) = remaining.popFirst() else { return }
                group.addTask {
                    let image = try? await cache.image(
                        for: cardID, imageBase: imageBase, quality: .high, pinned: true)
                    return (cardID, image)
                }
            }
            for _ in 0..<min(maxConcurrentFetches, remaining.count) { addNext() }
            while let (cardID, image) = await group.next() {
                if let image { images[cardID] = image }
                done += 1
                progress(0.05 + 0.9 * Double(done) / Double(total))
                addNext()
            }
        }
        progress(0.95)
        return BinderExportJob(binderName: binder.name, pages: pages, images: images)
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

    /// Multi-page PDF, one page per binder side.
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

    /// Writes one PNG per binder side into a fresh temporary folder and
    /// returns the files, ready to hand to a share sheet.
    @MainActor
    static func writePNGs(_ job: BinderExportJob) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinderExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var urls: [URL] = []
        for page in job.pages {
            let renderer = ImageRenderer(content: pageView(page, job: job))
            renderer.scale = renderScale
            guard let data = renderer.uiImage?.pngData() else { continue }
            let url = folder.appendingPathComponent(
                pngFileName(binderName: job.binderName, page: page), isDirectory: false)
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    @MainActor
    private static func pageView(_ page: BinderExportPage, job: BinderExportJob) -> some View {
        BinderExportPageView(
            title: pageTitle(binderName: job.binderName, page: page),
            slots: page.slots,
            images: job.images,
            size: pageSize)
    }
}

/// The printable page: white, a 3x3 pocket grid with thin borders, a header
/// naming the binder and page, and the app-name footer. Colors are explicit so
/// the render never picks up the viewer's dark appearance.
private struct BinderExportPageView: View {
    let title: String
    let slots: [BinderExportSlot?]
    let images: [String: CGImage]
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
                if let image = images[slot.ref.cardID] {
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

struct ExportShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
