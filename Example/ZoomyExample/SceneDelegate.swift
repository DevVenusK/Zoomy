import UIKit
import Zoomy

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let (tabBarController, pushGrid, torture) = makeRootTabBarController()
        window.rootViewController = tabBarController
        window.makeKeyAndVisible()
        self.window = window

        // Screenshot / UI-test affordance: jump to the Torture tab and auto-trigger the source-
        // offscreen fallback present so the cross-dissolve fallback can be captured. No-op otherwise.
        if ProcessInfo.processInfo.arguments.contains("-zoomyTortureFallback") {
            tabBarController.selectedIndex = 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                torture.triggerFallbackPresentForDemo()
            }
        }

        // Screenshot / UI-test affordance: jump straight to the Settings tab. No-op otherwise.
        if ProcessInfo.processInfo.arguments.contains("-zoomySettings") {
            tabBarController.selectedIndex = 3
        }

        // Screenshot / UI-test affordance: stay on the Push tab and auto-push the first item so the
        // push zoom can be captured without a synthesized tap. No-op otherwise.
        if ProcessInfo.processInfo.arguments.contains("-zoomyDemoPush") {
            tabBarController.selectedIndex = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                pushGrid.pushFirstItemForDemo()
            }
            // Then pop back so a single run exercises push zoom *and* the adjacent pop zoom.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                pushGrid.navigationController?.popViewController(animated: true)
            }
        }
    }

    private func makeRootTabBarController()
        -> (UITabBarController, GridViewController, TortureViewController) {
        let pushGrid = GridViewController()
        pushGrid.title = "Push"
        let pushTab = UINavigationController(rootViewController: pushGrid)
        // Install the Zoomy navigation proxy so single-step push/pop of a VC carrying a
        // `zoomTransition` animates as a zoom while any other delegate messages still forward.
        pushTab.enableZoomTransitions()
        pushTab.tabBarItem = UITabBarItem(
            title: "Push",
            image: UIImage(systemName: "square.grid.3x3"),
            tag: 0
        )

        let modalTab = GridViewController()
        modalTab.mode = .modal
        modalTab.title = "Modal"
        modalTab.tabBarItem = UITabBarItem(
            title: "Modal",
            image: UIImage(systemName: "rectangle.portrait.on.rectangle.portrait"),
            tag: 1
        )

        // Torture tab (M7 §7): manual-QA harness for the edge cases that can't be unit-tested. Wrapped
        // in a navigation controller (with the Zoomy proxy) so the hidesBottomBarWhenPushed push
        // scenario has a nav stack and a tab bar to snapshot.
        let torture = TortureViewController()
        let tortureTab = UINavigationController(rootViewController: torture)
        tortureTab.enableZoomTransitions()
        tortureTab.tabBarItem = UITabBarItem(
            title: "Torture",
            image: UIImage(systemName: "tornado"),
            tag: 2
        )

        // Settings tab: live-adjust the zoom animation speed/bounciness (DemoSettings).
        let settings = SettingsViewController()
        let settingsTab = UINavigationController(rootViewController: settings)
        settingsTab.tabBarItem = UITabBarItem(
            title: "Settings",
            image: UIImage(systemName: "slider.horizontal.3"),
            tag: 3
        )

        let tabBarController = UITabBarController()
        tabBarController.viewControllers = [pushTab, modalTab, tortureTab, settingsTab]
        return (tabBarController, pushGrid, torture)
    }
}
