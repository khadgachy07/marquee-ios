#if os(iOS)
import AVKit
import MediaPlayer
import UIKit

/// Netflix-style side controls for the player: drag up or down on the left edge for brightness,
/// on the right edge for volume, with a bar showing the level.
@MainActor
final class SideSliders: NSObject, UIGestureRecognizerDelegate {
    private enum Kind { case brightness, volume }

    private weak var host: UIView?
    private let brightnessBar = LevelBar { $0 < 0.5 ? "sun.min.fill" : "sun.max.fill" }
    private let volumeBar = LevelBar { $0 == 0 ? "speaker.slash.fill" : $0 < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill" }
    /// Moving this view's slider is how apps set the system volume. While it's on screen iOS hides its own
    /// volume pop-up, so the volume buttons show our bar instead (see `volumeObservation`).
    private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 40, height: 40))
    private var volumeObservation: NSKeyValueObservation?
    private var active: Kind?
    private var startLevel: Float = 0
    private var originalBrightness: CGFloat?
    private var hideTask: Task<Void, Never>?

    func install(on controller: AVPlayerViewController) {
        guard let view = controller.view else { return }
        host = view
        volumeView.alpha = 0.01
        view.addSubview(volumeView)

        // On the player's own view (not contentOverlayView, which has no safe area), so the bars clear the Dynamic Island.
        for bar in [brightnessBar, volumeBar] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            bar.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            brightnessBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            volumeBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] session, _ in
            let level = session.outputVolume
            Task { @MainActor in
                guard let self, self.active != .volume else { return }
                self.volumeBar.show(level)
                self.scheduleHide()
            }
        }
    }

    /// Puts the screen brightness back to where it was before the player changed it.
    func restore() {
        if let originalBrightness { screen?.brightness = originalBrightness }
        originalBrightness = nil
        volumeObservation = nil
    }

    private var screen: UIScreen? { host?.window?.windowScene?.screen }

    private func level(_ kind: Kind) -> Float {
        switch kind {
        case .brightness: Float(screen?.brightness ?? 0.5)
        case .volume: AVAudioSession.sharedInstance().outputVolume
        }
    }

    private func set(_ kind: Kind, _ level: Float) {
        switch kind {
        case .brightness:
            screen?.brightness = CGFloat(level)
            brightnessBar.show(level)
        case .volume:
            volumeView.subviews.compactMap { $0 as? UISlider }.first?.value = level
            volumeBar.show(level)
        }
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        switch gesture.state {
        case .began:
            let kind: Kind = gesture.location(in: view).x < view.bounds.midX ? .brightness : .volume
            if kind == .brightness, originalBrightness == nil { originalBrightness = screen?.brightness }
            active = kind
            startLevel = level(kind)
            hideTask?.cancel()
        case .changed:
            guard let active else { return }
            // Dragging 60% of the screen height goes from empty to full.
            let delta = Float(-gesture.translation(in: view).y / (view.bounds.height * 0.6))
            set(active, min(max(startLevel + delta, 0), 1))
        default:
            active = nil
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.3) {
                self.brightnessBar.alpha = 0
                self.volumeBar.alpha = 0
            }
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Only mostly-vertical drags that start near the left or right edge; the middle keeps swipe-down-to-close.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)
        let x = pan.location(in: view).x
        let edge = view.bounds.width * 0.3
        return abs(velocity.y) > abs(velocity.x) && (x < edge || x > view.bounds.width - edge)
    }

    /// The player's own drags (swipe down to close) wait for this one, so an edge drag doesn't close the player.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer
    }
}

/// A thin vertical level bar with an icon underneath.
private final class LevelBar: UIView {
    private static let trackHeight: CGFloat = 140

    private let symbol: (Float) -> String
    private let fill = UIView()
    private let icon = UIImageView()
    private lazy var fillHeight = fill.heightAnchor.constraint(equalToConstant: 0)

    init(symbol: @escaping (Float) -> String) {
        self.symbol = symbol
        super.init(frame: .zero)
        alpha = 0
        isUserInteractionEnabled = false

        let track = UIView()
        track.backgroundColor = .white.withAlphaComponent(0.3)
        track.layer.cornerRadius = 3
        track.clipsToBounds = true
        fill.backgroundColor = .white
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        for view in [track, fill, icon] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(track)
        track.addSubview(fill)
        addSubview(icon)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            track.topAnchor.constraint(equalTo: topAnchor),
            track.centerXAnchor.constraint(equalTo: centerXAnchor),
            track.widthAnchor.constraint(equalToConstant: 6),
            track.heightAnchor.constraint(equalToConstant: Self.trackHeight),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: track.trailingAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillHeight,
            icon.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 10),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            icon.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ level: Float) {
        fillHeight.constant = Self.trackHeight * CGFloat(level)
        icon.image = UIImage(systemName: symbol(level))
        layer.removeAllAnimations()
        alpha = 1
    }
}
#endif
