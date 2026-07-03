import UIKit

/// Full-screen detail shown with a Zoomy zoom. Reused by both tabs:
/// - tab 2 (`.modal`) presents it and shows a top-right close button;
/// - tab 1 (`.push`) pushes it onto a navigation controller and relies on the back gesture/button,
///   hiding the navigation bar so the detail reads full-bleed.
///
/// `preferredStatusBarStyle = .lightContent` together with the modal presentation controller's
/// `modalPresentationCapturesStatusBarAppearance = true` demonstrates that the shown VC drives the
/// status bar appearance across the transition.
final class PhotoDetailViewController: UIViewController {

    enum PresentationContext {
        case push
        case modal
    }

    private let item: PhotoItem
    private let presentationContext: PresentationContext

    init(item: PhotoItem, presentationContext: PresentationContext = .modal) {
        self.item = item
        self.presentationContext = presentationContext
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

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        // The close button only makes sense for a modal; a pushed detail uses the back gesture/button.
        if presentationContext == .modal {
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
                closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
            ])
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Push detail reads full-bleed: hide the nav bar for this screen. Simple, unconditional
        // application here — fine-grained bar coordination across the transition is M7.
        if presentationContext == .push {
            navigationController?.setNavigationBarHidden(true, animated: animated)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Restore the bar for the grid we're returning to.
        if presentationContext == .push {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}
