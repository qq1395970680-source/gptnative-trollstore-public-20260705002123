import SwiftUI
import WebKit
import Photos
import UniformTypeIdentifiers
import UIKit

private enum ChatGPTSurface {
    static let light = UIColor.white
    static let dark = UIColor(red: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1)

    static var dynamic: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}

private final class WindowSurfaceView: UIView {
    private weak var statusSurfaceCover: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = ChatGPTSurface.dynamic
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        backgroundColor = ChatGPTSurface.dynamic
    }

    deinit {
        statusSurfaceCover?.removeFromSuperview()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applySurface()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applySurface()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applySurface()
    }

    func applySurface() {
        let surface = ChatGPTSurface.dynamic.resolvedColor(with: traitCollection)
        backgroundColor = surface
        window?.backgroundColor = surface
        window?.rootViewController?.view.backgroundColor = surface

        var ancestor = superview
        while let view = ancestor {
            if let window, view === window {
                break
            }

            view.backgroundColor = surface
            ancestor = view.superview
        }

        updateStatusSurfaceCover(surface)
    }

    private func updateStatusSurfaceCover(_ surface: UIColor) {
        guard let window else {
            statusSurfaceCover?.removeFromSuperview()
            return
        }

        let cover: UIView
        if let existing = statusSurfaceCover, existing.superview === window {
            cover = existing
        } else {
            let newCover = UIView(frame: .zero)
            newCover.accessibilityIdentifier = "gpt-native-status-surface-cover"
            newCover.isUserInteractionEnabled = false
            newCover.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
            newCover.layer.zPosition = CGFloat.greatestFiniteMagnitude
            window.addSubview(newCover)
            statusSurfaceCover = newCover
            cover = newCover
        }

        let topInset = max(window.safeAreaInsets.top, 0)
        cover.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: topInset)
        cover.backgroundColor = surface
        cover.isHidden = topInset <= 0
    }
}

private struct WindowSurfaceConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowSurfaceView {
        WindowSurfaceView()
    }

    func updateUIView(_ uiView: WindowSurfaceView, context: Context) {
        uiView.applySurface()
    }
}

@MainActor
final class ChatGPTWebState: ObservableObject {
    @Published var estimatedProgress = 0.0
    @Published var errorText: String?
    @Published var hasFinishedInitialLoad = false
    @Published var transientMessage: String?

    weak var webView: WKWebView?
    private let homeURL = URL(string: "https://chatgpt.com/")!
    private let lastChatGPTURLKey = "lastChatGPTURL"
    private var transientMessageTask: Task<Void, Never>?

    func reload() {
        errorText = nil
        if webView?.url == nil {
            openNewChat()
        } else {
            webView?.reload()
        }
    }

    func openNewChat() {
        errorText = nil
        var request = URLRequest(url: homeURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        webView?.load(request)
    }

    func initialRequest() -> URLRequest {
        var request = URLRequest(url: restoredChatGPTURL ?? homeURL)
        request.cachePolicy = .returnCacheDataElseLoad
        return request
    }

    func remember(_ url: URL?) {
        guard let url, isChatGPTURL(url) else {
            return
        }

        UserDefaults.standard.set(url.absoluteString, forKey: lastChatGPTURLKey)
    }

    func captureCurrentLocation() {
        webView?.evaluateJavaScript("window.location.href") { [weak self] result, _ in
            guard let value = result as? String,
                  let url = URL(string: value) else {
                return
            }

            Task { @MainActor in
                self?.remember(url)
            }
        }
    }

    func showTransientMessage(_ message: String) {
        transientMessageTask?.cancel()
        transientMessage = message
        transientMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.transientMessage = nil
            }
        }
    }

    private var restoredChatGPTURL: URL? {
        guard let value = UserDefaults.standard.string(forKey: lastChatGPTURLKey),
              let url = URL(string: value),
              isChatGPTURL(url) else {
            return nil
        }

        return url
    }

    private func isChatGPTURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else {
            return false
        }

        return host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
    }
}

struct ChatGPTLoginView: View {
    @StateObject private var webState = ChatGPTWebState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: ChatGPTSurface.dynamic)
                .ignoresSafeArea(.container, edges: [.top, .bottom])

            WindowSurfaceConfigurator()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            ChatGPTWebContainer(state: webState)
                .ignoresSafeArea(.container, edges: .bottom)

            topSafeAreaSurface

            if webState.estimatedProgress > 0 && webState.estimatedProgress < 1 {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(AppTheme.accent)
                        .frame(width: proxy.size.width * webState.estimatedProgress, height: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 2)
                .ignoresSafeArea(edges: .top)
            }

            if let errorText = webState.errorText {
                connectionError(errorText)
            }

            if let message = webState.transientMessage {
                toast(message)
            }

            if !webState.hasFinishedInitialLoad && webState.errorText == nil {
                launchOverlay
            }
        }
        .background(Color(uiColor: ChatGPTSurface.dynamic).ignoresSafeArea())
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                webState.estimatedProgress = 0
                webState.captureCurrentLocation()
            }
        }
    }

    private var topSafeAreaSurface: some View {
        GeometryReader { proxy in
            Color(uiColor: ChatGPTSurface.dynamic)
                .frame(height: proxy.safeAreaInsets.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
        }
        .allowsHitTesting(false)
    }

    private var launchOverlay: some View {
        VStack(spacing: 14) {
            Text("ChatGPT")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.primary)

            ProgressView()
                .tint(AppTheme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: ChatGPTSurface.dynamic))
        .ignoresSafeArea()
    }

    private func toast(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.78), in: Capsule())
                .padding(.bottom, 26)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func connectionError(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button {
                webState.reload()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: ChatGPTSurface.dynamic))
    }
}

private final class ImageMenuAnchorView: UIView {
    var onSaveImage: (() -> Void)?
    var onSaveAll: (() -> Void)?

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(saveImageMenuAction(_:)) || action == #selector(saveAllMenuAction(_:))
    }

    @objc func saveImageMenuAction(_ sender: Any?) {
        onSaveImage?()
    }

    @objc func saveAllMenuAction(_ sender: Any?) {
        onSaveAll?()
    }
}

private final class ImageSaveContextMenuView: UIView, UIGestureRecognizerDelegate {
    private let sourcePoint: CGPoint
    private let shadowView = UIView()
    private let panel = UIView()
    private let stackView = UIStackView()
    var onSaveImage: (() -> Void)?
    var onSaveAll: (() -> Void)?

    init(frame: CGRect, sourcePoint: CGPoint) {
        self.sourcePoint = sourcePoint
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        sourcePoint = .zero
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        accessibilityViewIsModal = true

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        tapRecognizer.cancelsTouchesInView = true
        tapRecognizer.delegate = self
        addGestureRecognizer(tapRecognizer)

        shadowView.backgroundColor = .clear
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = 0.16
        shadowView.layer.shadowRadius = 18
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 8)
        shadowView.clipsToBounds = false
        addSubview(shadowView)

        panel.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 0.96) : UIColor.white
        }
        panel.layer.cornerRadius = 14
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        shadowView.addSubview(panel)

        stackView.axis = .vertical
        stackView.distribution = .fill
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stackView)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: shadowView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: shadowView.trailingAnchor),
            panel.topAnchor.constraint(equalTo: shadowView.topAnchor),
            panel.bottomAnchor.constraint(equalTo: shadowView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: panel.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])

        stackView.addArrangedSubview(menuButton(title: "保存图片", systemImage: "square.and.arrow.down", action: #selector(saveImageTapped)))
        stackView.addArrangedSubview(separatorView())
        stackView.addArrangedSubview(menuButton(title: "批量保存", systemImage: "square.grid.2x2", action: #selector(saveAllTapped)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let width: CGFloat = 168
        let height: CGFloat = 52 * 2 + 1 / UIScreen.main.scale
        let margin: CGFloat = 10
        let sourceGap: CGFloat = 12
        let x = min(max(sourcePoint.x - width / 2, margin), max(bounds.width - width - margin, margin))
        var y = sourcePoint.y - height - sourceGap
        if y < margin {
            y = min(sourcePoint.y + sourceGap, max(bounds.height - height - margin, margin))
        }
        shadowView.frame = CGRect(x: x, y: y, width: width, height: height)
    }

    func present() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        alpha = 0
        shadowView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.alpha = 1
            self.shadowView.transform = .identity
        }
    }

    func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        let cleanup = {
            self.removeFromSuperview()
            completion?()
        }

        guard animated else {
            cleanup()
            return
        }

        UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 0
            self.shadowView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        } completion: { _ in
            cleanup()
        }
    }

    private func menuButton(title: String, systemImage: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isExclusiveTouch = true
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 10
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        configuration.baseForegroundColor = .label
        let baseConfiguration = configuration
        button.configuration = baseConfiguration
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.configurationUpdateHandler = { button in
            var updated = baseConfiguration
            updated.baseBackgroundColor = button.isHighlighted ? UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.06)
            } : .clear
            button.configuration = updated
        }
        button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return button
    }

    private func separatorView() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return view
    }

    @objc private func backgroundTapped(_ recognizer: UITapGestureRecognizer) {
        dismiss(animated: true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: self)
        return !shadowView.frame.contains(point)
    }

    @objc private func saveImageTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let action = onSaveImage
        dismiss(animated: true) {
            action?()
        }
    }

    @objc private func saveAllTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let action = onSaveAll
        dismiss(animated: true) {
            action?()
        }
    }
}

struct ChatGPTWebContainer: UIViewRepresentable {
    @ObservedObject var state: ChatGPTWebState

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(Self.pageAppearanceScript)
        configuration.userContentController.addUserScript(Self.imageSaveBridgeScript)
        configuration.userContentController.addUserScript(Self.locationObserverScript)
        configuration.userContentController.add(context.coordinator, name: "gptNativeLocation")
        configuration.userContentController.add(context.coordinator, name: "gptNativeImageSave")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.delaysContentTouches = false
        webView.scrollView.canCancelContentTouches = true
        webView.scrollView.decelerationRate = .fast
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.backgroundColor = ChatGPTSurface.dynamic
        webView.layer.drawsAsynchronously = true
        webView.scrollView.layer.drawsAsynchronously = true
        webView.isOpaque = true
        webView.backgroundColor = ChatGPTSurface.dynamic
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = ChatGPTSurface.dynamic
        }
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1"

        context.coordinator.attach(to: webView)
        state.webView = webView

        webView.load(state.initialRequest())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        state.webView = webView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    private static let pageAppearanceScript = WKUserScript(
        source: """
        (() => {
            if (window.__gptNativePageAppearanceInstalled) {
                return;
            }

            window.__gptNativePageAppearanceInstalled = true;

            let viewport = document.querySelector("meta[name='viewport']");
            if (!viewport) {
                viewport = document.createElement("meta");
                viewport.name = "viewport";
                (document.head || document.documentElement).appendChild(viewport);
            }

            const content = viewport.getAttribute("content") || "width=device-width, initial-scale=1";
            if (!content.includes("viewport-fit=cover")) {
                viewport.setAttribute("content", content + ", viewport-fit=cover");
            }

            const style = document.createElement("style");
            style.id = "gpt-native-page-appearance";
            style.textContent = `
                :root {
                    --gpt-native-safe-surface: #ffffff;
                    --gpt-native-safe-bottom: env(safe-area-inset-bottom);
                    --gpt-native-composer-clearance: 0px;
                    --main-surface-primary: var(--gpt-native-safe-surface) !important;
                    --main-surface-secondary: var(--gpt-native-safe-surface) !important;
                    --main-surface-tertiary: var(--gpt-native-safe-surface) !important;
                    --bg-primary: var(--gpt-native-safe-surface) !important;
                    --bg-secondary: var(--gpt-native-safe-surface) !important;
                }

                :root,
                html,
                body,
                #__next,
                [data-nextjs-scroll-focus-boundary] {
                    background: var(--gpt-native-safe-surface) !important;
                    background-color: var(--gpt-native-safe-surface) !important;
                    background-image: none !important;
                    min-height: 100%;
                }

                html {
                    scroll-padding-bottom: calc(var(--gpt-native-safe-bottom) + var(--gpt-native-composer-clearance) + 24px);
                }

                body {
                    min-height: 100dvh;
                }

                * {
                    -ms-overflow-style: none !important;
                    scrollbar-width: none !important;
                }

                *::-webkit-scrollbar {
                    display: none !important;
                    height: 0 !important;
                    width: 0 !important;
                }

                #gpt-native-drawer-mask {
                    background-color: var(--gpt-native-safe-surface) !important;
                    bottom: 0 !important;
                    left: var(--gpt-native-drawer-mask-left, 100vw) !important;
                    opacity: 0 !important;
                    pointer-events: none !important;
                    position: fixed !important;
                    right: 0 !important;
                    top: 0 !important;
                    transition: opacity 0.16s ease-out !important;
                    z-index: 2147482500 !important;
                }

                #gpt-native-drawer-mask[data-visible="true"] {
                    opacity: 0.94 !important;
                }

                #gpt-native-top-surface-mask {
                    background: var(--gpt-native-safe-surface) !important;
                    background-color: var(--gpt-native-safe-surface) !important;
                    background-image: none !important;
                    height: env(safe-area-inset-top) !important;
                    left: 0 !important;
                    pointer-events: none !important;
                    position: fixed !important;
                    right: 0 !important;
                    top: 0 !important;
                    z-index: 2147482600 !important;
                }

                body,
                main,
                [role="main"] {
                    scroll-padding-bottom: calc(var(--gpt-native-safe-bottom) + var(--gpt-native-composer-clearance) + 24px) !important;
                }

                article,
                [data-testid*="conversation-turn"],
                [data-message-author-role],
                img,
                picture,
                canvas,
                video {
                    scroll-margin-bottom: calc(var(--gpt-native-safe-bottom) + var(--gpt-native-composer-clearance) + 72px) !important;
                }

                header,
                nav,
                [role="banner"],
                [data-testid*="header"],
                [class*="header"],
                [class*="navbar"],
                [class*="sticky"][class*="top"],
                [class*="top-0"] {
                    -webkit-backdrop-filter: none !important;
                    backdrop-filter: none !important;
                    background: var(--gpt-native-safe-surface) !important;
                    background-image: none !important;
                    background-color: var(--gpt-native-safe-surface) !important;
                    border-bottom-color: transparent !important;
                    box-shadow: none !important;
                }

                header::before,
                header::after,
                nav::before,
                nav::after,
                [role="banner"]::before,
                [role="banner"]::after,
                [data-testid*="header"]::before,
                [data-testid*="header"]::after,
                [class*="header"]::before,
                [class*="header"]::after,
                [class*="navbar"]::before,
                [class*="navbar"]::after,
                [class*="sticky"][class*="top"]::before,
                [class*="sticky"][class*="top"]::after,
                [class*="top-0"]::before,
                [class*="top-0"]::after {
                    -webkit-backdrop-filter: none !important;
                    backdrop-filter: none !important;
                    background: transparent !important;
                    background-image: none !important;
                    box-shadow: none !important;
                }

                img,
                picture,
                [style*="background-image"] {
                    -webkit-touch-callout: none !important;
                }

                @media (prefers-color-scheme: dark) {
                    :root {
                        --gpt-native-safe-surface: #212121;
                    }
                }
            `;
            (document.head || document.documentElement).appendChild(style);

            const originalBottom = new WeakMap();
            const originalPaddingBottom = new WeakMap();
            const drawerMask = document.createElement("div");
            drawerMask.id = "gpt-native-drawer-mask";
            drawerMask.setAttribute("aria-hidden", "true");
            document.documentElement.appendChild(drawerMask);
            const topSurfaceMask = document.createElement("div");
            topSurfaceMask.id = "gpt-native-top-surface-mask";
            topSurfaceMask.setAttribute("aria-hidden", "true");
            document.documentElement.appendChild(topSurfaceMask);
            const chromeElementSelector = [
                "header",
                "nav",
                "footer",
                "form",
                "[role='banner']",
                "[role='contentinfo']",
                "[data-testid*='composer']",
                "[data-testid*='prompt']",
                "[data-testid*='header']",
                "[class*='header']",
                "[class*='navbar']",
                "[class*='sticky']",
                "[class*='top-0']",
                "[class*='composer']",
                "[class*='prompt']",
                "[class*='fixed']",
                "[style*='position: fixed']",
                "[style*='position: sticky']"
            ].join(",");

            const topSurfaceCandidateSelector = [
                "body > *",
                "main > *",
                "[role='main'] > *",
                "[data-testid*='header']",
                "[class*='header']",
                "[class*='navbar']",
                "[class*='sticky']",
                "[class*='top-0']",
                "[class*='fixed']",
                "[style*='position: fixed']",
                "[style*='position: sticky']"
            ].join(",");

            const drawerElementSelector = [
                "aside",
                "nav",
                "[role='navigation']",
                "[data-testid*='sidebar']",
                "[data-testid*='drawer']",
                "[class*='sidebar']",
                "[class*='drawer']",
                "[class*='sheet']"
            ].join(",");

            const insetBase = (inlineValue, computedValue) => {
                const value = inlineValue && inlineValue !== "auto" ? inlineValue : computedValue;
                return value && value !== "auto" ? value : "0px";
            };

            const shouldPaintTopElement = (element) => {
                if (!element || element === document.body || element === document.documentElement) {
                    return false;
                }

                const style = window.getComputedStyle(element);
                const rect = element.getBoundingClientRect();
                const nearTopSurface = rect.top <= 2
                    && rect.width >= window.innerWidth * 0.45
                    && rect.height > 0
                    && rect.height <= 200;
                if (style.position !== "fixed" && style.position !== "sticky" && !nearTopSurface) {
                    return false;
                }

                if (rect.width < window.innerWidth * 0.45 || rect.height <= 0 || rect.height > 160) {
                    return false;
                }

                return rect.top <= 2 && rect.bottom <= Math.max(176, window.innerHeight * 0.22);
            };

            let safeAreaMutationSuppressedUntil = 0;
            const setStyleValue = (element, property, value, priority = "") => {
                if (!element || !element.style) {
                    return;
                }

                if (element.style.getPropertyValue(property) === value && element.style.getPropertyPriority(property) === priority) {
                    return;
                }

                safeAreaMutationSuppressedUntil = performance.now() + 180;
                element.style.setProperty(property, value, priority);
            };
            const setImportantStyle = (element, property, value) => setStyleValue(element, property, value, "important");

            const paintSurface = (element) => {
                setImportantStyle(element, "-webkit-backdrop-filter", "none");
                setImportantStyle(element, "backdrop-filter", "none");
                setImportantStyle(element, "background", "var(--gpt-native-safe-surface)");
                setImportantStyle(element, "background-color", "var(--gpt-native-safe-surface)");
                setImportantStyle(element, "background-image", "none");
                setImportantStyle(element, "border-bottom-color", "transparent");
                setImportantStyle(element, "box-shadow", "none");
            };

            const surfaceTokenNames = [
                "--main-surface-primary",
                "--main-surface-secondary",
                "--main-surface-tertiary",
                "--bg-primary",
                "--bg-secondary"
            ];

            const paintRootSurface = () => {
                [document.documentElement, document.body].forEach((element) => {
                    if (!element) {
                        return;
                    }

                    setImportantStyle(element, "background", "var(--gpt-native-safe-surface)");
                    setImportantStyle(element, "background-color", "var(--gpt-native-safe-surface)");
                    setImportantStyle(element, "background-image", "none");
                    surfaceTokenNames.forEach((tokenName) => {
                        setImportantStyle(element, tokenName, "var(--gpt-native-safe-surface)");
                    });
                });
                paintSurface(topSurfaceMask);
                setImportantStyle(topSurfaceMask, "height", "env(safe-area-inset-top)");
                setImportantStyle(topSurfaceMask, "left", "0");
                setImportantStyle(topSurfaceMask, "pointer-events", "none");
                setImportantStyle(topSurfaceMask, "position", "fixed");
                setImportantStyle(topSurfaceMask, "right", "0");
                setImportantStyle(topSurfaceMask, "top", "0");
                setImportantStyle(topSurfaceMask, "z-index", "2147482600");
            };

            const shouldOffsetBottomElement = (element) => {
                if (!element || element === document.body || element === document.documentElement) {
                    return false;
                }

                const style = window.getComputedStyle(element);
                if (style.position !== "fixed" && style.position !== "sticky") {
                    return false;
                }

                const rect = element.getBoundingClientRect();
                if (rect.width <= 0 || rect.height <= 0 || rect.height > window.innerHeight * 0.45) {
                    return false;
                }

                const bottomValue = Number.parseFloat(style.bottom || "0");
                const bottomTolerance = Math.max(96, window.innerHeight * 0.12);
                const nearBottom = (Number.isFinite(bottomValue) && bottomValue >= 0 && bottomValue <= bottomTolerance)
                    || rect.bottom >= window.innerHeight - bottomTolerance;
                const bottomRegion = rect.bottom > window.innerHeight - Math.max(180, window.innerHeight * 0.28);
                return nearBottom && bottomRegion;
            };

            const rectsOverlapHorizontally = (a, b) => {
                const left = Math.max(a.left, b.left);
                const right = Math.min(a.right, b.right);
                return right - left > Math.min(96, Math.max(24, Math.min(a.width, b.width) * 0.3));
            };

            const shouldPadScrollElement = (element, bottomChromeRects) => {
                if (!element || element === document.documentElement) {
                    return false;
                }

                if (shouldOffsetBottomElement(element)) {
                    return false;
                }

                const style = window.getComputedStyle(element);
                const rect = element.getBoundingClientRect();
                const rootScroll = element === document.body || element === document.scrollingElement;
                const verticalOverflow = /(auto|scroll|overlay)/.test(style.overflowY || "") || rootScroll;
                const usefulRegion = rootScroll || (rect.width >= window.innerWidth * 0.5 && rect.height >= window.innerHeight * 0.35);
                const reachesBottom = rootScroll || rect.bottom >= window.innerHeight * 0.62;
                const overlapsBottomChrome = bottomChromeRects.some((bottomRect) => rectsOverlapHorizontally(rect, bottomRect));
                return verticalOverflow && usefulRegion && reachesBottom && overlapsBottomChrome;
            };

            const looksLikeOpenDrawer = (element) => {
                if (!element || element === drawerMask || element === topSurfaceMask || element === document.body || element === document.documentElement) {
                    return false;
                }

                const style = window.getComputedStyle(element);
                if (style.display === "none" || style.visibility === "hidden" || Number.parseFloat(style.opacity || "1") < 0.05) {
                    return false;
                }

                const rect = element.getBoundingClientRect();
                if (rect.width < window.innerWidth * 0.42 || rect.width > window.innerWidth * 0.92) {
                    return false;
                }

                if (rect.height < window.innerHeight * 0.55 || rect.left > 8 || rect.right >= window.innerWidth - 16 || rect.top > 150) {
                    return false;
                }

                const fixedLike = style.position === "fixed" || style.position === "sticky" || rect.top <= 120;
                if (!fixedLike) {
                    return false;
                }

                const text = (element.textContent || "").slice(0, 240);
                const drawerLabels = [
                    String.fromCharCode(0x65b0, 0x804a, 0x5929),
                    String.fromCharCode(0x641c, 0x7d22, 0x804a, 0x5929),
                    String.fromCharCode(0x6587, 0x4ef6, 0x5e93),
                    String.fromCharCode(0x9879, 0x76ee),
                    String.fromCharCode(0x5df2, 0x5b89, 0x6392),
                    String.fromCharCode(0x5e94, 0x7528),
                    String.fromCharCode(0x66f4, 0x591a),
                    String.fromCharCode(0x6700, 0x8fd1)
                ];
                const semanticDrawer = element.matches("aside, nav, [role='navigation']")
                    || drawerLabels.some((label) => text.includes(label));
                return semanticDrawer;
            };

            const updateDrawerMask = () => {
                const drawer = Array.from(document.querySelectorAll(drawerElementSelector))
                    .slice(0, 120)
                    .find(looksLikeOpenDrawer);

                if (!drawer) {
                    drawerMask.removeAttribute("data-visible");
                    return;
                }

                const rect = drawer.getBoundingClientRect();
                const left = Math.min(window.innerWidth, Math.max(0, Math.ceil(rect.right)));
                if (window.innerWidth - left < 18) {
                    drawerMask.removeAttribute("data-visible");
                    return;
                }

                setStyleValue(document.documentElement, "--gpt-native-drawer-mask-left", `${left}px`);
                drawerMask.setAttribute("data-visible", "true");
            };

            const scrollElementSelector = [
                "body",
                "main",
                "[role='main']",
                "[data-testid*='conversation']",
                "[data-testid*='thread']",
                "[class*='conversation']",
                "[class*='thread']",
                "[class*='scroll']",
                "[data-testid*='scroll']",
                "[class*='flex-1']",
                "[class*='h-full']",
                "[class*='overflow-y-auto']",
                "[class*='overflow-auto']",
                "[style*='overflow-y: auto']",
                "[style*='overflow-y: scroll']",
                "[style*='overflow: auto']"
            ].join(",");

            const layoutMutationSelector = [
                "body",
                "main",
                "header",
                "nav",
                "footer",
                "form",
                "[role='main']",
                "[role='banner']",
                "[role='contentinfo']",
                "[role='navigation']",
                "aside",
                "[data-testid*='composer']",
                "[data-testid*='sidebar']",
                "[data-testid*='drawer']",
                "[data-testid*='prompt']",
                "[data-testid*='header']",
                "[data-testid*='conversation']",
                "[data-testid*='thread']",
                "[class*='header']",
                "[class*='navbar']",
                "[class*='sticky']",
                "[class*='top-0']",
                "[class*='sidebar']",
                "[class*='drawer']",
                "[class*='sheet']",
                "[class*='composer']",
                "[class*='prompt']",
                "[class*='conversation']",
                "[class*='thread']",
                "[class*='scroll']",
                "[data-testid*='scroll']",
                "[class*='flex-1']",
                "[class*='h-full']",
                "[class*='overflow-y-auto']",
                "[class*='overflow-auto']"
            ].join(",");

            const layoutChromeAncestorSelector = [
                "header",
                "nav",
                "footer",
                "form",
                "[role='banner']",
                "[role='contentinfo']",
                "[role='navigation']",
                "aside",
                "[data-testid*='composer']",
                "[data-testid*='sidebar']",
                "[data-testid*='drawer']",
                "[data-testid*='prompt']",
                "[data-testid*='header']",
                "[class*='header']",
                "[class*='navbar']",
                "[class*='sticky']",
                "[class*='top-0']",
                "[class*='sidebar']",
                "[class*='drawer']",
                "[class*='sheet']",
                "[class*='composer']",
                "[class*='prompt']"
            ].join(",");

            const elementForMutationTarget = (target) => {
                if (!target) {
                    return null;
                }

                if (target.nodeType === Node.ELEMENT_NODE) {
                    return target;
                }

                return target.parentElement || null;
            };

            const elementHasLayoutRole = (element) => {
                if (!element || element.nodeType !== Node.ELEMENT_NODE) {
                    return false;
                }

                if (element === document.body || element === document.documentElement) {
                    return true;
                }

                try {
                    return element.matches(layoutMutationSelector) || Boolean(element.closest(layoutChromeAncestorSelector));
                } catch (_) {
                    return false;
                }
            };

            const nodeAddsLayoutElement = (node) => {
                if (!node || node.nodeType !== Node.ELEMENT_NODE) {
                    return false;
                }

                try {
                    return node.matches(layoutMutationSelector) || Boolean(node.querySelector(layoutMutationSelector));
                } catch (_) {
                    return false;
                }
            };

            const mutationLooksLayoutRelevant = (mutation) => {
                if (elementHasLayoutRole(elementForMutationTarget(mutation.target))) {
                    return true;
                }

                return Array.from(mutation.addedNodes || []).slice(0, 12).some(nodeAddsLayoutElement);
            };

            const applySafeAreaToChromeElements = () => {
                try {
                    paintRootSurface();
                    let bottomChromeHeight = 0;
                    const bottomChromeRects = [];
                    const chromeElements = Array.from(new Set([
                        ...Array.from(document.querySelectorAll(chromeElementSelector)).slice(0, 140),
                        ...Array.from(document.querySelectorAll(topSurfaceCandidateSelector)).slice(0, 180)
                    ]));
                    chromeElements.forEach((element) => {
                        if (shouldPaintTopElement(element)) {
                            paintSurface(element);
                        }

                        if (shouldOffsetBottomElement(element)) {
                            const style = window.getComputedStyle(element);
                            const rect = element.getBoundingClientRect();
                            if (!originalBottom.has(element)) {
                                originalBottom.set(element, insetBase(element.style.bottom, style.bottom));
                            }

                            const baseBottom = originalBottom.get(element) || "0px";
                            setImportantStyle(element, "bottom", `calc(${baseBottom} + var(--gpt-native-safe-bottom))`);
                            paintSurface(element);
                            const occludedHeight = window.innerHeight - Math.max(0, Math.min(rect.top, window.innerHeight));
                            bottomChromeHeight = Math.max(bottomChromeHeight, Math.ceil(rect.height), Math.ceil(occludedHeight));
                            bottomChromeRects.push(rect);
                        }
                    });

                    const clearance = bottomChromeHeight > 0 ? Math.min(420, bottomChromeHeight + 72) : 0;
                    setStyleValue(document.documentElement, "--gpt-native-composer-clearance", `${clearance}px`);

                    Array.from(document.querySelectorAll(scrollElementSelector)).slice(0, 80).forEach((element) => {
                        if (!shouldPadScrollElement(element, bottomChromeRects)) {
                            return;
                        }

                        const style = window.getComputedStyle(element);
                        if (!originalPaddingBottom.has(element)) {
                            originalPaddingBottom.set(element, insetBase(element.style.paddingBottom, style.paddingBottom));
                        }

                        const basePadding = originalPaddingBottom.get(element) || "0px";
                        setImportantStyle(element, "padding-bottom", `calc(${basePadding} + var(--gpt-native-composer-clearance) + var(--gpt-native-safe-bottom))`);
                    });
                    updateDrawerMask();
                } catch (_) {}
            };

            let safeAreaApplyQueued = false;
            let lastSafeAreaApply = 0;
            const scheduleSafeAreaApply = (immediate = false) => {
                if (safeAreaApplyQueued) {
                    return;
                }

                safeAreaApplyQueued = true;
                const elapsed = performance.now() - lastSafeAreaApply;
                const delay = immediate === true ? 40 : Math.max(90, 320 - elapsed);
                window.setTimeout(() => {
                    window.requestAnimationFrame(() => {
                        safeAreaApplyQueued = false;
                        lastSafeAreaApply = performance.now();
                        applySafeAreaToChromeElements();
                    });
                }, delay);
            };

            window.__gptNativeApplySafeArea = scheduleSafeAreaApply;
            window.addEventListener("resize", () => scheduleSafeAreaApply(true), { passive: true });
            if (window.visualViewport) {
                window.visualViewport.addEventListener("resize", () => scheduleSafeAreaApply(true), { passive: true });
            }
            const observer = new MutationObserver((mutations) => {
                if (performance.now() < safeAreaMutationSuppressedUntil) {
                    return;
                }

                if (mutations.some(mutationLooksLayoutRelevant)) {
                    scheduleSafeAreaApply();
                }
            });
            observer.observe(document.documentElement, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ["class", "style", "data-state", "aria-hidden"]
            });
            [0, 120, 350, 900, 1600].forEach((delay) => window.setTimeout(applySafeAreaToChromeElements, delay));
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    private static let imageSaveBridgeScript = WKUserScript(
        source: """
        (() => {
            if (window.__gptNativeImageSaveBridgeInstalled) {
                return;
            }

            window.__gptNativeImageSaveBridgeInstalled = true;
            const minimumImageSize = 48;
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gptNativeImageSave;
            if (!bridge) {
                return;
            }

            const post = (payload) => {
                try {
                    bridge.postMessage(payload);
                } catch (_) {}
            };

            const isCandidateImage = (img) => {
                if (!img || !img.isConnected) {
                    return false;
                }

                const src = img.currentSrc || img.src || img.getAttribute("src") || "";
                if (!src || src.startsWith("chrome-extension:")) {
                    return false;
                }

                const rect = img.getBoundingClientRect();
                const naturalWidth = img.naturalWidth || rect.width;
                const naturalHeight = img.naturalHeight || rect.height;
                return naturalWidth >= minimumImageSize && naturalHeight >= minimumImageSize && rect.width >= 24 && rect.height >= 24;
            };

            const isCandidateCanvas = (canvas) => {
                if (!canvas || !canvas.isConnected || !canvas.getContext) {
                    return false;
                }

                const rect = canvas.getBoundingClientRect();
                return canvas.width >= minimumImageSize
                    && canvas.height >= minimumImageSize
                    && rect.width >= 24
                    && rect.height >= 24;
            };

            const candidateFromElement = (element) => {
                if (!element) {
                    return null;
                }

                if (isCandidateImage(element)) {
                    return element;
                }

                if (element.closest) {
                    const closest = element.closest("img");
                    if (isCandidateImage(closest)) {
                        return closest;
                    }
                }

                if (element.querySelectorAll) {
                    const nested = Array.from(element.querySelectorAll("img"))
                        .filter(isCandidateImage)
                        .map((img) => ({ img, score: visibleScore(img) }))
                        .sort((a, b) => b.score - a.score)[0]?.img;
                    if (nested) {
                        return nested;
                    }
                }

                return null;
            };

            const visibleScoreForRect = (rect) => {
                if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= window.innerHeight || rect.left >= window.innerWidth) {
                    return -1;
                }

                const centerX = rect.left + rect.width / 2;
                const centerY = rect.top + rect.height / 2;
                const dx = Math.abs(centerX - window.innerWidth / 2);
                const dy = Math.abs(centerY - window.innerHeight / 2);
                return (rect.width * rect.height) - (dx + dy);
            };

            const visibleScore = (element) => visibleScoreForRect(element.getBoundingClientRect());
            const metricsForElement = (element) => {
                const rect = element.getBoundingClientRect();
                return {
                    area: Math.max(0, rect.width * rect.height),
                    score: visibleScoreForRect(rect)
                };
            };

            const viewportFallbackMinimumArea = () => {
                const viewportArea = Math.max(1, window.innerWidth * window.innerHeight);
                return Math.max(10000, Math.min(90000, viewportArea * 0.035));
            };

            const images = () => {
                const seen = new Set();
                return Array.from(document.images)
                    .filter(isCandidateImage)
                    .filter((img) => {
                        const key = img.currentSrc || img.src || img.getAttribute("src") || "";
                        if (seen.has(key)) {
                            return false;
                        }
                        seen.add(key);
                        return true;
                    });
            };

            const canvases = () => {
                return Array.from(document.querySelectorAll("canvas"))
                    .filter(isCandidateCanvas);
            };

            const normalizedURL = (value) => {
                try {
                    return new URL(String(value || ""), window.location.href).href;
                } catch (_) {
                    return String(value || "");
                }
            };

            const imageURLLooksSaveable = (value) => {
                const url = String(value || "").toLowerCase();
                return /\\.(png|jpe?g|webp|gif|avif|heic|heif|svg)(\\?|#|$)/.test(url)
                    || url.includes("/image")
                    || url.includes("/images/")
                    || url.startsWith("blob:")
                    || url.startsWith("data:image/");
            };

            const bestImage = () => {
                return images()
                    .map((img) => ({ img, score: visibleScore(img) }))
                    .sort((a, b) => b.score - a.score)[0]?.img || null;
            };

            const bestCanvas = () => {
                return canvases()
                    .map((canvas) => ({ canvas, score: visibleScore(canvas) }))
                    .sort((a, b) => b.score - a.score)[0]?.canvas || null;
            };

            const imageForURL = (value) => {
                const target = normalizedURL(value);
                if (!target) {
                    return null;
                }

                return images().find((img) => {
                    const src = normalizedURL(img.currentSrc || img.src || img.getAttribute("src") || "");
                    return src === target;
                }) || null;
            };

            const filenameFor = (img, index) => {
                const alt = (img.getAttribute("alt") || "").trim().replace(/[^a-zA-Z0-9._-]+/g, "_").slice(0, 48);
                if (alt) {
                    return alt;
                }

                try {
                    const src = img.currentSrc || img.src || "";
                    const url = new URL(src, window.location.href);
                    const name = url.pathname.split("/").filter(Boolean).pop();
                    if (name) {
                        return name.replace(/[^a-zA-Z0-9._-]+/g, "_").slice(0, 64);
                    }
                } catch (_) {}

                return "chatgpt-image-" + String(index + 1);
            };

            const payloadForImage = (image, index = 0) => {
                const metrics = metricsForElement(image);
                return {
                    url: image.currentSrc || image.src || image.getAttribute("src") || "",
                    filename: filenameFor(image, index),
                    capturedAt: Date.now(),
                    _area: metrics.area,
                    _score: metrics.score
                };
            };

            const payloadForCanvas = (canvas, index = 0) => {
                try {
                    const metrics = metricsForElement(canvas);
                    return {
                        url: canvas.toDataURL("image/png"),
                        filename: "chatgpt-canvas-" + String(index + 1) + ".png",
                        capturedAt: Date.now(),
                        _area: metrics.area,
                        _score: metrics.score
                    };
                } catch (_) {
                    return null;
                }
            };

            const backgroundPayloadForNode = (node) => {
                if (!node || node.nodeType !== Node.ELEMENT_NODE) {
                    return null;
                }

                const rect = node.getBoundingClientRect();
                if (rect.width < 24 || rect.height < 24 || rect.bottom <= 0 || rect.right <= 0 || rect.top >= window.innerHeight || rect.left >= window.innerWidth) {
                    return null;
                }

                const background = window.getComputedStyle(node).backgroundImage || "";
                const match = background.match(/url\\((['"]?)(.*?)\\1\\)/);
                if (!match || !match[2]) {
                    return null;
                }

                const value = normalizedURL(match[2]);
                const metrics = metricsForElement(node);
                return {
                    url: value,
                    filename: filenameFromURL(value, node.getAttribute("aria-label") || node.getAttribute("alt") || "chatgpt-image"),
                    capturedAt: Date.now(),
                    _area: metrics.area,
                    _score: metrics.score
                };
            };

            const backgroundPayloadFromElement = (element) => {
                let node = element;
                while (node && node !== document.documentElement) {
                    const payload = backgroundPayloadForNode(node);
                    if (payload) {
                        return payload;
                    }
                    node = node.parentElement;
                }
                return null;
            };

            const canvasPayloadFromElement = (element) => {
                if (!element || !element.closest) {
                    return null;
                }

                const closest = element.closest("canvas");
                if (isCandidateCanvas(closest)) {
                    return payloadForCanvas(closest);
                }

                if (element.querySelectorAll) {
                    const nested = Array.from(element.querySelectorAll("canvas"))
                        .filter(isCandidateCanvas)
                        .map((canvas, index) => ({ canvas, index, score: visibleScore(canvas) }))
                        .sort((a, b) => b.score - a.score)[0];
                    if (nested) {
                        return payloadForCanvas(nested.canvas, nested.index);
                    }
                }

                return null;
            };

            const linkPayloadFromElement = (element) => {
                const anchor = element?.closest ? element.closest("a[href]") : null;
                if (!anchor) {
                    return null;
                }

                const value = normalizedURL(anchor.getAttribute("href") || anchor.href || "");
                const hasImageChild = Boolean(anchor.querySelector?.("img, picture, [style*='background-image']"));
                const isDownload = anchor.hasAttribute("download");
                if (!hasImageChild && !isDownload && !imageURLLooksSaveable(value)) {
                    return null;
                }

                return {
                    url: value,
                    filename: filenameFromURL(value, anchor.getAttribute("download") || anchor.getAttribute("aria-label") || "chatgpt-image"),
                    capturedAt: Date.now(),
                    _area: metricsForElement(anchor).area,
                    _score: metricsForElement(anchor).score
                };
            };

            const backgroundPayloads = () => {
                const seen = new Set();
                return Array.from(document.querySelectorAll("[style*='background-image'], [role='img'], [data-testid*='image'], [class*='image'], figure, a, button"))
                    .slice(0, 260)
                    .map(backgroundPayloadForNode)
                    .filter(Boolean)
                    .filter((payload) => {
                        const key = normalizedURL(payload.url);
                        if (!key || seen.has(key)) {
                            return false;
                        }
                        seen.add(key);
                        return true;
                    });
            };

            const linkPayloads = () => {
                const seen = new Set();
                return Array.from(document.querySelectorAll("a[href]"))
                    .slice(0, 180)
                    .map(linkPayloadFromElement)
                    .filter(Boolean)
                    .filter((payload) => {
                        const key = normalizedURL(payload.url);
                        if (!key || seen.has(key)) {
                            return false;
                        }
                        seen.add(key);
                        return true;
                    });
            };

            const canvasPayloads = () => {
                return canvases()
                    .slice(0, 40)
                    .map(payloadForCanvas)
                    .filter(Boolean);
            };

            const imagePayloads = () => {
                const seen = new Set();
                const add = (payloads, payload) => {
                    const key = normalizedURL(payload?.url || "");
                    if (!key || seen.has(key)) {
                        return;
                    }

                    seen.add(key);
                    payloads.push(payload);
                };

                const payloads = [];
                images().forEach((img, index) => add(payloads, payloadForImage(img, index)));
                canvasPayloads().forEach((payload) => add(payloads, payload));
                backgroundPayloads().forEach((payload) => add(payloads, payload));
                linkPayloads().forEach((payload) => add(payloads, payload));
                return payloads;
            };

            const payloadRank = (payload) => Number(payload?._score || -1);

            const bestVisiblePayload = (requireLarge = false) => {
                const minimumArea = requireLarge ? viewportFallbackMinimumArea() : 0;
                const payloads = [];
                images().forEach((img, index) => payloads.push(payloadForImage(img, index)));
                canvases().forEach((canvas, index) => {
                    const payload = payloadForCanvas(canvas, index);
                    if (payload) {
                        payloads.push(payload);
                    }
                });
                backgroundPayloads().forEach((payload) => payloads.push(payload));
                linkPayloads().forEach((payload) => payloads.push(payload));

                return payloads
                    .filter((payload) => payloadRank(payload) >= 0)
                    .filter((payload) => !requireLarge || Number(payload._area || 0) >= minimumArea)
                    .sort((a, b) => payloadRank(b) - payloadRank(a))[0] || null;
            };

            const nonMediaInteractiveSelector = [
                "textarea",
                "input",
                "select",
                "[contenteditable='true']",
                "[role='textbox']",
                "[data-testid*='composer']",
                "[data-testid*='prompt']",
                "[class*='composer']",
                "[class*='prompt']",
                "header",
                "nav",
                "[role='banner']",
                "[data-testid*='header']",
                "[class*='header']",
                "[class*='navbar']"
            ].join(",");

            const isNonMediaInteractivePoint = (elements) => {
                return elements.some((element) => {
                    if (!element || !element.closest) {
                        return false;
                    }

                    const container = element.closest(nonMediaInteractiveSelector);
                    if (!container) {
                        return false;
                    }

                    if (candidateFromElement(container) || canvasPayloadFromElement(container) || backgroundPayloadFromElement(container) || linkPayloadFromElement(container)) {
                        return false;
                    }

                    return true;
                });
            };

            const imageAtPoint = (x, y) => {
                const elements = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [document.elementFromPoint(x, y)];
                for (const element of elements) {
                    const image = candidateFromElement(element);
                    if (image) {
                        return payloadForImage(image);
                    }

                    const canvasPayload = canvasPayloadFromElement(element);
                    if (canvasPayload) {
                        return canvasPayload;
                    }

                    const backgroundPayload = backgroundPayloadFromElement(element);
                    if (backgroundPayload) {
                        return backgroundPayload;
                    }

                    const linkPayload = linkPayloadFromElement(element);
                    if (linkPayload) {
                        return linkPayload;
                    }
                }

                if (isNonMediaInteractivePoint(elements)) {
                    return null;
                }

                const nearby = images()
                    .map((img) => {
                        const rect = img.getBoundingClientRect();
                        const clampedX = Math.max(rect.left, Math.min(x, rect.right));
                        const clampedY = Math.max(rect.top, Math.min(y, rect.bottom));
                        const dx = x - clampedX;
                        const dy = y - clampedY;
                        const distance = Math.sqrt(dx * dx + dy * dy);
                        const contains = x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
                        return { img, distance: contains ? 0 : distance, area: rect.width * rect.height };
                    })
                    .filter((entry) => entry.distance <= 44)
                    .sort((a, b) => a.distance - b.distance || b.area - a.area)[0]?.img || null;

                if (nearby) {
                    return payloadForImage(nearby);
                }

                const nearbyCanvas = canvases()
                    .map((canvas) => {
                        const rect = canvas.getBoundingClientRect();
                        const clampedX = Math.max(rect.left, Math.min(x, rect.right));
                        const clampedY = Math.max(rect.top, Math.min(y, rect.bottom));
                        const dx = x - clampedX;
                        const dy = y - clampedY;
                        const distance = Math.sqrt(dx * dx + dy * dy);
                        const contains = x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
                        return { canvas, distance: contains ? 0 : distance, area: rect.width * rect.height };
                    })
                    .filter((entry) => entry.distance <= 60)
                    .sort((a, b) => a.distance - b.distance || b.area - a.area)[0]?.canvas || null;

                return nearbyCanvas ? payloadForCanvas(nearbyCanvas) : bestVisiblePayload(true);
            };

            const filenameFromURL = (value, fallback) => {
                const cleanedFallback = String(fallback || "").trim().replace(/[^a-zA-Z0-9._-]+/g, "_").slice(0, 64);
                if (cleanedFallback) {
                    return cleanedFallback;
                }

                try {
                    const name = new URL(String(value || ""), window.location.href).pathname.split("/").filter(Boolean).pop();
                    if (name) {
                        return name.replace(/[^a-zA-Z0-9._-]+/g, "_").slice(0, 64);
                    }
                } catch (_) {}

                return "chatgpt-image";
            };

            const extensionForMime = (mimeType) => {
                const mime = String(mimeType || "").toLowerCase();
                if (mime.includes("png")) { return "png"; }
                if (mime.includes("jpeg") || mime.includes("jpg")) { return "jpg"; }
                if (mime.includes("webp")) { return "webp"; }
                if (mime.includes("gif")) { return "gif"; }
                return "png";
            };

            const filenameWithExtension = (filename, mimeType) => {
                const value = String(filename || "chatgpt-image");
                const extension = extensionForMime(mimeType);
                return value.toLowerCase().endsWith("." + extension.toLowerCase()) ? value : value + "." + extension;
            };

            const postBase64 = (base64, mimeType, filename, mode) => {
                const chunkSize = 220000;
                const id = String(Date.now()) + "-" + Math.random().toString(36).slice(2);
                const total = Math.max(1, Math.ceil(base64.length / chunkSize));
                for (let index = 0; index < total; index += 1) {
                    post({
                        type: "imageChunk",
                        id,
                        index,
                        total,
                        mode,
                        filename,
                        mimeType,
                        data: base64.slice(index * chunkSize, (index + 1) * chunkSize)
                    });
                }
            };

            const dataURLPayload = (dataURL) => {
                const commaIndex = dataURL.indexOf(",");
                const header = commaIndex >= 0 ? dataURL.slice(0, commaIndex) : "";
                const data = commaIndex >= 0 ? dataURL.slice(commaIndex + 1) : dataURL;
                const mimeMatch = header.match(/^data:([^;]+)/);
                return {
                    base64: data,
                    mimeType: mimeMatch ? mimeMatch[1] : "image/png"
                };
            };

            const blobToDataURL = (blob) => new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(String(reader.result || ""));
                reader.onerror = () => reject(reader.error || new Error("read failed"));
                reader.readAsDataURL(blob);
            });

            const saveImage = async (img, index, mode) => {
                const src = img.currentSrc || img.src || img.getAttribute("src") || "";
                const filename = filenameFor(img, index);

                if (/^https?:/i.test(src)) {
                    post({
                        type: "imageURL",
                        url: src,
                        filename,
                        mode
                    });
                    return;
                }

                if (src.startsWith("data:")) {
                    const payload = dataURLPayload(src);
                    postBase64(payload.base64, payload.mimeType, filenameWithExtension(filename, payload.mimeType), mode);
                    return;
                }

                const response = await fetch(src, { credentials: "include", cache: "force-cache" });
                const blob = await response.blob();
                const dataURL = await blobToDataURL(blob);
                const payload = dataURLPayload(dataURL);
                const mimeType = payload.mimeType || blob.type || response.headers.get("content-type") || "image/png";
                postBase64(payload.base64, mimeType, filenameWithExtension(filename, mimeType), mode);
            };

            const saveURL = async (url, suggestedFilename, mode) => {
                const image = imageForURL(url);
                if (image) {
                    await saveImage(image, 0, mode);
                    return;
                }

                const filename = filenameFromURL(url, suggestedFilename);
                if (/^https?:/i.test(String(url))) {
                    post({
                        type: "imageURL",
                        url: String(url),
                        filename,
                        mode
                    });
                    return;
                }

                if (String(url).startsWith("data:")) {
                    const payload = dataURLPayload(String(url));
                    postBase64(payload.base64, payload.mimeType, filenameWithExtension(filename, payload.mimeType), mode);
                    return;
                }

                const response = await fetch(String(url), { credentials: "include", cache: "force-cache" });
                const blob = await response.blob();
                const dataURL = await blobToDataURL(blob);
                const payload = dataURLPayload(dataURL);
                const mimeType = payload.mimeType || blob.type || response.headers.get("content-type") || "image/png";
                postBase64(payload.base64, mimeType, filenameWithExtension(filename, mimeType), mode);
            };

            const savePayload = async (payload, index, mode) => {
                await saveURL(payload.url, payload.filename || ("chatgpt-image-" + String(index + 1)), mode);
            };

            const saveOne = async () => {
                const payload = bestVisiblePayload(false);
                if (!payload) {
                    post({ type: "status", message: "未找到图片" });
                    return;
                }

                post({ type: "status", message: "正在保存图片..." });
                try {
                    await savePayload(payload, 0, "single");
                } catch (_) {
                    post({ type: "status", message: "保存失败" });
                }
            };

            const saveAll = async () => {
                const list = imagePayloads();
                if (!list.length) {
                    post({ type: "status", message: "未找到图片" });
                    return;
                }

                post({ type: "status", message: "正在保存 " + list.length + " 张图片..." });
                for (let index = 0; index < list.length; index += 1) {
                    try {
                        await savePayload(list[index], index, "batch");
                    } catch (_) {}
                    await new Promise((resolve) => setTimeout(resolve, 90));
                }
                post({ type: "status", message: "已提交 " + list.length + " 张图片保存" });
            };

            const saveContextURL = async (url, suggestedFilename) => {
                if (!url) {
                    post({ type: "status", message: "未找到图片" });
                    return false;
                }

                post({ type: "status", message: "正在保存图片..." });
                try {
                    await saveURL(String(url), suggestedFilename || "chatgpt-image", "single");
                } catch (_) {
                    post({ type: "status", message: "保存失败" });
                }
                return true;
            };

            window.__gptNativeSaveOne = saveOne;
            window.__gptNativeSaveAll = saveAll;
            window.__gptNativeSaveURL = saveContextURL;
            window.__gptNativeImageAtPoint = imageAtPoint;
            window.__gptNativeBestImagePayload = bestVisiblePayload;
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    private static let locationObserverScript = WKUserScript(
        source: """
        (() => {
            if (window.__gptNativeLocationObserverInstalled) {
                return;
            }

            window.__gptNativeLocationObserverInstalled = true;
            const lastLocation = { value: "" };
            const postLocation = () => {
                const href = String(window.location.href);
                if (href === lastLocation.value) {
                    return;
                }

                lastLocation.value = href;
                try {
                    window.__gptNativeApplySafeArea && window.__gptNativeApplySafeArea(true);
                } catch (_) {}
                try {
                    window.webkit.messageHandlers.gptNativeLocation.postMessage(href);
                } catch (_) {}
            };
            const wrapHistory = (name) => {
                const original = window.history[name];
                window.history[name] = function() {
                    const result = original.apply(this, arguments);
                    setTimeout(postLocation, 0);
                    return result;
                };
            };

            wrapHistory("pushState");
            wrapHistory("replaceState");
            window.addEventListener("popstate", postLocation);
            window.addEventListener("hashchange", postLocation);
            document.addEventListener("visibilitychange", postLocation);
            postLocation();
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
        private struct ImageTransfer {
            var total: Int
            var filename: String
            var mimeType: String?
            var mode: String?
            var chunks: [String?]
        }

        private struct ContextImage {
            let url: URL
            let filename: String
        }

        private weak var state: ChatGPTWebState?
        private weak var attachedWebView: WKWebView?
        private weak var imageMenuAnchorView: ImageMenuAnchorView?
        private weak var imageSaveContextMenuView: ImageSaveContextMenuView?
        private var observations: [NSKeyValueObservation] = []
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]
        private var imageTransfers: [String: ImageTransfer] = [:]
        private var imageLongPressRecognizer: UILongPressGestureRecognizer?

        init(state: ChatGPTWebState) {
            self.state = state
        }

        func attach(to webView: WKWebView) {
            removeStaleTemporaryImages()
            installImageLongPressRecognizer(on: webView)
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        guard let state = self?.state else {
                            return
                        }

                        let progress = webView.estimatedProgress
                        if progress == 1 || abs(progress - state.estimatedProgress) >= 0.02 {
                            state.estimatedProgress = progress
                        }
                    }
                },
                webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.state?.remember(webView.url)
                    }
                }
            ]
        }

        private func installImageLongPressRecognizer(on webView: WKWebView) {
            if let recognizer = imageLongPressRecognizer,
               attachedWebView === webView,
               recognizer.view === webView {
                return
            }

            if let recognizer = imageLongPressRecognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            imageMenuAnchorView?.removeFromSuperview()
            imageSaveContextMenuView?.dismiss(animated: false)

            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleImageLongPress(_:)))
            recognizer.minimumPressDuration = 0.42
            recognizer.allowableMovement = 18
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            webView.addGestureRecognizer(recognizer)

            let anchorView = ImageMenuAnchorView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
            anchorView.backgroundColor = .clear
            anchorView.alpha = 0.01
            anchorView.accessibilityElementsHidden = true
            webView.addSubview(anchorView)

            attachedWebView = webView
            imageLongPressRecognizer = recognizer
            imageMenuAnchorView = anchorView
        }

        @objc private func handleImageLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let webView = recognizer.view as? WKWebView else {
                return
            }

            let point = recognizer.location(in: webView)
            resolveHitImage(at: point, in: webView) { [weak self, weak webView] contextImage in
                guard let self,
                      let webView,
                      let contextImage else {
                    return
                }

                self.presentImageActionMenu(for: contextImage, at: point, in: webView)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer === imageLongPressRecognizer else {
                return true
            }

            if let menuView = imageSaveContextMenuView,
               let touchedView = touch.view,
               touchedView.isDescendant(of: menuView) {
                return false
            }

            return true
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "gptNativeLocation":
                guard let value = message.body as? String,
                      let url = URL(string: value) else {
                    return
                }

                Task { @MainActor in
                    self.state?.remember(url)
                }
            case "gptNativeImageSave":
                handleImageSaveMessage(message.body)
            default:
                return
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state?.errorText = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state?.estimatedProgress = 1
            state?.hasFinishedInitialLoad = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel, preferences)
                return
            }

            if navigationAction.shouldPerformDownload {
                decisionHandler(.download, preferences)
                return
            }

            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                decisionHandler(.allow, preferences)
                return
            }

            if ["about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") {
                decisionHandler(.allow, preferences)
                return
            }

            if let scheme = url.scheme?.lowercased(),
               ["mailto", "tel", "sms", "facetime", "facetime-audio", "itms-apps"].contains(scheme) {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel, preferences)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func resolveHitImage(
            at point: CGPoint,
            in webView: WKWebView,
            completion: @escaping (ContextImage?) -> Void
        ) {
            let x = javaScriptNumberLiteral(point.x)
            let y = javaScriptNumberLiteral(point.y)
            let script = """
            (() => {
                if (!window.__gptNativeImageAtPoint) {
                    return null;
                }
                return window.__gptNativeImageAtPoint(\(x), \(y));
            })();
            """

            webView.evaluateJavaScript(script) { [weak self] result, _ in
                completion(self?.contextImage(from: result))
            }
        }

        private func presentImageActionMenu(for contextImage: ContextImage, at point: CGPoint, in webView: WKWebView) {
            imageSaveContextMenuView?.dismiss(animated: false)

            let menuView = ImageSaveContextMenuView(frame: webView.bounds, sourcePoint: point)
            menuView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            menuView.onSaveImage = { [weak self, weak webView] in
                guard let webView else {
                    return
                }
                self?.saveContextImage(contextImage.url, suggestedFilename: contextImage.filename, in: webView)
            }
            menuView.onSaveAll = { [weak self, weak webView] in
                guard let webView else {
                    return
                }
                self?.saveAllImages(in: webView)
            }

            webView.addSubview(menuView)
            imageSaveContextMenuView = menuView
            menuView.present()
        }

        private func saveContextImage(_ url: URL, suggestedFilename: String, in webView: WKWebView) {
            state?.showTransientMessage("正在保存图片...")
            let script = """
            (() => {
                if (!window.__gptNativeSaveURL) {
                    return false;
                }
                window.__gptNativeSaveURL(\(javaScriptStringLiteral(url.absoluteString)), \(javaScriptStringLiteral(suggestedFilename)));
                return true;
            })();
            """

            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                guard (result as? Bool) != true else {
                    return
                }

                guard let self else {
                    return
                }

                if ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                   let webView {
                    self.saveRemoteImage(url, suggestedFilename: suggestedFilename, mimeTypeHint: nil, mode: "single", webView: webView)
                    return
                }

                self.showSaveFailed()
            }
        }

        private func saveAllImages(in webView: WKWebView) {
            let script = """
            (() => {
                if (!window.__gptNativeSaveAll) {
                    return false;
                }
                window.__gptNativeSaveAll();
                return true;
            })();
            """

            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard (result as? Bool) == true else {
                    Task { @MainActor in
                        self?.state?.showTransientMessage("保存工具加载中")
                    }
                    return
                }
            }
        }

        private func suggestedFilename(for url: URL) -> String {
            let value = url.lastPathComponent
            return value.isEmpty ? "chatgpt-image" : value
        }

        private func contextImage(from result: Any?) -> ContextImage? {
            guard let payload = result as? [String: Any],
                  let value = payload["url"] as? String,
                  !value.isEmpty,
                  let url = URL(string: value) else {
                return nil
            }

            let filename = (payload["filename"] as? String) ?? suggestedFilename(for: url)
            return ContextImage(url: url, filename: filename)
        }

        private func javaScriptNumberLiteral(_ value: CGFloat) -> String {
            let number = Double(value)
            guard number.isFinite else {
                return "0"
            }

            return String(format: "%.2f", number)
        }

        private func javaScriptStringLiteral(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
                  let json = String(data: data, encoding: .utf8) else {
                return "\"\""
            }

            return String(json.dropFirst().dropLast())
        }

        private func handle(_ error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else {
                return
            }
            state?.hasFinishedInitialLoad = true
            state?.errorText = userFacingConnectionMessage(for: nsError)
        }

        private func userFacingConnectionMessage(for error: NSError) -> String {
            guard error.domain == NSURLErrorDomain else {
                return error.localizedDescription
            }

            switch error.code {
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return "无法建立安全连接。通常是当前网络、节点/代理或证书链异常导致，不是只能在 Wi-Fi 下使用。请切换节点或网络后重试。"
            case NSURLErrorNotConnectedToInternet:
                return "当前没有网络连接。请检查 Wi-Fi、蜂窝数据或代理节点后重试。"
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed:
                return "连接 ChatGPT 超时或中断。通常是网络、DNS 或节点不稳定导致，请切换节点或网络后重试。"
            default:
                return error.localizedDescription
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let destination = temporaryDownloadURL(for: suggestedFilename, response: response)
            downloadDestinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let identifier = ObjectIdentifier(download)
            guard let destination = downloadDestinations.removeValue(forKey: identifier) else {
                return
            }

            saveDownloadedImageIfPossible(at: destination, mode: "single")
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
                try? FileManager.default.removeItem(at: destination)
            }

            Task { @MainActor in
                self.state?.showTransientMessage("保存失败")
            }
        }

        private func temporaryDownloadURL(for suggestedFilename: String, response: URLResponse) -> URL {
            temporaryImageURL(for: suggestedFilename, mimeType: response.mimeType)
        }

        private func saveDownloadedImageIfPossible(at url: URL, mode: String?) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }

            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    try? FileManager.default.removeItem(at: url)
                    Task { @MainActor in
                        self.state?.showTransientMessage("需要相册权限")
                    }
                    return
                }

                self.saveImageResourceToPhotos(url, mode: mode)
            }
        }

        private func saveImageResourceToPhotos(_ url: URL, mode: String?) {
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: url, options: options)
            }, completionHandler: { success, _ in
                if success {
                    self.finishSavingImage(at: url, message: self.successMessage(for: mode))
                    return
                }

                self.saveImageFileToPhotos(url, mode: mode)
            })
        }

        private func saveImageFileToPhotos(_ url: URL, mode: String?) {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }, completionHandler: { success, _ in
                if success {
                    self.finishSavingImage(at: url, message: self.successMessage(for: mode))
                    return
                }

                self.saveImageDataToPhotos(url, mode: mode)
            })
        }

        private func saveImageDataToPhotos(_ url: URL, mode: String?) {
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else {
                finishSavingImage(at: url, message: "保存失败")
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { success, _ in
                self.finishSavingImage(at: url, message: success ? self.successMessage(for: mode) : "保存失败")
            })
        }

        private func finishSavingImage(at url: URL, message: String?) {
            try? FileManager.default.removeItem(at: url)
            if let message {
                Task { @MainActor in
                    self.state?.showTransientMessage(message)
                }
            }
        }

        private func successMessage(for mode: String?) -> String? {
            mode == "batch" ? nil : "已保存到相册"
        }

        private func handleImageSaveMessage(_ body: Any) {
            guard let payload = body as? [String: Any],
                  let type = payload["type"] as? String else {
                return
            }

            switch type {
            case "status":
                if let message = payload["message"] as? String {
                    Task { @MainActor in
                        self.state?.showTransientMessage(message)
                    }
                }
            case "imageURL":
                handleImageURL(payload)
            case "imageChunk":
                handleImageChunk(payload)
            default:
                break
            }
        }

        private func handleImageURL(_ payload: [String: Any]) {
            guard let value = payload["url"] as? String,
                  let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                showSaveFailed()
                return
            }

            let filename = (payload["filename"] as? String) ?? "chatgpt-image"
            let mimeTypeHint = payload["mimeType"] as? String
            let mode = payload["mode"] as? String
            saveRemoteImage(url, suggestedFilename: filename, mimeTypeHint: mimeTypeHint, mode: mode, webView: attachedWebView)
        }

        private func saveRemoteImage(_ url: URL, suggestedFilename: String, mimeTypeHint: String?, mode: String?, webView: WKWebView?) {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

            guard let webView else {
                startImageDataTask(request, suggestedFilename: suggestedFilename, mimeTypeHint: mimeTypeHint, mode: mode)
                return
            }

            if let referer = webView.url?.absoluteString {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else {
                    return
                }

                var cookieRequest = request
                let matchingCookies = cookies.filter { self.cookie($0, appliesTo: url) }
                if !matchingCookies.isEmpty,
                   let cookieHeader = HTTPCookie.requestHeaderFields(with: matchingCookies)["Cookie"] {
                    cookieRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }

                self.startImageDataTask(cookieRequest, suggestedFilename: suggestedFilename, mimeTypeHint: mimeTypeHint, mode: mode)
            }
        }

        private func startImageDataTask(_ request: URLRequest, suggestedFilename: String, mimeTypeHint: String?, mode: String?) {
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self else {
                    return
                }

                guard error == nil,
                      let data,
                      !data.isEmpty else {
                    self.showSaveFailed()
                    return
                }

                let mimeType = response?.mimeType ?? mimeTypeHint
                self.saveImageDataToPhotos(data, suggestedFilename: suggestedFilename, mimeType: mimeType, mode: mode)
            }.resume()
        }

        private func cookie(_ cookie: HTTPCookie, appliesTo url: URL) -> Bool {
            guard let host = url.host?.lowercased() else {
                return false
            }

            let domain = cookie.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            let hostMatches = host == domain || host.hasSuffix("." + domain)
            guard hostMatches else {
                return false
            }

            let path = url.path.isEmpty ? "/" : url.path
            return path.hasPrefix(cookie.path)
        }

        private func handleImageChunk(_ payload: [String: Any]) {
            guard let id = payload["id"] as? String,
                  let chunk = payload["data"] as? String,
                  let index = numberValue(payload["index"]),
                  let total = numberValue(payload["total"]),
                  total > 0,
                  index >= 0,
                  index < total else {
                showSaveFailed()
                return
            }

            let filename = (payload["filename"] as? String) ?? "chatgpt-image"
            let mimeType = payload["mimeType"] as? String
            let mode = payload["mode"] as? String
            var transfer = imageTransfers[id] ?? ImageTransfer(
                total: total,
                filename: filename,
                mimeType: mimeType,
                mode: mode,
                chunks: Array(repeating: nil, count: total)
            )

            guard transfer.total == total,
                  index < transfer.chunks.count else {
                imageTransfers[id] = nil
                showSaveFailed()
                return
            }

            transfer.chunks[index] = chunk
            if transfer.chunks.contains(where: { $0 == nil }) {
                imageTransfers[id] = transfer
                return
            }

            imageTransfers[id] = nil
            let base64 = transfer.chunks.compactMap { $0 }.joined()
            guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
                  !data.isEmpty else {
                showSaveFailed()
                return
            }

            saveImageDataToPhotos(data, suggestedFilename: transfer.filename, mimeType: transfer.mimeType, mode: transfer.mode)
        }

        private func saveImageDataToPhotos(_ data: Data, suggestedFilename: String, mimeType: String?, mode: String?) {
            let url = temporaryImageURL(for: suggestedFilename, mimeType: mimeType)
            do {
                try data.write(to: url, options: [.atomic])
                saveDownloadedImageIfPossible(at: url, mode: mode)
            } catch {
                showSaveFailed()
            }
        }

        private func temporaryImageURL(for suggestedFilename: String, mimeType: String?) -> URL {
            var filename = safeFilename(suggestedFilename)
            if URL(fileURLWithPath: filename).pathExtension.isEmpty {
                let fileExtension = mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "png"
                filename += "." + fileExtension
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GPTNativeDownloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            return directory
                .appendingPathComponent(UUID().uuidString + "-" + filename)
        }

        private func removeStaleTemporaryImages() {
            DispatchQueue.global(qos: .utility).async {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("GPTNativeDownloads", isDirectory: true)
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    return
                }

                let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
                for url in contents {
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    if (values?.contentModificationDate ?? .distantPast) < cutoff {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
        }

        private func safeFilename(_ suggestedFilename: String) -> String {
            let safeName = suggestedFilename
                .map { character -> Character in
                    character.isLetter || character.isNumber || character == "." || character == "-" || character == "_" ? character : "_"
                }
                .reduce(into: "") { $0.append($1) }

            return safeName.isEmpty ? "chatgpt-image" : safeName
        }

        private func numberValue(_ value: Any?) -> Int? {
            if let value = value as? Int {
                return value
            }

            return (value as? NSNumber)?.intValue
        }

        private func showSaveFailed() {
            Task { @MainActor in
                self.state?.showTransientMessage("保存失败")
            }
        }
    }
}
