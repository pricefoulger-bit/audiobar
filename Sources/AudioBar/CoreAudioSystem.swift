import AudioToolbox
import CoreAudio
import Foundation

/// Thin wrapper over `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData`.
///
/// Volume prefers `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (what Sound settings
/// and the volume keys use). Devices without it fall back to `kAudioDevicePropertyVolumeScalar`
/// on the main element, then to per-channel scalars. Balance prefers virtual main balance, then
/// `kAudioDevicePropertyStereoPan`, then per-channel scalars. Nothing here starts IO, so listing
/// devices and reading gain does not prompt for microphone access.
enum CoreAudioSystem {
    private static let mainElement = kAudioObjectPropertyElementMain

    // MARK: - Defaults

    static func defaultOutputDevice() -> AudioDeviceID {
        readDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputDevice() -> AudioDeviceID {
        readDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    static func setDefaultOutput(_ deviceID: AudioDeviceID) {
        let status = writeDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice, deviceID: deviceID)
        guard status == noErr else {
            logFailure("set default output", status)
            return
        }
        // Alert sounds follow the system output device. Some endpoints cannot be the system
        // default; the main output switch still stands if this second write fails.
        if canBeSystemOutput(deviceID) {
            let systemStatus = writeDeviceID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice, deviceID: deviceID)
            if systemStatus != noErr {
                logFailure("set system output", systemStatus)
            }
        }
    }

    static func setDefaultInput(_ deviceID: AudioDeviceID) {
        let status = writeDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice, deviceID: deviceID)
        if status != noErr {
            logFailure("set default input", status)
        }
    }

    /// Stable id. Bluetooth endpoints often embed the device address here (`aa-bb-cc-dd-ee-ff`).
    static func deviceUID(_ deviceID: AudioDeviceID) -> String {
        guard deviceID != kAudioObjectUnknown else { return "" }
        return readString(kAudioDevicePropertyDeviceUID, objectID: deviceID) ?? ""
    }

    // MARK: - Device lists

    static func devices(direction: AudioDirection) -> [AudioDevice] {
        let currentDefault = direction == .output ? defaultOutputDevice() : defaultInputDevice()
        var listed: [AudioDevice] = []
        listed.reserveCapacity(8)
        for id in allDeviceIDs() {
            if let device = makeDevice(id, direction: direction, currentDefault: currentDefault) {
                listed.append(device)
            }
        }
        return disambiguate(sortDevices(listed))
    }

    // MARK: - Controls

    static func outputControls(deviceID: AudioDeviceID) -> (volume: Float?, volumeWritable: Bool, balance: Float?, balanceWritable: Bool, muted: Bool, muteWritable: Bool) {
        guard deviceID != kAudioObjectUnknown else {
            return (nil, false, nil, false, false, false)
        }
        let scope = kAudioDevicePropertyScopeOutput
        let volumeBinding = volumeBinding(deviceID: deviceID, scope: scope)
        let balanceBinding = balanceBinding(deviceID: deviceID, scope: scope, volume: volumeBinding)
        let mute = muteState(deviceID: deviceID, scope: scope)
        return (
            readVolume(deviceID: deviceID, scope: scope, binding: volumeBinding),
            volumeBinding.writable,
            readBalance(deviceID: deviceID, scope: scope, binding: balanceBinding),
            balanceBinding.writable,
            mute.value,
            mute.writable
        )
    }

    static func inputControls(deviceID: AudioDeviceID) -> (volume: Float?, volumeWritable: Bool) {
        guard deviceID != kAudioObjectUnknown else {
            return (nil, false)
        }
        let scope = kAudioDevicePropertyScopeInput
        let binding = volumeBinding(deviceID: deviceID, scope: scope)
        return (readVolume(deviceID: deviceID, scope: scope, binding: binding), binding.writable)
    }

    static func setOutputVolume(_ volume: Float, balance: Float, deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }
        let scope = kAudioDevicePropertyScopeOutput
        let binding = volumeBinding(deviceID: deviceID, scope: scope)
        guard binding.writable else { return }
        switch binding.kind {
        case .virtualMain:
            writeFloat(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, element: mainElement, value: volume, deviceID: deviceID)
        case .masterScalar:
            writeFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: mainElement, value: volume, deviceID: deviceID)
        case .stereo(let left, let right):
            let gains = StereoMix.channelGains(volume: volume, pan: balance)
            writeFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: left, value: gains.left, deviceID: deviceID)
            writeFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: right, value: gains.right, deviceID: deviceID)
        case .mono(let element):
            writeFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: element, value: volume, deviceID: deviceID)
        case .none:
            break
        }
    }

    static func setBalance(_ pan: Float, deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }
        let scope = kAudioDevicePropertyScopeOutput
        let volume = volumeBinding(deviceID: deviceID, scope: scope)
        let binding = balanceBinding(deviceID: deviceID, scope: scope, volume: volume)
        guard binding.writable else { return }
        switch binding.kind {
        case .virtualMain:
            writeFloat(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope: scope, element: mainElement, value: pan, deviceID: deviceID)
        case .stereoPan:
            writeFloat(kAudioDevicePropertyStereoPan, scope: scope, element: mainElement, value: pan, deviceID: deviceID)
        case .channels(let left, let right):
            let level = readVolume(deviceID: deviceID, scope: scope, binding: volume) ?? 1
            let gains = StereoMix.channelGains(volume: level, pan: pan)
            writeFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: left, value: gains.left, deviceID: deviceID)
            writeFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: right, value: gains.right, deviceID: deviceID)
        case .none:
            break
        }
    }

    static func setOutputMuted(_ muted: Bool, deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }
        let state = muteState(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
        guard state.writable else { return }
        let value: UInt32 = muted ? 1 : 0
        for element in state.elements {
            writeUInt32(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element, value: value, deviceID: deviceID)
        }
    }

    static func setInputVolume(_ volume: Float, deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }
        let scope = kAudioDevicePropertyScopeInput
        let binding = volumeBinding(deviceID: deviceID, scope: scope)
        guard binding.writable else { return }
        switch binding.kind {
        case .virtualMain:
            writeFloat(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, element: mainElement, value: volume, deviceID: deviceID)
        case .masterScalar:
            writeFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: mainElement, value: volume, deviceID: deviceID)
        case .stereo(let left, let right):
            writeFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: left, value: volume, deviceID: deviceID)
            writeFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: right, value: volume, deviceID: deviceID)
        case .mono(let element):
            writeFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: element, value: volume, deviceID: deviceID)
        case .none:
            break
        }
    }

    // MARK: - Listeners

    static func observationTokens(
        outputs: [AudioDevice],
        inputs: [AudioDevice],
        defaultOutput: AudioDeviceID,
        defaultInput: AudioDeviceID
    ) -> Set<AudioPropertyToken> {
        var tokens = Set<AudioPropertyToken>()
        let system = AudioObjectID(kAudioObjectSystemObject)
        tokens.insert(token(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, mainElement))
        tokens.insert(token(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, mainElement))
        tokens.insert(token(system, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, mainElement))
        tokens.insert(token(system, kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, mainElement))

        for device in outputs {
            tokens.insert(token(device.id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, mainElement))
            consider(device.id, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, mainElement, into: &tokens)
        }
        for device in inputs {
            tokens.insert(token(device.id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, mainElement))
            consider(device.id, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeInput, mainElement, into: &tokens)
        }
        if defaultOutput != kAudioObjectUnknown {
            controlTokens(deviceID: defaultOutput, scope: kAudioDevicePropertyScopeOutput, into: &tokens)
        }
        if defaultInput != kAudioObjectUnknown {
            controlTokens(deviceID: defaultInput, scope: kAudioDevicePropertyScopeInput, into: &tokens)
        }
        return tokens
    }

    // MARK: - Listing helpers

    private static func makeDevice(_ id: AudioDeviceID, direction: AudioDirection, currentDefault: AudioDeviceID) -> AudioDevice? {
        guard streamCount(id, scope: direction.scope) > 0 else { return nil }
        let isCurrent = id == currentDefault && currentDefault != kAudioObjectUnknown
        if !isCurrent {
            if isHidden(id) || isSubDevice(id) || isAutoAggregate(id) || !isAlive(id) || !canBeDefault(id, scope: direction.scope) {
                return nil
            }
        }
        let transport = readUInt32(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal, element: mainElement, objectID: id) ?? 0
        let name = deviceName(id)
        guard !name.isEmpty else { return nil }
        return AudioDevice(id: id, name: name, transport: transport)
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        if let name = readString(kAudioObjectPropertyName, objectID: id), !name.isEmpty {
            return name
        }
        if let name = readString(kAudioDevicePropertyDeviceUID, objectID: id), !name.isEmpty {
            return name
        }
        return "Unknown device"
    }

    private static func sortDevices(_ devices: [AudioDevice]) -> [AudioDevice] {
        devices.sorted { a, b in
            let aBuiltIn = a.transport == kAudioDeviceTransportTypeBuiltIn
            let bBuiltIn = b.transport == kAudioDeviceTransportTypeBuiltIn
            if aBuiltIn != bBuiltIn {
                return aBuiltIn
            }
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            if order == .orderedSame {
                return a.id < b.id
            }
            return order == .orderedAscending
        }
    }

    /// Two "MacBook Pro" entries become "MacBook Pro (USB)" so a click hits the intended device.
    private static func disambiguate(_ devices: [AudioDevice]) -> [AudioDevice] {
        var counts: [String: Int] = [:]
        for device in devices {
            counts[device.name, default: 0] += 1
        }
        return devices.map { device in
            guard counts[device.name, default: 0] > 1 else { return device }
            var copy = device
            copy.name = "\(device.name) (\(TransportInfo.label(device.transport)))"
            return copy
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize >= UInt32(MemoryLayout<AudioDeviceID>.size) else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0, count <= 512 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        let status = devices.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            var localAddress = address
            var localSize = dataSize
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &localAddress,
                0,
                nil,
                &localSize,
                base
            )
        }
        guard status == noErr else {
            logFailure("read devices", status)
            return []
        }
        return devices
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        guard let value = readUInt32(kAudioDevicePropertyIsHidden, scope: kAudioObjectPropertyScopeGlobal, element: mainElement, objectID: id) else {
            return false
        }
        return value != 0
    }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        guard let value = readUInt32(kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal, element: mainElement, objectID: id) else {
            return true
        }
        return value != 0
    }

    private static func isSubDevice(_ id: AudioDeviceID) -> Bool {
        guard let classID = readUInt32(kAudioObjectPropertyClass, scope: kAudioObjectPropertyScopeGlobal, element: mainElement, objectID: id) else {
            return false
        }
        return AudioClassID(classID) == kAudioSubDeviceClassID
    }

    private static func isAutoAggregate(_ id: AudioDeviceID) -> Bool {
        guard let transport = readUInt32(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal, element: mainElement, objectID: id) else {
            return false
        }
        return transport == kAudioDeviceTransportTypeAutoAggregate
    }

    private static func canBeDefault(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        guard let value = readUInt32(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope, element: mainElement, objectID: id) else {
            return true
        }
        return value != 0
    }

    private static func canBeSystemOutput(_ id: AudioDeviceID) -> Bool {
        if let value = readUInt32(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, scope: kAudioDevicePropertyScopeOutput, element: mainElement, objectID: id) {
            return value != 0
        }
        if let value = readUInt32(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, scope: kAudioObjectPropertyScopeGlobal, element: mainElement, objectID: id) {
            return value != 0
        }
        return true
    }

    private static func streamCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: mainElement
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    // MARK: - Volume / balance / mute binding

    private enum VolumeKind {
        case virtualMain
        case masterScalar
        case stereo(left: AudioObjectPropertyElement, right: AudioObjectPropertyElement)
        case mono(AudioObjectPropertyElement)
        case none
    }

    private struct VolumeBinding {
        var kind: VolumeKind
        var writable: Bool
    }

    private enum BalanceKind {
        case virtualMain
        case stereoPan
        case channels(left: AudioObjectPropertyElement, right: AudioObjectPropertyElement)
        case none
    }

    private struct BalanceBinding {
        var kind: BalanceKind
        var writable: Bool
    }

    private static func volumeBinding(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> VolumeBinding {
        let virtual = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, element: mainElement)
        if hasProperty(deviceID, virtual) {
            return VolumeBinding(kind: .virtualMain, writable: isSettable(deviceID, virtual))
        }
        let master = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: mainElement)
        if hasProperty(deviceID, master) {
            return VolumeBinding(kind: .masterScalar, writable: isSettable(deviceID, master))
        }
        let channels = scalarChannels(deviceID: deviceID, scope: scope)
        if channels.count >= 2 {
            let left = channels[0]
            let right = channels[1]
            let writable = isSettable(deviceID, address(kAudioDevicePropertyVolumeScalar, scope: scope, element: left))
                || isSettable(deviceID, address(kAudioDevicePropertyVolumeScalar, scope: scope, element: right))
            return VolumeBinding(kind: .stereo(left: left, right: right), writable: writable)
        }
        if let only = channels.first {
            return VolumeBinding(
                kind: .mono(only),
                writable: isSettable(deviceID, address(kAudioDevicePropertyVolumeScalar, scope: scope, element: only))
            )
        }
        return VolumeBinding(kind: .none, writable: false)
    }

    private static func balanceBinding(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, volume: VolumeBinding) -> BalanceBinding {
        guard scope == kAudioDevicePropertyScopeOutput else {
            return BalanceBinding(kind: .none, writable: false)
        }
        let virtual = address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope: scope, element: mainElement)
        if hasProperty(deviceID, virtual) {
            return BalanceBinding(kind: .virtualMain, writable: isSettable(deviceID, virtual))
        }
        let pan = address(kAudioDevicePropertyStereoPan, scope: scope, element: mainElement)
        if hasProperty(deviceID, pan) {
            return BalanceBinding(kind: .stereoPan, writable: isSettable(deviceID, pan))
        }
        if case .stereo(let left, let right) = volume.kind {
            return BalanceBinding(kind: .channels(left: left, right: right), writable: volume.writable)
        }
        return BalanceBinding(kind: .none, writable: false)
    }

    private static func readVolume(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, binding: VolumeBinding) -> Float? {
        switch binding.kind {
        case .virtualMain:
            return readFloat(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, element: mainElement, objectID: deviceID)
        case .masterScalar:
            return readFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: mainElement, objectID: deviceID)
        case .stereo(let left, let right):
            guard let l = readFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: left, objectID: deviceID),
                  let r = readFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: right, objectID: deviceID) else {
                return nil
            }
            return StereoMix.volumeAndPan(left: l, right: r).volume
        case .mono(let element):
            return readFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: element, objectID: deviceID)
        case .none:
            return nil
        }
    }

    private static func readBalance(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, binding: BalanceBinding) -> Float? {
        switch binding.kind {
        case .virtualMain:
            return readFloat(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope: scope, element: mainElement, objectID: deviceID).map(clampUnit)
        case .stereoPan:
            return readFloat(kAudioDevicePropertyStereoPan, scope: scope, element: mainElement, objectID: deviceID).map(clampUnit)
        case .channels(let left, let right):
            guard let l = readFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: left, objectID: deviceID),
                  let r = readFloat(kAudioDevicePropertyVolumeScalar, scope: scope, element: right, objectID: deviceID) else {
                return nil
            }
            return StereoMix.volumeAndPan(left: l, right: r).pan
        case .none:
            return nil
        }
    }

    private struct MuteState {
        var value: Bool
        var writable: Bool
        var elements: [AudioObjectPropertyElement]
    }

    private static func muteState(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> MuteState {
        let elements = muteElements(deviceID: deviceID, scope: scope)
        guard let primary = elements.first else {
            return MuteState(value: false, writable: false, elements: [])
        }
        // A main-element mute is the switch Sound settings shows. Channel mutes are only
        // consulted when the device has no main mute.
        let used = primary == mainElement ? [mainElement] : elements
        let value = used.contains {
            (readUInt32(kAudioDevicePropertyMute, scope: scope, element: $0, objectID: deviceID) ?? 0) != 0
        }
        let writable = used.contains {
            isSettable(deviceID, address(kAudioDevicePropertyMute, scope: scope, element: $0))
        }
        return MuteState(value: value, writable: writable, elements: used)
    }

    private static func muteElements(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioObjectPropertyElement] {
        let preferred = preferredStereoChannels(deviceID, scope: scope)
        var ordered: [AudioObjectPropertyElement] = [mainElement, preferred.0, preferred.1, 1, 2]
        var seen = Set<AudioObjectPropertyElement>()
        return ordered.filter { element in
            seen.insert(element).inserted && hasProperty(deviceID, address(kAudioDevicePropertyMute, scope: scope, element: element))
        }
    }

    /// Preferred stereo pair first, then the usual channel elements 1 and 2.
    private static func scalarChannels(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioObjectPropertyElement] {
        var ordered: [AudioObjectPropertyElement] = []
        let preferred = preferredStereoChannels(deviceID, scope: scope)
        ordered.append(contentsOf: [preferred.0, preferred.1, 1, 2])
        var seen = Set<AudioObjectPropertyElement>()
        return ordered.filter { element in
            element != mainElement && element != 0 && seen.insert(element).inserted
                && hasProperty(deviceID, address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element))
        }
    }

    private static func preferredStereoChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> (AudioObjectPropertyElement, AudioObjectPropertyElement) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: scope,
            mElement: mainElement
        )
        guard AudioObjectHasProperty(id, &address) else { return (1, 2) }
        var channels = (AudioObjectPropertyElement(0), AudioObjectPropertyElement(0))
        var size = UInt32(MemoryLayout<(AudioObjectPropertyElement, AudioObjectPropertyElement)>.size)
        let status = withUnsafeMutablePointer(to: &channels) { pointer -> OSStatus in
            var localAddress = address
            var localSize = size
            return AudioObjectGetPropertyData(id, &localAddress, 0, nil, &localSize, UnsafeMutableRawPointer(pointer))
        }
        if status != noErr || channels.0 == 0 || channels.1 == 0 {
            return (1, 2)
        }
        return channels
    }

    private static func controlTokens(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, into tokens: inout Set<AudioPropertyToken>) {
        consider(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, mainElement, into: &tokens)
        consider(deviceID, kAudioDevicePropertyVolumeScalar, scope, mainElement, into: &tokens)
        consider(deviceID, kAudioDevicePropertyMute, scope, mainElement, into: &tokens)
        if scope == kAudioDevicePropertyScopeOutput {
            consider(deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope, mainElement, into: &tokens)
            consider(deviceID, kAudioDevicePropertyStereoPan, scope, mainElement, into: &tokens)
        }
        let channels = scalarChannels(deviceID: deviceID, scope: scope)
        for element in channels {
            consider(deviceID, kAudioDevicePropertyVolumeScalar, scope, element, into: &tokens)
            consider(deviceID, kAudioDevicePropertyMute, scope, element, into: &tokens)
        }
        // Also watch elements 1 and 2 even when scalarChannels filtered them, so a channel-only
        // mute still wakes the menu bar icon.
        for element: AudioObjectPropertyElement in [1, 2] {
            consider(deviceID, kAudioDevicePropertyVolumeScalar, scope, element, into: &tokens)
            consider(deviceID, kAudioDevicePropertyMute, scope, element, into: &tokens)
        }
    }

    private static func consider(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
        _ element: AudioObjectPropertyElement,
        into tokens: inout Set<AudioPropertyToken>
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(objectID, &address) else { return }
        tokens.insert(token(objectID, selector, scope, element))
    }

    private static func token(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
        _ element: AudioObjectPropertyElement
    ) -> AudioPropertyToken {
        AudioPropertyToken(objectID: objectID, selector: selector, scope: scope, element: element)
    }

    // MARK: - Property IO

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func hasProperty(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(objectID, &address)
    }

    private static func isSettable(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(objectID, &address) else { return false }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(objectID, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private static func readDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { return AudioDeviceID(kAudioObjectUnknown) }
        return deviceID
    }

    private static func writeDeviceID(selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
        var value = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &value)
    }

    private static func readUInt32(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        objectID: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func readFloat(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        objectID: AudioObjectID
    ) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func writeFloat(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        value: Float,
        deviceID: AudioDeviceID
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var stored = Float32(clampUnit(value))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &stored)
        if status != noErr {
            logFailure("set float property", status)
        }
    }

    private static func writeUInt32(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        value: UInt32,
        deviceID: AudioDeviceID
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var stored = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &stored)
        if status != noErr {
            logFailure("set mute", status)
        }
    }

    /// Caller releases CF objects returned by `AudioObjectGetPropertyData`.
    private static func readString(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer -> OSStatus in
            var localAddress = address
            var localSize = size
            return AudioObjectGetPropertyData(objectID, &localAddress, 0, nil, &localSize, UnsafeMutableRawPointer(pointer))
        }
        guard status == noErr, let unmanaged else { return nil }
        return (unmanaged.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func logFailure(_ message: String, _ status: OSStatus) {
        NSLog("%@", "AudioBar: \(message) failed (\(status))")
    }
}
