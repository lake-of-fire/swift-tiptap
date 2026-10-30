import SwiftUI
import WebKit
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// HTML editor with native formatting controls on both platforms.
/// On iOS the controls follow the public keyboard layout guide; on macOS they
/// remain above the document. A supplied context may drive additional controls.
@MainActor
public struct RichTextEditorView: View {
    @Binding private var htmlContent: String
    private let placeholder: String?
    private let suppliedContext: EditorContext?
    private let onEditorReady: (() -> Void)?
    @StateObject private var ownedContext = EditorContext()

    public init(htmlContent: Binding<String>, placeholder: String? = nil,
                editorContext: EditorContext? = nil, onEditorReady: (() -> Void)? = nil) {
        _htmlContent = htmlContent
        self.placeholder = placeholder
        suppliedContext = editorContext
        self.onEditorReady = onEditorReady
    }

    public var body: some View {
        EditorPresentation(htmlContent: $htmlContent, placeholder: placeholder,
                           context: suppliedContext ?? ownedContext, onEditorReady: onEditorReady)
    }
}

@MainActor
private struct EditorPresentation: View {
    @Binding var htmlContent: String
    let placeholder: String?
    @ObservedObject var context: EditorContext
    let onEditorReady: (() -> Void)?
    @State private var linkURL = ""
    @State private var imageURL = ""

    var body: some View {
        VStack(spacing: 0) {
#if canImport(AppKit)
            FormattingToolbar(context: context)
                .padding(.vertical, 4)
                .background(.regularMaterial)
            Divider()
#endif
            EditorWebSurface(htmlContent: $htmlContent, placeholder: placeholder,
                             editorContext: context, onEditorReady: onEditorReady)
                .id(ObjectIdentifier(context))
#if canImport(UIKit)
                // UIKit's keyboard guide owns avoidance, including undocked keyboards.
                .ignoresSafeArea(.keyboard, edges: .bottom)
#endif
        }
        .alert("Add Link", isPresented: $context.isLinkAlertPresented) {
            TextField("URL, email, or phone number", text: $linkURL)
#if canImport(UIKit)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
#endif
            Button("Add") {
                if !linkURL.isEmpty { context.setLink(url: linkURL.autoDetectedLink) }
                linkURL = ""
            }
            Button("Remove Link", role: .destructive) {
                context.removeLink()
                linkURL = ""
            }
            Button("Cancel", role: .cancel) { linkURL = "" }
        } message: {
            Text("Auto-detects links, emails, and phone numbers")
        }
        .alert("Add Image", isPresented: $context.isImageAlertPresented) {
            TextField("https://example.com/image.jpg", text: $imageURL)
#if canImport(UIKit)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
#endif
            Button("Insert") {
                if !imageURL.isEmpty { context.insertImage(url: imageURL) }
                imageURL = ""
            }
            Button("Cancel", role: .cancel) { imageURL = "" }
        }
    }
}

/// One coordinator owns each concrete WebView. Async callbacks are fenced to
/// that view and document, so replacing an editor cannot publish stale state.
@MainActor
struct EditorWebSurface {
    @Binding var htmlContent: String
    let placeholder: String?
    @ObservedObject var editorContext: EditorContext
    let onEditorReady: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    init(htmlContent: Binding<String>, placeholder: String? = nil,
         editorContext: EditorContext? = nil, onEditorReady: (() -> Void)? = nil) {
        _htmlContent = htmlContent
        self.placeholder = placeholder
        self.editorContext = editorContext ?? EditorContext()
        self.onEditorReady = onEditorReady
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        coordinator.installBridge(in: configuration.userContentController)
        for name in Coordinator.messageNames {
            configuration.userContentController.add(coordinator, name: name)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
#if canImport(UIKit)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
#endif
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        editorContext.attach(webView)
        if let url = Bundle.module.url(forResource: "tiptap-editor", withExtension: "html",
                                       subdirectory: "RichTextEditor") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func update(_ webView: WKWebView, coordinator: Coordinator) {
        let contextChanged = coordinator.parent.editorContext !== editorContext
        if contextChanged {
            coordinator.parent.editorContext.detach(webView)
            editorContext.bind(to: webView, contentGeneration: coordinator.contentGeneration)
        }
        coordinator.parent = self
        guard coordinator.isEditorReady else { return }
        let theme = colorScheme == .dark ? "dark" : "light"
        if coordinator.currentTheme != theme {
            coordinator.currentTheme = theme
            webView.evaluateJavaScript("window.setTheme('\(theme)')", completionHandler: nil)
        }
        coordinator.replaceContentIfNeeded(htmlContent, force: contextChanged)
    }

    static func dismantle(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.documentGeneration += 1
        for name in Coordinator.messageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        webView.navigationDelegate = nil
        webView.stopLoading()
        // Dismantling runs inside SwiftUI's update transaction. Publish the
        // context reset on the next main-actor turn; detach's identity check
        // prevents this old view from resetting a replacement editor.
        let context = coordinator.parent.editorContext
        Task { @MainActor [weak context] in context?.detach(webView) }
        coordinator.webView = nil
    }

    static func literal(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, @unchecked Sendable {
        static let messageNames = ["contentChanged", "editorReady", "editorHeightChanged", "editorStateChanged"]
        var documentGeneration = 0
        var parent: EditorWebSurface
        var webView: WKWebView?
        var lastContentFromJS: String = ""
        var isEditorReady = false
        var currentTheme: String?
        private var isInitializingEditor = false
        let bridgeGeneration = UUID().uuidString
        private(set) var contentGeneration = UUID().uuidString
        private var pendingContent: String?

        init(_ parent: EditorWebSurface) {
            self.parent = parent
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let webView, message.webView === webView, message.frameInfo.isMainFrame else { return }
            switch message.name {
            case "contentChanged":
                // Initialization publishes its normalized result once, before readiness.
                // TipTap can also emit contentChanged while setContent is in flight.
                if isEditorReady,
                   let payload = message.body as? [String: Any],
                   payload["bridgeGeneration"] as? String == bridgeGeneration,
                   payload["contentGeneration"] as? String == contentGeneration,
                   let html = payload["html"] as? String {
                    // A binding can change before SwiftUI delivers its next
                    // representable update. Adopt that native target first,
                    // instead of overwriting it with an already queued edit.
                    guard parent.htmlContent == (pendingContent ?? lastContentFromJS) else {
                        replaceContentIfNeeded(parent.htmlContent, force: false)
                        return
                    }
                    pendingContent = nil
                    lastContentFromJS = html
                    parent.htmlContent = html
                }

            case "editorReady":
                guard !isEditorReady, !isInitializingEditor,
                      let payload = message.body as? [String: Any],
                      payload["bridgeGeneration"] as? String == bridgeGeneration else { return }
                initializeEditor()

            case "editorStateChanged":
                guard let payload = message.body as? [String: Any],
                      payload["bridgeGeneration"] as? String == bridgeGeneration,
                      payload["contentGeneration"] as? String == contentGeneration else { return }
                parent.editorContext.updateState(payload, from: webView)

            case "editorHeightChanged":
                break

            default:
                break
            }
        }

        func replaceContentIfNeeded(_ content: String, force: Bool) {
            // Compare with the pending native target too: A → B → A must retire
            // B even when A still equals the last delivered JavaScript value.
            guard let webView, force || content != (pendingContent ?? lastContentFromJS) else { return }
            let generation = beginContentReplacement(content, in: webView)
            let escaped = EditorWebSurface.literal(content)
            webView.evaluateJavaScript("window.setContent(\(escaped), '\(generation)'); window.getContent()") { [weak self, weak webView] result, error in
                guard let self, let webView, self.webView === webView,
                      self.contentGeneration == generation else { return }
                // A no-op setContent need not emit an update. Publish its
                // normalization only while the requested binding value remains
                // current; a later native value or user edit owns its own result.
                guard error == nil, let html = result as? String else {
                    self.pendingContent = nil
                    return
                }
                guard self.parent.htmlContent == content else {
                    self.replaceContentIfNeeded(self.parent.htmlContent, force: false)
                    return
                }
                self.pendingContent = nil
                self.lastContentFromJS = html
                if self.parent.htmlContent != html { self.parent.htmlContent = html }
                if self.isEditorReady { self.parent.editorContext.markReady(webView) }
            }
        }

        private func beginContentReplacement(_ content: String, in webView: WKWebView) -> String {
            // Retire queued edits before submitting the asynchronous replacement.
            contentGeneration = UUID().uuidString
            pendingContent = content
            parent.editorContext.bind(to: webView, contentGeneration: contentGeneration)
            return contentGeneration
        }

        private func initializeEditor() {
            guard let webView else { return }
            isInitializingEditor = true
            let theme = parent.colorScheme == .dark ? "dark" : "light"
            currentTheme = theme
            let content = parent.htmlContent
            let generation = beginContentReplacement(content, in: webView)
            let escaped = EditorWebSurface.literal(content)
            let placeholder = EditorWebSurface.literal(parent.placeholder ?? "Start typing...")
            webView.evaluateJavaScript("window.setPlaceholder(\(placeholder)); window.setTheme('\(theme)'); window.setContent(\(escaped), '\(generation)'); window.getContent()") { [weak self, weak webView] result, error in
                guard let self, let webView, self.webView === webView,
                      self.contentGeneration == generation else { return }
                self.isInitializingEditor = false
                self.pendingContent = nil
                guard error == nil else { return }
                // The binding may change while WebKit initializes. Never replace its
                // newer value with the normalization of the previous content.
                guard self.parent.htmlContent == content else {
                    self.initializeEditor()
                    return
                }
                if let html = result as? String {
                    self.lastContentFromJS = html
                    self.parent.htmlContent = html
                }
                guard self.webView === webView else { return }
                self.isEditorReady = true
                self.parent.editorContext.markReady(webView)
                self.parent.onEditorReady?()
                webView.evaluateJavaScript("window.publishEditorState()", completionHandler: nil)
            }
        }

        func installBridge(in controller: WKUserContentController) {
            controller.addUserScript(WKUserScript(
                source: "window.__tipTapBridgeGeneration = '\(bridgeGeneration)';",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard self.webView === webView else { return }
            documentGeneration += 1
            contentGeneration = UUID().uuidString
            pendingContent = nil
            isInitializingEditor = false
            isEditorReady = false
            parent.editorContext.resetReadiness()
        }

        public func webView(_ webView: WKWebView,
                            decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.navigationType == .other || navigationAction.request.url?.isFileURL == true
                ? .allow : .cancel
        }
    }
}

#if canImport(UIKit)
extension EditorWebSurface: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> EditorViewController {
        EditorViewController(webView: makeWebView(coordinator: context.coordinator), context: editorContext)
    }

    func updateUIViewController(_ controller: EditorViewController, context: Context) {
        update(controller.webView, coordinator: context.coordinator)
        controller.updateToolbar()
    }

    static func dismantleUIViewController(_ controller: EditorViewController, coordinator: Coordinator) {
        dismantle(controller.webView, coordinator: coordinator)
    }
}

/// Pure geometry used by the native controller and layout regression tests.
struct EditorKeyboardGeometry: Equatable {
    let toolbarWidth: CGFloat
    let toolbarCenterX: CGFloat
    let reservesBottomSpace: Bool

    init(bounds: CGRect, safeArea: CGRect, keyboard: CGRect) {
        let overlaps = keyboard.intersects(bounds) && keyboard.height > 1
        let docked = overlaps && keyboard.maxY >= bounds.maxY - 1
            && keyboard.width >= safeArea.width - 1
        let floating = overlaps && !docked
        toolbarWidth = floating ? min(safeArea.width, max(240, keyboard.width)) : safeArea.width
        let center = floating ? keyboard.midX : safeArea.midX
        toolbarCenterX = min(max(center, safeArea.minX + toolbarWidth / 2), safeArea.maxX - toolbarWidth / 2)
        reservesBottomSpace = !floating
    }
}

@MainActor
final class EditorViewController: UIViewController {
    let webView: WKWebView
    let context: EditorContext
    private let toolbar: UIHostingController<AnyView>
    private var toolbarHeight: NSLayoutConstraint!
    private var toolbarWidth: NSLayoutConstraint!
    private var toolbarCenter: NSLayoutConstraint!
    private var webViewBottom: NSLayoutConstraint!

    init(webView: WKWebView, context: EditorContext) {
        self.webView = webView
        self.context = context
        toolbar = UIHostingController(rootView: AnyView(FormattingToolbar(context: context)
            .padding(.vertical, 4).background(.regularMaterial)))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        addChild(toolbar)
        toolbar.view.backgroundColor = .clear
        toolbar.view.translatesAutoresizingMaskIntoConstraints = false
        toolbar.view.accessibilityIdentifier = "RichTextEditor.FormattingToolbarHost"
        view.addSubview(toolbar.view)
        toolbar.didMove(toParent: self)
        toolbarHeight = toolbar.view.heightAnchor.constraint(equalToConstant: 0)
        toolbarWidth = toolbar.view.widthAnchor.constraint(equalToConstant: 0)
        toolbarCenter = toolbar.view.centerXAnchor.constraint(equalTo: view.leadingAnchor)
        webViewBottom = webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor), webViewBottom,
            toolbarHeight, toolbarWidth, toolbarCenter,
        ])
        let guide = view.keyboardLayoutGuide
        guide.followsUndockedKeyboard = true
        guide.setConstraints([toolbar.view.bottomAnchor.constraint(equalTo: guide.topAnchor)], activeWhenAwayFrom: .top)
        guide.setConstraints([toolbar.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)], activeWhenNearEdge: .top)
        updateToolbar()
    }

    func updateToolbar() {
        guard isViewLoaded else { return }
        let visible = context.isReady && (context.isFocused || context.isLinkAlertPresented || context.isImageAlertPresented)
        toolbarHeight.constant = visible ? 52 : 0
        toolbar.view.isHidden = !visible
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safeArea = view.safeAreaLayoutGuide.layoutFrame
        let geometry = EditorKeyboardGeometry(bounds: view.bounds, safeArea: safeArea,
                                               keyboard: view.keyboardLayoutGuide.layoutFrame)
        if abs(toolbarWidth.constant - geometry.toolbarWidth) > 0.5 {
            toolbarWidth.constant = max(0, geometry.toolbarWidth)
        }
        if abs(toolbarCenter.constant - geometry.toolbarCenterX) > 0.5 {
            toolbarCenter.constant = geometry.toolbarCenterX
        }
        let visible = !toolbar.view.isHidden
        let barAtBottom = toolbar.view.frame.maxY >= safeArea.maxY - 1
        let inset = visible && (geometry.reservesBottomSpace || barAtBottom)
            ? max(view.safeAreaInsets.bottom, view.bounds.maxY - toolbar.view.frame.minY)
            : view.safeAreaInsets.bottom
        let constant = -max(0, inset)
        if abs(webViewBottom.constant - constant) > 0.5 {
            webViewBottom.constant = constant
            view.setNeedsLayout()
        }
    }
}
#elseif canImport(AppKit)
extension EditorWebSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, coordinator: context.coordinator) }
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) { dismantle(webView, coordinator: coordinator) }
}
#endif
