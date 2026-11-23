//
//  EditorContext.swift
//  TipTapSwift
//
//  Observable command channel for driving TipTap formatting from native SwiftUI.
//

import SwiftUI
import WebKit
import Combine
import Foundation

/// A command channel that lets native SwiftUI controls trigger TipTap formatting.
///
/// ``RichTextEditorView`` populates the internal web view reference automatically.
/// Use the provided methods to drive the editor from native controls.
@MainActor
public final class EditorContext: ObservableObject {

    // MARK: - Internal

    /// Set by RichTextEditorView's coordinator once the WKWebView is created.
    weak var webView: WKWebView?
    private var contentGeneration: String?
    private var bindingID = UUID()
    private var saveCaptureID: UUID?

    func bind(to webView: WKWebView, contentGeneration: String?) {
        if let saveCaptureID { releaseSaveCapture(saveCaptureID) }
        bindingID = UUID()
        self.webView = webView
        self.contentGeneration = contentGeneration
    }

    func unbind(from webView: WKWebView) {
        guard self.webView === webView else { return }
        if let saveCaptureID { releaseSaveCapture(saveCaptureID) }
        bindingID = UUID()
        self.webView = nil
        contentGeneration = nil
    }

    // MARK: - Alert State (observed by RichTextEditorSheet)

    /// Set to `true` to present a link URL input alert.
    @Published public var isLinkAlertPresented = false

    /// Set to `true` to present an image URL input alert.
    @Published public var isImageAlertPresented = false

    public init() {}

    // MARK: - History

    public func undo() {
        run("window.undo()")
    }

    public func redo() {
        run("window.redo()")
    }

    /// Replaces the current document as a single undoable edit.
    /// Use the view's HTML binding to load a new baseline instead.
    public func replaceContent(with html: String) {
        let escaped = RichTextEditorView.escapeForJS(html)
        run("window.setContent('\(escaped)')")
    }

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
        let escaped = RichTextEditorView.escapeForJS(url)
        run("window.setLink('\(escaped)')")
    }

    public func removeLink() {
        run("window.setLink(null)")
    }

    // MARK: - Text Alignment

    public func setTextAlign(_ alignment: String) {
        let escaped = RichTextEditorView.escapeForJS(alignment)
        run("window.setTextAlign('\(escaped)')")
    }

    // MARK: - Images

    public func insertImage(url: String, alt: String = "") {
        let escapedURL = RichTextEditorView.escapeForJS(url)
        let escapedAlt = RichTextEditorView.escapeForJS(alt)
        run("window.setImage('\(escapedURL)', '\(escapedAlt)')")
    }

    /// Suspends input and reads the web document at the same JavaScript boundary.
    func captureHTMLForSave(_ requestID: UUID, completion: @escaping @MainActor (String?) -> Void) {
        guard saveCaptureID == nil, let webView, let generation = contentGeneration else {
            completion(nil)
            return
        }
        saveCaptureID = requestID
        let bindingID = bindingID
        webView.evaluateJavaScript("""
            (() => {
                if (!window.isEditorContentGeneration?.('\(generation)')) return null
                window.__tipTapSaveCaptureID = '\(requestID.uuidString)'
                window.setEditable(false)
                return window.getContent()
            })()
            """) { [weak self, weak webView] result, error in
            guard let self, let webView, self.webView === webView,
                  self.contentGeneration == generation, self.bindingID == bindingID,
                  self.saveCaptureID == requestID, error == nil else {
                completion(nil)
                return
            }
            completion(result as? String)
        }
    }

    func ownsSaveCapture(_ requestID: UUID) -> Bool {
        saveCaptureID == requestID && webView != nil
    }

    func releaseSaveCapture(_ requestID: UUID) {
        guard saveCaptureID == requestID else { return }
        saveCaptureID = nil
        guard let webView, let generation = contentGeneration else { return }
        webView.evaluateJavaScript("""
            if (window.__tipTapSaveCaptureID === '\(requestID.uuidString)') {
                delete window.__tipTapSaveCaptureID
                if (window.isEditorContentGeneration?.('\(generation)')) window.setEditable(true)
            }
            """) { _, _ in }
    }

    // MARK: - Private

    private func run(_ js: String) {
        guard saveCaptureID == nil, let webView, let contentGeneration else { return }
        // A command queued by the previous context cannot format replacement
        // content if WebKit executes it after that content has been installed.
        webView.evaluateJavaScript("""
            if (!window.__tipTapSaveCaptureID && window.isEditorContentGeneration?.('\(contentGeneration)')) { \(js); }
            """) { _, _ in }
    }
}
