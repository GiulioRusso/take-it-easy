import SwiftUI

/// A saved preset that shows up as an item in the wheel's "Ricette" ring.
/// ponytail: two kinds cover the plan's examples ("PDF A4 < 5 MB", "Ridimensiona 1080px"); add kinds when asked.
nonisolated struct Recipe: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable {
        case a4PDF, resize

        var label: String {
            switch self {
            case .a4PDF: String(localized: "Immagini → PDF A4")
            case .resize: String(localized: "Ridimensiona immagini")
            }
        }
    }

    enum Format: String, Codable, CaseIterable {
        case original, jpeg, png, heic

        var label: String {
            switch self {
            case .original: String(localized: "Come l'originale")
            case .jpeg: "JPEG"
            case .png: "PNG"
            case .heic: "HEIC"
            }
        }

        var imageFormat: FileActions.ImageFormat? {
            switch self {
            case .original: nil
            case .jpeg: .jpeg
            case .png: .png
            case .heic: .heic
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// a4PDF: size limit in MB, 0 = none.
    var maxMB: Double = 0
    /// resize: long side in pixels.
    var maxPixels = 1080
    var format: Format = .original

    /// Recipes only work on images for now.
    func work(_ urls: [URL]) -> @Sendable () async throws -> [URL] {
        let recipe = self
        return {
            switch recipe.kind {
            case .a4PDF:
                try FileActions.imagesToA4PDF(urls, maxBytes: recipe.maxMB > 0 ? Int(recipe.maxMB * 1_000_000) : nil)
            case .resize:
                try FileActions.resize(urls, maxPixels: max(recipe.maxPixels, 1), format: recipe.format.imageFormat)
            }
        }
    }

    static let defaultsKey = "wheel.recipes"

    static var saved: [Recipe] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return defaults }
            return (try? JSONDecoder().decode([Recipe].self, from: data)) ?? defaults
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey) }
    }

    /// The two examples from the plan, so the ring isn't empty on first use.
    static let defaults = [
        Recipe(name: String(localized: "PDF A4 < 5 MB"), kind: .a4PDF, maxMB: 5),
        Recipe(name: String(localized: "Ridimensiona 1080 px"), kind: .resize, maxPixels: 1080),
    ]
}

struct RecipesEditor: View {
    @State private var recipes = Recipe.saved
    private static let maxRecipes = 8 // what fits in one sub-ring

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ricette").font(.headline).padding(.top, 6)
            ForEach($recipes) { $recipe in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Nome", text: $recipe.name)
                        Button(role: .destructive) {
                            recipes.removeAll { $0.id == recipe.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                    Picker("Tipo", selection: $recipe.kind) {
                        ForEach(Recipe.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    switch recipe.kind {
                    case .a4PDF:
                        TextField("Limite MB (0 = nessuno)", value: $recipe.maxMB, format: .number)
                    case .resize:
                        TextField("Lato lungo (px)", value: $recipe.maxPixels, format: .number)
                        Picker("Formato", selection: $recipe.format) {
                            ForEach(Recipe.Format.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            Button("Aggiungi ricetta") {
                recipes.append(Recipe(name: String(localized: "Nuova ricetta"), kind: .resize))
            }
            .disabled(recipes.count >= Self.maxRecipes)
        }
        .onChange(of: recipes) { _, new in Recipe.saved = new }
    }
}
