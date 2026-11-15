import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Video/audio operations behind the wheel. Async, meant to run off the main thread.
/// Outputs follow the same naming as FileActions and never overwrite.
nonisolated enum MediaActions {
    typealias Failure = FileActions.Failure

    /// H.264 MP4 at the source resolution.
    static func toMP4(_ urls: [URL]) async throws -> [URL] {
        try await export(urls, preset: AVAssetExportPresetHighestQuality, type: .mp4, ext: "mp4")
    }

    /// HEVC, at most 1080p.
    static func compressVideo(_ urls: [URL]) async throws -> [URL] {
        try await export(urls, preset: AVAssetExportPresetHEVC1920x1080, type: .mp4, ext: "mp4")
    }

    /// AAC in M4A; works for both video (extracts the soundtrack) and audio files.
    static func toM4A(_ urls: [URL]) async throws -> [URL] {
        for url in urls where try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty {
            throw Failure(String(localized: "\(url.lastPathComponent) non contiene audio"))
        }
        return try await export(urls, preset: AVAssetExportPresetAppleM4A, type: .m4a, ext: "m4a")
    }

    private static func export(_ urls: [URL], preset: String, type: AVFileType, ext: String) async throws -> [URL] {
        var outs: [URL] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw Failure(String(localized: "Formato non supportato: \(url.lastPathComponent)"))
            }
            let out = FileActions.output(for: url, ext: ext)
            session.outputURL = out
            session.outputFileType = type
            session.shouldOptimizeForNetworkUse = true
            // ponytail: callback API because the async `export(to:as:)` needs macOS 15.
            nonisolated(unsafe) let unsafeSession = session
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                unsafeSession.exportAsynchronously {
                    if unsafeSession.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: unsafeSession.error
                            ?? Failure(String(localized: "Esportazione non riuscita: \(url.lastPathComponent)")))
                    }
                }
            }
            outs.append(out)
        }
        return outs
    }

    // ponytail: 10 fps, 480 px, first 60 s; make these options if someone needs longer/bigger GIFs.
    static func toGIF(_ urls: [URL]) async throws -> [URL] {
        let fps = 10.0
        var outs: [URL] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let frames = max(1, min(Int(duration * fps), 600))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance

            let out = FileActions.output(for: url, ext: "gif")
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
                throw Failure(String(localized: "Impossibile creare la GIF"))
            }
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
            for i in 0..<frames {
                let (image, _) = try await generator.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
                CGImageDestinationAddImage(dest, image, frameProperties)
            }
            guard CGImageDestinationFinalize(dest) else { throw Failure(String(localized: "Impossibile creare la GIF")) }
            outs.append(out)
        }
        return outs
    }

    // MARK: - Silence trimming

    static let windowSeconds = 0.01
    static let silenceThreshold: Float = 0.0056 // ≈ −45 dBFS
    static let minSilence = 60                  // windows (0.6 s): shorter pauses are left alone
    static let keptSilence = 30                 // windows (0.3 s): what remains of a long pause

    /// Long pauses shortened to 0.3 s, written as M4A. Two passes over the file in chunks,
    /// so memory stays flat even for hour-long recordings.
    static func trimSilences(_ urls: [URL]) async throws -> [URL] {
        try urls.map { url in
            let input = try AVAudioFile(forReading: url)
            let format = input.processingFormat
            let window = AVAudioFrameCount(format.sampleRate * windowSeconds)
            let chunk = window * 1000
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw Failure(String(localized: "Audio non leggibile"))
            }

            // Pass 1: one silent/loud flag per window.
            var silent: [Bool] = []
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
                forEachWindow(buffer, window) { start, count in
                    silent.append(peak(buffer, start, count) < silenceThreshold)
                }
            }
            let keep = keepMask(silent: silent, minRun: minSilence, keep: keptSilence)
            guard keep.contains(false) else { throw Failure(String(localized: "Nessun silenzio da tagliare")) }

            // Pass 2: copy only kept windows.
            let out = FileActions.output(for: url, ext: "m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 192_000,
            ]
            let output = try AVAudioFile(forWriting: out, settings: settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let kept = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw Failure(String(localized: "Audio non leggibile"))
            }
            input.framePosition = 0
            var index = 0
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
                kept.frameLength = 0
                forEachWindow(buffer, window) { start, count in
                    defer { index += 1 }
                    guard index < keep.count, keep[index] else { return }
                    append(buffer, start, count, to: kept)
                }
                if kept.frameLength > 0 { try output.write(from: kept) }
            }
            return out
        }
    }

    /// For each silent run of at least `minRun` windows, keep only `keep` windows (half at each end).
    static func keepMask(silent: [Bool], minRun: Int, keep: Int) -> [Bool] {
        var mask = Array(repeating: true, count: silent.count)
        var i = 0
        while i < silent.count {
            guard silent[i] else { i += 1; continue }
            var end = i
            while end < silent.count, silent[end] { end += 1 }
            if end - i >= minRun {
                let head = keep / 2, tail = keep - keep / 2
                for j in (i + head)..<(end - tail) { mask[j] = false }
            }
            i = end
        }
        return mask
    }

    private static func forEachWindow(_ buffer: AVAudioPCMBuffer, _ window: AVAudioFrameCount,
                                      _ body: (Int, Int) -> Void) {
        var start = 0
        let length = Int(buffer.frameLength)
        while start < length {
            body(start, min(Int(window), length - start))
            start += Int(window)
        }
    }

    /// Max absolute sample over all channels (float formats only; AVAudioFile's processing format is float32).
    private static func peak(_ buffer: AVAudioPCMBuffer, _ start: Int, _ count: Int) -> Float {
        guard let data = buffer.floatChannelData else { return 1 }
        var peak: Float = 0
        let stride = buffer.stride
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in start..<(start + count) { peak = max(peak, abs(data[channel][frame * stride])) }
        }
        return peak
    }

    private static func append(_ source: AVAudioPCMBuffer, _ start: Int, _ count: Int, to dest: AVAudioPCMBuffer) {
        guard let from = source.floatChannelData, let to = dest.floatChannelData else { return }
        let offset = Int(dest.frameLength)
        let channels = source.format.isInterleaved ? 1 : Int(source.format.channelCount)
        let samplesPerFrame = source.stride
        for channel in 0..<channels {
            (to[channel] + offset * samplesPerFrame)
                .update(from: from[channel] + start * samplesPerFrame, count: count * samplesPerFrame)
        }
        dest.frameLength += AVAudioFrameCount(count)
    }

    #if DEBUG
    static func selfCheck() {
        let s = [false] + Array(repeating: true, count: 10) + [false, true, true, false]
        let m = keepMask(silent: s, minRun: 5, keep: 4)
        // Long run (10): keep 2 at each end, drop the 6 in the middle. Short run (2): untouched.
        assert(m == [true, true, true] + Array(repeating: false, count: 6) + [true, true, true, true, true, true])
        assert(keepMask(silent: [], minRun: 5, keep: 4) == [])
        assert(keepMask(silent: Array(repeating: true, count: 5), minRun: 5, keep: 4) == [true, true, false, true, true])
    }
    #endif
}
