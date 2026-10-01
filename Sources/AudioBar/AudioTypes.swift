import CoreAudio
import Foundation

/// Output is the left column, input is the right. Scope selects which HAL streams and controls apply.
enum AudioDirection {
    case output
    case input

    var scope: AudioObjectPropertyScope {
        switch self {
        case .output:
            return kAudioDevicePropertyScopeOutput
        case .input:
            return kAudioDevicePropertyScopeInput
        }
    }
}

struct AudioDevice: Equatable {
    var id: AudioDeviceID
    var name: String
    var transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// A paired Bluetooth audio device Pull can move onto this Mac.
struct PullCandidate: Equatable {
    var address: String
    var name: String
}

/// One installed CoreAudio listener. All fields are four-byte IDs, so this is cheap to diff.
struct AudioPropertyToken: Hashable {
    var objectID: AudioObjectID
    var selector: AudioObjectPropertySelector
    var scope: AudioObjectPropertyScope
    var element: AudioObjectPropertyElement
}

struct AudioSnapshot: Equatable {
    var outputs: [AudioDevice] = []
    var inputs: [AudioDevice] = []
    var defaultOutputID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    var defaultInputID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    var outputVolume: Float?
    var outputVolumeEnabled = false
    var balance: Float?
    var balanceEnabled = false
    var outputMuted = false
    var outputMuteEnabled = false
    var inputVolume: Float?
    var inputVolumeEnabled = false
    var launchAtLogin = false
    var launchApprovalRequired = false
    var loginMessage: String?
    /// Result of the last Disconnect or Pull. Empty until the first attempt.
    var statusText = ""
    var pullCandidates: [PullCandidate] = []
    /// Last Bluetooth default, otherwise a paired device named like "Bose NC 700".
    var preferredPullAddress = ""
    /// When more than one Bluetooth device is listed, each of these rows disconnects itself.
    var perRowDisconnectIDs: Set<AudioDeviceID> = []
    var showColumnDisconnect = true
    var columnDisconnectEnabled = false
    var pullEnabled = false
    var pullInProgress = false

    /// Menu bar icon. Zero and mute share the slashed speaker, matching the system volume item.
    var statusSymbol: String {
        if outputMuted {
            return "speaker.slash.fill"
        }
        guard let outputVolume else {
            return "speaker.wave.2.fill"
        }
        if outputVolume <= 0.001 {
            return "speaker.slash.fill"
        }
        if outputVolume < 0.33 {
            return "speaker.wave.1.fill"
        }
        if outputVolume < 0.66 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }

    var statusToolTip: String {
        if outputMuted {
            return "AudioBar — Muted"
        }
        guard let outputVolume else {
            return "AudioBar"
        }
        let percent = Int((outputVolume * 100).rounded())
        return "AudioBar — \(percent)%"
    }
}

enum TransportInfo {
    static func label(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeHDMI:
            return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort:
            return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay:
            return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt:
            return "Thunderbolt"
        case kAudioDeviceTransportTypePCI:
            return "PCI"
        case kAudioDeviceTransportTypeFireWire:
            return "FireWire"
        case kAudioDeviceTransportTypeAVB:
            return "AVB"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return "Aggregate"
        case kAudioDeviceTransportTypeVirtual:
            return "Virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "Continuity"
        default:
            return "Audio"
        }
    }

    static func symbol(transport: UInt32, direction: AudioDirection) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeThunderbolt:
            return "bolt.horizontal"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return "square.stack.3d.up"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeAVB:
            return direction == .input ? "mic" : "hifispeaker"
        case kAudioDeviceTransportTypeBuiltIn:
            return direction == .input ? "mic" : "speaker.wave.2"
        default:
            return direction == .input ? "mic" : "speaker.wave.2"
        }
    }
}

/// Balance math for devices that only expose per-channel scalars.
/// Pan is 0 (full left) ... 0.5 (center) ... 1 (full right), same as Sound settings.
enum StereoMix {
    static func channelGains(volume: Float, pan: Float) -> (left: Float, right: Float) {
        let volume = clampUnit(volume)
        let pan = clampUnit(pan)
        if pan <= 0.5 {
            let right = pan == 0 ? 0 : volume * (pan / 0.5)
            return (volume, right)
        }
        let left = volume * ((1 - pan) / 0.5)
        return (left, volume)
    }

    static func volumeAndPan(left: Float, right: Float) -> (volume: Float, pan: Float) {
        let left = clampUnit(left)
        let right = clampUnit(right)
        let volume = max(left, right)
        if volume <= 0.000_1 {
            return (0, 0.5)
        }
        if abs(left - right) <= 0.001 {
            return (volume, 0.5)
        }
        if left >= right {
            return (left, 0.5 * (right / left))
        }
        return (right, 1 - 0.5 * (left / right))
    }
}

func clampUnit(_ value: Float) -> Float {
    min(max(value, 0), 1)
}
