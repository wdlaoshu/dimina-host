//
//  ToastManager.swift
//  dimina
//
//  Created by DosLin on 2025/5/10.
//

import UIKit

/// Toast type enum to determine the icon to display
public enum ToastType {
    case success
    case error
    case loading
    case none
}

/// ToastManager is a singleton class that handles showing and hiding toast messages
public class ToastManager {
    
    // MARK: - Singleton
    
    /// Shared instance
    public static let shared = ToastManager()
    
    // MARK: - Properties
    
    /// 承载遮罩和内容的覆盖层。Toast 直接挂在当前窗口的根视图上，
    /// 不再单独建 .alert + 1 的高层窗口 —— 高层窗口会盖在系统相册 /
    /// 图片选择器之上，选图时就是一层灰遮罩挡住照片、中间压着“处理中...”。
    private var overlayView: UIView?
    
    /// Toast container view
    private var containerView: UIView?
    
    /// Work item for dismissal
    private var dismissWorkItem: DispatchWorkItem?
    private var presentationGeneration: UInt64 = 0
    
    // MARK: - Layout constants

    private let cornerRadius: CGFloat = 18
    private let badgeSize: CGFloat = 22
    private let contentSpacing: CGFloat = 10
    private let maxWidth: CGFloat = 300

    /// Private initializer to enforce singleton pattern
    private init() {}
    
    // MARK: - Public Methods
    
    /// Show a toast message with the specified parameters
    /// - Parameters:
    ///   - title: The message to display
    ///   - type: The type of toast (success, error, loading, none)
    ///   - duration: How long to display the toast in milliseconds (default: 1500)
    ///   - mask: Whether to show a mask behind the toast (default: false)
    public func showToast(title: String, type: ToastType = .success, duration: Int = 1500, mask: Bool = false) {
        // Ensure UI updates happen on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel any previous dismiss work
            self.dismissWorkItem?.cancel()
            self.dismissWorkItem = nil
            
            // Invalidate the old fade/timeout before interrupting its animation.
            self.presentationGeneration &+= 1
            let generation = self.presentationGeneration
            self.overlayView?.layer.removeAllAnimations()
            self.overlayView?.removeFromSuperview()
            self.overlayView = nil
            self.containerView = nil

            guard let hostView = self.resolveHostView() else { return }
            let overlay = UIView(frame: hostView.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.backgroundColor = .clear
            overlay.alpha = 0
            overlay.isUserInteractionEnabled = false // Pass through touches
            hostView.addSubview(overlay)
            self.overlayView = overlay

            // Create toast content
            self.createToastContent(in: overlay, title: title, type: type, mask: mask)

            // Auto-dismiss if not loading type
            if type != .loading && duration > 0 {
                let durationInSeconds = Double(duration) / 1000.0
                
                // Create a new work item for dismissal
                let workItem = DispatchWorkItem { [weak self, weak overlay] in
                    guard let self, let overlay, self.overlayView === overlay,
                          self.presentationGeneration == generation else { return }
                    self.hideToastOnMainThread()
                }
                self.dismissWorkItem = workItem
                
                // Schedule dismissal
                DispatchQueue.main.asyncAfter(deadline: .now() + durationInSeconds, execute: workItem)
            }
        }
    }
    
    /// Hide the currently displayed toast
    public func hideToast() {
        DispatchQueue.main.async { [weak self] in
            self?.hideToastOnMainThread()
        }
    }

    private func hideToastOnMainThread() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let overlay = overlayView else { return }
        presentationGeneration &+= 1
        overlayView = nil
        containerView = nil
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState], animations: {
            overlay.alpha = 0
        }) { _ in
            overlay.removeFromSuperview()
        }
    }

    // MARK: - Private Methods
    
    /// Toast 贴在当前窗口的根视图里，跟随窗口的视图层级：
    /// 系统相册、图片选择器、权限弹窗等模态出现时会自然盖住它，
    /// 不会再出现遮罩挡住图片、上层窗口点不动的问题。
    private func resolveHostView() -> UIView? {
        guard let window = DMPUIManager.getCurrentWindow() else { return nil }
        return window.rootViewController?.view ?? window
    }
    
    /// 深色毛玻璃卡片 + 语义色图标：宽度随文案自适应，
    /// 不再固定 120x120 的灰方块，长文案也不会被挤成三行。
    private func createToastContent(in overlay: UIView, title: String, type: ToastType, mask: Bool) {
        // Add mask if needed
        if mask {
            let maskView = UIView(frame: overlay.bounds)
            maskView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            maskView.backgroundColor = UIColor.black.withAlphaComponent(0.24)
            overlay.addSubview(maskView)
        }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = cornerRadius
        container.layer.cornerCurve = .continuous
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.22
        container.layer.shadowRadius = 22
        container.layer.shadowOffset = CGSize(width: 0, height: 10)
        overlay.addSubview(container)
        self.containerView = container

        // 毛玻璃底：模糊跟随下方内容，深色材质保证白字始终可读。
        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.layer.cornerRadius = cornerRadius
        blurView.layer.cornerCurve = .continuous
        blurView.clipsToBounds = true
        container.addSubview(blurView)

        // 叠一层半透明黑，避免浅色页面上看起来发灰；同时承担 1pt 描边。
        let tintView = UIView()
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        tintView.layer.cornerRadius = cornerRadius
        tintView.layer.cornerCurve = .continuous
        tintView.layer.borderWidth = 1
        tintView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        container.addSubview(tintView)

        let contentStack = UIStackView()
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = contentSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)

        if let badge = makeBadge(for: type) {
            contentStack.addArrangedSubview(badge)
        }

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.96)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textAlignment = type == .none ? .center : .left
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        contentStack.addArrangedSubview(titleLabel)

        let hasBadge = type != .none
        let leadingInset: CGFloat = hasBadge ? 15 : 20
        let trailingInset: CGFloat = hasBadge ? 18 : 20
        let verticalInset: CGFloat = hasBadge ? 12 : 13

        let availableWidth = max(min(maxWidth, overlay.bounds.width - 64), 140)
        let labelWidth = availableWidth - leadingInset - trailingInset - (hasBadge ? badgeSize + contentSpacing : 0)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: container.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            tintView.topAnchor.constraint(equalTo: container.topAnchor),
            tintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -trailingInset),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalInset),

            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: labelWidth),

            // Container: 内容自适应，只限制最大宽度并居中。
            container.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: hasBadge ? 108 : 84),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: availableWidth)
        ])

        // 淡入 + 轻微弹性放大
        container.alpha = 0
        container.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        overlay.layoutIfNeeded()

        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            overlay.alpha = 1
        }
        UIView.animate(
            withDuration: 0.34,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.4,
            options: [.beginFromCurrentState]
        ) {
            container.alpha = 1
            container.transform = .identity
        }
    }

    /// 图标徽标：成功/失败用语义色圆底 + 白色符号，加载用系统指示器。
    private func makeBadge(for type: ToastType) -> UIView? {
        switch type {
        case .none:
            return nil

        case .loading:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = .white
            spinner.startAnimating()
            spinner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                spinner.widthAnchor.constraint(equalToConstant: badgeSize),
                spinner.heightAnchor.constraint(equalToConstant: badgeSize)
            ])
            return spinner

        case .success, .error:
            let tint: UIColor = type == .success ? .systemGreen : .systemRed
            let symbolName = type == .success ? "checkmark" : "exclamationmark"

            let badge = UIView()
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.backgroundColor = tint.withAlphaComponent(0.2)
            badge.layer.cornerRadius = badgeSize / 2
            badge.layer.cornerCurve = .continuous

            let configuration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            let imageView = UIImageView(image: UIImage(systemName: symbolName, withConfiguration: configuration))
            imageView.tintColor = tint
            imageView.contentMode = .scaleAspectFit
            imageView.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(imageView)

            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: badgeSize),
                badge.heightAnchor.constraint(equalToConstant: badgeSize),
                imageView.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
            ])
            return badge
        }
    }
}
