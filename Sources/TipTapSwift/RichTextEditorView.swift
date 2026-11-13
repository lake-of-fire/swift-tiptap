//
//  RichTextEditorView.swift
//  TipTapSwift
//
//  A SwiftUI view wrapping WKWebView with a full TipTap WYSIWYG editor.
//  Communicates bidirectionally with the TipTap JS bundle via WKScriptMessageHandler.
//

import SwiftUI
import WebKit
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A WYSIWYG rich text editor powered by TipTap, rendered inside a WKWebView.
///
/// Use this view when you need full rich text editing.
/// Content is stored as HTML.
///
/// ```swift
/// @State private var html = ""
/// @State private var context = EditorContext()
///
/// RichTextEditorView(htmlContent: $html, editorContext: context)
/// ```
@MainActor
public struct RichTextEditorView {
    @Binding var htmlContent: String
    var documentID: AnyHashable?
    var placeholder: String?
    var editorContext: EditorContext?
    var onEditorReady: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    /// Creates a rich text editor.
    /// - Parameters:
    ///   - htmlContent: Bidirectional binding to the HTML content string.
    ///     Assigning a new value loads a new baseline and clears undo/redo history.
    ///     Its getter and setter must capture a stable document or ID, rather
    ///     than redirecting through a selection that can change before a view update.
    ///   - documentID: Stable identity of the document being edited. Change this
    ///     when switching documents, including documents with identical HTML.
    ///   - placeholder: Placeholder text shown when the editor is empty.
    ///   - editorContext: Optional context for driving formatting from native controls.
    ///   - onEditorReady: Called after each page has initialized, including recovery
    ///     after WebKit reloads or its content process terminates.
    ///     Editing and context commands remain disabled until initialization completes.
    public init(
        htmlContent: Binding<String>,
        documentID: AnyHashable? = nil,
        placeholder: String? = nil,
        editorContext: EditorContext? = nil,
        onEditorReady: (() -> Void)? = nil
    ) {
        self._htmlContent = htmlContent
        self.documentID = documentID
        self.placeholder = placeholder
        self.editorContext = editorContext
        self.onEditorReady = onEditorReady
    }

    @MainActor
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    private func configureWebView(_ webView: WKWebView, coordinator: Coordinator) {
        #if canImport(UIKit)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        #elseif canImport(AppKit)
        webView.setValue(false, forKey: "drawsBackground")
        #endif

        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        #if canImport(UIKit)
        editorContext?.bind(to: webView, contentGeneration: nil)

        if let editorContext {
            let accessoryView = FormattingAccessoryView(context: editorContext)
            coordinator.accessoryView = accessoryView
            Self.installInputAccessoryView(coordinator, on: webView)
        }
        #else
        editorContext?.bind(to: webView, contentGeneration: nil)
        #endif

        Self.loadEditor(in: webView)
    }

    private static func loadEditor(in webView: WKWebView) {
        if let resourceURL = Bundle.module.url(
            forResource: "tiptap-editor",
            withExtension: "html",
            subdirectory: "RichTextEditor"
        ) {
            let directory = resourceURL.deletingLastPathComponent()
            webView.loadFileURL(resourceURL, allowingReadAccessTo: directory)
        }
    }

    @MainActor
    private func applyContentIfNeeded(in webView: WKWebView, coordinator: Coordinator) {
        let documentChanged = coordinator.parent.documentID != documentID
        let contextChanged = coordinator.parent.editorContext !== editorContext
        if contextChanged {
            coordinator.parent.editorContext?.unbind(from: webView)
            editorContext?.bind(
                to: webView, contentGeneration: coordinator.isEditorReady ? coordinator.contentGeneration : nil
            )
            #if canImport(UIKit)
            coordinator.accessoryView = editorContext.map { FormattingAccessoryView(context: $0) }
            Self.installInputAccessoryView(coordinator, on: webView)
            #endif
        }
        coordinator.parent = self
        let theme = colorScheme == .dark ? "dark" : "light"
        if coordinator.currentTheme != theme {
            coordinator.currentTheme = theme
            webView.evaluateJavaScript("window.setTheme('\(theme)')") { _, _ in }
        }

        if coordinator.isEditorReady {
            coordinator.replaceContentIfNeeded(htmlContent, force: documentChanged || contextChanged)
        }
    }

    // MARK: - Helpers

    static func escapeForJS(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    // MARK: - Input Accessory View Installation

    #if canImport(UIKit)
    /// Replaces WKWebView's default input accessory view by dynamically subclassing WKContentView.
    /// This is the standard approach used by production rich text editors on iOS.
    @MainActor
    private static func installInputAccessoryView(_ coordinator: Coordinator, on webView: WKWebView) {
        guard let contentView = webView.scrollView.subviews.first(where: {
            let name = NSStringFromClass(type(of: $0))
            return name.hasPrefix("WKContent") || name.hasPrefix("_TipTapContent_")
        }) else { return }

        let contentViewClass: AnyClass = type(of: contentView)
        let customClassName = "_TipTapContent_\(UInt(bitPattern: ObjectIdentifier(contentView)))"

        let selector = #selector(getter: UIResponder.inputAccessoryView)
        guard let method = class_getInstanceMethod(UIResponder.self, selector) else { return }
        let typeEncoding = method_getTypeEncoding(method)
        let block: @convention(block) (AnyObject) -> UIView? = { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.accessoryView }
        }
        let customClass: AnyClass
        if let existingClass = objc_lookUpClass(customClassName) {
            customClass = existingClass
            // Class names can survive a deallocated content view whose address
            // is reused. Refresh the weak coordinator as well as the accessory.
            let imp = imp_implementationWithBlock(block)
            if let previous = class_replaceMethod(customClass, selector, imp, typeEncoding) {
                imp_removeBlock(previous)
            }
        } else {
            guard let newClass = objc_allocateClassPair(contentViewClass, customClassName, 0) else { return }
            let imp = imp_implementationWithBlock(block)
            class_addMethod(newClass, selector, imp, typeEncoding)
            objc_registerClassPair(newClass)
            customClass = newClass
        }

        object_setClass(contentView, customClass)
        contentView.reloadInputViews()
    }
    #endif

    @MainActor
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, @unchecked Sendable {
        var parent: RichTextEditorView
        var webView: WKWebView?
        #if canImport(UIKit)
        var accessoryView: FormattingAccessoryView?
        #endif
        var lastContentFromJS: String = ""
        var isEditorReady = false
        var currentTheme: String?
        private var isInitializingEditor = false
        private var acceptsEditorReadiness = false
        private var activeNavigation: WKNavigation?
        let bridgeGeneration = UUID().uuidString
        private var editorPageGeneration: String?
        private(set) var contentGeneration = UUID().uuidString
        private var pendingContent: String?

        init(_ parent: RichTextEditorView) {
            self.parent = parent
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let webView, message.webView === webView, message.frameInfo.isMainFrame else { return }
            switch message.name {
            case "contentChanged":
                // Native loads publish normalization through their completion.
                // Only edits arrive here, potentially while a load is in flight.
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
                guard acceptsEditorReadiness, !isEditorReady, !isInitializingEditor,
                      let payload = message.body as? [String: Any],
                      payload["bridgeGeneration"] as? String == bridgeGeneration,
                      let pageGeneration = payload["pageGeneration"] as? String else { return }
                initializeEditor(pageGeneration: pageGeneration)

            case "editorHeightChanged":
                break

            default:
                break
            }
        }

        func replaceContentIfNeeded(_ content: String, force: Bool) {
            // Compare with the pending native target too: A → B → A must retire
            // B even when A still equals the last delivered JavaScript value.
            guard let webView, let pageGeneration = editorPageGeneration,
                  force || content != (pendingContent ?? lastContentFromJS) else { return }
            let generation = beginContentReplacement(content, in: webView)
            let escaped = RichTextEditorView.escapeForJS(content)
            let escapedPage = RichTextEditorView.escapeForJS(pageGeneration)
            let script = """
                (() => {
                    if (!window.isEditorPageGeneration?.('\(escapedPage)')) return null
                    window.loadContent('\(escaped)', '\(generation)')
                    return window.getContent()
                })()
                """
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
                guard let self, let webView, self.webView === webView,
                      self.contentGeneration == generation else { return }
                // Loading is silent. Publish normalization only while its binding remains
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
            }
        }

        private func beginContentReplacement(_ content: String, in webView: WKWebView) -> String {
            // Retire queued edits before submitting the asynchronous replacement.
            contentGeneration = UUID().uuidString
            pendingContent = content
            if isEditorReady {
                parent.editorContext?.bind(to: webView, contentGeneration: contentGeneration)
            }
            return contentGeneration
        }

        private func initializeEditor(pageGeneration: String) {
            guard let webView else { return }
            isInitializingEditor = true
            editorPageGeneration = pageGeneration
            let theme = parent.colorScheme == .dark ? "dark" : "light"
            currentTheme = theme
            let content = parent.htmlContent
            let documentID = parent.documentID
            let editorContext = parent.editorContext
            let generation = beginContentReplacement(content, in: webView)
            let escaped = RichTextEditorView.escapeForJS(content)
            let escapedPage = RichTextEditorView.escapeForJS(pageGeneration)
            let script = """
                (() => {
                    if (!window.isEditorPageGeneration?.('\(escapedPage)')) return null
                    window.setTheme('\(theme)')
                    window.loadContent('\(escaped)', '\(generation)')
                    return window.getContent()
                })()
                """
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
                guard let self, let webView, self.webView === webView,
                      self.contentGeneration == generation else { return }
                self.isInitializingEditor = false
                self.pendingContent = nil
                guard error == nil else { return }
                guard let html = result as? String else {
                    // A retired page's readiness can arrive after navigation.
                    // Ask the current page to announce itself again if its
                    // original announcement raced this stale initialization.
                    self.editorPageGeneration = nil
                    webView.evaluateJavaScript("window.requestEditorReady?.()") { _, _ in }
                    return
                }
                // The binding may change while WebKit initializes. Never replace its
                // newer value with the normalization of the previous content.
                guard self.parent.documentID == documentID,
                      self.parent.editorContext === editorContext,
                      self.parent.htmlContent == content else {
                    self.initializeEditor(pageGeneration: pageGeneration)
                    return
                }
                self.lastContentFromJS = html
                self.parent.htmlContent = html
                guard self.webView === webView else { return }
                self.parent.editorContext?.bind(to: webView, contentGeneration: generation)
                self.isEditorReady = true
                // Native is now ready to accept edit messages. Enabling input
                // before this point could discard typing during initialization.
                webView.evaluateJavaScript("""
                    if (window.isEditorPageGeneration?.('\(escapedPage)') &&
                        window.isEditorContentGeneration?.('\(generation)')) {
                        window.setEditable(true)
                    }
                    """) { _, _ in }
                self.parent.onEditorReady?()
            }
        }

        func installBridge(in controller: WKUserContentController) {
            controller.addUserScript(WKUserScript(
                source: "window.__tipTapBridgeGeneration = '\(bridgeGeneration)';",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }

        private func retireEditorPage(in webView: WKWebView) {
            acceptsEditorReadiness = false
            activeNavigation = nil
            isEditorReady = false
            isInitializingEditor = false
            editorPageGeneration = nil
            contentGeneration = UUID().uuidString
            pendingContent = nil
            currentTheme = nil
            parent.editorContext?.bind(to: webView, contentGeneration: nil)
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard self.webView === webView else { return }
            retireEditorPage(in: webView)
            activeNavigation = navigation
        }

        private func resumeEditorPage(in webView: WKWebView, navigation: WKNavigation?) {
            guard self.webView === webView, let navigation, activeNavigation === navigation else { return }
            activeNavigation = nil
            acceptsEditorReadiness = true
            // Old JavaScript can remain executable during provisional loading.
            // Wait for navigation to finish before accepting any page's readiness,
            // then request a fresh announcement in case onCreate ran earlier.
            webView.evaluateJavaScript("window.requestEditorReady?.()") { _, _ in }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            resumeEditorPage(in: webView, navigation: navigation)
        }

        public func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            // A failed provisional navigation may leave the previous document
            // alive. Reinitialize that page from the latest native binding.
            resumeEditorPage(in: webView, navigation: navigation)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            resumeEditorPage(in: webView, navigation: navigation)
        }

        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard self.webView === webView else { return }
            // Keep the latest native binding; JavaScript history died with the
            // page. Reload the bundled editor even if the first load never committed.
            retireEditorPage(in: webView)
            RichTextEditorView.loadEditor(in: webView)
        }

        @MainActor
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .other || navigationAction.request.url?.isFileURL == true {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

#if canImport(UIKit)
extension RichTextEditorView: UIViewRepresentable {
    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        contentController.add(context.coordinator, name: "contentChanged")
        contentController.add(context.coordinator, name: "editorReady")
        contentController.add(context.coordinator, name: "editorHeightChanged")
        context.coordinator.installBridge(in: contentController)

        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        configureWebView(webView, coordinator: context.coordinator)
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        applyContentIfNeeded(in: webView, coordinator: context.coordinator)
    }

    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "contentChanged")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editorReady")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editorHeightChanged")
        coordinator.parent.editorContext?.unbind(from: webView)
        coordinator.webView = nil
        coordinator.accessoryView = nil
    }
}

#elseif canImport(AppKit)
extension RichTextEditorView: NSViewRepresentable {
    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        contentController.add(context.coordinator, name: "contentChanged")
        contentController.add(context.coordinator, name: "editorReady")
        contentController.add(context.coordinator, name: "editorHeightChanged")
        context.coordinator.installBridge(in: contentController)

        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        configureWebView(webView, coordinator: context.coordinator)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        applyContentIfNeeded(in: webView, coordinator: context.coordinator)
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "contentChanged")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editorReady")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editorHeightChanged")
        coordinator.parent.editorContext?.unbind(from: webView)
        coordinator.webView = nil
    }
}
#endif
