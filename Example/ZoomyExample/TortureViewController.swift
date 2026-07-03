import UIKit
import Zoomy

/// Manual-QA harness (M7 §7 — the "Torture" tab). Each button triggers one of the robustness edge
/// cases that can't be exercised by a unit test, so a human can watch the transition degrade or hold
/// up: a source scrolled off-screen, data reloaded so the source vanishes, the keyboard up at present
/// time, a `hidesBottomBarWhenPushed` push, and a half-clipped source tile. Present/push a Zoomy zoom
/// and observe the fallback (cross-dissolve) or the correct zoom.
final class TortureViewController: UIViewController {

    /// A horizontally scrollable strip holding the source tile, so it can be scrolled off-screen.
    private let sourceScrollView: UIScrollView = {
        let view = UIScrollView()
        view.showsHorizontalScrollIndicator = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let sourceTile: UIView = {
        let view = UIView()
        view.backgroundColor = .systemPurple
        view.layer.cornerRadius = 16
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// A `clipsToBounds` container whose tile overflows the bottom edge — a half-clipped source, to
    /// check the resolver's visible-rect handling.
    private let clipContainer: UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 12
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let halfClippedTile: UIView = {
        let view = UIView()
        view.backgroundColor = .systemTeal
        view.layer.cornerRadius = 16
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let keyboardField: UITextField = {
        let field = UITextField()
        field.placeholder = "Focus me, then present"
        field.borderStyle = .roundedRect
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    /// Flipped to `false` by "Reload data then dismiss" so the source provider returns `nil` and the
    /// transition falls back; reset to `true` at the start of the source-resolving scenarios.
    private var sourceIsValid = true

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Torture"
        view.backgroundColor = .systemBackground
        layoutContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from the hidesBottomBarWhenPushed push: restore the bar for this list screen.
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    // MARK: - Layout

    private func layoutContent() {
        sourceScrollView.addSubview(sourceTile)
        clipContainer.addSubview(halfClippedTile)

        let buttons = UIStackView(arrangedSubviews: [
            makeButton("Scroll source offscreen then present", #selector(scrollOffscreenThenPresent)),
            makeButton("Reload data then dismiss (fallback)", #selector(reloadThenPresent)),
            makeButton("Present with keyboard up", #selector(presentWithKeyboardUp)),
            makeButton("hidesBottomBarWhenPushed push", #selector(pushHidesBottomBar)),
            makeButton("Half-clipped cell target", #selector(presentHalfClipped))
        ])
        buttons.axis = .vertical
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sourceScrollView)
        view.addSubview(clipContainer)
        view.addSubview(keyboardField)
        view.addSubview(buttons)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            sourceScrollView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            sourceScrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            sourceScrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            sourceScrollView.heightAnchor.constraint(equalToConstant: 140),

            // The tile sits at the left with a wide trailing gap so it can be scrolled out of view.
            sourceTile.topAnchor.constraint(equalTo: sourceScrollView.topAnchor, constant: 10),
            sourceTile.bottomAnchor.constraint(equalTo: sourceScrollView.bottomAnchor, constant: -10),
            sourceTile.leadingAnchor.constraint(equalTo: sourceScrollView.leadingAnchor, constant: 20),
            sourceTile.widthAnchor.constraint(equalToConstant: 120),
            sourceTile.heightAnchor.constraint(equalToConstant: 120),
            sourceTile.trailingAnchor.constraint(equalTo: sourceScrollView.trailingAnchor, constant: -1200),

            clipContainer.topAnchor.constraint(equalTo: sourceScrollView.bottomAnchor, constant: 16),
            clipContainer.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            clipContainer.widthAnchor.constraint(equalToConstant: 120),
            clipContainer.heightAnchor.constraint(equalToConstant: 80),

            // Overflow the bottom so the tile is visibly half-clipped by the container.
            halfClippedTile.topAnchor.constraint(equalTo: clipContainer.topAnchor, constant: 20),
            halfClippedTile.centerXAnchor.constraint(equalTo: clipContainer.centerXAnchor),
            halfClippedTile.widthAnchor.constraint(equalToConstant: 100),
            halfClippedTile.heightAnchor.constraint(equalToConstant: 100),

            keyboardField.topAnchor.constraint(equalTo: clipContainer.bottomAnchor, constant: 24),
            keyboardField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            keyboardField.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),

            buttons.topAnchor.constraint(equalTo: keyboardField.bottomAnchor, constant: 24),
            buttons.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20)
        ])
    }

    private func makeButton(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.titleAlignment = .center
        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: - Scenarios

    /// Scroll the source out of view, then present: the resolver can't find a visible source, so the
    /// present degrades to a cross-dissolve.
    @objc private func scrollOffscreenThenPresent() {
        sourceIsValid = true
        sourceScrollView.setContentOffset(CGPoint(x: 900, y: 0), animated: false)
        presentZoomDetail(source: sourceTile)
    }

    /// "Reload" invalidates the source (as a diffable reload with new IDs would), so the provider
    /// returns nil and the transition falls back.
    @objc private func reloadThenPresent() {
        sourceIsValid = false
        presentZoomDetail(source: sourceTile)
    }

    /// Focus the text field (keyboard up), then present: `resignsFirstResponders` should dismiss the
    /// keyboard as the zoom begins.
    @objc private func presentWithKeyboardUp() {
        sourceIsValid = true
        sourceScrollView.setContentOffset(.zero, animated: false)
        keyboardField.becomeFirstResponder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.presentZoomDetail(source: self?.sourceTile)
        }
    }

    /// Push a detail that hides the bottom bar — exercises the tab-bar snapshot fade.
    @objc private func pushHidesBottomBar() {
        sourceIsValid = true
        sourceScrollView.setContentOffset(.zero, animated: false)
        let detail = makeDetail(context: .push)
        detail.hidesBottomBarWhenPushed = true
        detail.zoomTransition = makeTransition(source: sourceTile)
        navigationController?.pushViewController(detail, animated: true)
    }

    /// Present from the half-clipped tile — the source's visible rect is smaller than its frame.
    @objc private func presentHalfClipped() {
        sourceIsValid = true
        presentZoomDetail(source: halfClippedTile)
    }

    /// Screenshot / UI-test affordance: trigger the source-offscreen fallback present without a tap.
    /// Inert unless invoked from `SceneDelegate` under the `-zoomyTortureFallback` launch argument.
    func triggerFallbackPresentForDemo() {
        scrollOffscreenThenPresent()
    }

    // MARK: - Present helpers

    private func presentZoomDetail(source: UIView?) {
        let detail = makeDetail(context: .modal)
        detail.zoomTransition = makeTransition(source: source)
        present(detail, animated: true)
    }

    private func makeDetail(context: PhotoDetailViewController.PresentationContext) -> PhotoDetailViewController {
        let item = PhotoItem(id: UUID(), color: sourceTile.backgroundColor ?? .systemPurple)
        return PhotoDetailViewController(item: item, presentationContext: context)
    }

    private func makeTransition(source: UIView?) -> ZoomTransition {
        ZoomTransition { [weak self, weak source] _ in
            guard let self, self.sourceIsValid, let source, source.window != nil else { return nil }
            return source
        }
    }
}
