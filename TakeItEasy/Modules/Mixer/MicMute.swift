import AppKit
import CoreAudio

/// Global microphone mute on the default input device, with push-to-talk and a red menu bar mic while muted.
/// `restore()` unmutes whatever we muted (called from the module's stop()).
@Observable
final class MicMute {
    private(set) var isMuted = false
    /// Device we muted, and its volume when muting had to go through "volume 0".
    private var muted: (device: AudioDeviceID, volume: Float?)?
    private var indicator: StatusItem?
    /// Push-to-talk is holding the mic open.
    private var talking = false

    func refresh() {
        let device = CA.defaultInput
        isMuted = device != 0 && CA.isInputMuted(device)
    }

    func toggle() { set(!isMuted) }

    func set(_ mute: Bool, announce: Bool = true) {
        if mute {
            let device = CA.defaultInput
            guard device != 0 else {
                return Toast.show(String(localized: "Nessun microfono"), symbol: "mic.slash")
            }
            if CA.setInputMuted(device, true) {
                muted = (device, nil)
            } else {
                muted = (device, CA.inputVolume(device))
                CA.setInputVolume(device, 0)
            }
        } else if let muted {
            if let volume = muted.volume { CA.setInputVolume(muted.device, volume) } else { CA.setInputMuted(muted.device, false) }
            self.muted = nil
        } else {
            CA.setInputMuted(CA.defaultInput, false) // muted by someone else (System Settings, another app)
        }
        isMuted = mute
        if mute, indicator == nil {
            indicator = StatusItem(symbol: "mic.slash.fill", accessibilityName: String(localized: "Microfono spento"), tint: .systemRed) { [weak self] in
                self?.set(false)
            }
        } else if !mute {
            indicator?.remove()
            indicator = nil
        }
        if announce {
            Toast.show(mute ? String(localized: "Microfono spento") : String(localized: "Microfono acceso"),
                       symbol: mute ? "mic.slash.fill" : "mic.fill")
        }
    }

    func pushToTalk(_ down: Bool) {
        if down, isMuted {
            talking = true
            set(false, announce: false)
        } else if !down, talking {
            talking = false
            set(true, announce: false)
        }
    }

    func restore() {
        talking = false
        if muted != nil { set(false, announce: false) }
    }
}
