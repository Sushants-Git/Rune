import Cocoa

/// What a terminal is doing right now, as far as Rune can tell from outside it.
///
/// The point is triage. With several agents running, the question you're
/// actually asking is "which one is waiting on me" — so the ⌘K list and the tab
/// strip say so in words, rather than making you visit each one to find out.
///
/// Ordering is by how much it wants you, because a workspace reports the
/// loudest thing any of its terminals is doing. `waiting` outranks `working`
/// deliberately: an agent that's busy needs nothing, an agent that's stopped
/// needs you.
///
/// Two states and silence, and that's the whole set. There used to be a third,
/// `attention`, for an agent holding a permission prompt open or ringing the
/// bell. It didn't earn the distinction: for triage, "it's blocked on you" and
/// "it finished and is waiting" are the same instruction — go to this one,
/// nothing happens without you. A third colour to decode bought nothing.
///
/// There is deliberately no "a command is running" state either.
///
/// Rune used to have one, inferred from how recently libghostty asked for a
/// frame. That was never a measure of output: the renderer also asks for a
/// frame every time the cursor blinks, which is every 600ms, forever. So every
/// focused terminal claimed to be running something for as long as it was open.
/// Knowing a plain command is running needs shell integration (OSC 133), not a
/// guess — until then Rune says nothing about it, which at least is true.
enum Activity: Comparable {
    /// Nothing worth saying: a shell, or an agent that doesn't publish state.
    case idle
    /// An agent is mid-turn.
    case working
    /// Your move: the agent has stopped, whether at its prompt or on a question.
    case waiting

    /// The colour of the indicator. Nil means "say nothing at all", which is
    /// the right answer for a terminal Rune knows nothing about.
    var color: NSColor? {
        switch self {
        case .idle: nil
        case .working: .systemGreen
        case .waiting: .systemBlue
        }
    }

    /// The word Rune actually shows. A coloured dot on its own is a riddle;
    /// this is the answer to it.
    var label: String? {
        switch self {
        case .idle: nil
        case .working: "working"
        case .waiting: "your turn"
        }
    }

    /// Whether the indicator should pulse. Only for the state that is actually
    /// in motion — a steady dot for a steady state.
    var pulses: Bool {
        switch self {
        case .working: true
        case .idle, .waiting: false
        }
    }
}

/// An activity plus whatever the agent said about it, and when it started.
///
/// The detail is what the agent's own session log says it's doing — "Running a
/// command", "Editing Split.swift". See `AgentSession`.
///
/// Deliberately not `Equatable`: the two questions Rune asks of a pair of
/// statuses are "which of these is louder" and "is this worth a redraw", and
/// they have different answers. Conflating them into `==` invites the wrong one.
struct Status {
    var activity: Activity = .idle
    var detail: String?
    /// When this terminal entered this activity, for the elapsed-time readout.
    var since: Date = Date()

    /// The loudest of a set — what a tab or workspace reports on behalf of the
    /// terminals inside it.
    static func loudest(of statuses: [Status]) -> Status {
        statuses.max { $0.activity < $1.activity } ?? Status()
    }

    /// Whether a change is worth redrawing chrome for. `since` deliberately
    /// isn't compared — it moves on its own and would force a redraw a second.
    func differs(from other: Status) -> Bool {
        activity != other.activity || detail != other.detail
    }

    /// `working · 1m 20s` — the elapsed part, or nil for states where how long
    /// it's been says nothing useful. Only `working` gets one: for "your turn"
    /// the clock stopped being information the moment it became your move.
    func elapsedText(now: Date = Date()) -> String? {
        guard activity == .working else { return nil }
        let seconds = Int(now.timeIntervalSince(since))
        guard seconds >= 3 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return seconds % 60 == 0 ? "\(minutes)m" : "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// The breathing an in-motion indicator does.
///
/// A slow breath rather than a blink: it has to be noticeable in the corner of
/// your eye while you're reading something else, and ignorable the rest of the
/// time. A blink is neither.
enum Pulse {
    private static let key = "pulse"

    static func apply(to layer: CALayer?) {
        // Re-adding would restart the cycle, and this is called on every
        // refresh of a terminal that is still doing the same thing.
        guard let layer, layer.animation(forKey: key) == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.35
        animation.duration = 0.9
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key)
    }

    static func remove(from layer: CALayer?) {
        layer?.removeAnimation(forKey: key)
    }
}

/// The full readout — dot, state, and what the agent said it was doing — for
/// the ⌘K list, where the whole point of the row is telling you where to go.
@MainActor
final class ActivityBadge: NSView {
    init?(_ status: Status) {
        guard let color = status.activity.color, let label = status.activity.label else {
            return nil
        }
        super.init(frame: .zero)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        if status.activity.pulses { Pulse.apply(to: dot.layer) }

        // The agent's own word for it wins over Rune's generic one — "Running
        // bash" tells you more than "working" ever could. But only when it's
        // short: a notification body like "Claude is waiting for your input"
        // is a sentence, and a sentence in a badge truncates to nonsense and
        // squeezes the row's name out of the way to do it. Long details become
        // the tooltip and the row keeps the one-word version.
        var text = label
        if let detail = status.detail, detail.count <= Self.maximumDetail {
            text = detail
        }
        if let elapsed = status.elapsedText() { text += " · \(elapsed)" }

        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10.5, weight: .medium)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        toolTip = status.detail

        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = color.withAlphaComponent(0.13).cgColor

        addSubview(dot)
        addSubview(field)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),

            field.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// Anything longer than this is a sentence, not a status.
    private static let maximumDetail = 22

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
