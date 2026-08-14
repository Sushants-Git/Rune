import Cocoa

/// The diff, beside the terminal rather than in a window of its own.
///
/// Not a pane in the split tree, deliberately. `SplitPane` is typed to a
/// terminal through every path that touches it — focus, dimming, the find bar,
/// zoom, close — and a diff answers almost none of those questions. Making it a
/// pane means a protocol through all of that, and the reward is being able to
/// split a diff against a diff, which nobody asked for.
///
/// So it sits alongside the tab instead: the terminal area gives up the width,
/// the panel takes it, and a divider moves the line between them. It
/// full-screens because the window does, and it goes away leaving the pane tree
/// exactly as it was.
@MainActor
final class DiffPanel: NSView {
    private let diffView = DiffView()
    private let status = NSTextField(labelWithString: "")
    private let divider = DiffDivider()

    /// Where the panel's left edge is being dragged to, in the container's
    /// coordinates. The controller owns the width; this only reports.
    var onResize: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?

    static let minimumWidth: CGFloat = 320

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor


        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)


        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        diffView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(diffView)

        divider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.onResize?(self.frame.width - delta)
        }
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 6),

            // One line of chrome, not two. The panel's contents say what it is.
            status.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            rule.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),

            diffView.topAnchor.constraint(equalTo: rule.bottomAnchor),
            diffView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            diffView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }


    // MARK: - Content

    func show(files: [GitDiff.File], root: String?, directory: String) {
        diffView.show(files)
        let added = files.reduce(0) { $0 + $1.addedCount }
        let removed = files.reduce(0) { $0 + $1.removedCount }
        let name = root.map { ($0 as NSString).lastPathComponent } ?? directory
        status.stringValue = files.isEmpty
            ? "\(name) is clean"
            : "\(name) · \(files.count) file\(files.count == 1 ? "" : "s"), +\(added) −\(removed)"
    }

    func showMessage(_ message: String) {
        diffView.show([])
        status.stringValue = message
    }

    func goToHunk(_ delta: Int) { diffView.goToHunk(delta) }

    func takeFocus() { window?.makeFirstResponder(diffView) }
}

/// The grab handle down the panel's left edge.
private final class DiffDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var origin: CGFloat?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let x = convert(event.locationInWindow, from: nil).x
        onDrag?(x - origin)
    }

    override func mouseUp(with event: NSEvent) {
        origin = nil
    }
}
