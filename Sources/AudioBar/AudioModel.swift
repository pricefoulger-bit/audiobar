import CoreAudio
import Foundation
import ServiceManagement

/// Owns the snapshot the panel renders and the HAL listeners that keep it current.
/// Listener callbacks hop to the main queue; they do not call CoreAudio themselves.
final class AudioModel {
    private(set) var snapshot = AudioSnapshot()
    var onChange: (() -> Void)?

    /// HAL callbacks must not run on the main queue: a synchronous bounce back to main while
    /// main is inside `AudioObjectSetPropertyData` can deadlock.
    private let listenerQueue = DispatchQueue(label: "com.pricefoulger.audiobar.listeners")
    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.scheduleRefresh()
    }
    private var installed: Set<AudioPropertyToken> = []
    private var rejectedListeners: Set<AudioPropertyToken> = []
    private var pendingRefresh: DispatchWorkItem?
    private var started = false
    private var pullInProgress = false
    private var config = AppConfig(peerHost: "", secret: "")
    private let peer = PeerService()
    private static let lastAddressKey = "lastBluetoothAddress"
    private static let lastNameKey = "lastBluetoothName"

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        config = AppConfig.load()
        if !config.peerHost.isEmpty {
            NSLog("%@", "AudioBar peer host \(config.peerHost)")
        }
        peer.start(secret: config.secret) { [weak self] address in
            self?.disconnectFromPeer(address: address)
        }
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
    }

    func reload() {
        dispatchPrecondition(condition: .onQueue(.main))
        refresh()
    }

    func disconnectCurrentBluetooth() {
        dispatchPrecondition(condition: .onQueue(.main))
        let output = snapshot.outputs.first { $0.id == snapshot.defaultOutputID }
        let input = snapshot.inputs.first { $0.id == snapshot.defaultInputID }
        let device = (output?.isBluetooth == true ? output : nil) ?? (input?.isBluetooth == true ? input : nil)
        guard let device else {
            setStatus("Current device is not Bluetooth")
            return
        }
        disconnectBluetooth(deviceID: device.id)
    }

    func disconnectBluetooth(deviceID: AudioDeviceID) {
        dispatchPrecondition(condition: .onQueue(.main))
        let device = (snapshot.outputs + snapshot.inputs).first { $0.id == deviceID }
        guard let device else { return }
        let targets = BluetoothClient.targets()
        guard let target = BluetoothClient.resolve(device, targets: targets) else {
            setStatus("Couldn't find that Bluetooth device")
            return
        }
        closeLocally(target.address, name: target.name)
    }

    func pullBluetooth(address: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !pullInProgress else { return }
        let chosen = snapshot.pullCandidates.first { $0.address == address }
            ?? snapshot.pullCandidates.first { $0.address == snapshot.preferredPullAddress }
        guard let chosen else {
            setStatus("No Bluetooth device to pull")
            return
        }
        pullInProgress = true
        remember(address: chosen.address, name: chosen.name)
        setStatus("Asking the other Mac to release \(chosen.name)…")
        let peerHost = config.peerHost
        let secret = config.secret
        peer.askToDisconnect(address: chosen.address, peerHost: peerHost, secret: secret) { [weak self] result in
            DispatchQueue.main.async {
                self?.continuePull(chosen, peerResult: result)
            }
        }
    }

    func selectOutput(_ id: AudioDeviceID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard id != kAudioObjectUnknown, id != snapshot.defaultOutputID else { return }
        CoreAudioSystem.setDefaultOutput(id)
        refresh()
    }

    func selectInput(_ id: AudioDeviceID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard id != kAudioObjectUnknown, id != snapshot.defaultInputID else { return }
        CoreAudioSystem.setDefaultInput(id)
        refresh()
    }

    func setOutputVolume(_ volume: Float) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard snapshot.outputVolumeEnabled else { return }
        let volume = clampUnit(volume)
        CoreAudioSystem.setOutputVolume(volume, balance: snapshot.balance ?? 0.5, deviceID: snapshot.defaultOutputID)
        snapshot.outputVolume = volume
        publish()
    }

    func setBalance(_ pan: Float) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard snapshot.balanceEnabled else { return }
        let pan = clampUnit(pan)
        CoreAudioSystem.setBalance(pan, deviceID: snapshot.defaultOutputID)
        snapshot.balance = pan
        publish()
    }

    func setOutputMuted(_ muted: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard snapshot.outputMuteEnabled else { return }
        CoreAudioSystem.setOutputMuted(muted, deviceID: snapshot.defaultOutputID)
        refresh()
    }

    func setInputVolume(_ volume: Float) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard snapshot.inputVolumeEnabled else { return }
        let volume = clampUnit(volume)
        CoreAudioSystem.setInputVolume(volume, deviceID: snapshot.defaultInputID)
        snapshot.inputVolume = volume
        publish()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            snapshot.loginMessage = nil
        } catch {
            snapshot.loginMessage = error.localizedDescription
        }
        applyLoginState()
        publish()
    }

    func refreshLoginItemStatus() {
        dispatchPrecondition(condition: .onQueue(.main))
        let previous = (snapshot.launchAtLogin, snapshot.launchApprovalRequired)
        applyLoginState()
        if previous != (snapshot.launchAtLogin, snapshot.launchApprovalRequired) {
            publish()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    deinit {
        let block = listenerBlock
        let queue = listenerQueue
        for token in installed {
            var address = AudioObjectPropertyAddress(
                mSelector: token.selector,
                mScope: token.scope,
                mElement: token.element
            )
            AudioObjectRemovePropertyListenerBlock(token.objectID, &address, queue, block)
        }
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.refresh()
            }
            self.pendingRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    private func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        let outputs = CoreAudioSystem.devices(direction: .output)
        let inputs = CoreAudioSystem.devices(direction: .input)
        let defaultOutput = CoreAudioSystem.defaultOutputDevice()
        let defaultInput = CoreAudioSystem.defaultInputDevice()
        let output = CoreAudioSystem.outputControls(deviceID: defaultOutput)
        let input = CoreAudioSystem.inputControls(deviceID: defaultInput)

        if outputs.map(\.id) != snapshot.outputs.map(\.id) || inputs.map(\.id) != snapshot.inputs.map(\.id) {
            NSLog("%@", "AudioBar outputs: \(outputs.map(\.name).joined(separator: ", "))")
            NSLog("%@", "AudioBar inputs: \(inputs.map(\.name).joined(separator: ", "))")
        }

        var next = snapshot
        next.outputs = outputs
        next.inputs = inputs
        next.defaultOutputID = defaultOutput
        next.defaultInputID = defaultInput
        next.outputVolume = output.volume
        next.outputVolumeEnabled = output.volumeWritable
        next.balance = output.balance
        next.balanceEnabled = output.balanceWritable
        next.outputMuted = output.muted
        next.outputMuteEnabled = output.muteWritable
        next.inputVolume = input.volume
        next.inputVolumeEnabled = input.volumeWritable
        applyBluetoothFields(&next, outputs: outputs, inputs: inputs, defaultOutput: defaultOutput, defaultInput: defaultInput)
        let previous = snapshot
        snapshot = next
        applyLoginState()
        syncListeners(outputs: outputs, inputs: inputs, defaultOutput: defaultOutput, defaultInput: defaultInput)
        if snapshot != previous {
            publish()
        }
    }

    private func applyBluetoothFields(
        _ snapshot: inout AudioSnapshot,
        outputs: [AudioDevice],
        inputs: [AudioDevice],
        defaultOutput: AudioDeviceID,
        defaultInput: AudioDeviceID
    ) {
        let targets = BluetoothClient.targets()
        if let current = outputs.first(where: { $0.id == defaultOutput && $0.isBluetooth }),
           let target = BluetoothClient.resolve(current, targets: targets) {
            remember(address: target.address, name: target.name)
        }
        let names = (outputs + inputs).filter(\.isBluetooth).map(\.name)
        let candidates = BluetoothClient.pullCandidates(targets: targets, coreAudioNames: names)
        snapshot.pullCandidates = candidates
        snapshot.preferredPullAddress = preferredAddress(among: candidates)
        let perRow = perRowDisconnectIDs(outputs: outputs, inputs: inputs, targets: targets)
        snapshot.perRowDisconnectIDs = perRow
        snapshot.showColumnDisconnect = perRow.isEmpty
        let outputIsBluetooth = outputs.first { $0.id == defaultOutput }?.isBluetooth ?? false
        let inputIsBluetooth = inputs.first { $0.id == defaultInput }?.isBluetooth ?? false
        snapshot.columnDisconnectEnabled = (outputIsBluetooth || inputIsBluetooth) && !pullInProgress
        snapshot.pullInProgress = pullInProgress
        snapshot.pullEnabled = !candidates.isEmpty && !pullInProgress
    }

    private func perRowDisconnectIDs(outputs: [AudioDevice], inputs: [AudioDevice], targets: [BluetoothTarget]) -> Set<AudioDeviceID> {
        let listed = (outputs + inputs).filter(\.isBluetooth)
        var groups: [String: [AudioDeviceID]] = [:]
        for device in listed {
            let key = BluetoothClient.resolve(device, targets: targets)?.address ?? "id:\(device.id)"
            groups[key, default: []].append(device.id)
        }
        guard groups.count > 1 else { return [] }
        return Set(listed.map(\.id))
    }

    private func preferredAddress(among candidates: [PullCandidate]) -> String {
        let saved = UserDefaults.standard.string(forKey: Self.lastAddressKey) ?? ""
        if candidates.contains(where: { $0.address == saved }) {
            return saved
        }
        if let bose = candidates.first(where: { $0.name.range(of: "bose nc 700", options: .caseInsensitive) != nil }) {
            return bose.address
        }
        return candidates.first?.address ?? ""
    }

    private func remember(address: String, name: String) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.lastAddressKey) != address else { return }
        defaults.set(address, forKey: Self.lastAddressKey)
        defaults.set(name, forKey: Self.lastNameKey)
    }

    private func closeLocally(_ address: String, name: String) {
        if BluetoothClient.close(address: address) {
            setStatus("Disconnected")
            refresh()
        } else {
            setStatus("Couldn't disconnect \(name)")
        }
    }

    private func disconnectFromPeer(address: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let known = BluetoothClient.targets().contains { $0.address == address }
        guard known else {
            NSLog("%@", "AudioBar peer asked to disconnect \(address), which is not paired here")
            return
        }
        NSLog("%@", "AudioBar peer asked to disconnect \(address)")
        if BluetoothClient.close(address: address) {
            setStatus("Disconnected")
            refresh()
        } else {
            setStatus("Couldn't disconnect.")
        }
    }

    private func continuePull(_ candidate: PullCandidate, peerResult: PeerAskResult) {
        switch peerResult {
        case .released:
            let note = "Other Mac released it"
            setStatus(note)
            waitUntilReleased(address: candidate.address, remaining: 8) { [weak self] in
                self?.connectLocally(candidate, peerNote: note)
            }
        case .unreachable:
            let note = "Other Mac didn't respond"
            setStatus(note)
            connectLocally(candidate, peerNote: note)
        case .refused:
            let note = "Other Mac refused the request"
            setStatus(note)
            connectLocally(candidate, peerNote: note)
        }
    }

    private func waitUntilReleased(address: String, remaining: Int, then: @escaping () -> Void) {
        if remaining <= 0 || !BluetoothClient.isConnected(address: address) {
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.waitUntilReleased(address: address, remaining: remaining - 1, then: then)
        }
    }

    private func connectLocally(_ candidate: PullCandidate, peerNote: String) {
        setStatus("\(peerNote). Connecting…")
        scheduleOpen(candidate, peerNote: peerNote, opensLeft: 3)
    }

    private func scheduleOpen(_ candidate: PullCandidate, peerNote: String, opensLeft: Int) {
        if BluetoothClient.isConnected(address: candidate.address) || coreAudioMatch(candidate) != nil {
            waitForAudioDevice(candidate, peerNote: peerNote, remaining: 10)
            return
        }
        BluetoothClient.open(address: candidate.address)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            let connected = BluetoothClient.isConnected(address: candidate.address) || self.coreAudioMatch(candidate) != nil
            if connected || opensLeft <= 1 {
                self.waitForAudioDevice(candidate, peerNote: peerNote, remaining: 10)
            } else {
                self.scheduleOpen(candidate, peerNote: peerNote, opensLeft: opensLeft - 1)
            }
        }
    }

    private func waitForAudioDevice(_ candidate: PullCandidate, peerNote: String, remaining: Int) {
        refresh()
        let match = coreAudioMatch(candidate)
        let outputReady = match?.output != nil
        let inputReady = match?.input != nil
        let done = remaining <= 0 || (outputReady && inputReady) || (outputReady && remaining <= 3)
        guard done else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.waitForAudioDevice(candidate, peerNote: peerNote, remaining: remaining - 1)
            }
            return
        }
        if let output = match?.output {
            CoreAudioSystem.setDefaultOutput(output.id)
        }
        if let input = match?.input {
            CoreAudioSystem.setDefaultInput(input.id)
        }
        pullInProgress = false
        refresh()
        let connected = outputReady || inputReady || BluetoothClient.isConnected(address: candidate.address)
        if connected {
            setStatus(peerNote.isEmpty ? "Connected" : "\(peerNote). Connected")
        } else {
            setStatus(peerNote.isEmpty ? "Couldn't connect." : "\(peerNote). Couldn't connect.")
        }
    }

    private func coreAudioMatch(_ candidate: PullCandidate) -> (output: AudioDevice?, input: AudioDevice?)? {
        let outputs = CoreAudioSystem.devices(direction: .output)
        let inputs = CoreAudioSystem.devices(direction: .input)
        let output = BluetoothClient.match(candidate, devices: outputs)
        let input = BluetoothClient.match(candidate, devices: inputs)
        if output == nil && input == nil { return nil }
        return (output, input)
    }

    private func setStatus(_ text: String) {
        snapshot.statusText = text
        snapshot.pullInProgress = pullInProgress
        snapshot.pullEnabled = !snapshot.pullCandidates.isEmpty && !pullInProgress
        snapshot.columnDisconnectEnabled = snapshot.columnDisconnectEnabled && !pullInProgress
        publish()
    }

    private func publish() {
        onChange?()
    }

    private func applyLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            snapshot.launchAtLogin = true
            snapshot.launchApprovalRequired = false
        case .requiresApproval:
            snapshot.launchAtLogin = true
            snapshot.launchApprovalRequired = true
        case .notRegistered, .notFound:
            snapshot.launchAtLogin = false
            snapshot.launchApprovalRequired = false
        @unknown default:
            snapshot.launchAtLogin = false
            snapshot.launchApprovalRequired = false
        }
    }

    // MARK: - Listeners

    private func syncListeners(
        outputs: [AudioDevice],
        inputs: [AudioDevice],
        defaultOutput: AudioDeviceID,
        defaultInput: AudioDeviceID
    ) {
        let needed = CoreAudioSystem.observationTokens(
            outputs: outputs,
            inputs: inputs,
            defaultOutput: defaultOutput,
            defaultInput: defaultInput
        )
        rejectedListeners.formIntersection(needed)
        for token in installed.subtracting(needed) {
            removeListener(token)
        }
        for token in needed.subtracting(installed) {
            addListener(token)
        }
    }

    private func addListener(_ token: AudioPropertyToken) {
        if rejectedListeners.contains(token) {
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: token.selector,
            mScope: token.scope,
            mElement: token.element
        )
        guard AudioObjectHasProperty(token.objectID, &address) else { return }
        let status = AudioObjectAddPropertyListenerBlock(token.objectID, &address, listenerQueue, listenerBlock)
        if status == noErr {
            installed.insert(token)
        } else {
            rejectedListeners.insert(token)
            NSLog("%@", "AudioBar: add listener failed (\(status))")
        }
    }

    private func removeListener(_ token: AudioPropertyToken) {
        var address = AudioObjectPropertyAddress(
            mSelector: token.selector,
            mScope: token.scope,
            mElement: token.element
        )
        AudioObjectRemovePropertyListenerBlock(token.objectID, &address, listenerQueue, listenerBlock)
        installed.remove(token)
    }
}
