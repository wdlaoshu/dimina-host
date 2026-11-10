//
//  DMPPageController.swift
//  dimina
//
//  Created by Lehem on 2025/5/15.
//

import Foundation
import SwiftUI
import UIKit
import WebKit

/// DMPPageController is a specialized view controller for displaying mini-program pages
/// It directly integrates the functionality of both DMPPage and DMPViewController
public class DMPPageController: UIViewController {

    // Weak reference to the navigator
    private weak var navigator: DMPNavigator?

    // Page properties
    private let pagePath: String
    private let query: [String: Any]?
    private let appConfig: DMPAppConfig
    private weak var app: DMPApp?
    private let isRoot: Bool
    private let showsLaunchLoading: Bool

    // 这个页面为什么被拆掉。默认按路由处理：系统主动回收、宿主自己 pop 都属于路由，
    // 页面照常卸载。退出小程序由关闭方在拆栈之前标注，见 DMPNavigator.markPageTeardownReason。
    private var pageStateTeardownReason: DMPPageStateTeardown = .routing

    // WebView related
    private var webview: DMPWebview
    private let loadingStateObserverToken = UUID()
    private var hostingController: UIHostingController<DMPWebViewContainer>?
    private var customNavigationBar: UIView?
    private var customNavigationContentView: UIView?
    private var customNavigationTitleLabel: UILabel?
    private var customNavigationBackButton: UIButton?
    private var customNavigationHomeButton: UIButton?
    // 微信真机 home 图标带灰色圆形底，比返回箭头更粗更显眼；颜色随导航栏深浅切换，见 updateCustomHomeButton
    private var customNavigationHomeButtonBackground: UIView?
    // home 键的两套水平位置：独占左槽（栈底自动规则）/ 紧随返回箭头之后
    // （homeButton: true 的内页，微信实测两者并存），按 showBack 切换激活
    private var homeButtonLeadingToEdge: NSLayoutConstraint?
    private var homeButtonLeadingAfterBack: NSLayoutConstraint?
    private var miniProgramMenuContainerView: UIView?
    private var miniProgramSwitcherContainerView: UIView?
    // 菜单遮罩挂在共享的 navigationController.view 上，需要 tag 才能跨页面找回并清理
    private static let miniProgramMenuTag = 0x4D50_0001
    private static let miniProgramSwitcherTag = 0x4D50_0002
    private var isClosingMiniProgram = false
    private var webViewTopToNavigationConstraint: NSLayoutConstraint?
    private var webViewTopToViewConstraint: NSLayoutConstraint?
    private var loadingView: UIView?
    private weak var loadingParentController: UIViewController?

    // State
    private var isWebViewDestroyed = false
    private var hasDispatchedPageUnload = false
    private var hasStartedLoading = false
    private var hasShownLaunchLoading = false

    /// Initialization method
    /// - Parameters:
    ///   - pagePath: Page path
    ///   - query: Query parameters
    ///   - appConfig: App configuration
    ///   - app: App instance
    ///   - navigator: Navigator
    ///   - isRoot: Whether this is a root view controller
    ///   - showsLaunchLoading: Whether to show the app launch loading overlay
    public init(
        pagePath: String, query: [String: Any]?, appConfig: DMPAppConfig, app: DMPApp?,
        navigator: DMPNavigator?, isRoot: Bool = false, showsLaunchLoading: Bool = false
    ) {
        self.pagePath = pagePath
        self.query = query
        self.appConfig = appConfig
        self.app = app
        self.navigator = navigator
        self.isRoot = isRoot
        self.showsLaunchLoading = showsLaunchLoading

        // Create WebView
        self.webview = (app?.render!.createWebView(appName: appConfig.appName))!

        super.init(nibName: nil, bundle: nil)

        // Configure WebView - Configure immediately to ensure page path is set correctly
        configWebView()
        observeLoadingState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Configure WebView
    private func configWebView() {        
        // Set page path and query parameters
        self.webview.setPagePath(pagePath: pagePath)
        if let query = query {
            self.webview.setQuery(query: query)
        }
        
        DMPLogger.debug("🔧 DMPPageController: WebView (ID: \(webview.getWebViewId())) configuration completed, current page path: \(webview.getPagePath())")
        
        app?.render?.setupJSBridge(webViewId: webview.getWebViewId())

    }

    // View loaded
    public override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .white
        setupCustomNavigationBar()

        // Create SwiftUI view container
        let webViewContainer = DMPWebViewContainer(webview: webview, isRoot: isRoot)
        hostingController = UIHostingController(rootView: webViewContainer)

        // Add child view controller
        if let hostingController = hostingController {
            addChild(hostingController)
            view.addSubview(hostingController.view)
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false
            webViewTopToNavigationConstraint = hostingController.view.topAnchor.constraint(
                equalTo: customNavigationBar?.bottomAnchor ?? view.topAnchor
            )
            webViewTopToViewConstraint = hostingController.view.topAnchor.constraint(equalTo: view.topAnchor)
            NSLayoutConstraint.activate([
                webViewTopToNavigationConstraint!,
                hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            hostingController.didMove(toParent: self)
        }

        // Set navigation bar style
        setupNavigationBar()
    }

    // View will appear
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigator?.setCapsuleVisible(true)
        if loadingView == nil {
            navigator?.bringCapsuleToFront()
        }
        setupNavigationBar()
        showPageLoadingIfNeeded()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let customNavigationBar = customNavigationBar, !customNavigationBar.isHidden {
            view.bringSubviewToFront(customNavigationBar)
        }
        if let miniProgramMenuContainerView = miniProgramMenuContainerView {
            miniProgramMenuContainerView.superview?.bringSubviewToFront(miniProgramMenuContainerView)
        }
        loadingView?.superview?.bringSubviewToFront(loadingView!)
    }

    // View did appear
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 上一个页面的胶囊菜单遮罩可能还留在共享的导航容器上，新页面出现时兜底清掉，
        // 否则整页会被一层灰盖住、连图片选择器也点不动。
        let presentationView: UIView = navigationController?.view ?? parent?.view ?? view
        presentationView.subviews
            .filter { $0.tag == DMPPageController.miniProgramMenuTag && $0 !== miniProgramMenuContainerView }
            .forEach { $0.removeFromSuperview() }

        startLoadingIfNeeded()
    }

    private func startLoadingIfNeeded() {
        guard !hasStartedLoading, !isWebViewDestroyed else {
            return
        }

        hasStartedLoading = true
        showPageLoadingIfNeeded()
        webview.poolState = .loading
        webview.loadPageFrame(enableVConsole: appConfig.isVConsoleEnabled)
    }

    public func preparePageLoading(in parentController: UIViewController) {
        guard showsLaunchLoading else {
            return
        }

        installPageLoading(in: parentController, isVisible: false)
    }

    private func observeLoadingState() {
        webview.setLoadingStateObserver(ownerToken: loadingStateObserverToken) { [weak self] isLoading in
            let updateLoading = {
                if isLoading {
                    self?.showPageLoadingIfNeeded()
                } else {
                    self?.hidePageLoading()
                }
            }

            if Thread.isMainThread {
                updateLoading()
            } else {
                DispatchQueue.main.async {
                    updateLoading()
                }
            }
        }
    }

    private func showPageLoadingIfNeeded() {
        guard showsLaunchLoading, !hasShownLaunchLoading else {
            return
        }

        hasShownLaunchLoading = true
        showPageLoading()
    }

    private func showPageLoading() {
        let parentController = loadingParentController ?? navigationController ?? self
        installPageLoading(in: parentController, isVisible: true)
    }

    private func installPageLoading(in parentController: UIViewController, isVisible: Bool) {
        let parentView = parentController.view!

        if let loadingView = self.loadingView {
            loadingView.superview?.bringSubviewToFront(loadingView)
            UIView.performWithoutAnimation {
                loadingView.alpha = isVisible ? 1 : 0
                loadingView.isUserInteractionEnabled = isVisible
                parentView.layoutIfNeeded()
            }
            return
        }

        let loadingView = makePageLoadingView()
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.alpha = isVisible ? 1 : 0
        loadingView.isUserInteractionEnabled = isVisible

        parentView.addSubview(loadingView)
        NSLayoutConstraint.activate([
            loadingView.topAnchor.constraint(equalTo: parentView.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            loadingView.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
        ])
        parentView.bringSubviewToFront(loadingView)
        UIView.performWithoutAnimation {
            parentView.layoutIfNeeded()
        }

        self.loadingView = loadingView
        self.loadingParentController = parentController
    }

    private func setupCustomNavigationBar() {
        let navigationBar = UIView()
        navigationBar.translatesAutoresizingMaskIntoConstraints = false

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let backButton = UIButton(type: .custom)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.addTarget(self, action: #selector(customBackButtonTapped), for: .touchUpInside)

        let homeButton = UIButton(type: .custom)
        homeButton.translatesAutoresizingMaskIntoConstraints = false
        homeButton.accessibilityLabel = "Home"
        homeButton.addTarget(self, action: #selector(homeButtonTapped), for: .touchUpInside)

        let homeButtonBackground = UIView()
        homeButtonBackground.translatesAutoresizingMaskIntoConstraints = false
        homeButtonBackground.isUserInteractionEnabled = false
        homeButtonBackground.layer.cornerRadius = 16

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        view.addSubview(navigationBar)
        navigationBar.addSubview(contentView)
        contentView.addSubview(backButton)
        contentView.addSubview(homeButtonBackground)
        contentView.addSubview(homeButton)
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: view.topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: navigationBar.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: navigationBar.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            contentView.heightAnchor.constraint(equalToConstant: DMPMenuButtonLayout.navigationBarContentHeight),

            backButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),

            homeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            homeButton.widthAnchor.constraint(equalToConstant: 44),
            homeButton.heightAnchor.constraint(equalToConstant: 44),

            homeButtonBackground.centerXAnchor.constraint(equalTo: homeButton.centerXAnchor),
            homeButtonBackground.centerYAnchor.constraint(equalTo: homeButton.centerYAnchor),
            homeButtonBackground.widthAnchor.constraint(equalToConstant: 32),
            homeButtonBackground.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor,
                constant: -DMPMenuButtonLayout.titleTrailingInset
            )
        ])

        let homeLeadingToEdge = homeButton.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: 8)
        // 44pt 触摸热区本身比图标大（图标 24pt 居中，热区两侧各留 10pt），
        // 热区自带的留白已经提供了视觉间距，这里不再叠加额外 margin，
        // 否则视觉间距会远超微信原生 `.navigator-hd a+a{margin-left:10px}` 的 10pt
        let homeLeadingAfterBack = homeButton.leadingAnchor.constraint(
            equalTo: backButton.trailingAnchor)
        homeLeadingToEdge.isActive = true
        homeButtonLeadingToEdge = homeLeadingToEdge
        homeButtonLeadingAfterBack = homeLeadingAfterBack

        customNavigationBar = navigationBar
        customNavigationContentView = contentView
        customNavigationBackButton = backButton
        customNavigationHomeButton = homeButton
        customNavigationHomeButtonBackground = homeButtonBackground
        customNavigationTitleLabel = titleLabel
    }

    private func makePageLoadingView() -> UIView {
        let container = UIView()
        container.accessibilityIdentifier = "dimina.launchLoading"
        container.backgroundColor = .white

        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIView()
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let ringView = UIView()
        ringView.layer.borderColor = UIColor.gray.withAlphaComponent(0.3).cgColor
        ringView.layer.borderWidth = 1
        ringView.layer.cornerRadius = 30
        ringView.translatesAutoresizingMaskIntoConstraints = false

        let appIconView = UIView()
        appIconView.backgroundColor = loadingIconColor(for: webview.appName)
        appIconView.layer.cornerRadius = 20
        appIconView.clipsToBounds = true
        appIconView.translatesAutoresizingMaskIntoConstraints = false

        let rotorView = UIView()
        rotorView.translatesAutoresizingMaskIntoConstraints = false

        let dotView = UIView()
        dotView.backgroundColor = .systemGreen
        dotView.layer.cornerRadius = 3
        dotView.translatesAutoresizingMaskIntoConstraints = false

        let appNameLabel = UILabel()
        appNameLabel.text = webview.appName
        appNameLabel.textColor = .label
        appNameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        appNameLabel.textAlignment = .center

        container.addSubview(stackView)
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(appNameLabel)

        iconView.addSubview(ringView)
        iconView.addSubview(appIconView)
        iconView.addSubview(rotorView)
        rotorView.addSubview(dotView)

        if let iconImage = appConfig.iconImage {
            // 和胶囊菜单保持一致：有宿主下发的真实图标就直接展示，
            // 不再退回首字母色块。
            appIconView.backgroundColor = .clear
            let iconImageView = UIImageView(image: iconImage)
            iconImageView.contentMode = .scaleAspectFill
            iconImageView.translatesAutoresizingMaskIntoConstraints = false
            appIconView.addSubview(iconImageView)
            NSLayoutConstraint.activate([
                iconImageView.topAnchor.constraint(equalTo: appIconView.topAnchor),
                iconImageView.leadingAnchor.constraint(equalTo: appIconView.leadingAnchor),
                iconImageView.trailingAnchor.constraint(equalTo: appIconView.trailingAnchor),
                iconImageView.bottomAnchor.constraint(equalTo: appIconView.bottomAnchor),
            ])
        } else {
            let initialLabel = UILabel()
            initialLabel.text = String(webview.appName.prefix(1))
            initialLabel.textColor = .white
            initialLabel.font = .systemFont(ofSize: 16, weight: .bold)
            initialLabel.textAlignment = .center
            initialLabel.translatesAutoresizingMaskIntoConstraints = false
            appIconView.addSubview(initialLabel)
            NSLayoutConstraint.activate([
                initialLabel.centerXAnchor.constraint(equalTo: appIconView.centerXAnchor),
                initialLabel.centerYAnchor.constraint(equalTo: appIconView.centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 60),
            iconView.heightAnchor.constraint(equalToConstant: 60),

            ringView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            ringView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            ringView.widthAnchor.constraint(equalToConstant: 60),
            ringView.heightAnchor.constraint(equalToConstant: 60),

            appIconView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            appIconView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 40),
            appIconView.heightAnchor.constraint(equalToConstant: 40),

            rotorView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            rotorView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            rotorView.widthAnchor.constraint(equalToConstant: 60),
            rotorView.heightAnchor.constraint(equalToConstant: 60),

            dotView.centerXAnchor.constraint(equalTo: rotorView.centerXAnchor),
            dotView.centerYAnchor.constraint(equalTo: rotorView.topAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),
        ])

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 1.2
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotorView.layer.add(rotation, forKey: "loading.rotation")

        return container
    }

    private func loadingIconColor(for name: String) -> UIColor {
        guard !name.isEmpty else {
            return UIColor(red: 33 / 255, green: 150 / 255, blue: 243 / 255, alpha: 1)
        }

        var hash: Int32 = 0
        for scalar in name.unicodeScalars {
            hash = 31 &* hash &+ Int32(scalar.value)
        }

        let hue = CGFloat(abs(hash % 360)) / 360.0
        let saturation = CGFloat(0.7 + Float(hash % 3000) / 10000.0)
        let brightness = CGFloat(0.8 + Float(hash % 2000) / 10000.0)
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private func hidePageLoading() {
        guard let loadingView = loadingView else {
            return
        }

        loadingView.removeFromSuperview()

        self.loadingView = nil
        self.loadingParentController = nil

        setupNavigationBar()
        navigator?.bringCapsuleToFront()
    }

    public func updateNavigationTitle(_ title: String) {
        let nextTitle = title.isEmpty ? appConfig.appName : title
        customNavigationTitleLabel?.text = nextTitle
        navigationItem.title = nextTitle
    }

    public func updateNavigationColor(backgroundColor: UIColor, textColor: UIColor, darkStyle: Bool) {
        customNavigationBar?.backgroundColor = backgroundColor
        customNavigationTitleLabel?.textColor = textColor
        updateCustomBackButton(darkStyle: darkStyle)
        updateCustomHomeButton(darkStyle: darkStyle)
        applyStatusBarStyle(darkStyle: darkStyle)
    }

    /// 当前页面希望的状态栏样式；nil 表示沿用系统/宿主的判断
    private var statusBarStyleOverride: UIStatusBarStyle?

    public override var preferredStatusBarStyle: UIStatusBarStyle {
        statusBarStyleOverride ?? super.preferredStatusBarStyle
    }

    /// 状态栏图标颜色跟随小程序自身导航栏深浅，而不是宿主的 window 外观。
    /// 宿主可能是深色、小程序页面是浅色，此时状态栏必须用深色图标，
    /// 否则就是白字压在浅底上（“雾蒙蒙”）。
    /// 只覆盖当前页面控制器，不改共享 window，返回宿主不受影响。
    private func applyStatusBarStyle(darkStyle: Bool) {
        let style: UIUserInterfaceStyle = darkStyle ? .dark : .light
        if #available(iOS 13.0, *) {
            statusBarStyleOverride = darkStyle ? .lightContent : .darkContent
        } else {
            statusBarStyleOverride = darkStyle ? .lightContent : .default
        }
        if overrideUserInterfaceStyle != style {
            overrideUserInterfaceStyle = style
        }
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
        // 胶囊挂在导航控制器视图上，跟着小程序自身深浅走，避免深色胶囊压在浅色导航栏上
        navigator?.setCapsuleInterfaceStyle(style)
        // SwiftUI 根 hosting controller 才是状态栏的真正决策者，广播给宿主去应用
        DMPUIManager.notifyMiniProgramInterfaceStyle(style)
    }

    /// 离开小程序（被 pop / 隐藏 / 关闭）时把整窗外观还给宿主，
    /// 否则宿主会停留在小程序最后使用的浅色或深色。
    private func notifyHostStyleIfLeavingMiniProgram() {
        let stack = navigationController?.viewControllers ?? []
        let stillInside = stack.contains {
            $0 is DMPPageController || $0 is DMPTabBarContainerController
        }
        guard !stillInside else { return }
        DMPUIManager.notifyMiniProgramInterfaceStyle(.unspecified)
    }

    private func updateCustomBackButton(darkStyle: Bool) {
        guard let backButton = customNavigationBackButton else {
            return
        }

        if let bundle = DMPResourceManager.assetsBundle {
            let imageName = darkStyle ? "arrow-back-dark" : "arrow-back-light"
            if let image = UIImage(named: imageName, in: bundle, compatibleWith: nil) {
                backButton.setImage(image.withRenderingMode(.alwaysOriginal), for: .normal)
                backButton.setTitle(nil, for: .normal)
                return
            }
        }

        backButton.setImage(nil, for: .normal)
        backButton.setTitle("back", for: .normal)
        backButton.setTitleColor(darkStyle ? .white : .black, for: .normal)
    }

    private func updateCustomHomeButton(darkStyle: Bool) {
        guard let homeButton = customNavigationHomeButton else {
            return
        }

        // 微信真机 home 图标的灰色圆形底，颜色随导航栏深浅切换
        customNavigationHomeButtonBackground?.backgroundColor = darkStyle
            ? UIColor.white.withAlphaComponent(0.24)
            : UIColor(red: 0.839, green: 0.839, blue: 0.839, alpha: 1)

        // 与返回箭头同机制：按 darkStyle 选择 Material home 造型的 SVG 资产
        if let bundle = DMPResourceManager.assetsBundle {
            let imageName = darkStyle ? "home-dark" : "home-light"
            if let image = UIImage(named: imageName, in: bundle, compatibleWith: nil) {
                homeButton.setImage(image.withRenderingMode(.alwaysOriginal), for: .normal)
                return
            }
        }

        // 资产缺失时退回 SF Symbol 模板渲染
        if let homeImage = UIImage(systemName: "house") {
            homeButton.setImage(homeImage.withRenderingMode(.alwaysTemplate), for: .normal)
        }
        homeButton.tintColor = darkStyle ? .white : .black
    }

    @objc private func customBackButtonTapped() {
        backButtonTapped()
    }

    // 路由判定收敛在 DMPNavigator.navigateHome（switchTab / redirectTo 的选择），按钮只发起
    @objc private func homeButtonTapped() {
        Task { @MainActor [weak self] in
            await self?.navigator?.navigateHome()
        }
    }

    func showMiniProgramMenuFromCapsule() {
        showMiniProgramMenu()
    }

    func closeMiniProgramFromCapsule() {
        guard !isClosingMiniProgram else {
            return
        }
        isClosingMiniProgram = true

        dismissMiniProgramMenu(animated: true)
        // loading 遮罩现在挂在共享的导航容器上，关闭小程序时要一并收掉
        ToastManager.shared.hideToast()
        navigator?.setCapsuleEnabled(false)

        guard let app else {
            isClosingMiniProgram = false
            navigator?.setCapsuleEnabled(true)
            return
        }
        Task { @MainActor [weak self] in
            do {
                try await app.hideMiniProgram()
                self?.isClosingMiniProgram = false
            } catch {
                self?.isClosingMiniProgram = false
                self?.navigator?.setCapsuleEnabled(true)
                DMPLogger.debug("capsule close rejected: \(error.localizedDescription)")
            }
        }
    }

    private func showMiniProgramMenu() {
        guard miniProgramMenuContainerView == nil else {
            return
        }

        // 遮罩挂在共享的 navigationController.view 上，页面切换/销毁时不会自动跟着走。
        // 这里先清掉别的页面遗留的同名遮罩，避免旧遮罩一直盖住整个小程序
        // （表现为选图片时被一层灰挡住、点哪里都没反应）。
        let presentationView: UIView = navigationController?.view ?? parent?.view ?? view
        presentationView.subviews
            .filter { $0.tag == DMPPageController.miniProgramMenuTag }
            .forEach { $0.removeFromSuperview() }

        let overlay = UIControl()
        overlay.tag = DMPPageController.miniProgramMenuTag
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        overlay.alpha = 0
        overlay.addTarget(self, action: #selector(dismissMiniProgramMenuFromOverlay), for: .touchUpInside)

        let sheetView = UIView()
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.backgroundColor = .systemBackground
        sheetView.layer.cornerRadius = 20
        if #available(iOS 11.0, *) {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        sheetView.layer.masksToBounds = true

        // 头像优先用宿主下发的真实小程序图标；拿不到时退回首字母占位
        let avatarContainer = UIView()
        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.backgroundColor = .secondarySystemBackground
        avatarContainer.layer.cornerRadius = 11
        avatarContainer.clipsToBounds = true

        if let iconImage = appConfig.iconImage {
            let avatarImageView = UIImageView(image: iconImage)
            avatarImageView.translatesAutoresizingMaskIntoConstraints = false
            avatarImageView.contentMode = .scaleAspectFill
            avatarContainer.addSubview(avatarImageView)
            NSLayoutConstraint.activate([
                avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
                avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
                avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
                avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            ])
        } else {
            let letterLabel = UILabel()
            letterLabel.translatesAutoresizingMaskIntoConstraints = false
            letterLabel.text = String(appConfig.appName.prefix(1)).isEmpty ? "小" : String(appConfig.appName.prefix(1))
            letterLabel.textAlignment = .center
            letterLabel.font = .systemFont(ofSize: 18, weight: .medium)
            letterLabel.textColor = .secondaryLabel
            avatarContainer.addSubview(letterLabel)
            NSLayoutConstraint.activate([
                letterLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
                letterLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
            ])
        }

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = appConfig.appName
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label

        let subtitleLabel = UILabel()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "小程序"
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel

        let titleStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.axis = .vertical
        titleStack.spacing = 2

        let headerView = UIView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(avatarContainer)
        headerView.addSubview(titleStack)

        let topDivider = UIView()
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topDivider.backgroundColor = .separator

        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)

        let reenterItem = makeMiniProgramMenuItem(
            title: "刷新",
            image: UIImage(systemName: "arrow.clockwise", withConfiguration: symbolConfiguration),
            action: #selector(miniProgramMenuReenterTapped)
        )
        let switchItem = makeMiniProgramMenuItem(
            title: "切换",
            image: UIImage(systemName: "square.on.square", withConfiguration: symbolConfiguration),
            action: #selector(miniProgramMenuSwitchTapped)
        )
        let closeItem = makeMiniProgramMenuItem(
            title: "关闭",
            image: UIImage(systemName: "xmark", withConfiguration: symbolConfiguration),
            action: #selector(miniProgramMenuCloseTapped)
        )

        let actionStack = UIStackView(arrangedSubviews: [reenterItem, switchItem, closeItem])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.axis = .horizontal
        actionStack.alignment = .top
        actionStack.distribution = .fillEqually
        actionStack.spacing = 8

        let bottomDivider = UIView()
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        bottomDivider.backgroundColor = .separator

        let cancelButton = UIButton(type: .system)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(.systemBlue, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        cancelButton.addTarget(self, action: #selector(dismissMiniProgramMenuFromOverlay), for: .touchUpInside)

        presentationView.addSubview(overlay)
        overlay.addSubview(sheetView)
        sheetView.addSubview(headerView)
        sheetView.addSubview(topDivider)
        sheetView.addSubview(actionStack)
        sheetView.addSubview(bottomDivider)
        sheetView.addSubview(cancelButton)

        let bottomInset = presentationView.safeAreaInsets.bottom
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: presentationView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: presentationView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: presentationView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: presentationView.bottomAnchor),

            sheetView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            sheetView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            sheetView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),

            headerView.topAnchor.constraint(equalTo: sheetView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 88),

            avatarContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 24),
            avatarContainer.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            avatarContainer.widthAnchor.constraint(equalToConstant: 44),
            avatarContainer.heightAnchor.constraint(equalToConstant: 44),

            titleStack.leadingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: 14),
            titleStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -24),

            topDivider.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            actionStack.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 22),
            actionStack.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 20),
            actionStack.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -20),
            actionStack.heightAnchor.constraint(equalToConstant: 96),

            bottomDivider.topAnchor.constraint(equalTo: actionStack.bottomAnchor, constant: 20),
            bottomDivider.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            cancelButton.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: 56),
            cancelButton.bottomAnchor.constraint(equalTo: sheetView.bottomAnchor, constant: -bottomInset),
        ])

        miniProgramMenuContainerView = overlay
        presentationView.bringSubviewToFront(overlay)

        // 入场：遮罩淡入 + 卡片从底部滑入
        sheetView.transform = CGAffineTransform(translationX: 0, y: 320)
        presentationView.layoutIfNeeded()
        UIView.animate(withDuration: 0.26, delay: 0, options: .curveEaseOut) {
            overlay.alpha = 1
            sheetView.transform = .identity
        }
    }

    private func makeMiniProgramMenuItem(title: String, image: UIImage?, action: Selector) -> UIControl {
        let control = UIControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addTarget(self, action: action, for: .touchUpInside)

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = .secondarySystemBackground
        iconContainer.layer.cornerRadius = 14
        iconContainer.isUserInteractionEnabled = false

        let imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .center
        imageView.tintColor = .label

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 1

        control.addSubview(iconContainer)
        iconContainer.addSubview(imageView)
        control.addSubview(label)

        NSLayoutConstraint.activate([
            iconContainer.topAnchor.constraint(equalTo: control.topAnchor),
            iconContainer.centerXAnchor.constraint(equalTo: control.centerXAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 56),
            iconContainer.heightAnchor.constraint(equalToConstant: 56),

            imageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 24),
            imageView.heightAnchor.constraint(equalToConstant: 24),

            label.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: control.bottomAnchor),
        ])

        return control
    }

    @objc private func dismissMiniProgramMenuFromOverlay() {
        dismissMiniProgramMenu(animated: true)
    }

    private func dismissMiniProgramMenu(animated: Bool) {
        guard let overlay = miniProgramMenuContainerView else {
            return
        }
        miniProgramMenuContainerView = nil

        guard animated, let sheetView = overlay.subviews.first else {
            overlay.removeFromSuperview()
            return
        }

        UIView.animate(withDuration: 0.2, animations: {
            overlay.alpha = 0
            sheetView.transform = CGAffineTransform(translationX: 0, y: sheetView.bounds.height)
        }) { _ in
            overlay.removeFromSuperview()
        }
    }

    @objc private func miniProgramMenuReenterTapped() {
        dismissMiniProgramMenu(animated: true)
        Task { @MainActor in
            await app?.reEnter()
        }
    }

    @objc private func miniProgramMenuCloseTapped() {
        dismissMiniProgramMenu(animated: true)
        closeMiniProgramFromCapsule()
    }

    // MARK: - Mini Program Switcher

    @objc private func miniProgramMenuSwitchTapped() {
        dismissMiniProgramMenu(animated: true)
        guard DMPAppManager.sharedInstance().runningMiniPrograms().count > 1 else {
            ToastManager.shared.showToast(title: "当前只有一个小程序在运行", type: .none)
            return
        }
        showMiniProgramSwitcher()
    }

    /// 卡片式实例切换器：列出运行中的小程序，点击切回，非当前实例可直接关闭。
    private func showMiniProgramSwitcher() {
        guard miniProgramSwitcherContainerView == nil else { return }

        let apps = DMPAppManager.sharedInstance().runningMiniPrograms()
        guard apps.count > 1 else { return }

        let presentationView: UIView = navigationController?.view ?? parent?.view ?? view
        presentationView.subviews
            .filter { $0.tag == DMPPageController.miniProgramSwitcherTag }
            .forEach { $0.removeFromSuperview() }

        let overlay = UIControl()
        overlay.tag = DMPPageController.miniProgramSwitcherTag
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        overlay.alpha = 0
        overlay.addTarget(self, action: #selector(dismissMiniProgramSwitcherFromOverlay), for: .touchUpInside)

        let sheetView = UIView()
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.backgroundColor = .systemBackground
        sheetView.layer.cornerRadius = 20
        if #available(iOS 11.0, *) {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        sheetView.layer.masksToBounds = true

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "切换小程序"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label

        let countLabel = UILabel()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.text = "\(apps.count) 个正在运行 · 切回不重载"
        countLabel.font = .systemFont(ofSize: 13)
        countLabel.textColor = .secondaryLabel

        let headerStack = UIStackView(arrangedSubviews: [titleLabel, countLabel])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .vertical
        headerStack.spacing = 2

        let listStack = UIStackView()
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.axis = .vertical
        listStack.spacing = 8
        apps.forEach { listStack.addArrangedSubview(makeMiniProgramSwitcherRow($0)) }

        let bottomDivider = UIView()
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        bottomDivider.backgroundColor = .separator

        let cancelButton = UIButton(type: .system)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(.systemBlue, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        cancelButton.addTarget(self, action: #selector(dismissMiniProgramSwitcherFromOverlay), for: .touchUpInside)

        presentationView.addSubview(overlay)
        overlay.addSubview(sheetView)
        sheetView.addSubview(headerStack)
        sheetView.addSubview(listStack)
        sheetView.addSubview(bottomDivider)
        sheetView.addSubview(cancelButton)

        let bottomInset = presentationView.safeAreaInsets.bottom
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: presentationView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: presentationView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: presentationView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: presentationView.bottomAnchor),

            sheetView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            sheetView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            sheetView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),

            headerStack.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: 22),
            headerStack.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 24),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: sheetView.trailingAnchor, constant: -24),

            listStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 16),
            listStack.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 20),
            listStack.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -20),

            bottomDivider.topAnchor.constraint(equalTo: listStack.bottomAnchor, constant: 16),
            bottomDivider.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            cancelButton.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: 56),
            cancelButton.bottomAnchor.constraint(equalTo: sheetView.bottomAnchor, constant: -bottomInset),
        ])

        miniProgramSwitcherContainerView = overlay
        presentationView.bringSubviewToFront(overlay)

        sheetView.transform = CGAffineTransform(translationX: 0, y: 320)
        presentationView.layoutIfNeeded()
        UIView.animate(withDuration: 0.26, delay: 0, options: .curveEaseOut) {
            overlay.alpha = 1
            sheetView.transform = .identity
        }
    }

    private func makeMiniProgramSwitcherRow(_ item: DMPRunningMiniProgram) -> UIControl {
        let row = UIControl()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.backgroundColor = .secondarySystemBackground
        row.layer.cornerRadius = 14
        row.accessibilityIdentifier = item.appId
        row.addTarget(self, action: #selector(miniProgramSwitcherRowTapped(_:)), for: .touchUpInside)

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = .systemBackground
        iconContainer.layer.cornerRadius = 10
        iconContainer.clipsToBounds = true
        iconContainer.isUserInteractionEnabled = false

        if let iconImage = item.iconImage {
            let iconView = UIImageView(image: iconImage)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.contentMode = .scaleAspectFill
            iconContainer.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.topAnchor.constraint(equalTo: iconContainer.topAnchor),
                iconView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
                iconView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
                iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
            ])
        } else {
            let letterLabel = UILabel()
            letterLabel.translatesAutoresizingMaskIntoConstraints = false
            letterLabel.text = String(item.name.prefix(1)).isEmpty ? "小" : String(item.name.prefix(1))
            letterLabel.font = .systemFont(ofSize: 16, weight: .medium)
            letterLabel.textColor = .secondaryLabel
            iconContainer.addSubview(letterLabel)
            NSLayoutConstraint.activate([
                letterLabel.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
                letterLabel.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            ])
        }

        let nameLabel = UILabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.text = item.name
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isUserInteractionEnabled = false

        row.addSubview(iconContainer)
        row.addSubview(nameLabel)

        let trailingView: UIView
        if item.isActive {
            let badge = UILabel()
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.text = "当前"
            badge.font = .systemFont(ofSize: 12, weight: .medium)
            badge.textColor = .systemBlue
            badge.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            badge.textAlignment = .center
            badge.layer.cornerRadius = 11
            badge.layer.masksToBounds = true
            badge.isUserInteractionEnabled = false
            trailingView = badge
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: 44),
                badge.heightAnchor.constraint(equalToConstant: 22),
            ])
        } else {
            let closeButton = UIButton(type: .system)
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.setImage(
                UIImage(systemName: "xmark.circle.fill",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)),
                for: .normal
            )
            closeButton.tintColor = .tertiaryLabel
            closeButton.accessibilityIdentifier = item.appId
            closeButton.accessibilityLabel = "关闭 \(item.name)"
            closeButton.addTarget(self, action: #selector(miniProgramSwitcherCloseTapped(_:)), for: .touchUpInside)
            trailingView = closeButton
            NSLayoutConstraint.activate([
                closeButton.widthAnchor.constraint(equalToConstant: 40),
                closeButton.heightAnchor.constraint(equalToConstant: 40),
            ])
        }
        row.addSubview(trailingView)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 64),

            iconContainer.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            iconContainer.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),

            nameLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingView.leadingAnchor, constant: -12),

            trailingView.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            trailingView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    @objc private func miniProgramSwitcherRowTapped(_ sender: UIControl) {
        guard let appId = sender.accessibilityIdentifier else { return }
        dismissMiniProgramSwitcher(animated: false)
        Task { @MainActor [weak self] in
            do {
                try await DMPAppManager.sharedInstance().switchToMiniProgram(appId: appId)
            } catch {
                DMPLogger.debug("switch mini program rejected: \(error.localizedDescription)")
                if self?.view.window != nil {
                    ToastManager.shared.showToast(title: "切换失败", type: .error)
                }
            }
        }
    }

    @objc private func miniProgramSwitcherCloseTapped(_ sender: UIButton) {
        guard let appId = sender.accessibilityIdentifier else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let runningApp = DMPAppManager.sharedInstance().existApp(appId: appId) {
                    try await runningApp.closeMiniProgram()
                }
            } catch {
                DMPLogger.debug("close mini program rejected: \(error.localizedDescription)")
            }
            guard self.view.window != nil else { return }
            self.dismissMiniProgramSwitcher(animated: false)
            if DMPAppManager.sharedInstance().runningMiniPrograms().count > 1 {
                self.showMiniProgramSwitcher()
            }
        }
    }

    @objc private func dismissMiniProgramSwitcherFromOverlay() {
        dismissMiniProgramSwitcher(animated: true)
    }

    private func dismissMiniProgramSwitcher(animated: Bool) {
        guard let overlay = miniProgramSwitcherContainerView else { return }
        miniProgramSwitcherContainerView = nil

        guard animated, let sheetView = overlay.subviews.first else {
            overlay.removeFromSuperview()
            return
        }

        UIView.animate(withDuration: 0.2, animations: {
            overlay.alpha = 0
            sheetView.transform = CGAffineTransform(translationX: 0, y: sheetView.bounds.height)
        }) { _ in
            overlay.removeFromSuperview()
        }
    }

    /// 解析导航栏颜色：小程序显式指定就用；否则返回动态 UIColor，跟随宿主 trait
    /// 自动在浅色/深色之间切换。这个逻辑既覆盖 UINavigationBarAppearance 也覆盖
    /// 自定义导航栏（updateNavigationColor），保证两条渲染链路都吃到深底白字兜底。
    static func resolveNavigationColors(navStyle: [String: Any]?) -> (backgroundColor: UIColor, textColor: UIColor) {
        if let bgHex = navStyle?["navigationBarBackgroundColor"] as? String, !bgHex.isEmpty,
           let fgStr = navStyle?["navigationBarTextStyle"] as? String, !fgStr.isEmpty
        {
            // 小程序显式指定了 → 原封不动照用
            let bg = DMPUtil.colorFromHexString(bgHex) ?? .white
            let fg: UIColor = (fgStr == "white") ? .white : .black
            return (bg, fg)
        }

        // 未完全指定 → 动态色兜底，跟随宿主 trait 自动深浅
        let dynamicBg = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.094, green: 0.110, blue: 0.149, alpha: 1)
                : .white
        }
        let dynamicFg = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .white : .black
        }
        return (dynamicBg, dynamicFg)
    }

    // Set navigation bar style
    private func setupNavigationBar() {
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigationItem.hidesBackButton = true
        navigationItem.backButtonTitle = ""

        let pageRecord = navigator?.pageRecord(webViewId: webview.getWebViewId())
        let navStyle = pageRecord?.navStyle
            ?? app?.getBundleAppConfig()?.getPageConfig(pagePath: pagePath)
        let (backgroundColor, textColor) = DMPPageController.resolveNavigationColors(navStyle: navStyle)
        let darkStyle = textColor == .white
        var title = appConfig.appName
        var isCustomNavigationStyle = false

        if let navStyle = navStyle {
            if let navTitle = navStyle["navigationBarTitleText"] as? String, !navTitle.isEmpty {
                title = navTitle
            }

            if let navigationStyle = navStyle["navigationStyle"] as? String {
                isCustomNavigationStyle = navigationStyle == "custom"
            }

            // Only set default style if navigationItem has not been customized
            // This ensures that styles set via API are not overridden
            if navigationItem.standardAppearance == nil {

                let appearance = UINavigationBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = backgroundColor
                appearance.titleTextAttributes = [.foregroundColor: textColor]

                // Set navigation bar appearance for the current controller
                navigationItem.standardAppearance = appearance
                navigationItem.scrollEdgeAppearance = appearance
                navigationItem.compactAppearance = appearance

                if #available(iOS 15.0, *) {
                    navigationItem.compactScrollEdgeAppearance = appearance
                }

                // Set navigation bar button color
                navigationController?.navigationBar.tintColor = textColor
            }
        }

        updateNavigationTitle(title)
        updateNavigationColor(backgroundColor: backgroundColor, textColor: textColor, darkStyle: darkStyle)

        let leftNav = resolveLeftNavAffordances(
            isCustomNavigationStyle: isCustomNavigationStyle,
            homeButtonForceHidden: pageRecord?.homeButtonForceHidden ?? false,
            homeButtonForcedByConfig: (navStyle?["homeButton"] as? Bool) == true
        )
        customNavigationBackButton?.isHidden = !leftNav.showBack
        customNavigationHomeButton?.isHidden = !leftNav.showHome
        customNavigationHomeButtonBackground?.isHidden = !leftNav.showHome
        // home 键位置随返回箭头存在与否切换：并存时紧随箭头，否则独占左槽
        if leftNav.showBack {
            homeButtonLeadingToEdge?.isActive = false
            homeButtonLeadingAfterBack?.isActive = true
        } else {
            homeButtonLeadingAfterBack?.isActive = false
            homeButtonLeadingToEdge?.isActive = true
        }

        customNavigationBar?.isHidden = isCustomNavigationStyle
        webViewTopToNavigationConstraint?.isActive = !isCustomNavigationStyle
        webViewTopToViewConstraint?.isActive = isCustomNavigationStyle

        if !isCustomNavigationStyle, let customNavigationBar = customNavigationBar {
            view.bringSubviewToFront(customNavigationBar)
        }
    }

    /// 导航栏左侧的两个 affordance（微信真机实测语义）：
    /// 返回箭头 = 非栈底页面或宿主隐藏胶囊；home 键 = 非首页 + 非 tabBar 页（这两条排除
    /// `homeButton: true` 也不能突破）且（栈底自动显示 ‖ 页面配置
    /// `homeButton: true`——此时与返回箭头并存）。`wx.hideHomeButton()` 只压制
    /// home 键。
    private func resolveLeftNavAffordances(
        isCustomNavigationStyle: Bool,
        homeButtonForceHidden: Bool,
        homeButtonForcedByConfig: Bool
    ) -> (showBack: Bool, showHome: Bool) {
        guard !isCustomNavigationStyle else {
            return (false, false)
        }

        // isRoot 表示这个页面在栈底（没有可以返回的上一页）
        let showBack = !isRoot || !DMPAppManager.sharedInstance().showCapsule

        if homeButtonForceHidden {
            return (showBack, false)
        }

        guard let bundleAppConfig = app?.getBundleAppConfig() else {
            return (showBack, false)
        }

        if bundleAppConfig.isTabBarPage(pagePath: pagePath) {
            return (showBack, false)
        }

        // entryPagePath 由 DMPBundleAppConfig 统一输出规范形态（无前导斜杠），
        // 只需归一化当前页一侧。pagePath 不保证已归一化：站内路由 URL
        // （navigateTo/redirectTo/switchTab/reLaunch）经 DMPUtil.queryPath 已
        // 归一化，但 tabBar 页的 pagePath 直接取自 tabBar 配置项
        // （DMPTabBarContainerController 的 onSelect/prepareInitialTab），
        // 未经 queryPath，写法不受调用方控制；entry 未知（空）时自动规则关闭
        let entryPagePath = bundleAppConfig.entryPagePath
        if entryPagePath.isEmpty || DMPUtil.normalizePagePath(pagePath) == entryPagePath {
            return (showBack, false)
        }

        return (showBack, isRoot || homeButtonForcedByConfig)
    }

    /// 仅当这个 controller 当前显示的正是 `webViewId` 时才重新计算导航栏（含
    /// home 按钮显隐）；其它页面这里不做任何事——它们的 `viewWillAppear` 会
    /// 重新跑一次 `setupNavigationBar()`，自然会读到后台期间被设置的页面标记
    public func refreshNavigationBar(ifDisplaying webViewId: Int) {
        guard webview.getWebViewId() == webViewId else { return }
        setupNavigationBar()
    }

    // Back button tap event
    @objc private func backButtonTapped() {
        if isRoot && !DMPAppManager.sharedInstance().showCapsule {
            closeMiniProgramFromCapsule()
            return
        }
        if let navigator = navigator {
            navigator.handleBackButtonTapped()
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    // Get WebView instance
    public func getWebView() -> DMPWebview {
        return webview
    }

    // Called when page is shown
    public func onShow() {
        // Add your logic here
    }
    
    // MARK: - Lifecycle Methods
    
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hidePageLoading()

        // 页面离开时必须收掉胶囊菜单，否则遮罩留在共享的导航容器上会一直盖住后续页面
        dismissMiniProgramMenu(animated: false)
        dismissMiniProgramSwitcher(animated: false)
        
        // Notify lifecycle management when page completely disappears
        if isMovingFromParent && navigator?.isRetainedInBackground != true {
            // Page is removed from navigation stack
            destroyWebView()
        }

        notifyHostStyleIfLeavingMiniProgram()
    }
    
    // Destroy WebView
    private func destroyWebView() {
        // Add state check to prevent duplicate destruction
        guard !isWebViewDestroyed else {
            DMPLogger.debug("🟡 DMPPageController: WebView (ID: \(webview.getWebViewId())) has already been destroyed, skipping duplicate operation")
            return
        }
        
        DMPLogger.debug("🗑️ DMPPageController: Destroy WebView (ID: \(webview.getWebViewId()))")
        isWebViewDestroyed = true
        webview.clearLoadingStateObserver(ownerToken: loadingStateObserverToken)

        notifyRoutingUnloadIfNeeded()
        
        // Release WebView back to pool
        app?.render?.releaseWebView(webview)
    }
    
    /// 标注这次拆栈的原因。必须在页面离开导航栈之前调用：销毁可能要等转场动画结束才发生，
    /// 那时导航栈里已经找不到这个控制器了。
    public func markTeardownReason(_ reason: DMPPageStateTeardown) {
        pageStateTeardownReason = reason
    }

    /// 路由层在修改原生导航栈之前调用，保证旧页 onUnload 先于新页 onShow；真正的桥消息仍由
    /// 页面控制器单点拥有。稍后的 viewDidDisappear/deinit 会再次走这里，但不会重复派发。
    func notifyRoutingUnloadIfNeeded() {
        guard pageStateTeardownReason == .routing,
              !hasDispatchedPageUnload,
              let app
        else {
            return
        }
        hasDispatchedPageUnload = true
        DMPPageLifecycle(app: app).onUnload(webviewId: webview.getWebViewId())
    }

    // Manual destroy method (for external calls)
    public func destroy() {
        destroyWebView()
    }
    
    deinit {
        DMPLogger.debug("🗑️ DMPPageController: deinit (WebView ID: \(webview.getWebViewId()))")
        // deinit 不会再走 viewDidDisappear，这里兜底清理挂在共享容器上的菜单遮罩
        miniProgramMenuContainerView?.removeFromSuperview()
        miniProgramMenuContainerView = nil
        webview.clearLoadingStateObserver(ownerToken: loadingStateObserverToken)
        // Ensure WebView is correctly released
        destroyWebView()
    }
}

// SwiftUI view container for displaying WebView
public struct DMPWebViewContainer: View {
    @ObservedObject var webview: DMPWebview
    var isRoot: Bool = false

    public init(webview: DMPWebview, isRoot: Bool = false) {
        self.webview = webview
        self.isRoot = isRoot
    }

    public var body: some View {
        ZStack {
            DMPWebview.WebViewRepresentable(webview: webview)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }
}
