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
    var placeholder: String?
    var editorContext: EditorContext?
    var onEditorReady: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    /// Creates a rich text editor.
    /// - Parameters:
    ///   - htmlContent: Bidirectional binding to the HTML content string.
    ///   - placeholder: Placeholder text shown when the editor is empty.
    ///   - editorContext: Optional context for driving formatting from native controls.
    ///   - onEditorReady: Called once the TipTap editor has fully initialized.
    public init(
        htmlContent: Binding<String>,
        placeholder: String? = nil,
        editorContext: EditorContext? = nil,
        onEditorReady: (() -> Void)? = nil
    ) {
        self._htmlContent = htmlContent
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
        let contextChanged = coordinator.parent.editorContext !== editorContext
        if contextChanged {
            coordinator.parent.editorContext?.unbind(from: webView)
            editorContext?.bind(to: webView, contentGeneration: coordinator.contentGeneration)
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
            coordinator.replaceContentIfNeeded(htmlContent, force: contextChanged)
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
        let bridgeGeneration = UUID().uuidString
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
            let escaped = RichTextEditorView.escapeForJS(content)
            webView.evaluateJavaScript("window.setContent('\(escaped)', '\(generation)'); window.getContent()") { [weak self, weak webView] result, error in
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
            }
        }

        private func beginContentReplacement(_ content: String, in webView: WKWebView) -> String {
            // Retire queued edits before submitting the asynchronous replacement.
            contentGeneration = UUID().uuidString
            pendingContent = content
            parent.editorContext?.bind(to: webView, contentGeneration: contentGeneration)
            return contentGeneration
        }

        private func initializeEditor() {
            guard let webView else { return }
            isInitializingEditor = true
            let theme = parent.colorScheme == .dark ? "dark" : "light"
            currentTheme = theme
            let content = parent.htmlContent
            let generation = beginContentReplacement(content, in: webView)
            let escaped = RichTextEditorView.escapeForJS(content)
            webView.evaluateJavaScript("window.setTheme('\(theme)'); window.setContent('\(escaped)', '\(generation)'); window.getContent()") { [weak self, weak webView] result, error in
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
