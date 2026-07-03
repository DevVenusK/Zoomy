import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let (tabBarController, modalGrid) = makeRootTabBarController()
        window.rootViewController = tabBarController
        window.makeKeyAndVisible()
        self.window = window

        // Screenshot / UI-test affordance: jump to the Modal tab and auto-present the first item
        // so the zoom transition can be captured without a synthesized tap. No-op otherwise.
        if ProcessInfo.processInfo.arguments.contains("-zoomyDemoPresent") {
            tabBarController.selectedIndex = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                modalGrid.presentFirstItemForDemo()
            }
        }
    }

    private func makeRootTabBarController() -> (UITabBarController, GridViewController) {
        let pushGrid = GridViewController()
        pushGrid.title = "Push"
        let pushTab = UINavigationController(rootViewController: pushGrid)
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

        let tortureTab = UIViewController()
        tortureTab.view.backgroundColor = .systemBackground
        tortureTab.tabBarItem = UITabBarItem(
            title: "Torture",
            image: UIImage(systemName: "tornado"),
            tag: 2
        )

        let tabBarController = UITabBarController()
        tabBarController.viewControllers = [pushTab, modalTab, tortureTab]
        return (tabBarController, modalTab)
    }
}
