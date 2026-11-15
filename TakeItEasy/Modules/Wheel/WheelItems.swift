import AppKit
import UniformTypeIdentifiers

/// Builds the wheel for a Finder selection: 8 fixed slots (stable positions = muscle memory);
/// slots that don't fit the selection are dimmed. Sub-rings adapt to the file type.
enum WheelItems {
    enum Kind { case none, images, pdfs, videos, audio, mixed }

    /// Every selected item must be of the same kind, otherwise most slots are dimmed.
    static func kind(of urls: [URL]) -> Kind {
        guard !urls.isEmpty else { return .none }
        let types = urls.map { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType }
        func all(_ t: UTType) -> Bool { types.allSatisfy { $0?.conforms(to: t) == true } }
        if all(.image) { return .images }
        if all(.pdf) { return .pdfs }
        if all(.movie) { return .videos }
        if all(.audio) { return .audio }
        return .mixed
    }

    static func build(for selection: FinderSelection) -> [WheelItem] {
        let urls = selection.items
        let kind = kind(of: urls)
        let any = !urls.isEmpty
        typealias F = FileActions
        typealias M = MediaActions

        let convert: [WheelItem] = switch kind {
        case .images: [
            WheelItem(title: "JPEG", symbol: "photo", action: run(urls) { try F.convert(urls, to: .jpeg) }),
            WheelItem(title: "PNG", symbol: "photo", action: run(urls) { try F.convert(urls, to: .png) }),
            WheelItem(title: "HEIC", symbol: "photo", action: run(urls) { try F.convert(urls, to: .heic) }),
        ]
        case .pdfs: [
            WheelItem(title: "JPEG", symbol: "photo", action: run(urls) { try F.pdfToImages(urls, format: .jpeg) }),
            WheelItem(title: "PNG", symbol: "photo", action: run(urls) { try F.pdfToImages(urls, format: .png) }),
            WheelItem(title: String(localized: "Pagine"), symbol: "doc.on.doc", action: run(urls) { try F.splitPDFs(urls) }),
        ]
        case .videos: [
            WheelItem(title: "MP4", symbol: "film", action: run(urls) { try await M.toMP4(urls) }),
            WheelItem(title: "GIF", symbol: "photo.stack", action: run(urls) { try await M.toGIF(urls) }),
            WheelItem(title: String(localized: "Audio"), symbol: "waveform", action: run(urls) { try await M.toM4A(urls) }),
        ]
        case .audio: [
            WheelItem(title: "M4A", symbol: "waveform", action: run(urls) { try await M.toM4A(urls) }),
        ]
        case .none, .mixed: []
        }

        let recipes = kind == .images ? Recipe.saved.prefix(8).map { recipe in
            WheelItem(title: recipe.name, symbol: recipe.kind == .a4PDF ? "doc.richtext" : "wand.and.stars",
                      action: run(urls, recipe.work(urls)))
        } : []

        return [
            WheelItem(title: kind == .pdfs ? String(localized: "Unisci PDF") : String(localized: "→ PDF"),
                      symbol: "doc.richtext", isEnabled: kind == .images || (kind == .pdfs && urls.count > 1),
                      action: run(urls) { kind == .pdfs ? try F.mergePDFs(urls) : try F.imagesToPDF(urls) }),
            WheelItem(title: String(localized: "Converti"), symbol: "arrow.triangle.2.circlepath",
                      children: convert, isEnabled: !convert.isEmpty),
            WheelItem(title: String(localized: "Comprimi"), symbol: "arrow.down.right.and.arrow.up.left",
                      isEnabled: [.images, .pdfs, .videos].contains(kind),
                      action: run(urls, showSavings: true) {
                          switch kind {
                          case .pdfs: try F.compressPDFs(urls)
                          case .videos: try await M.compressVideo(urls)
                          default: try F.compressImages(urls)
                          }
                      }),
            WheelItem(title: String(localized: "Ridimensiona"), symbol: "arrow.up.left.and.down.right.magnifyingglass", children: [
                WheelItem(title: "50%", symbol: "divide", action: run(urls) { try F.resize(urls, factor: 0.5) }),
                WheelItem(title: "1920 px", symbol: "rectangle", action: run(urls) { try F.resize(urls, maxPixels: 1920) }),
                WheelItem(title: "1080 px", symbol: "rectangle.portrait", action: run(urls) { try F.resize(urls, maxPixels: 1080) }),
            ], isEnabled: kind == .images),
            WheelItem(title: String(localized: "Ruota"), symbol: "rotate.right", children: [
                WheelItem(title: String(localized: "Sinistra"), symbol: "rotate.left",
                          action: run(urls) { try F.rotate(urls, clockwise: false) }),
                WheelItem(title: String(localized: "Destra"), symbol: "rotate.right",
                          action: run(urls) { try F.rotate(urls, clockwise: true) }),
            ], isEnabled: kind == .images),
            WheelItem(title: String(localized: "Ricette"), symbol: "list.star", children: recipes, isEnabled: !recipes.isEmpty),
            WheelItem(title: kind == .audio ? String(localized: "Taglia silenzi") : String(localized: "Rimuovi metadati"),
                      symbol: kind == .audio ? "waveform.badge.minus" : "eye.slash",
                      isEnabled: kind == .images || kind == .audio,
                      action: run(urls) { kind == .audio ? try await M.trimSilences(urls) : try F.stripMetadata(urls) }),
            WheelItem(title: String(localized: "Altro"), symbol: "ellipsis.circle", children: [
                WheelItem(title: String(localized: "Copia percorso"), symbol: "link", isEnabled: any) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                    Toast.show(String(localized: "Percorso copiato"))
                },
                WheelItem(title: "Zip", symbol: "doc.zipper", isEnabled: any, action: run(urls, reveal: true) { try F.zip(urls) }),
                WheelItem(title: String(localized: "Rinomina"), symbol: "character.cursor.ibeam", isEnabled: any) {
                    guard let base = askBaseName(count: urls.count) else { return }
                    run(urls, reveal: true) { try F.rename(urls, base: base) }()
                },
                WheelItem(title: String(localized: "Nuovo file"), symbol: "doc.badge.plus",
                          action: run([], reveal: true) { try F.newTextFile(in: selection.folder) }),
                WheelItem(title: String(localized: "Terminale"), symbol: "terminal") {
                    // A single selected folder opens itself, anything else opens the window's folder.
                    let isFolder = urls.count == 1 && (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    NSWorkspace.shared.open([isFolder ? urls[0] : selection.folder],
                                            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
                },
                WheelItem(title: String(localized: "File nascosti"), symbol: "eye") {
                    // Finder's own ⌘⇧. toggle (Finder is frontmost: the wheel only opens over it).
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: nil, virtualKey: 47, keyDown: down)
                        event?.flags = [.maskCommand, .maskShift]
                        event?.post(tap: .cghidEventTap)
                    }
                },
            ]),
        ]
    }

    /// Runs `work` off the main thread with a progress toast, then reports the result.
    static func run(_ urls: [URL], showSavings: Bool = false, reveal: Bool = false,
                    _ work: @escaping @Sendable () async throws -> [URL]) -> () -> Void {
        {
            Toast.show(String(localized: "Elaboro…"), symbol: "gearshape", duration: .seconds(3600))
            Task {
                do {
                    let outputs = try await Task.detached(priority: .userInitiated) { try await work() }.value
                    if showSavings, let saved = savings(from: urls, to: outputs) {
                        Toast.show(String(localized: "Fatto · \(outputs.count) file · −\(saved)%"))
                    } else {
                        Toast.show(String(localized: "Fatto · \(outputs.count) file"))
                    }
                    if reveal { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                } catch {
                    Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", duration: .seconds(4))
                }
            }
        }
    }

    /// Size reduction in percent, or nil if the outputs aren't smaller.
    private static func savings(from inputs: [URL], to outputs: [URL]) -> Int? {
        func total(_ urls: [URL]) -> Int {
            urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        let before = total(inputs), after = total(outputs)
        guard before > 0, after < before else { return nil }
        return Int((1 - Double(after) / Double(before)) * 100)
    }

    // ponytail: modal NSAlert (activates the app) instead of an inline field in the wheel; fine for a rare action.
    private static func askBaseName(count: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rinomina \(count) elementi")
        alert.informativeText = String(localized: "Diventeranno «Nome 1», «Nome 2», … in ordine di nome.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Nome")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rinomina"))
        alert.addButton(withTitle: String(localized: "Annulla"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
