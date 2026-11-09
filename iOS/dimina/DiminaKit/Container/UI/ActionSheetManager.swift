//
//  ActionSheetManager.swift
//  dimina
//
//  Created by DosLin on 2025/5/10.
//

import UIKit

/// Completion handler for action sheet selection
public typealias ActionSheetCompletionHandler = (Int) -> Void

/// ActionSheetManager is a singleton class that handles showing action sheets
public class ActionSheetManager {
    
    // MARK: - Singleton
    
    /// Shared instance
    public static let shared = ActionSheetManager()
    
    // MARK: - Properties
    
    /// Dedicated window for action sheets
    private var actionSheetWindow: UIWindow?
    
    /// Action sheet container view
    private var containerView: UIView?
    
    /// Background view for dimming
    private var backgroundView: UIView?
    
    /// 当前 action sheet 的回调。由 manager 自己持有，而不是塞进按钮的 layer 里再取回，
    /// 这样背景点击、"取消"、item 点击三条路径都能拿到同一个回调，
    /// 不会因为某条路径拿不到回调而让 JS promise 永久 pending。
    private var currentCompletion: ActionSheetCompletionHandler?

    /// 正在执行退场动画，防止按钮/遮罩在动画期间重复触发导致回调执行两次
    private var isDismissing = false
    
    /// Private initializer to enforce singleton pattern
    private init() {}
    
    // MARK: - Public Methods
    
    /// Show an action sheet with the specified items
    /// - Parameters:
    ///   - itemList: List of items to display in the action sheet
    ///   - itemColor: Color for the item text
    ///   - completion: Completion handler called when an item is selected
    public func showActionSheet(
        itemList: [String],
        itemColor: String = "#000000",
        completion: @escaping ActionSheetCompletionHandler
    ) {
        // Ensure UI updates happen on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 上一个 sheet 还没结算（例如退场动画被打断）：先按"取消"交付回调，
            // 否则它的 JS promise 会永久 pending，页面一直停在 loading。
            if let pending = self.currentCompletion {
                self.currentCompletion = nil
                pending(-1)
            }
            // 清掉可能残留的窗口，避免旧遮罩叠在新 picker / 新页面之上
            self.destroyActionSheetWindow()

            self.currentCompletion = completion
            self.isDismissing = false
            
            // Create a dedicated window for the action sheet
            self.createActionSheetWindow()
            
            // Create action sheet content
            self.createActionSheetContent(
                itemList: itemList,
                itemColor: itemColor
            )
            
            // Make the window visible
            self.actionSheetWindow?.isHidden = false
            
            // Animate in
            UIView.animate(withDuration: 0.3) {
                self.backgroundView?.alpha = 1
                self.containerView?.transform = .identity
            }
        }
    }
    
    /// Hide the currently displayed action sheet
    private func hideActionSheet(selectedIndex: Int, completion: ActionSheetCompletionHandler?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isDismissing else { return }
            self.isDismissing = true

            let window = self.actionSheetWindow
            let background = self.backgroundView
            let container = self.containerView
            self.currentCompletion = nil

            // Animate out and remove action sheet window
            UIView.animate(withDuration: 0.2, animations: {
                background?.alpha = 0
                if let container = container {
                    container.transform = CGAffineTransform(translationX: 0, y: container.frame.height)
                }
            }) { _ in
                // 动画期间可能已经弹出了新的 sheet。只销毁自己那个窗口，
                // 否则会把新窗口一起干掉，遮罩反而消失不掉。
                if self.actionSheetWindow === window {
                    self.destroyActionSheetWindow()
                    self.isDismissing = false
                } else {
                    background?.removeFromSuperview()
                    container?.removeFromSuperview()
                    window?.isHidden = true
                }

                // Call completion handler
                completion?(selectedIndex)
            }
        }
    }

    /// 销毁 action sheet 窗口。幂等，可在任意时机调用。
    private func destroyActionSheetWindow() {
        backgroundView?.layer.removeAllAnimations()
        backgroundView?.removeFromSuperview()
        containerView?.layer.removeAllAnimations()
        containerView?.removeFromSuperview()
        backgroundView = nil
        containerView = nil
        actionSheetWindow?.isHidden = true
        actionSheetWindow = nil
    }
    
    // MARK: - Private Methods
    
    /// Create a dedicated window for the action sheet
    private func createActionSheetWindow() {
        // Create a new window
        if #available(iOS 13.0, *) {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let window = UIWindow(windowScene: windowScene)
                window.windowLevel = .alert + 1 // Above alerts
                window.backgroundColor = .clear
                self.actionSheetWindow = window
            }
        } else {
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.windowLevel = .alert + 1 // Above alerts
            window.backgroundColor = .clear
            self.actionSheetWindow = window
        }
        
        // Set up the root view controller (required for window)
        let viewController = UIViewController()
        viewController.view.backgroundColor = .clear
        self.actionSheetWindow?.rootViewController = viewController
    }
    
    /// Create the action sheet content
    private func createActionSheetContent(
        itemList: [String],
        itemColor: String
    ) {
        guard let window = self.actionSheetWindow, let rootView = window.rootViewController?.view else { return }
        
        // Create background view for dimming and tap to dismiss
        let backgroundView = UIView(frame: rootView.bounds)
        backgroundView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        backgroundView.alpha = 0
        
        // Add tap gesture to dismiss
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        backgroundView.addGestureRecognizer(tapGesture)
        
        rootView.addSubview(backgroundView)
        self.backgroundView = backgroundView
        
        // Create action sheet container
        let containerView = UIView()
        containerView.backgroundColor = UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0) // Light gray background
        containerView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(containerView)
        self.containerView = containerView
        
        // Apply initial transform for animation (start from bottom)
        containerView.transform = CGAffineTransform(translationX: 0, y: rootView.bounds.height)
        
        // Create main stack view for all content
        let mainStackView = UIStackView()
        mainStackView.axis = .vertical
        mainStackView.alignment = .fill
        mainStackView.spacing = 8
        mainStackView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(mainStackView)
        
        // Create options stack view
        let optionsStackView = UIStackView()
        optionsStackView.axis = .vertical
        optionsStackView.alignment = .fill
        optionsStackView.spacing = 1
        optionsStackView.translatesAutoresizingMaskIntoConstraints = false
        optionsStackView.layer.cornerRadius = 10
        optionsStackView.clipsToBounds = true
        mainStackView.addArrangedSubview(optionsStackView)
        
        // Debug print
        DMPLogger.debug("Creating action sheet with \(itemList.count) items")
        
        // Add item buttons
        for (index, item) in itemList.enumerated() {
            // Create button
            let button = UIButton(type: .system)
            button.setTitle(item, for: .normal)
            button.setTitleColor(UIColor(hexString: itemColor), for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 16)
            button.backgroundColor = .white
            button.tag = index // Store index for later
            button.translatesAutoresizingMaskIntoConstraints = false
            button.addTarget(self, action: #selector(itemButtonTapped(_:)), for: .touchUpInside)
            button.heightAnchor.constraint(equalToConstant: 50).isActive = true
            
            optionsStackView.addArrangedSubview(button)
        }
        
        // Add cancel button (separate from the items)
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(.black, for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        cancelButton.backgroundColor = .white
        cancelButton.layer.cornerRadius = 10
        cancelButton.clipsToBounds = true
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelButtonTapped(_:)), for: .touchUpInside)
        cancelButton.heightAnchor.constraint(equalToConstant: 55).isActive = true
        
        mainStackView.addArrangedSubview(cancelButton)
        
        // Set up constraints
        NSLayoutConstraint.activate([
            // Main stack view constraints
            mainStackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            mainStackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            mainStackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            mainStackView.bottomAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            
            // Container view constraints (at the bottom of the screen)
            containerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
        
        // Add corner radius to the top of the container
        containerView.layer.cornerRadius = 10
        containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        containerView.clipsToBounds = true
    }
    
    // MARK: - Button Actions
    
    @objc private func itemButtonTapped(_ sender: UIButton) {
        hideActionSheet(selectedIndex: sender.tag, completion: currentCompletion)
    }
    
    @objc private func cancelButtonTapped(_ sender: UIButton) {
        hideActionSheet(selectedIndex: -1, completion: currentCompletion) // -1 indicates cancel
    }
    
    @objc private func backgroundTapped() {
        // 点背景取消也要把结果回调给调用方（selectedIndex = -1），
        // 否则 chooseMedia/chooseVideo 等 API 的 bridge 回调永远不会触发，
        // JS 侧 promise 一直 pending，页面卡在 loading 无法恢复。
        hideActionSheet(selectedIndex: -1, completion: currentCompletion)
    }
}
