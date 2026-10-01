import Foundation
import IOBluetooth

struct BluetoothTarget: Equatable {
    var address: String
    var name: String
    var isAudio: Bool
    var connected: Bool
}

/// IOBluetooth connect and disconnect. Call on the main thread; the framework uses the main run loop.
enum BluetoothClient {
    static func targets() -> [BluetoothTarget] {
        var seen: Set<String> = []
        var found: [BluetoothTarget] = []
        for device in pairedDevices() {
            let address = BluetoothAddress.normalize(device.addressString ?? "")
            guard !address.isEmpty, !seen.contains(address) else { continue }
            seen.insert(address)
            let name = (device.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(BluetoothTarget(
                address: address,
                name: name.isEmpty ? address : name,
                isAudio: looksLikeAudio(name: name, classOfDevice: classOfDevice(device)),
                connected: device.isConnected()
            ))
        }
        return found
    }

    static func pullCandidates(targets: [BluetoothTarget], coreAudioNames: [String]) -> [PullCandidate] {
        let foldedNames = coreAudioNames.map { $0.lowercased() }
        let audio = targets.filter { target in
            if target.isAudio { return true }
            let name = target.name.lowercased()
            guard !name.isEmpty else { return false }
            return foldedNames.contains { existing in
                existing == name || existing.contains(name) || name.contains(existing)
            }
        }
        let candidates = audio.map { PullCandidate(address: $0.address, name: $0.name) }
        return candidates.sorted { lhs, rhs in
            let leftBose = lhs.name.range(of: "bose nc 700", options: .caseInsensitive) != nil
            let rightBose = rhs.name.range(of: "bose nc 700", options: .caseInsensitive) != nil
            if leftBose != rightBose { return leftBose }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func resolve(_ device: AudioDevice, targets: [BluetoothTarget]) -> BluetoothTarget? {
        guard device.isBluetooth else { return nil }
        let uid = CoreAudioSystem.deviceUID(device.id)
        if let address = BluetoothAddress.first(in: uid) ?? BluetoothAddress.first(in: device.name) {
            if let known = targets.first(where: { $0.address == address }) {
                return known
            }
            return BluetoothTarget(address: address, name: device.name, isAudio: true, connected: isConnected(address: address))
        }
        return targets.first { sameAudioName($0.name, device.name) }
    }

    static func match(_ candidate: PullCandidate, devices: [AudioDevice]) -> AudioDevice? {
        let address = candidate.address
        let colon = address.replacingOccurrences(of: "-", with: ":")
        for device in devices where device.isBluetooth {
            let uid = CoreAudioSystem.deviceUID(device.id).lowercased()
            if uid.contains(address) || uid.contains(colon) {
                return device
            }
        }
        return devices.first { device in
            device.isBluetooth && sameAudioName(device.name, candidate.name)
        }
    }

    @discardableResult
    static func close(address: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let device = device(forAddress: address) else {
            NSLog("%@", "AudioBar: no paired Bluetooth device \(address)")
            return false
        }
        if !device.isConnected() {
            return true
        }
        let status = device.closeConnection()
        if status != 0 {
            NSLog("%@", "AudioBar: closeConnection \(address) failed (\(status))")
            return false
        }
        return true
    }

    @discardableResult
    static func open(address: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let device = device(forAddress: address) else {
            NSLog("%@", "AudioBar: cannot open unknown Bluetooth device \(address)")
            return false
        }
        if device.isConnected() {
            return true
        }
        let status = device.openConnection()
        if status != 0 {
            NSLog("%@", "AudioBar: openConnection \(address) failed (\(status))")
            return false
        }
        return true
    }

    static func isConnected(address: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let device = device(forAddress: address) else { return false }
        return device.isConnected()
    }

    private static func device(forAddress address: String) -> IOBluetoothDevice? {
        let dashed = BluetoothAddress.dashedUpper(address)
        guard !dashed.isEmpty else { return nil }
        // `deviceWithAddressString:` is imported as this initializer. It returns nil for a bad address.
        return IOBluetoothDevice(addressString: dashed)
    }

    private static func pairedDevices() -> [IOBluetoothDevice] {
        let raw = IOBluetoothDevice.pairedDevices() ?? []
        var devices: [IOBluetoothDevice] = []
        for item in raw {
            if let device = item as? IOBluetoothDevice {
                devices.append(device)
            }
        }
        return devices
    }

    /// `classOfDevice` is an Objective-C getter. Calling it through the runtime avoids depending
    /// on whether the SDK imports it as a property or a method.
    private static func classOfDevice(_ device: IOBluetoothDevice) -> UInt32 {
        let selector = NSSelectorFromString("classOfDevice")
        guard device.responds(to: selector), let implementation = device.method(for: selector) else {
            return 0
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt32
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(device, selector)
    }

    /// "Bose NC 700 Headphones" and "Bose NC 700 Hands-Free" are the same headset.
    private static func sameAudioName(_ lhs: String, _ rhs: String) -> Bool {
        let left = foldedAudioName(lhs)
        let right = foldedAudioName(rhs)
        guard left.count > 3, right.count > 3 else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private static func foldedAudioName(_ name: String) -> String {
        var folded = name.lowercased()
        let suffixes = [" headphones", " headset", " hands-free", " hands free", " microphone"]
        var trimmed = true
        while trimmed {
            trimmed = false
            for suffix in suffixes where folded.hasSuffix(suffix) {
                folded.removeLast(suffix.count)
                trimmed = true
            }
        }
        return folded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeAudio(name: String, classOfDevice: UInt32) -> Bool {
        let major = (classOfDevice >> 8) & 0x1F
        if major == 0x04 { return true }
        let audioService = classOfDevice & (1 << 21) != 0
        let renderingService = classOfDevice & (1 << 18) != 0
        if audioService || renderingService { return true }
        let folded = name.lowercased()
        let hints = [
            "bose", "headphone", "headset", "airpod", "speaker", "beats", "buds",
            "soundlink", "jabra", "sennheiser", "wh-", "qc", "audio",
        ]
        return hints.contains { folded.contains($0) }
    }
}
