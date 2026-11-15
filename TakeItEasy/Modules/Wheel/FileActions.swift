import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// File operations behind the wheel slices. All synchronous and meant to run off the main thread.
/// Originals are never touched: outputs go next to the source as "name (take-it-easy).ext".
nonisolated enum FileActions {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    enum ImageFormat: Sendable {
        case jpeg, png, heic
        var type: UTType { switch self { case .jpeg: .jpeg; case .png: .png; case .heic: .heic } }
        var ext: String { switch self { case .jpeg: "jpg"; case .png: "png"; case .heic: "heic" } }
    }

    static let tag = "take-it-easy"

    // MARK: - Naming

    /// "base (take-it-easy).ext", then "base (take-it-easy 2).ext", … until `exists` says no.
    static func outputName(base: String, ext: String, exists: (String) -> Bool) -> String {
        var n = 1
        while true {
            let name = n == 1 ? "\(base) (\(tag)).\(ext)" : "\(base) (\(tag) \(n)).\(ext)"
            if !exists(name) { return name }
            n += 1
        }
    }

    /// Drops a previous " (take-it-easy)" / " (take-it-easy 3)" so outputs of outputs don't stack tags.
    static func baseName(_ name: String) -> String {
        name.replacingOccurrences(of: #" \(\#(tag)( \d+)?\)$"#, with: "", options: .regularExpression)
    }

    static func output(for source: URL, suffix: String = "", ext: String) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = baseName(source.deletingPathExtension().lastPathComponent) + suffix
        let name = outputName(base: base, ext: ext) {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        return dir.appendingPathComponent(name)
    }

    /// Finder order is click order; sort by name so merged/combined output is predictable.
    static func sortedByName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Images

    static func convert(_ urls: [URL], to format: ImageFormat) throws -> [URL] {
        try urls.map { url in
            let out = output(for: url, ext: format.ext)
            try reencode(url, to: out, type: format.type, quality: 0.9)
            return out
        }
    }

    /// JPEG at 0.6 (HEIC stays HEIC). Metadata is kept.
    static func compressImages(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let src = try source(url)
            let isHEIC = (CGImageSourceGetType(src) as String?) == UTType.heic.identifier
            let format: ImageFormat = isHEIC ? .heic : .jpeg
            let out = output(for: url, ext: format.ext)
            try reencode(url, to: out, type: format.type, quality: 0.6)
            return out
        }
    }

    /// Long side capped at `maxPixels`, or scaled by `factor`. Never upscales.
    /// `format` nil keeps the source format.
    static func resize(_ urls: [URL], maxPixels: Int? = nil, factor: Double? = nil, format: ImageFormat? = nil) throws -> [URL] {
        try urls.map { url in
            let src = try source(url)
            let long = longSide(src)
            let target = maxPixels ?? Int(Double(long) * (factor ?? 1))
            let image = try decode(src, maxPixels: min(target, long))
            let type = format?.type ?? writableType(of: src)
            let out = output(for: url, ext: ext(for: type, source: url))
            try write(image, to: out, type: type)
            return out
        }
    }

    static func rotate(_ urls: [URL], clockwise: Bool) throws -> [URL] {
        try urls.map { url in
            let src = try source(url)
            let image = try decode(src)
            // Output is the input with width and height swapped.
            let width = image.height, height = image.width
            guard let ctx = bitmap(width: width, height: height, colorSpace: image.colorSpace) else {
                throw Failure(String(localized: "Impossibile ruotare \(url.lastPathComponent)"))
            }
            if clockwise {
                ctx.translateBy(x: 0, y: CGFloat(height))
                ctx.rotate(by: -.pi / 2)
            } else {
                ctx.translateBy(x: CGFloat(width), y: 0)
                ctx.rotate(by: .pi / 2)
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let rotated = ctx.makeImage() else { throw Failure(String(localized: "Impossibile ruotare \(url.lastPathComponent)")) }
            let type = writableType(of: src)
            let out = output(for: url, ext: ext(for: type, source: url))
            try write(rotated, to: out, type: type)
            return out
        }
    }

    // ponytail: strips by re-encoding pixels (quality 0.95), which removes EXIF/GPS/XMP for sure;
    // a lossless JPEG path (CGImageDestinationCopyImageSource) can come later if quality loss matters.
    static func stripMetadata(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let src = try source(url)
            let image = try decode(src)
            let type = writableType(of: src)
            let out = output(for: url, ext: ext(for: type, source: url))
            try write(image, to: out, type: type, quality: 0.95)
            return out
        }
    }

    // ponytail: one page per image at its native size; fitting to A4 belongs to recipes (Phase 2, step 4).
    static func imagesToPDF(_ urls: [URL]) throws -> [URL] {
        let sorted = sortedByName(urls)
        let doc = PDFDocument()
        for url in sorted {
            let image = try decode(try source(url))
            guard let page = PDFPage(image: NSImage(cgImage: image, size: .zero)) else {
                throw Failure(String(localized: "Impossibile aggiungere \(url.lastPathComponent)"))
            }
            doc.insert(page, at: doc.pageCount)
        }
        let out = output(for: sorted[0], ext: "pdf")
        guard doc.write(to: out) else { throw Failure(String(localized: "Impossibile salvare il PDF")) }
        return [out]
    }

    /// Images fitted on A4 pages (portrait or landscape to match each image), at most `maxBytes`.
    /// Tries decreasing resolution/quality until the file fits; if it never does, saves the smallest and says so.
    static func imagesToA4PDF(_ urls: [URL], maxBytes: Int?) throws -> [URL] {
        let sorted = sortedByName(urls)
        let images = try sorted.map { try decode(try source($0)) }
        let attempts: [(dpi: Double, quality: Double)] = maxBytes == nil
            ? [(200, 0.85)]
            : [(200, 0.85), (150, 0.75), (150, 0.6), (120, 0.5), (100, 0.4), (72, 0.3)]
        var data = Data()
        for attempt in attempts {
            data = try renderA4(images, dpi: attempt.dpi, quality: attempt.quality)
            if let maxBytes, data.count > maxBytes { continue }
            break
        }
        let out = output(for: sorted[0], ext: "pdf")
        try data.write(to: out, options: .withoutOverwriting)
        if let maxBytes, data.count > maxBytes {
            let mb = { (bytes: Int) -> String in String(format: "%.1f", Double(bytes) / 1_000_000) }
            throw Failure(String(localized: "PDF salvato ma pesa \(mb(data.count)) MB (limite \(mb(maxBytes)) MB)"))
        }
        return [out]
    }

    private static func renderA4(_ images: [CGImage], dpi: Double, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw Failure(String(localized: "Impossibile creare il PDF")) }
        for image in images {
            let landscape = image.width > image.height
            var page = CGRect(x: 0, y: 0, width: landscape ? 842 : 595, height: landscape ? 595 : 842) // A4 in points
            let scale = min(page.width / CGFloat(image.width), page.height / CGFloat(image.height))
            let fit = CGRect(x: (page.width - CGFloat(image.width) * scale) / 2, y: (page.height - CGFloat(image.height) * scale) / 2,
                             width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            // Downscale to the target dpi, then embed as JPEG (Quartz passes JPEG data through untouched).
            let px = (Int(fit.width / 72 * dpi), Int(fit.height / 72 * dpi))
            let target = px.0 < image.width ? try scaled(image, width: max(px.0, 1), height: max(px.1, 1)) : image
            let jpeg = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(jpeg as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw Failure(String(localized: "Impossibile creare il PDF"))
            }
            CGImageDestinationAddImage(dest, target, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: jpeg as CFData),
                  let embedded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw Failure(String(localized: "Impossibile creare il PDF")) }
            let box = withUnsafeBytes(of: &page) { Data($0) }
            ctx.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
            ctx.draw(embedded, in: fit)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    private static func scaled(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let ctx = bitmap(width: width, height: height, colorSpace: image.colorSpace) else {
            throw Failure(String(localized: "Immagine non leggibile"))
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = ctx.makeImage() else { throw Failure(String(localized: "Immagine non leggibile")) }
        return result
    }

    // MARK: - Any file

    /// One item → "name (take-it-easy).zip"; several → "Archivio (take-it-easy).zip". Uses /usr/bin/zip.
    static func zip(_ urls: [URL]) throws -> [URL] {
        let dir = urls[0].deletingLastPathComponent()
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL }) else {
            throw Failure(String(localized: "Seleziona elementi della stessa cartella"))
        }
        let out = urls.count == 1
            ? output(for: urls[0], ext: "zip")
            : dir.appendingPathComponent(outputName(base: String(localized: "Archivio"), ext: "zip") {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = dir // relative names inside the archive
        process.arguments = ["-r", "-y", "-q", out.lastPathComponent] + urls.map(\.lastPathComponent) + ["-x", "*.DS_Store"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(String(localized: "Compressione zip non riuscita")) }
        return [out]
    }

    /// "Base 1.jpg", "Base 2.jpg", … (zero-padded when there are 10+ items), in name order.
    /// Checks every target first: either all files are renamed or none.
    static func rename(_ urls: [URL], base: String) throws -> [URL] {
        let base = base.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !base.contains("/"), !base.contains(":") else {
            throw Failure(String(localized: "Nome non valido"))
        }
        let sorted = sortedByName(urls)
        let targets = seriesNames(sorted.map(\.pathExtension), base: base).enumerated().map { i, name in
            sorted[i].deletingLastPathComponent().appendingPathComponent(name)
        }
        let sources = Set(sorted.map(\.standardizedFileURL.path))
        for target in targets where FileManager.default.fileExists(atPath: target.path) && !sources.contains(target.standardizedFileURL.path) {
            throw Failure(String(localized: "«\(target.lastPathComponent)» esiste già"))
        }
        // Two steps through temporary names, so "a 2 → a 1" swaps can't collide.
        let temps = try sorted.map { url in
            let temp = url.deletingLastPathComponent().appendingPathComponent(".tie-rename-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: temp)
            return temp
        }
        for (temp, target) in Swift.zip(temps, targets) { try FileManager.default.moveItem(at: temp, to: target) }
        return targets
    }

    static func seriesNames(_ extensions: [String], base: String) -> [String] {
        let digits = extensions.count >= 10 ? String(extensions.count).count : 1
        return extensions.enumerated().map { i, ext in
            let number = String(i + 1).leftPadded(to: digits)
            return ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
        }
    }

    /// Empty "Nuovo file.txt" (then "Nuovo file 2.txt", …) in `folder`.
    static func newTextFile(in folder: URL) throws -> [URL] {
        let base = String(localized: "Nuovo file")
        var n = 1
        while true {
            let url = folder.appendingPathComponent(n == 1 ? "\(base).txt" : "\(base) \(n).txt")
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .withoutOverwriting)
                return [url]
            }
            n += 1
        }
    }

    // MARK: - PDF

    static func mergePDFs(_ urls: [URL]) throws -> [URL] {
        let sorted = sortedByName(urls)
        let merged = PDFDocument()
        for url in sorted {
            let doc = try pdf(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let out = output(for: sorted[0], ext: "pdf")
        guard merged.write(to: out) else { throw Failure(String(localized: "Impossibile salvare il PDF")) }
        return [out]
    }

    static func compressPDFs(_ urls: [URL]) throws -> [URL] {
        try urls.map { url in
            let out = output(for: url, ext: "pdf")
            let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
            guard try pdf(url).write(to: out, withOptions: options) else {
                throw Failure(String(localized: "Impossibile comprimere \(url.lastPathComponent)"))
            }
            return out
        }
    }

    /// One PDF per page: "name-1 (take-it-easy).pdf", …
    static func splitPDFs(_ urls: [URL]) throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            let doc = try pdf(url)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                let out = output(for: url, suffix: "-\(i + 1)", ext: "pdf")
                guard single.write(to: out) else { throw Failure(String(localized: "Impossibile salvare la pagina \(i + 1)")) }
                outs.append(out)
            }
        }
        return outs
    }

    /// Every page rendered at 2× (144 dpi): "name-1 (take-it-easy).png", …
    static func pdfToImages(_ urls: [URL], format: ImageFormat) throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            let doc = try pdf(url)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                var size = page.bounds(for: .mediaBox).size
                if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
                let thumb = page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
                guard let image = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let out = output(for: url, suffix: "-\(i + 1)", ext: format.ext)
                try write(image, to: out, type: format.type)
                outs.append(out)
            }
        }
        return outs
    }

    // MARK: - Helpers

    private static func source(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw Failure(String(localized: "Impossibile leggere \(url.lastPathComponent)"))
        }
        return src
    }

    private static func pdf(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw Failure(String(localized: "Impossibile leggere \(url.lastPathComponent)")) }
        guard !doc.isLocked else { throw Failure(String(localized: "\(url.lastPathComponent) è protetto da password")) }
        return doc
    }

    private static func longSide(_ src: CGImageSource) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        return max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    /// Full decode with EXIF orientation applied, optionally downscaled.
    private static func decode(_ src: CGImageSource, maxPixels: Int? = nil) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels ?? longSide(src),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw Failure(String(localized: "Immagine non leggibile"))
        }
        return image
    }

    /// Same type as the source keeps its extension ("JPG" stays "JPG"); otherwise the usual one.
    private static func ext(for type: UTType, source url: URL) -> String {
        if UTType(filenameExtension: url.pathExtension) == type { return url.pathExtension }
        return type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "jpg"
    }

    /// Keep the source type when ImageIO can write it, else JPEG.
    private static func writableType(of src: CGImageSource) -> UTType {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        if let id = CGImageSourceGetType(src) as String?, writable.contains(id), let type = UTType(id) { return type }
        return .jpeg
    }

    /// Re-encodes keeping metadata and orientation tag (no pixel transform needed).
    private static func reencode(_ url: URL, to out: URL, type: UTType, quality: Double) throws {
        let src = try source(url)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure(String(localized: "Formato non supportato"))
        }
        CGImageDestinationAddImageFromSource(dest, src, 0, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure(String(localized: "Impossibile salvare \(out.lastPathComponent)")) }
    }

    private static func write(_ image: CGImage, to out: URL, type: UTType, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure(String(localized: "Formato non supportato"))
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure(String(localized: "Impossibile salvare \(out.lastPathComponent)")) }
    }

    /// RGB bitmap, keeping the image's color space when it is RGB (e.g. Display P3), else sRGB.
    private static func bitmap(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    #if DEBUG
    static func selfCheck() {
        assert(outputName(base: "a", ext: "pdf") { _ in false } == "a (take-it-easy).pdf")
        let taken: Set = ["a (take-it-easy).pdf", "a (take-it-easy 2).pdf"]
        assert(outputName(base: "a", ext: "pdf") { taken.contains($0) } == "a (take-it-easy 3).pdf")
        let sorted = sortedByName([URL(fileURLWithPath: "/x/img10.png"), URL(fileURLWithPath: "/x/img2.png")])
        assert(sorted.map(\.lastPathComponent) == ["img2.png", "img10.png"])
        assert(baseName("a (take-it-easy)") == "a")
        assert(baseName("a (take-it-easy 12)") == "a")
        assert(baseName("a (take-it-easy) b") == "a (take-it-easy) b")
        assert(ext(for: .jpeg, source: URL(fileURLWithPath: "/x/a.JPG")) == "JPG")
        assert(ext(for: .jpeg, source: URL(fileURLWithPath: "/x/a.png")) == "jpg")
        assert(seriesNames(["jpg", "png", ""], base: "Foto") == ["Foto 1.jpg", "Foto 2.png", "Foto 3"])
        assert(seriesNames(Array(repeating: "jpg", count: 12), base: "F")[0] == "F 01.jpg")
    }
    #endif
}

private extension String {
    nonisolated func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
