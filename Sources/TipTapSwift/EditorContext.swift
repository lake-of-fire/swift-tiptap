//
//  EditorContext.swift
//  TipTapSwift
//
//  Observable command channel for driving TipTap formatting from native SwiftUI.
//

import SwiftUI
import WebKit
import Combine

/// A command channel that lets native SwiftUI controls trigger TipTap formatting.
///
/// ``RichTextEditorView`` populates the internal web view reference automatically.
/// Use the provided methods to drive the editor from native controls.
@MainActor
public final class EditorContext: ObservableObject {

    // MARK: - Internal

    /// Set by RichTextEditorView's coordinator once the WKWebView is created.
    weak var webView: WKWebView?
    @Published public private(set) var isReady = false
    @Published public private(set) var isFocused = false
    @Published public private(set) var activeFormats = Set<String>()

    func attach(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView
        resetReadiness()
    }

    func detach(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        self.webView = nil
        resetReadiness()
    }

    func resetReadiness() {
        if isReady { isReady = false }
        if isFocused { isFocused = false }
        if !activeFormats.isEmpty { activeFormats = [] }
    }

    func markReady(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        isReady = true
    }

    func updateState(_ state: [String: Any], from webView: WKWebView) {
        guard self.webView === webView, isReady else { return }
        let focused = state["focused"] as? Bool ?? false
        let formats = Set(state["active"] as? [String] ?? [])
        if focused != isFocused { isFocused = focused }
        if formats != activeFormats { activeFormats = formats }
    }

    public func presentLinkEditor() {
        guard isReady else { return }
        isLinkAlertPresented = true
    }

    public func presentImageEditor() {
        guard isReady else { return }
        isImageAlertPresented = true
    }

#if canImport(UIKit)
    public func dismissKeyboard() {
        webView?.endEditing(true)
    }
#endif

    // MARK: - Alert State (presented by the reusable editor)

    /// Set to `true` to present a link URL input alert.
    @Published public var isLinkAlertPresented = false

    /// Set to `true` to present an image URL input alert.
    @Published public var isImageAlertPresented = false

    public init() {}

    // MARK: - Inline Formatting

    public func toggleBold() {
        run("window.toggleBold()")
    }

    public func toggleItalic() {
        run("window.toggleItalic()")
    }

    public func toggleStrike() {
        run("window.toggleStrike()")
    }

    public func toggleUnderline() {
        run("window.toggleUnderline()")
    }

    // MARK: - Block Formatting

    public func toggleHeading(level: Int) {
        run("window.toggleHeading(\(level))")
    }

    public func toggleBulletList() {
        run("window.toggleBulletList()")
    }

    public func toggleOrderedList() {
        run("window.toggleOrderedList()")
    }

    public func toggleBlockquote() {
        run("window.toggleBlockquote()")
    }

    public func toggleCodeBlock() {
        run("window.toggleCodeBlock()")
    }

    public func setHorizontalRule() {
        run("window.setHorizontalRule()")
    }

    // MARK: - Links

    public func setLink(url: String) {
        run("window.setLink(\(Self.literal(url)))")
    }

    public func removeLink() {
        run("window.setLink(null)")
    }

    // MARK: - Text Alignment

    public func setTextAlign(_ alignment: String) {
        run("window.setTextAlign(\(Self.literal(alignment)))")
    }

    // MARK: - Images

    public func insertImage(url: String, alt: String = "") {
        run("window.setImage(\(Self.literal(url)), \(Self.literal(alt)))")
    }

    // MARK: - Private

    private static func literal(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private func run(_ js: String) {
        // Never execute commands against an uninitialized or replaced editor.
        guard isReady else { return }
        webView?.evaluateJavaScript(js) { _, _ in }
    }
}
