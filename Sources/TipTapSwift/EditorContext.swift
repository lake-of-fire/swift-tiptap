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
    private var contentGeneration: String?

    func bind(to webView: WKWebView, contentGeneration: String?) {
        if (self.webView !== webView || self.contentGeneration != contentGeneration), localWritingSnapshotJSON != nil {
            localWritingSnapshotJSON = nil
        }
        self.webView = webView
        self.contentGeneration = contentGeneration
    }

    func unbind(from webView: WKWebView) {
        guard self.webView === webView else { return }
        self.webView = nil
        contentGeneration = nil
        if localWritingSnapshotJSON != nil { localWritingSnapshotJSON = nil }
    }

    /// Versioned coherent editor messages from the opt-in local-writing profile.
    /// This is transient transport, not an HTML binding or persistence receipt.
    @Published public private(set) var localWritingSnapshotJSON: String?

    func receiveLocalWritingSnapshot(_ json: String, from webView: WKWebView) {
        guard self.webView === webView, contentGeneration != nil,
              json.utf8.count <= 262_144 else { return }
        localWritingSnapshotJSON = json
    }

    /// Sends a versioned local-writing bridge request without interpolating user
    /// text into JavaScript. A replaced native binding retires an in-flight reply.
    /// Flow's typed codec validates the response and its source-bound coordinator
    /// validates transaction acknowledgments before adopting them.
    public func localWritingRequest(_ request: Data) async throws -> Data {
        guard request.count <= 262_144, let json = String(data: request, encoding: .utf8) else {
            throw NSError(domain: "TipTapSwift.LocalWriting", code: 1)
        }
        guard let webView, let generation = contentGeneration else {
            throw NSError(domain: "TipTapSwift.LocalWriting", code: 2)
        }
        return try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                """
                if (!window.isEditorContentGeneration?.(generation) || !window.localWritingRequest) return null
                return JSON.stringify(window.localWritingRequest(JSON.parse(requestJSON)))
                """,
                arguments: ["generation": generation, "requestJSON": json],
                in: nil,
                in: .page,
                completionHandler: { [weak self, weak webView] result in
                    MainActor.assumeIsolated {
                        guard let self, let webView, self.webView === webView,
                              self.contentGeneration == generation else {
                            continuation.resume(throwing: NSError(domain: "TipTapSwift.LocalWriting", code: 2))
                            return
                        }
                        switch result {
                        case .failure(let error): continuation.resume(throwing: error)
                        case .success(let value):
                            guard let json = value as? String, let data = json.data(using: .utf8), data.count <= 262_144 else {
                                continuation.resume(throwing: NSError(domain: "TipTapSwift.LocalWriting", code: 3))
                                return
                            }
                            continuation.resume(returning: data)
                        }
                    }
                }
            )
        }
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

    // MARK: - Private

    private func run(_ js: String) {
        guard let webView, let contentGeneration else { return }
        // A command queued by the previous context cannot format replacement
        // content if WebKit executes it after that content has been installed.
        webView.evaluateJavaScript("if (window.isEditorContentGeneration?.('\(contentGeneration)')) { \(js); }") { _, _ in }
    }
}
