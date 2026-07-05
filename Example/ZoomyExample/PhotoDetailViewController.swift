import UIKit

/// Full-screen detail shown with a Zoomy zoom. Reused by both tabs:
/// - tab 2 (`.modal`) presents it and shows a top-right close button;
/// - tab 1 (`.push`) pushes it onto a navigation controller, hiding the navigation bar so the detail
///   reads full-bleed, and shows a floating top-left back button (plus the back/edge gestures).
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

        switch presentationContext {
        case .modal:
            // Top-right close button dismisses the modal.
            addCornerButton(
                systemImage: "xmark.circle.fill",
                accessibilityLabel: "Close",
                edge: .trailing,
                action: #selector(closeTapped)
            )
        case .push:
            // Top-left back button pops the navigation stack (the nav bar is hidden for full-bleed).
            addCornerButton(
                systemImage: "chevron.backward.circle.fill",
                accessibilityLabel: "Back",
                edge: .leading,
                action: #selector(backTapped)
            )
        }
    }

    private enum CornerEdge { case leading, trailing }

    private func addCornerButton(
        systemImage: String,
        accessibilityLabel: String,
        edge: CornerEdge,
        action: Selector
    ) {
        let button = UIButton(type: .system)
        let image = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30)
        )
        button.setImage(image, for: .normal)
        button.tintColor = .black
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)

        let horizontal: NSLayoutConstraint
        switch edge {
        case .leading:
            horizontal = button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16)
        case .trailing:
            horizontal = button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        }
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            horizontal
        ])
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

    @objc private func backTapped() {
        navigationController?.popViewController(animated: true)
    }
}
