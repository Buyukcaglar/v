import AppKit

/// The pen's colours and line widths, followed by `tools` (Undo and Save). It takes the
/// filmstrip's place while drawing, and remembers the pen picked last.
final class MarkupBar: NSView {
    private(set) var color: MarkColor
    private(set) var width: MarkWidth
    /// The user picked a colour or a width.
    var onChange: (() -> Void)?

    private var swatches: [Pick] = []
    private var widths: [Pick] = []
    private static let colorKey = "MarkColor", widthKey = "MarkWidth"

    init(tools: [NSView]) {
        let defaults = UserDefaults.standard
        color = MarkColor.palette.first { $0.name == defaults.string(forKey: Self.colorKey) } ?? MarkColor.palette[0]
        width = MarkWidth(rawValue: defaults.integer(forKey: Self.widthKey)) ?? .medium
        super.init(frame: .zero)
        swatches = MarkColor.palette.map { c in
            Pick(size: NSSize(width: 26, height: 26), tip: c.name, action: { [unowned self] in
                self.color = c
                self.picked()
            }, draw: { pick, rect in Self.drawSwatch(c, in: rect, selected: pick.isSelected) })
        }
        widths = MarkWidth.allCases.map { w in
            Pick(size: NSSize(width: 36, height: 26), tip: w.name, action: { [unowned self] in
                self.width = w
                self.picked()
            }, draw: { pick, rect in
                Self.drawWidth(w, in: rect, selected: pick.isSelected, scale: pick.window?.backingScaleFactor ?? 2)
            })
        }
        let stack = NSStackView(views: swatches + [Self.gap()] + widths + [Self.gap()] + tools)
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func picked() {
        UserDefaults.standard.set(color.name, forKey: Self.colorKey)
        UserDefaults.standard.set(width.rawValue, forKey: Self.widthKey)
        update()
        onChange?()
    }

    private func update() {
        for (pick, c) in zip(swatches, MarkColor.palette) { pick.isSelected = c == color }
        for (pick, w) in zip(widths, MarkWidth.allCases) { pick.isSelected = w == width }
    }

    private static func gap() -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return v
    }

    private static func drawSwatch(_ color: MarkColor, in rect: NSRect, selected: Bool) {
        if selected {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 2
            NSColor.white.setStroke()
            ring.stroke()
        }
        let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 5.5, dy: 5.5))
        color.nsColor.setFill()
        dot.fill()
        // An edge keeps the dark colours visible on the dimmed desktop.
        dot.lineWidth = 1
        NSColor(white: 1, alpha: 0.45).setStroke()
        dot.stroke()
    }

    /// A line as thick as the pen draws it on screen, on whole pixels.
    private static func drawWidth(_ width: MarkWidth, in rect: NSRect, selected: Bool, scale: CGFloat) {
        if selected {
            NSColor(white: 1, alpha: 0.22).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let thickness = CGFloat(width.rawValue) / scale
        let y = ((rect.midY - thickness / 2) * scale).rounded() / scale
        NSColor.white.setFill()
        NSRect(x: rect.minX + 8, y: y, width: rect.width - 16, height: thickness).fill()
    }
}

/// A colour or a width to pick, drawn by `draw`; the one in use is ringed or shaded.
private final class Pick: NSView {
    var isSelected = false {
        didSet {
            if isSelected != oldValue { needsDisplay = true }
            setAccessibilitySelected(isSelected)
        }
    }
    private let size: NSSize
    private let action: () -> Void
    private let drawing: (Pick, NSRect) -> Void

    init(size: NSSize, tip: String, action: @escaping () -> Void, draw: @escaping (Pick, NSRect) -> Void) {
        self.size = size
        self.action = action
        drawing = draw
        super.init(frame: NSRect(origin: .zero, size: size))
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) { drawing(self, bounds) }
    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
