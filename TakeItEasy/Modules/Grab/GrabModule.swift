import AppKit
import KeyboardShortcuts
import SwiftUI
import Vision

extension KeyboardShortcuts.Name {
    static let grab = Self("grab", default: .init(.two, modifiers: [.control, .shift]))
    static let grabLast = Self("grabLast", default: .init(.two, modifiers: [.control, .option, .shift]))
    static let grabColor = Self("grabColor", default: .init(.c, modifiers: [.control, .shift]))
}

/// Grab settings, stored in UserDefaults and shared between the settings view and the module.
private enum Keys {
    static let keepLineBreaks = "grab.keepLineBreaks"
    static let dehyphenate = "grab.dehyphenate"
}

final class GrabModule: TIEModule {
    let id = "grab"
    let name = String(localized: "Grab")
    let summary = String(localized: "Copia testo, QR e colori da qualsiasi punto dello schermo.")
    let symbol = "text.viewfinder"
    let requiredPermissions: [TIEPermission] = [.screenRecording]

    private var overlay: GrabOverlay?
    /// True while a screenshot is in flight: blocks a second capture that would orphan the first overlay's panels.
    private var capturing = false
    private var lastArea: GrabArea?

    init() {
        #if DEBUG
        GrabText.selfCheck()
        #endif
    }

    func start() throws {
        KeyboardShortcuts.removeHandler(for: .grab) // idempotent
        KeyboardShortcuts.removeHandler(for: .grabLast)
        KeyboardShortcuts.removeHandler(for: .grabColor)
        KeyboardShortcuts.onKeyUp(for: .grab) { [weak self] in self?.grab() }
        KeyboardShortcuts.onKeyUp(for: .grabLast) { [weak self] in self?.grabLast() }
        KeyboardShortcuts.onKeyUp(for: .grabColor) { Self.pickColor() }
    }

    /// System eyedropper (magnifier loupe); the picked color is copied as hex.
    private static func pickColor() {
        NSColorSampler().show { color in
            guard let rgb = color?.usingColorSpace(.sRGB) else { return } // Esc = nil
            let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                             Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
                Toast.show(String(localized: "\(hex) copiato"), symbol: "eyedropper.full")
            }
        }
    }

    func stop() {
        KeyboardShortcuts.removeHandler(for: .grab)
        KeyboardShortcuts.removeHandler(for: .grabLast)
        KeyboardShortcuts.removeHandler(for: .grabColor)
        overlay?.close()
        overlay = nil
    }

    func settingsView() -> AnyView { AnyView(GrabSettingsView()) }

    private func grab() {
        // Hotkey again while the overlay is open = cancel (escape hatch).
        if let overlay {
            overlay.close()
            self.overlay = nil
            return
        }
        guard !capturing else { return }
        capturing = true
        Task {
            defer { capturing = false }
            do {
                self.overlay = try await GrabOverlay.freezeScreens { selection in
                    // Strong capture is fine: close() drops this closure, breaking the cycle.
                    self.overlay = nil
                    guard let selection else { return }
                    self.lastArea = selection.area
                    self.recognize(selection.image, openLink: selection.openLink)
                }
            } catch {
                Self.showCaptureError(error)
            }
        }
    }

    private func grabLast() {
        guard overlay == nil, !capturing else { return }
        guard let lastArea else {
            Toast.show(String(localized: "Nessuna area precedente"), symbol: "rectangle.dashed")
            return
        }
        capturing = true
        Task {
            defer { capturing = false }
            do {
                guard let image = try await GrabOverlay.capture(lastArea) else {
                    Toast.show(String(localized: "Il display dell'ultima area non è collegato"),
                               symbol: "display.trianglebadge.exclamationmark")
                    return
                }
                recognize(image, openLink: false)
            } catch {
                Self.showCaptureError(error)
            }
        }
    }

    private func recognize(_ image: CGImage, openLink: Bool) {
        let defaults = UserDefaults.standard
        let keepLineBreaks = defaults.object(forKey: Keys.keepLineBreaks) as? Bool ?? true
        let dehyphenate = defaults.object(forKey: Keys.dehyphenate) as? Bool ?? true
        Task {
            let result = await Self.analyze(image)
            if let code = result.barcode {
                Self.copy(code)
                if openLink, let url = URL(string: code), url.scheme != nil {
                    NSWorkspace.shared.open(url)
                    Toast.show(String(localized: "Link aperto"), symbol: "safari")
                } else {
                    Toast.show(String(localized: "Codice copiato"), symbol: "qrcode")
                }
                return
            }
            let text = GrabText.format(result.lines, keepLineBreaks: keepLineBreaks, dehyphenate: dehyphenate)
            guard !text.isEmpty else {
                Toast.show(String(localized: "Nessun testo trovato"), symbol: "text.magnifyingglass")
                return
            }
            Self.copy(text)
            let words = text.split(whereSeparator: \.isWhitespace).count
            Toast.show(String(localized: "Copiato · \(words) parole"))
        }
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private static func showCaptureError(_ error: Error) {
        Toast.show(String(localized: "Cattura non riuscita: \(error.localizedDescription)"),
                   symbol: "exclamationmark.triangle.fill", duration: .seconds(3))
    }

    /// Runs Vision text + barcode recognition off the main thread.
    private nonisolated static func analyze(_ image: CGImage) async -> (lines: [String], barcode: String?) {
        await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
            let barcodes = VNDetectBarcodesRequest()
            try? VNImageRequestHandler(cgImage: image).perform([text, barcodes])
            let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let barcode = (barcodes.results ?? []).lazy.compactMap(\.payloadStringValue).first
            return (lines, barcode)
        }.value
    }
}

private struct GrabSettingsView: View {
    @AppStorage(Keys.keepLineBreaks) private var keepLineBreaks = true
    @AppStorage(Keys.dehyphenate) private var dehyphenate = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyboardShortcuts.Recorder(String(localized: "Seleziona area:"), name: .grab)
            KeyboardShortcuts.Recorder(String(localized: "Ripeti ultima area:"), name: .grabLast)
            KeyboardShortcuts.Recorder(String(localized: "Contagocce (copia colore HEX):"), name: .grabColor)
            Toggle("Mantieni gli a capo", isOn: $keepLineBreaks)
            Toggle("Rimuovi la sillabazione", isOn: $dehyphenate)
            Text("Con ⌘ premuto al rilascio, un QR con un link viene anche aperto.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
