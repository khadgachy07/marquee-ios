#if os(iOS)
import UIKit

/// One choice in an options panel ("English", "1.25x").
struct PlayerOption {
    let title: String
    var detail: String?
    let isOn: Bool
    let select: () -> Void
}

struct PlayerOptionSection {
    let title: String
    var options: [PlayerOption]
    /// Shown under the heading when there's nothing to pick.
    var note: String?
}

/// A Netflix-style full-screen panel over the video (Subtitles, Speed): a dark backdrop, a heading, a list of
/// choices with a check by the current one, and a close button. Picking a choice closes it.
@MainActor
final class OptionsPanel: UIView {
    var onClose: (() -> Void)?

    init(title: String, sections: [PlayerOptionSection]) {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.88)

        let heading = UILabel()
        heading.text = title
        heading.textColor = .white
        heading.font = .systemFont(ofSize: 22, weight: .bold)

        var close = UIButton.Configuration.plain()
        close.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        close.baseForegroundColor = .white
        let closeButton = UIButton(configuration: close)
        closeButton.accessibilityLabel = "Close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss() }, for: .touchUpInside)

        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 2
        for section in sections {
            if sections.count > 1 || section.title != title {
                let header = UILabel()
                header.text = section.title.uppercased()
                header.textColor = UIColor.white.withAlphaComponent(0.55)
                header.font = .systemFont(ofSize: 13, weight: .semibold)
                list.addArrangedSubview(header)
                list.setCustomSpacing(8, after: header)
            }
            if let note = section.note {
                let label = UILabel()
                label.text = note
                label.textColor = UIColor.white.withAlphaComponent(0.7)
                label.font = .systemFont(ofSize: 17)
                list.addArrangedSubview(label)
            }
            for option in section.options {
                list.addArrangedSubview(row(option))
            }
            if let last = list.arrangedSubviews.last { list.setCustomSpacing(22, after: last) }
        }

        let scroll = UIScrollView()
        scroll.indicatorStyle = .white
        scroll.alwaysBounceVertical = true
        for view in [heading, closeButton, scroll, list] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(heading)
        addSubview(closeButton)
        addSubview(scroll)
        scroll.addSubview(list)

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            closeButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            heading.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            heading.centerXAnchor.constraint(equalTo: centerXAnchor),

            scroll.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            scroll.centerXAnchor.constraint(equalTo: centerXAnchor),
            scroll.widthAnchor.constraint(equalTo: guide.widthAnchor, multiplier: 0.5),
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            list.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func row(_ option: PlayerOption) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        config.imagePadding = 14
        config.imageColorTransformer = UIConfigurationColorTransformer { _ in option.isOn ? .white : .clear }
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 4, bottom: 10, trailing: 4)
        config.attributedTitle = AttributedString(option.title, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 18, weight: option.isOn ? .bold : .regular),
            .foregroundColor: option.isOn ? UIColor.white : UIColor.white.withAlphaComponent(0.75),
        ]))
        if let detail = option.detail {
            config.attributedSubtitle = AttributedString(detail, attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.white.withAlphaComponent(0.5),
            ]))
        }
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.accessibilityTraits.insert(option.isOn ? .selected : [])
        button.addAction(UIAction { [weak self] _ in
            option.select()
            self?.dismiss()
        }, for: .touchUpInside)
        return button
    }

    func dismiss() {
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in
            self.removeFromSuperview()
            self.onClose?()
        }
    }
}
#endif
