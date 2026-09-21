import AppKit
import SwiftUI

// Waveforms are drawn with Core Animation layers instead of SwiftUI Canvas/TimelineView.
// A SwiftUI tick re-evaluates the view graph and runs a window layout pass (~3 ms each on an M-series Mac);
// swapping a CAShapeLayer path costs a fraction of that and never touches layout.

private enum Bars {
    static let step: CGFloat = 5
    static let width: CGFloat = 3
    static let minHeight: CGFloat = 3

    /// One path containing a rounded bar per level, starting at `originX`.
    static func path(_ levels: some Collection<Float>, originX: CGFloat, height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let midY = height / 2
        var x = originX
        for level in levels {
            let barHeight = max(minHeight, CGFloat(level) * height)
            path.addRoundedRect(in: CGRect(x: x, y: midY - barHeight / 2, width: width, height: barHeight),
                                cornerWidth: width / 2, cornerHeight: width / 2)
            x += step
        }
        return path
    }
}

private extension NSView {
    func resolved(_ color: NSColor) -> CGColor {
        var cgColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cgColor = color.cgColor }
        return cgColor
    }

    func makeDisplayLink(fps: Float, action: Selector) -> CADisplayLink {
        let link = displayLink(target: self, selector: action)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        return link
    }
}

// MARK: - Live meter

struct LiveWaveformView: NSViewRepresentable {
    let peaks: @MainActor (Int) -> [Float]

    func makeNSView(context: Context) -> LiveWaveformNSView { LiveWaveformNSView(peaks: peaks) }
    func updateNSView(_ view: LiveWaveformNSView, context: Context) { view.peaks = peaks }
}

/// Scrolling bar meter, newest peak on the right, refreshed at the rate peaks are produced.
final class LiveWaveformNSView: NSView {
    var peaks: @MainActor (Int) -> [Float]

    private let bars = CAShapeLayer()
    private let baseline = CAShapeLayer()
    private var link: CADisplayLink?
    private var lastLevels: [Float] = []

    init(peaks: @escaping @MainActor (Int) -> [Float]) {
        self.peaks = peaks
        super.init(frame: .zero)
        wantsLayer = true
        baseline.lineWidth = 1.5
        baseline.lineCap = .round
        baseline.lineDashPattern = [0.5, 4.5]
        baseline.fillColor = nil
        layer?.addSublayer(baseline)
        layer?.addSublayer(bars)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        link?.invalidate()
        link = window == nil ? nil : makeDisplayLink(fps: Float(Waveform.peaksPerSecond), action: #selector(tick))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        bars.frame = bounds
        baseline.frame = bounds
        redraw(force: true)
    }

    @objc private func tick() { redraw(force: false) }

    private func redraw(force: Bool) {
        let slots = max(0, Int(bounds.width / Bars.step))
        let levels = peaks(slots)
        guard force || levels != lastLevels else { return }
        lastLevels = levels

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let filledWidth = CGFloat(levels.count) * Bars.step
        bars.path = Bars.path(levels, originX: bounds.width - filledWidth, height: bounds.height)
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 0, y: bounds.midY))
        line.addLine(to: CGPoint(x: max(0, bounds.width - filledWidth), y: bounds.midY))
        baseline.path = line
        CATransaction.commit()
    }

    private func updateColors() {
        bars.fillColor = resolved(NSColor(Color.record))
        baseline.strokeColor = resolved(.secondaryLabelColor.withAlphaComponent(0.35))
    }
}

// MARK: - Playback

struct PlaybackWaveformView: NSViewRepresentable {
    let peaks: [Float]
    let isPlaying: Bool
    /// Only passed so SwiftUI refreshes the view after seeks and skips while paused.
    let pausedPosition: TimeInterval
    /// Current position as a 0…1 fraction; sampled every frame while playing.
    let progress: @MainActor () -> Double
    let seek: @MainActor (Double) -> Void

    func makeNSView(context: Context) -> PlaybackWaveformNSView {
        PlaybackWaveformNSView(progress: progress, seek: seek)
    }

    func updateNSView(_ view: PlaybackWaveformNSView, context: Context) {
        view.progress = progress
        view.seek = seek
        view.peaks = peaks
        view.isPlaying = isPlaying
        view.updateProgress()
    }
}

/// Bars are built once per data/size change; playback only slides a mask and the playhead.
final class PlaybackWaveformNSView: NSView {
    var progress: @MainActor () -> Double
    var seek: @MainActor (Double) -> Void
    var peaks: [Float] = [] {
        didSet { if peaks != oldValue { rebuild() } }
    }
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            link?.invalidate()
            link = isPlaying && window != nil ? makeDisplayLink(fps: 30, action: #selector(tick)) : nil
        }
    }

    private let remaining = CAShapeLayer()
    private let played = CAShapeLayer()
    private let playedMask = CALayer()
    private let playhead = CALayer()
    private var link: CADisplayLink?

    init(progress: @escaping @MainActor () -> Double, seek: @escaping @MainActor (Double) -> Void) {
        self.progress = progress
        self.seek = seek
        super.init(frame: .zero)
        wantsLayer = true
        playedMask.backgroundColor = .black
        played.mask = playedMask
        playhead.cornerRadius = 1
        layer?.addSublayer(remaining)
        layer?.addSublayer(played)
        layer?.addSublayer(playhead)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { seek(to: event) }
    override func mouseDragged(with event: NSEvent) { seek(to: event) }

    override func viewDidMoveToWindow() {
        link?.invalidate()
        link = isPlaying && window != nil ? makeDisplayLink(fps: 30, action: #selector(tick)) : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    @objc private func tick() { updateProgress() }

    func updateProgress() {
        let x = bounds.width * min(max(progress(), 0), 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playedMask.frame = CGRect(x: 0, y: 0, width: x, height: bounds.height)
        playhead.frame = CGRect(x: min(x, bounds.width - 2), y: 0, width: 2, height: bounds.height)
        CATransaction.commit()
    }

    private func rebuild() {
        let count = max(1, Int(bounds.width / Bars.step))
        // Fit the whole recording to the width: max-pool long ones, stretch short ones.
        let levels = peaks.count >= count
            ? Waveform.downsample(peaks, to: count)
            : (peaks.isEmpty ? [] : (0..<count).map { peaks[$0 * peaks.count / count] })
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [remaining, played] {
            shape.frame = bounds
            shape.path = Bars.path(levels, originX: 0, height: bounds.height)
        }
        CATransaction.commit()
        updateProgress()
    }

    private func seek(to event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        seek(min(max(x / max(bounds.width, 1), 0), 1))
        updateProgress()
    }

    private func updateColors() {
        remaining.fillColor = resolved(.secondaryLabelColor.withAlphaComponent(0.4))
        played.fillColor = resolved(.controlAccentColor)
        playhead.backgroundColor = resolved(.controlAccentColor)
    }
}
