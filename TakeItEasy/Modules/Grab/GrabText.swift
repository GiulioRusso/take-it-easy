import Foundation

/// Pure text post-processing for OCR output. Kept free of AppKit/Vision so it can be checked in isolation.
nonisolated enum GrabText {
    /// - keepLineBreaks: false joins all lines into one paragraph.
    /// - dehyphenate: "infor-" + "mazione" → "informazione" when the next line starts lowercase.
    static func format(_ lines: [String], keepLineBreaks: Bool, dehyphenate: Bool) -> String {
        var out = ""
        for (i, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            let next = lines.indices.contains(i + 1) ? lines[i + 1].trimmingCharacters(in: .whitespaces) : nil
            if dehyphenate, line.count > 1, line.hasSuffix("-"), let first = next?.first, first.isLowercase {
                line.removeLast()
                out += line // glue to the next line, no separator
                continue
            }
            out += line
            if next != nil { out += keepLineBreaks ? "\n" : " " }
        }
        return out
    }

    #if DEBUG
    static func selfCheck() {
        let lines = ["Una infor-", "mazione utile", "Fine-", "Riga"]
        assert(format(lines, keepLineBreaks: true, dehyphenate: true) == "Una informazione utile\nFine-\nRiga")
        assert(format(lines, keepLineBreaks: false, dehyphenate: true) == "Una informazione utile Fine- Riga")
        assert(format(lines, keepLineBreaks: true, dehyphenate: false) == "Una infor-\nmazione utile\nFine-\nRiga")
        assert(format(["a"], keepLineBreaks: false, dehyphenate: true) == "a")
        assert(format([], keepLineBreaks: true, dehyphenate: true) == "")
    }
    #endif
}
