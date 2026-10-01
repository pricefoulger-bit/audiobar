import AppKit
import CoreAudio

/// Scrollable device column. Rows are frame-positioned so the list does not depend on
/// a stack view inside an `NSScrollView` document view. The list reports the height it
/// needs (`preferredHeight`) so the panel can size to its rows instead of a fixed box.
final class DeviceListView: NSView {
    static let rowHeight: CGFloat = 30
    static let maxVisibleRows = 4
    /// Lists never shrink below this many rows, so both columns stay the same height.
    static let minVisibleRows = 4
    private static let inset: CGFloat = 4
    private static let emptyHeight: CGFloat = 34
    
    var onSelect: ((AudioDeviceID) -> Void)?
    var onDisconnect: ((AudioDeviceID) -> Void)?

    private let emptyMessage: String
    private let scrollView = NSScrollView(frame: .zero)
    private let document = FlippedView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "")
    private var rows: [DeviceRowView] = []
    private var direction: AudioDirection = .output

    /// Height that shows every row, capped at `maxVisibleRows`; beyond that the list scrolls.
    var preferredHeight: CGFloat {
        let visible = min(max(rows.count, Self.minVisibleRows), Self.maxVisibleRows)
        return CGFloat(visible) * Self.rowHeight + Self.inset * 2
    }

    init(emptyMessage: String) {
        self.emptyMessage = emptyMessage
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        emptyLabel.stringValue = emptyMessage
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        document.addSubview(emptyLabel)

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Layer colors are resolved here, inside the view's own appearance, so light/dark
    // switches pick up the right tint.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = 0.5
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func setDevices(
        _ devices: [AudioDevice],
        selected: AudioDeviceID,
        direction: AudioDirection,
        disconnectIDs: Set<AudioDeviceID>,
        disconnectEnabled: Bool
    ) {
        self.direction = direction
        if devices.map(\.id) == rows.map(\.deviceID) {
            for (device, row) in zip(devices, rows) {
                row.apply(
                    device: device,
                    direction: direction,
                    selected: device.id == selected,
                    showsDisconnect: disconnectIDs.contains(device.id),
                    disconnectEnabled: disconnectEnabled
                )
            }
            emptyLabel.isHidden = !devices.isEmpty
            needsLayout = true
            return
        }

        for row in rows {
            row.removeFromSuperview()
        }
        rows = devices.map { device in
            let row = DeviceRowView(frame: .zero)
            row.apply(
                device: device,
                direction: direction,
                selected: device.id == selected,
                showsDisconnect: disconnectIDs.contains(device.id),
                disconnectEnabled: disconnectEnabled
            )
            row.onClick = { [weak self] id in
                self?.onSelect?(id)
            }
            row.onDisconnect = { [weak self] id in
                self?.onDisconnect?(id)
            }
            document.addSubview(row)
            return row
        }
        emptyLabel.isHidden = !devices.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    private func layoutRows() {
        let width = scrollView.contentView.bounds.width
        guard width > 1 else { return }
        if rows.isEmpty {
            let height = max(bounds.height, Self.emptyHeight)
            document.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let labelHeight: CGFloat = 16
            emptyLabel.frame = NSRect(
                x: 8,
                y: max(0, (height - labelHeight) / 2),
                width: max(0, width - 16),
                height: labelHeight
            )
            return
        }
        var y = Self.inset
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: Self.rowHeight)
            y += Self.rowHeight
        }
        let height = max(y + Self.inset, scrollView.contentView.bounds.height)
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class DeviceRowView: NSView {
    var deviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    var onClick: ((AudioDeviceID) -> Void)?
    var onDisconnect: ((AudioDeviceID) -> Void)?
    private var selected = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    private let iconView = NSImageView(frame: .zero)
    private let nameField = NSTextField(labelWithString: "")
    private let checkView = NSImageView(frame: .zero)
    private let disconnectButton = NSButton(frame: .zero)
    private let disconnectWidth: NSLayoutConstraint

    override init(frame: NSRect) {
        disconnectWidth = disconnectButton.widthAnchor.constraint(equalToConstant: 0)
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameField.font = .systemFont(ofSize: 13)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        checkView.image = Symbols.image("checkmark", pointSize: 11, weight: .bold, description: "Current device")
        checkView.contentTintColor = .controlAccentColor
        checkView.imageScaling = .scaleProportionallyDown
        checkView.translatesAutoresizingMaskIntoConstraints = false

        disconnectButton.image = Symbols.image("xmark.circle.fill", pointSize: 12, weight: .regular, description: "Disconnect")
        disconnectButton.imagePosition = .imageOnly
        disconnectButton.isBordered = false
        disconnectButton.toolTip = "Disconnect"
        disconnectButton.setAccessibilityLabel("Disconnect")
        disconnectButton.contentTintColor = .tertiaryLabelColor
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectPressed)
        disconnectButton.translatesAutoresizingMaskIntoConstraints = false
        disconnectButton.isHidden = true

        addSubview(iconView)
        addSubview(nameField)
        addSubview(disconnectButton)
        addSubview(checkView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: disconnectButton.leadingAnchor, constant: -4),

            disconnectButton.trailingAnchor.constraint(equalTo: checkView.leadingAnchor, constant: -4),
            disconnectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disconnectWidth,
            disconnectButton.heightAnchor.constraint(equalToConstant: 16),

            checkView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            checkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 14),
            checkView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        device: AudioDevice,
        direction: AudioDirection,
        selected: Bool,
        showsDisconnect: Bool,
        disconnectEnabled: Bool
    ) {
        deviceID = device.id
        nameField.stringValue = device.name
        disconnectButton.isHidden = !showsDisconnect
        disconnectButton.isEnabled = disconnectEnabled
        disconnectWidth.constant = showsDisconnect ? 16 : 0
        toolTip = "\(device.name) — \(TransportInfo.label(device.transport))"
        iconView.image = Symbols.image(
            TransportInfo.symbol(transport: device.transport, direction: direction),
            pointSize: 13,
            weight: .regular,
            description: nil
        )
        setSelected(selected)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(device.name)
        setAccessibilityValue(selected ? "Current device" : nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 1)
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        } else if hovered {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if disconnectWidth.constant > 0, disconnectButton.frame.contains(point) {
            return
        }
        onClick?(deviceID)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        let local = convert(point, from: superview)
        if disconnectWidth.constant > 0, disconnectButton.frame.contains(local) {
            return disconnectButton
        }
        return self
    }

    @objc private func disconnectPressed() {
        onDisconnect?(deviceID)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func setSelected(_ selected: Bool) {
        self.selected = selected
        checkView.isHidden = !selected
        nameField.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        iconView.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        needsDisplay = true
    }
}
