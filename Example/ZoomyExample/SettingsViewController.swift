import UIKit

/// Settings tab: live-adjust the zoom animation's speed (spring response) and bounciness (damping).
/// Changes are written straight to `DemoSettings.shared`, so the next push/present zoom on the Push
/// and Modal tabs picks them up immediately — no restart needed.
final class SettingsViewController: UIViewController {

    private let settings = DemoSettings.shared

    private let speedSlider = UISlider()
    private let speedValueLabel = UILabel()
    private let bounceSlider = UISlider()
    private let bounceValueLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Settings"

        let speedRow = makeSliderRow(
            title: "Speed",
            subtitle: "Zoom duration (spring response). Lower is faster.",
            slider: speedSlider,
            valueLabel: speedValueLabel,
            range: DemoSettings.responseRange,
            value: settings.springResponse,
            action: #selector(speedChanged)
        )
        let bounceRow = makeSliderRow(
            title: "Bounciness",
            subtitle: "Spring damping. Lower overshoots more; 1.0 has no bounce.",
            slider: bounceSlider,
            valueLabel: bounceValueLabel,
            range: DemoSettings.dampingRange,
            value: settings.springDampingRatio,
            action: #selector(bounceChanged)
        )

        let resetButton = UIButton(type: .system)
        resetButton.setTitle("Reset to defaults", for: .normal)
        resetButton.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)

        let hint = UILabel()
        hint.text = "Applies to the Push and Modal zoom transitions. Try a value, then tap a cell."
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [speedRow, bounceRow, resetButton, hint])
        stack.axis = .vertical
        stack.spacing = 32
        stack.setCustomSpacing(24, after: bounceRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])

        updateSpeedLabel()
        updateBounceLabel()
    }

    // MARK: - Row builder

    private func makeSliderRow(
        title: String,
        subtitle: String,
        slider: UISlider,
        valueLabel: UILabel,
        range: ClosedRange<Double>,
        value: Double,
        action: Selector
    ) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        valueLabel.textColor = .secondaryLabel
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        header.axis = .horizontal
        header.alignment = .firstBaseline

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0

        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        slider.addTarget(self, action: action, for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [header, subtitleLabel, slider])
        row.axis = .vertical
        row.spacing = 8
        return row
    }

    // MARK: - Actions

    @objc private func speedChanged() {
        settings.springResponse = Double(speedSlider.value)
        updateSpeedLabel()
    }

    @objc private func bounceChanged() {
        settings.springDampingRatio = Double(bounceSlider.value)
        updateBounceLabel()
    }

    @objc private func resetTapped() {
        settings.resetToDefaults()
        speedSlider.value = Float(settings.springResponse)
        bounceSlider.value = Float(settings.springDampingRatio)
        updateSpeedLabel()
        updateBounceLabel()
    }

    private func updateSpeedLabel() {
        speedValueLabel.text = String(format: "%.2fs", settings.springResponse)
    }

    private func updateBounceLabel() {
        bounceValueLabel.text = String(format: "%.2f", settings.springDampingRatio)
    }
}
