import AudioToolbox
import CoreAudio
import Foundation

/// Per-process volume: a Core Audio process tap mutes the app's own output, a private aggregate
/// device (tap + current output device) reads the tapped audio, and an IOProc writes it back to the
/// output multiplied by `gain`. Destroying the tap restores the app's normal audio.
nonisolated final class ProcessTap: @unchecked Sendable {
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            String(localized: "Volume per app non disponibile (errore \(status)): controlla il permesso Registrazione audio di sistema.")
        }
    }

    /// Read on the real-time audio thread: a preallocated Float, written from the main thread.
    /// Aligned 32-bit stores are atomic on arm64/x86_64, so no lock (which the IOProc must never take).
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    var volume: Float {
        get { gain.pointee }
        set { gain.pointee = max(0, min(newValue, 1)) }
    }

    init(process: AudioObjectID, outputUID: String, volume: Float) throws {
        gain.initialize(to: volume)
        do { try build(process: process, outputUID: outputUID) } catch {
            invalidate()
            throw error
        }
    }

    deinit {
        invalidate()
        gain.deallocate()
    }

    private func build(process: AudioObjectID, outputUID: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure(status: status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "take-it-easy tap",
            kAudioAggregateDeviceUIDKey: "take-it-easy.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw Failure(status: status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, Self.ioBlock(gain: gain))
        guard status == noErr, let procID else { throw Failure(status: status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw Failure(status: status) }
    }

    /// Idempotent teardown.
    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Real-time: no allocation, no locks, no Swift runtime calls that may block.
    /// Copies the tap's input channels to the output channels with gain; output channels beyond the
    /// tap's (e.g. a multichannel interface) get silence. Assumes float32, the HAL's canonical format.
    private static func ioBlock(gain: UnsafeMutablePointer<Float>) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            let g = gain.pointee
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outputs = UnsafeMutableAudioBufferListPointer(output)
            var inputChannels = 0
            for buffer in inputs { inputChannels += Int(buffer.mNumberChannels) }
            var outputChannel = 0
            for out in outputs {
                let outChannels = Int(out.mNumberChannels)
                guard outChannels > 0, let dst = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let outFrames = Int(out.mDataByteSize) / (4 * outChannels)
                for c in 0..<outChannels {
                    let global = outputChannel + c
                    // Locate the input buffer + interleaved offset holding this channel.
                    var remaining = global, index = 0
                    while index < inputs.count, remaining >= Int(inputs[index].mNumberChannels) {
                        remaining -= Int(inputs[index].mNumberChannels)
                        index += 1
                    }
                    if global < inputChannels, index < inputs.count,
                       let src = inputs[index].mData?.assumingMemoryBound(to: Float.self) {
                        let inChannels = Int(inputs[index].mNumberChannels)
                        let frames = min(outFrames, Int(inputs[index].mDataByteSize) / (4 * inChannels))
                        for f in 0..<frames { dst[f * outChannels + c] = src[f * inChannels + remaining] * g }
                        for f in frames..<outFrames { dst[f * outChannels + c] = 0 }
                    } else {
                        for f in 0..<outFrames { dst[f * outChannels + c] = 0 }
                    }
                }
                outputChannel += outChannels
            }
        }
    }
}
