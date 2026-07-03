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
        window.rootViewController = makeRootTabBarController()
        window.makeKeyAndVisible()
        self.window = window
    }

    private func makeRootTabBarController() -> UITabBarController {
        let pushGrid = GridViewController()
        pushGrid.title = "Push"
        let pushTab = UINavigationController(rootViewController: pushGrid)
        pushTab.tabBarItem = UITabBarItem(
            title: "Push",
            image: UIImage(systemName: "square.grid.3x3"),
            tag: 0
        )

        let modalTab = GridViewController()
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
        return tabBarController
    }
}
