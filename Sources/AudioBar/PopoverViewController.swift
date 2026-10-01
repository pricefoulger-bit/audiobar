import AppKit
import CoreAudio

/// Two columns: output on the left, input on the right. One click switches the default.
/// The panel has no fixed height: it sizes to its content and keeps `preferredContentSize`
/// in step with `fittingSize`, so optional rows (pull picker, hints, login note, status)
/// grow and shrink the popover instead of leaving blank space.
final class PopoverViewController: NSViewController {
    private let model: AudioModel

    private let outputList = DeviceListView(emptyMessage: "No output devices")
    private let inputList = DeviceListView(emptyMessage: "No input devices")
    private let outputVolume = SliderRow(style: .volume(symbol: "speaker.wave.2.fill"), accessibilityLabel: "Output volume")
    private let outputBalance = SliderRow(style: .balance, accessibilityLabel: "Balance")
    private let inputVolume = SliderRow(style: .volume(symbol: "mic.fill"), accessibilityLabel: "Input volume")
    private let outputHint = PopoverViewController.hintLabel()
    private let inputHint = PopoverViewController.hintLabel()
    private let muteSwitch = NSSwitch(frame: .zero)
    private let loginSwitch = NSSwitch(frame: .zero)
    private let noteLabel = NSTextField(labelWithString: "")
    private let settingsButton = NSButton(frame: .zero)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let pullButton = NSButton(title: "Pull", target: nil, action: nil)
    private let pullPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")

    private var outputVolumeHold = Date.distantPast
    private var balanceHold = Date.distantPast
    private var inputVolumeHold = Date.distantPast
    private var renderedOutputID = AudioDeviceID(kAudioObjectUnknown)
    private var renderedInputID = AudioDeviceID(kAudioObjectUnknown)
    private var pullMenuSignature: [String] = []
    private var userPickedPullAddress = false
    private var selectedPullAddress: String?

    private let mainStack = NSStackView(frame: .zero)
    private let outputStack = NSStackView(frame: .zero)
    private let inputStack = NSStackView(frame: .zero)
    private let noteRow = NSStackView(frame: .zero)
    private var listHeight: [NSLayoutConstraint] = []

    init(model: AudioModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: 360))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        view = root

        outputList.onSelect = { [weak self] id in
            self?.model.selectOutput(id)
        }
        inputList.onSelect = { [weak self] id in
            self?.model.selectInput(id)
        }
        outputList.onDisconnect = { [weak self] id in
            self?.model.disconnectBluetooth(deviceID: id)
        }
        inputList.onDisconnect = { [weak self] id in
            self?.model.disconnectBluetooth(deviceID: id)
        }
        outputVolume.onChanged = { [weak self] value in
            guard let self else { return }
            self.outputVolumeHold = Date().addingTimeInterval(0.25)
            self.model.setOutputVolume(clampUnit(Float(value)))
        }
        outputBalance.onChanged = { [weak self] value in
            guard let self else { return }
            let pan = self.snappedBalance(value)
            if abs(pan - 0.5) < 0.001 {
                self.outputBalance.value = 0.5
            }
            self.balanceHold = Date().addingTimeInterval(0.25)
            self.model.setBalance(pan)
        }
        inputVolume.onChanged = { [weak self] value in
            guard let self else { return }
            self.inputVolumeHold = Date().addingTimeInterval(0.25)
            self.model.setInputVolume(clampUnit(Float(value)))
        }
        outputBalance.toolTip = "Balance"

        configureMuteSwitch()
        configureBluetoothControls()

        // Columns
        configureColumn(outputStack)
        configureColumn(inputStack)
        let outputHeader = sectionHeader("Output", symbol: "hifispeaker.fill", accessory: muteControl())
        let inputHeader = sectionHeader("Input", symbol: "mic.fill", accessory: nil)

        for view in [outputHeader, outputList, outputVolume, outputBalance, outputHint] as [NSView] {
            add(view, to: outputStack, width: Layout.columnWidth)
        }
        outputStack.setCustomSpacing(6, after: outputHeader)
        outputStack.setCustomSpacing(8, after: outputList)
        outputStack.setCustomSpacing(0, after: outputVolume)

        let buttonRow = NSStackView(views: [disconnectButton, pullButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually
        buttonRow.detachesHiddenViews = true
        buttonRow.setContentCompressionResistancePriority(.required, for: .vertical)
        buttonRow.setClippingResistancePriority(.required, for: .vertical)
        buttonRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
        for button in [disconnectButton, pullButton] {
            button.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        for view in [inputHeader, inputList, inputVolume, inputHint] as [NSView] {
            add(view, to: inputStack, width: Layout.columnWidth)
        }
        inputStack.setCustomSpacing(6, after: inputHeader)
        inputStack.setCustomSpacing(8, after: inputList)

        // Each list is exactly as tall as its rows (no empty box).
        listHeight = [
            outputList.heightAnchor.constraint(equalToConstant: outputList.preferredHeight),
            inputList.heightAnchor.constraint(equalToConstant: inputList.preferredHeight),
        ]
        NSLayoutConstraint.activate(listHeight)

        let divider = Hairline(axis: .vertical)
        let columns = NSStackView(views: [outputStack, divider, inputStack])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = Layout.columnGap
        columns.distribution = .fill
        columns.setHuggingPriority(.required, for: .vertical)
        columns.setClippingResistancePriority(.required, for: .vertical)
        columns.setContentCompressionResistancePriority(.required, for: .vertical)
        outputStack.widthAnchor.constraint(equalToConstant: Layout.columnWidth).isActive = true
        inputStack.widthAnchor.constraint(equalToConstant: Layout.columnWidth).isActive = true
        divider.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        // The columns row must be at least as tall as the taller column, whichever it is.
        columns.heightAnchor.constraint(greaterThanOrEqualTo: outputStack.heightAnchor).isActive = true
        columns.heightAnchor.constraint(greaterThanOrEqualTo: inputStack.heightAnchor).isActive = true

        // Footer
        let footerRule = Hairline(axis: .horizontal)
        let footer = makeFooterRow()
        configureNoteRow()

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.isHidden = true

        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 8
        mainStack.detachesHiddenViews = true
        mainStack.edgeInsets = NSEdgeInsets(top: Layout.margin, left: Layout.margin, bottom: 12, right: Layout.margin)
        mainStack.setHuggingPriority(.required, for: .vertical)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [columns, pullPicker, buttonRow, footerRule, footer, noteRow, statusLabel] as [NSView] {
            add(view, to: mainStack, width: Layout.contentWidth)
        }
        mainStack.setCustomSpacing(14, after: columns)
        mainStack.setCustomSpacing(12, after: columns)
        mainStack.setCustomSpacing(8, after: pullPicker)
        mainStack.setCustomSpacing(12, after: buttonRow)
        mainStack.setCustomSpacing(8, after: footerRule)
        mainStack.setCustomSpacing(4, after: footer)
        mainStack.setCustomSpacing(4, after: noteRow)

        root.addSubview(mainStack)
        let bottom = mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        bottom.priority = .init(999)
        let trailing = mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        trailing.priority = .init(999)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainStack.widthAnchor.constraint(equalToConstant: Layout.width),
            trailing,
            bottom,
        ])

        let columnWidth = Layout.columnWidth
        outputHint.preferredMaxLayoutWidth = columnWidth
        inputHint.preferredMaxLayoutWidth = columnWidth
        updatePreferredSize()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        model.refreshLoginItemStatus()
        model.reload()
        render()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let outputWidth = outputStack.bounds.width
        let inputWidth = inputStack.bounds.width
        if outputWidth > 1 {
            outputHint.preferredMaxLayoutWidth = outputWidth
        }
        if inputWidth > 1 {
            inputHint.preferredMaxLayoutWidth = inputWidth
        }
    }

    func render() {
        guard isViewLoaded else { return }
        let snapshot = model.snapshot
        if snapshot.defaultOutputID != renderedOutputID {
            renderedOutputID = snapshot.defaultOutputID
            outputVolumeHold = .distantPast
            balanceHold = .distantPast
        }
        if snapshot.defaultInputID != renderedInputID {
            renderedInputID = snapshot.defaultInputID
            inputVolumeHold = .distantPast
        }
        let disconnectEnabled = !snapshot.pullInProgress
        outputList.setDevices(
            snapshot.outputs,
            selected: snapshot.defaultOutputID,
            direction: .output,
            disconnectIDs: snapshot.perRowDisconnectIDs,
            disconnectEnabled: disconnectEnabled
        )
        inputList.setDevices(
            snapshot.inputs,
            selected: snapshot.defaultInputID,
            direction: .input,
            disconnectIDs: snapshot.perRowDisconnectIDs,
            disconnectEnabled: disconnectEnabled
        )
        let listHeights = [outputList.preferredHeight, inputList.preferredHeight]
        for (constraint, height) in zip(listHeight, listHeights) where constraint.constant != height {
            constraint.constant = height
        }
        renderBluetooth(snapshot)

        if Date() >= outputVolumeHold {
            outputVolume.value = Double(snapshot.outputVolume ?? 0)
        }
        outputVolume.isEnabled = snapshot.outputVolumeEnabled
        outputVolume.symbol = snapshot.statusSymbol
        outputHint.stringValue = snapshot.outputVolumeEnabled ? "" : "No volume control on device"
        outputHint.isHidden = snapshot.outputVolumeEnabled

        if Date() >= balanceHold {
            outputBalance.value = Double(snapshot.balance ?? 0.5)
        }
        outputBalance.isEnabled = snapshot.balanceEnabled

        muteSwitch.state = snapshot.outputMuted ? .on : .off
        muteSwitch.isEnabled = snapshot.outputMuteEnabled

        if Date() >= inputVolumeHold {
            inputVolume.value = Double(snapshot.inputVolume ?? 0)
        }
        inputVolume.isEnabled = snapshot.inputVolumeEnabled
        inputHint.stringValue = snapshot.inputVolumeEnabled ? "" : "No volume control on device"
        inputHint.isHidden = snapshot.inputVolumeEnabled

        loginSwitch.state = snapshot.launchAtLogin ? .on : .off
        if let loginMessage = snapshot.loginMessage, !loginMessage.isEmpty {
            noteLabel.stringValue = loginMessage
            noteLabel.textColor = .systemRed
        } else if snapshot.launchApprovalRequired {
            noteLabel.stringValue = "Allow AudioBar in System Settings → General → Login Items."
            noteLabel.textColor = .secondaryLabelColor
        } else {
            noteLabel.stringValue = ""
        }
        noteLabel.isHidden = noteLabel.stringValue.isEmpty
        settingsButton.isHidden = !snapshot.launchApprovalRequired
        noteRow.isHidden = noteLabel.isHidden && settingsButton.isHidden

        statusLabel.stringValue = snapshot.statusText
        statusLabel.isHidden = snapshot.statusText.isEmpty
        let failed = snapshot.statusText.contains("Couldn't")
            || snapshot.statusText.contains("refused")
            || snapshot.statusText.contains("not Bluetooth")
        statusLabel.textColor = failed ? .systemRed : .secondaryLabelColor

        updatePreferredSize()
    }

    /// Popover height follows the content. NSPopover animates when this changes while shown.
    private func updatePreferredSize() {
        mainStack.layoutSubtreeIfNeeded()
        let fitting = mainStack.fittingSize
        let size = NSSize(width: Layout.width, height: ceil(fitting.height))
        if abs(preferredContentSize.height - size.height) > 0.5 || preferredContentSize.width != size.width {
            preferredContentSize = size
        }
    }

    @objc private func disconnectPressed(_ sender: Any?) {
        model.disconnectCurrentBluetooth()
    }

    @objc private func pullPressed(_ sender: Any?) {
        let address = (pullPicker.selectedItem?.representedObject as? String) ?? selectedPullAddress ?? ""
        model.pullBluetooth(address: address)
    }

    @objc private func pullPickerChanged(_ sender: Any?) {
        userPickedPullAddress = true
        selectedPullAddress = pullPicker.selectedItem?.representedObject as? String
    }

    @objc private func loginChanged(_ sender: NSSwitch) {
        model.setLaunchAtLogin(sender.state == .on)
    }

    @objc private func muteChanged(_ sender: NSSwitch) {
        model.setOutputMuted(sender.state == .on)
    }

    @objc private func openLoginSettings(_ sender: Any?) {
        model.openLoginItemsSettings()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func snappedBalance(_ value: Double) -> Float {
        let pan = Float(value)
        if abs(pan - 0.5) < 0.02 {
            return 0.5
        }
        return clampUnit(pan)
    }

    private func configureBluetoothControls() {
        configureActionButton(
            disconnectButton,
            symbol: "xmark.circle",
            action: #selector(disconnectPressed(_:)),
            toolTip: "Disconnect the current Bluetooth device from this Mac"
        )
        configureActionButton(
            pullButton,
            symbol: "arrow.down.circle",
            action: #selector(pullPressed(_:)),
            toolTip: "Ask the other Mac to disconnect this Bluetooth device, then connect it here"
        )

        pullPicker.controlSize = .small
        pullPicker.font = .systemFont(ofSize: 12)
        pullPicker.target = self
        pullPicker.action = #selector(pullPickerChanged(_:))
        pullPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pullPicker.setAccessibilityLabel("Bluetooth device to pull")
        pullPicker.toolTip = "Bluetooth device to pull"
        pullPicker.isHidden = true
        pullPicker.setContentCompressionResistancePriority(.required, for: .vertical)
        pullPicker.setContentHuggingPriority(.required, for: .vertical)
        pullPicker.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func configureActionButton(_ button: NSButton, symbol: String, action: Selector, toolTip: String) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.image = Symbols.image(symbol, pointSize: 12, weight: .medium, description: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func renderBluetooth(_ snapshot: AudioSnapshot) {
        disconnectButton.isHidden = !snapshot.showColumnDisconnect
        disconnectButton.isEnabled = snapshot.columnDisconnectEnabled

        let candidates = snapshot.pullCandidates
        let signature = candidates.map { "\($0.address)|\($0.name)" }
        if signature != pullMenuSignature {
            pullMenuSignature = signature
            pullPicker.removeAllItems()
            for candidate in candidates {
                pullPicker.addItem(withTitle: candidate.name)
                pullPicker.lastItem?.representedObject = candidate.address
            }
        }
        let addresses = candidates.map(\.address)
        if userPickedPullAddress, let selectedPullAddress, addresses.contains(selectedPullAddress) {
            // Keep the device the user picked.
        } else {
            userPickedPullAddress = false
            selectedPullAddress = snapshot.preferredPullAddress
        }
        if let selectedPullAddress, let index = addresses.firstIndex(of: selectedPullAddress) {
            pullPicker.selectItem(at: index)
        }
        pullPicker.isHidden = candidates.count < 2
        pullPicker.isEnabled = snapshot.pullEnabled
        pullButton.isEnabled = snapshot.pullEnabled
    }

    /// The panel width is fixed, so stacked views get a constant width. Self-held width
    /// constraints survive `detachesHiddenViews`; constraints to the stack would not.
    private func add(_ view: NSView, to stack: NSStackView, width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(view)
    }

    private func configureColumn(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.setHuggingPriority(.required, for: .vertical)
        // Never squash rows (the pull picker / buttons were being compressed into each other).
        stack.setClippingResistancePriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    private func configureMuteSwitch() {
        muteSwitch.controlSize = .mini
        muteSwitch.target = self
        muteSwitch.action = #selector(muteChanged(_:))
        muteSwitch.setAccessibilityLabel("Mute output")
        muteSwitch.toolTip = "Mute output"
    }

    /// "Mute" label plus a mini switch, sitting at the trailing end of the Output header.
    private func muteControl() -> NSView {
        let label = NSTextField(labelWithString: "Mute")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, muteSwitch])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        return row
    }

    /// SF Symbol + small uppercase tracked label, with an optional trailing control.
    private func sectionHeader(_ title: String, symbol: String, accessory: NSView?) -> NSView {
        let icon = NSImageView(frame: .zero)
        icon.image = Symbols.image(symbol, pointSize: 11, weight: .semibold, description: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ]
        )
        label.setAccessibilityLabel(title)

        let spacer = NSView(frame: .zero)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [icon, label, spacer]
        if let accessory {
            views.append(accessory)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 6
        row.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return row
    }

    private func makeFooterRow() -> NSView {
        loginSwitch.controlSize = .mini
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged(_:))
        loginSwitch.setAccessibilityLabel("Launch at login")

        let loginLabel = NSTextField(labelWithString: "Launch at login")
        loginLabel.font = .systemFont(ofSize: 12)
        loginLabel.textColor = .secondaryLabelColor

        let quit = NSButton(title: "Quit", target: self, action: #selector(quit(_:)))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: 11, weight: .medium)
        quit.toolTip = "Quit AudioBar"

        let spacer = NSView(frame: .zero)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let footer = NSStackView(views: [loginSwitch, loginLabel, spacer, quit])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = 6
        return footer
    }

    private func configureNoteRow() {
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 2
        noteLabel.usesSingleLineMode = false
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.preferredMaxLayoutWidth = Layout.width - Layout.margin * 2 - 140
        noteLabel.isHidden = true

        settingsButton.title = "Login Items Settings…"
        settingsButton.bezelStyle = .recessed
        settingsButton.isBordered = false
        settingsButton.font = .systemFont(ofSize: 11, weight: .medium)
        settingsButton.contentTintColor = .controlAccentColor
        settingsButton.target = self
        settingsButton.action = #selector(openLoginSettings(_:))
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsButton.isHidden = true

        noteRow.setViews([noteLabel, settingsButton], in: .leading)
        noteRow.orientation = .horizontal
        noteRow.alignment = .centerY
        noteRow.spacing = 8
        noteRow.detachesHiddenViews = true
        noteRow.isHidden = true
    }

    private static func hintLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.usesSingleLineMode = false
        label.isHidden = true
        return label
    }
}

enum Layout {
    static let width: CGFloat = 520
    static let margin: CGFloat = 14
    static let columnGap: CGFloat = 12
    static var contentWidth: CGFloat { width - margin * 2 }
    /// One column's width: content minus two gaps and the 1pt divider.
    static var columnWidth: CGFloat { (contentWidth - columnGap * 2 - 1) / 2 }
}

/// Icon | slider | percentage for volume; faint L | slider | R for balance.
private final class SliderRow: NSView {
    enum Style {
        case volume(symbol: String)
        case balance
    }

    private static let leadingSlot: CGFloat = 16
    private static let trailingSlot: CGFloat = 34

    var onChanged: ((Double) -> Void)?

    private let style: Style
    private let slider = TrackingSlider(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let valueLabel = NSTextField(labelWithString: "")
    private var appliedSymbol: String?

    var value: Double {
        get { slider.doubleValue }
        set {
            slider.doubleValue = newValue
            updateValueLabel()
        }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            guard slider.isEnabled != newValue else { return }
            slider.isEnabled = newValue
            iconView.contentTintColor = newValue ? .secondaryLabelColor : .tertiaryLabelColor
            updateValueLabel()
        }
    }

    /// Volume rows only: swaps the leading SF Symbol (e.g. slashed speaker while muted).
    var symbol: String? {
        get { appliedSymbol }
        set {
            guard case .volume = style, let newValue, newValue != appliedSymbol else { return }
            appliedSymbol = newValue
            iconView.image = Symbols.image(newValue, pointSize: 12, weight: .regular, description: nil)
        }
    }

    init(style: Style, accessibilityLabel: String) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.onChanged = { [weak self] value in
            self?.updateValueLabel()
            self?.onChanged?(value)
        }
        addSubview(slider)

        let leading: NSView
        let trailing: NSView
        let rowHeight: CGFloat
        switch style {
        case .volume(let symbol):
            appliedSymbol = symbol
            iconView.image = Symbols.image(symbol, pointSize: 12, weight: .regular, description: nil)
            iconView.contentTintColor = .secondaryLabelColor
            iconView.imageScaling = .scaleProportionallyDown
            iconView.setAccessibilityElement(false)
            leading = iconView

            valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.alignment = .right
            valueLabel.setAccessibilityElement(false)
            trailing = valueLabel
            slider.controlSize = .small
            rowHeight = 22
        case .balance:
            leading = Self.mark("L")
            let right = Self.mark("R")
            right.alignment = .left
            trailing = right
            slider.controlSize = .mini
            rowHeight = 16
        }
        leading.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leading)
        addSubview(trailing)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: rowHeight),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.widthAnchor.constraint(equalToConstant: Self.leadingSlot),
            slider.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.widthAnchor.constraint(equalToConstant: Self.trailingSlot),
        ])
        if case .volume = style {
            iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        }
        updateValueLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateValueLabel() {
        guard case .volume = style else { return }
        if slider.isEnabled {
            valueLabel.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
            valueLabel.textColor = .secondaryLabelColor
        } else {
            valueLabel.stringValue = "—"
            valueLabel.textColor = .tertiaryLabelColor
        }
        slider.setAccessibilityValueDescription(valueLabel.stringValue)
    }

    private static func mark(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.setAccessibilityElement(false)
        return label
    }
}

private final class TrackingSlider: NSSlider {
    var onChanged: ((Double) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        minValue = 0
        maxValue = 1
        isContinuous = true
        controlSize = .small
        target = self
        action = #selector(changed(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed(_ sender: NSSlider) {
        onChanged?(sender.doubleValue)
    }
}

private final class Hairline: NSView {
    enum Axis {
        case horizontal
        case vertical
    }

    private let axis: Axis

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: axis == .vertical ? .horizontal : .vertical)
        setContentCompressionResistancePriority(.required, for: axis == .vertical ? .horizontal : .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        switch axis {
        case .horizontal:
            return NSSize(width: NSView.noIntrinsicMetric, height: 1)
        case .vertical:
            return NSSize(width: 1, height: NSView.noIntrinsicMetric)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
