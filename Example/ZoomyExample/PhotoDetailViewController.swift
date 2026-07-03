import UIKit

/// Full-screen detail presented with a Zoomy modal zoom (tab 2). A plain colored background
/// matching the tapped grid item, a centered label, and a top-right close button.
///
/// `preferredStatusBarStyle = .lightContent` together with the presentation controller's
/// `modalPresentationCapturesStatusBarAppearance = true` demonstrates that the presented VC
/// drives the status bar appearance across the transition.
final class PhotoDetailViewController: UIViewController {

    private let item: PhotoItem

    init(item: PhotoItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = item.color

        let label = UILabel()
        label.text = "Photo\n\(item.id.uuidString.prefix(8))"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .black
        label.font = .systemFont(ofSize: 26, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        let closeButton = UIButton(type: .system)
        let closeImage = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30)
        )
        closeButton.setImage(closeImage, for: .normal)
        closeButton.tintColor = .black
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}
