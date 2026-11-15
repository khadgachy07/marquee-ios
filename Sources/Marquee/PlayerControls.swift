#if os(iOS)
import AVFoundation
import AVKit
import UIKit

/// Netflix-style controls over the video, replacing Apple's: back, title and AirPlay along the top; back 10 s,
/// play/pause and forward 10 s in the middle; a red progress bar with the time left, and Speed, Subtitles and
/// Next Episode along the bottom. A tap shows or hides them, a double tap on either side skips 10 s, and they fade
/// out a few seconds into playing (they stay while paused or loading).
@MainActor
final class PlayerControls: UIView, UIGestureRecognizerDelegate {
    var onClose: (() -> Void)?
    var onNextEpisode: (() -> Void)?
    /// What the Subtitles panel lists, built fresh each time it opens.
    var subtitleOptions: (() -> [PlayerOptionSection])?
    /// Told when the controls appear and disappear (the subtitles move up out of their way).
    var onVisibilityChange: ((Bool) -> Void)?

    private weak var player: AVPlayer?
    private weak var playerController: AVPlayerViewController?
    private let content = UIView()
    private let topShade = GradientView(top: true)
    private let bottomShade = GradientView(top: false)
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let routePicker = AVRoutePickerView()
    private let zoomButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let speedButton = UIButton(type: .system)
    private let subtitlesButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let skipLeft = SkipBadge(forward: false)
    private let skipRight = SkipBadge(forward: true)

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var hideTask: Task<Void, Never>?
    private var visible = false
    private var scrubbing = false
    /// A Subtitles or Speed panel is open (the controls stay put underneath).
    private var panelOpen = false
    private var speed: Float = 1

    func install(on controller: AVPlayerViewController) {
        guard let view = controller.view, let player = controller.player else { return }
        self.player = player
        playerController = controller
        translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor), trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topAnchor.constraint(equalTo: view.topAnchor), bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        build()
        observe(player)

        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        // Pinch out to fill the screen (cropping the edges), pinch in to see the whole picture.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for gesture in [single, double, pinch] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        show()
    }

    func setTitle(_ title: String) {
        titleLabel.text = title
    }

    /// Shows the Next Episode button (only when there is one).
    func setHasNextEpisode(_ hasNext: Bool) {
        nextButton.isHidden = !hasNext
    }

    func stop() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        hideTask?.cancel()
    }

    // MARK: - Building

    private func build() {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        pin(content, to: self)
        for shade in [topShade, bottomShade] {
            shade.translatesAutoresizingMaskIntoConstraints = false
            shade.isUserInteractionEnabled = false
            content.addSubview(shade)
        }

        style(closeButton, symbol: "chevron.backward", size: 22)
        closeButton.accessibilityLabel = "Close"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        routePicker.tintColor = .white
        routePicker.activeTintColor = .systemRed
        routePicker.prioritizesVideoDevices = true
        zoomButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setZoomed(!isZoomed)
            scheduleHide()
        }, for: .touchUpInside)
        setZoomed(false)

        style(backButton, symbol: "gobackward.10", size: 34)
        backButton.accessibilityLabel = "Back 10 seconds"
        backButton.addAction(UIAction { [weak self] _ in self?.skip(-10) }, for: .touchUpInside)
        style(forwardButton, symbol: "goforward.10", size: 34)
        forwardButton.accessibilityLabel = "Forward 10 seconds"
        forwardButton.addAction(UIAction { [weak self] _ in self?.skip(10) }, for: .touchUpInside)
        style(playButton, symbol: "pause.fill", size: 48)
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)
        spinner.color = .white
        spinner.hidesWhenStopped = true

        slider.minimumTrackTintColor = .systemRed
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.setThumbImage(Self.thumb(diameter: 14), for: .normal)
        slider.setThumbImage(Self.thumb(diameter: 22), for: .highlighted)
        slider.addAction(UIAction { [weak self] _ in self?.scrubBegan() }, for: .touchDown)
        slider.addAction(UIAction { [weak self] _ in self?.scrubMoved() }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in self?.scrubEnded() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        timeLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Full-screen panels rather than pop-up menus: with Apple's controls off, its player draws menus underneath.
        styleRow(speedButton, symbol: "gauge.with.dots.needle.67percent", title: "Speed (1x)")
        speedButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            openPanel("Playback Speed", [PlayerOptionSection(title: "Playback Speed", options: speedOptions())])
        }, for: .touchUpInside)
        styleRow(subtitlesButton, symbol: "captions.bubble", title: "Subtitles")
        subtitlesButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            openPanel("Subtitles", subtitleOptions?() ?? [])
        }, for: .touchUpInside)
        styleRow(nextButton, symbol: "forward.end.fill", title: "Next Episode")
        nextButton.addAction(UIAction { [weak self] _ in self?.onNextEpisode?() }, for: .touchUpInside)
        nextButton.isHidden = true

        let top = UIStackView(arrangedSubviews: [closeButton, titleLabel, zoomButton, routePicker])
        top.alignment = .center
        top.spacing = 12
        let middle = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        middle.alignment = .center
        middle.spacing = 72
        let bar = UIStackView(arrangedSubviews: [slider, timeLabel])
        bar.alignment = .center
        bar.spacing = 14
        let row = UIStackView(arrangedSubviews: [speedButton, subtitlesButton, nextButton])
        row.alignment = .center
        row.spacing = 36
        for stack in [top, middle, bar, row] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(stack)
        }
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        for badge in [skipLeft, skipRight] {
            badge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(badge)
        }

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topShade.topAnchor.constraint(equalTo: content.topAnchor),
            topShade.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topShade.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topShade.heightAnchor.constraint(equalToConstant: 110),
            bottomShade.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomShade.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomShade.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomShade.heightAnchor.constraint(equalToConstant: 150),

            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            top.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            top.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            zoomButton.widthAnchor.constraint(equalToConstant: 44),
            zoomButton.heightAnchor.constraint(equalToConstant: 44),
            routePicker.widthAnchor.constraint(equalToConstant: 44),
            routePicker.heightAnchor.constraint(equalToConstant: 44),

            middle.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            middle.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            skipLeft.centerYAnchor.constraint(equalTo: centerYAnchor),
            skipLeft.centerXAnchor.constraint(equalTo: guide.leadingAnchor, constant: 110),
            skipRight.centerYAnchor.constraint(equalTo: centerYAnchor),
            skipRight.centerXAnchor.constraint(equalTo: guide.trailingAnchor, constant: -110),

            // Above the home-bar strip, where iOS holds taps back for its own swipe.
            row.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -6),
            row.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -10),
            bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
        ])
    }

    private func style(_ button: UIButton, symbol: String, size: CGFloat) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
        config.baseForegroundColor = .white
        button.configuration = config
    }

    private func styleRow(_ button: UIButton, symbol: String, title: String) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        config.imagePadding = 8
        config.baseForegroundColor = .white
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
        button.configuration = config
    }

    private func pin(_ view: UIView, to other: UIView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: other.leadingAnchor), view.trailingAnchor.constraint(equalTo: other.trailingAnchor),
            view.topAnchor.constraint(equalTo: other.topAnchor), view.bottomAnchor.constraint(equalTo: other.bottomAnchor),
        ])
    }

    private static func thumb(diameter: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { _ in
            UIColor.systemRed.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        }
    }

    // MARK: - Following the player

    private func observe(_ player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTime() }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.statusChanged(status) }
        }
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        let playing = status != .paused
        style(playButton, symbol: playing ? "pause.fill" : "play.fill", size: 48)
        playButton.accessibilityLabel = playing ? "Pause" : "Play"
        if status == .waitingToPlayAtSpecifiedRate {
            spinner.startAnimating()
            playButton.alpha = 0
        } else {
            spinner.stopAnimating()
            playButton.alpha = 1
        }
        if status == .playing { scheduleHide() } else { show() }
    }

    private var duration: Double {
        let seconds = player?.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private var current: Double {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private func refreshTime() {
        guard !scrubbing else { return }
        let total = duration
        slider.value = total > 0 ? Float(current / total) : 0
        timeLabel.text = Self.clock(max(total - current, 0))
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Actions

    private func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            player.playImmediately(atRate: speed)
        } else {
            player.pause()
        }
    }

    private func skip(_ seconds: Double) {
        guard let player else { return }
        let target = min(max(current + seconds, 0), max(duration - 1, 0))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        (seconds < 0 ? skipLeft : skipRight).flash()
        if visible { scheduleHide() }
    }

    private func scrubBegan() {
        scrubbing = true
        hideTask?.cancel()
    }

    private func scrubMoved() {
        let target = Double(slider.value) * duration
        timeLabel.text = Self.clock(max(duration - target, 0))
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
    }

    private func scrubEnded() {
        let target = Double(slider.value) * duration
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scrubbing = false
                self?.scheduleHide()
            }
        }
    }

    private func speedOptions() -> [PlayerOption] {
        [0.5, 0.75, 1, 1.25, 1.5].map { (rate: Float) in
            PlayerOption(title: rate == 1 ? "1x (Normal)" : "\(Self.rateText(rate))x", isOn: rate == speed) { [weak self] in
                self?.setSpeed(rate)
            }
        }
    }

    private func openPanel(_ title: String, _ sections: [PlayerOptionSection]) {
        let panel = OptionsPanel(title: title, sections: sections)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.alpha = 0
        addSubview(panel)
        pin(panel, to: self)
        panelOpen = true
        hideTask?.cancel()
        panel.onClose = { [weak self] in
            self?.panelOpen = false
            self?.scheduleHide()
        }
        UIView.animate(withDuration: 0.2) { panel.alpha = 1 }
    }

    private static func rateText(_ rate: Float) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(rate)
    }

    private func setSpeed(_ rate: Float) {
        speed = rate
        player?.defaultRate = rate
        if player?.timeControlStatus != .paused { player?.rate = rate }
        styleRow(speedButton, symbol: "gauge.with.dots.needle.67percent", title: "Speed (\(Self.rateText(rate))x)")
    }

    // MARK: - Zoom

    private var isZoomed: Bool { playerController?.videoGravity == .resizeAspectFill }

    private func setZoomed(_ zoomed: Bool) {
        playerController?.videoGravity = zoomed ? .resizeAspectFill : .resizeAspect
        style(zoomButton, symbol: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 18)
        zoomButton.accessibilityLabel = zoomed ? "Fit to screen" : "Fill screen"
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .ended, !panelOpen else { return }
        if gesture.scale > 1.1, !isZoomed { setZoomed(true) }
        if gesture.scale < 0.9, isZoomed { setZoomed(false) }
    }

    // MARK: - Showing and hiding

    @objc private func tapped() {
        guard !panelOpen else { return }
        if visible { hide() } else { show() }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard !panelOpen else { return }
        let x = gesture.location(in: self).x
        if x < bounds.width / 3 {
            skip(-10)
        } else if x > bounds.width * 2 / 3 {
            skip(10)
        } else {
            tapped()
        }
    }

    func show() {
        if !visible {
            visible = true
            onVisibilityChange?(true)
        }
        UIView.animate(withDuration: 0.2) { self.content.alpha = 1 }
        scheduleHide()
    }

    private func hide() {
        hideTask?.cancel()
        guard visible else { return }
        visible = false
        onVisibilityChange?(false)
        UIView.animate(withDuration: 0.3) { self.content.alpha = 0 }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !panelOpen, !scrubbing, player?.timeControlStatus == .playing else { return }
            hide()
        }
    }

    // Taps on buttons and the progress bar are theirs; the rest show/hide the controls.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, current !== self {
            if current is UIControl || current is AVRoutePickerView { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { other.view !== self }
}

/// "10" with an arrow that flashes where a double tap skipped.
private final class SkipBadge: UILabel {
    init(forward: Bool) {
        super.init(frame: .zero)
        let symbol = forward ? "goforward.10" : "gobackward.10"
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let text = NSMutableAttributedString(attachment: NSTextAttachment(image: image ?? UIImage()))
        attributedText = text
        alpha = 0
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func flash() {
        layer.removeAllAnimations()
        alpha = 1
        UIView.animate(withDuration: 0.4, delay: 0.4) { self.alpha = 0 }
    }
}

/// A soft black fade behind the top or bottom controls.
private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(top: Bool) {
        super.init(frame: .zero)
        let gradient = layer as! CAGradientLayer
        let dark = UIColor.black.withAlphaComponent(0.75).cgColor
        gradient.colors = top ? [dark, UIColor.clear.cgColor] : [UIColor.clear.cgColor, dark]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

#endif
