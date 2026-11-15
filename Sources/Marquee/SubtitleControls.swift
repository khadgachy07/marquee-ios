#if os(iOS)
import AVKit
import MarqueeCore
import UIKit

/// The player's subtitles: the text, drawn over the video, and the menu of the file's subtitle tracks
/// (shown in the Subtitles panel of PlayerControls).
@MainActor
final class SubtitleControls {
    /// What the menu offers: the tracks, which one is on, and what to do when one is picked (nil = Off).
    struct Choices {
        var tracks: [MediaStream] = []
        var selected: Int?
        /// Picture subtitles need the server; downloads don't have them.
        var allowPictureTracks = true
    }

    var choices = Choices()
    var onSelect: ((MediaStream?) -> Void)?

    private let label = UILabel()
    private var shown: String?
    /// Lifted above the progress bar while the controls are showing.
    private var labelBottom: NSLayoutConstraint?

    func install(on controller: AVPlayerViewController) {
        guard let overlay = controller.contentOverlayView else { return }
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)
        let bottom = label.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -34)
        labelBottom = bottom
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            bottom,
            label.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.8),
        ])
    }

    /// Called about ten times a second with the line to show.
    func update(text: String?) {
        guard text != shown else { return }
        shown = text
        guard let text else {
            label.attributedText = nil
            return
        }
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 21, weight: .semibold),
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -2.5,
            .shadow: shadow,
        ])
    }

    /// A short note in the subtitle spot ("Subtitles unavailable").
    func flash(_ message: String) {
        update(text: message)
        Task {
            try? await Task.sleep(for: .seconds(3))
            if shown == message { update(text: nil) }
        }
    }

    func setLifted(_ lifted: Bool) {
        labelBottom?.constant = lifted ? -128 : -34
        UIView.animate(withDuration: 0.25) { self.label.superview?.layoutIfNeeded() }
    }

    /// The Subtitles panel: Off, English (and untagged tracks, usually English), then Other Languages.
    func sections() -> [PlayerOptionSection] {
        let names = Subtitles.names(for: choices.tracks)
        let tracks = choices.tracks.filter { $0.isSubtitle && ($0.isText || choices.allowPictureTracks) }
        func option(_ track: MediaStream) -> PlayerOption {
            PlayerOption(title: names[track.index] ?? "Subtitles",
                         detail: track.isText ? nil : "Drawn by the server, takes a moment",
                         isOn: choices.selected == track.index) { [weak self] in self?.pick(track) }
        }
        let off = PlayerOption(title: "Off", isOn: choices.selected == nil) { [weak self] in self?.pick(nil) }
        let main = tracks.filter { $0.languageCode == Subtitles.preferredLanguage || $0.languageCode == nil }
        let others = tracks.filter { !main.contains($0) }
        var sections = [PlayerOptionSection(title: "Subtitles", options: [off] + main.map(option))]
        if !others.isEmpty { sections.append(PlayerOptionSection(title: "Other Languages", options: others.map(option))) }
        if tracks.isEmpty { sections[0].note = "This title has no subtitles." }
        return sections
    }

    private func pick(_ track: MediaStream?) {
        choices.selected = track?.index
        onSelect?(track)
    }
}
#endif
