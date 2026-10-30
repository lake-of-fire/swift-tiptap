//
//  RichTextEditorSheet.swift
//  TipTapSwift
//
//  A ready-to-use sheet for editing HTML content with the TipTap editor.
//  The reusable editor owns native formatting and keyboard layout.
//

import SwiftUI
import Combine

/// A sheet that wraps ``RichTextEditorView`` with Cancel / Done toolbar buttons.
///
/// The reusable editor provides native formatting controls on iOS and macOS.
///
/// Works on a local copy of the content and only commits changes on "Done".
///
/// ```swift
/// .sheet(isPresented: $showEditor) {
///     RichTextEditorSheet(htmlContent: $description)
/// }
/// ```
public struct RichTextEditorSheet: View {
    @Binding var htmlContent: String
    @Environment(\.dismiss) private var dismiss

    @StateObject private var draftStore: RichTextEditorSheetDraftStore
    @State private var isEditorReady = false
    @State private var isPresentingDiscardConfirmation = false
    @StateObject private var editorContext = EditorContext()

    private let navigationTitleBinding: Binding<String>?
    private let placeholder: String?
    private let normalizeOnSave: (String) -> String
    private let onCancel: (() -> Void)?
    private let onSave: ((String, String) -> Void)?

    /// Creates a rich text editor sheet.
    /// - Parameters:
    ///   - htmlContent: Binding to the HTML string to edit.
    ///   - title: Navigation bar title.
    ///   - placeholder: Placeholder shown when editor is empty.
    public init(
        htmlContent: Binding<String>,
        title: String = "Description",
        placeholder: String? = nil,
        normalizeOnSave: @escaping (String) -> String = { $0 },
        onCancel: (() -> Void)? = nil,
        onSave: ((String, String) -> Void)? = nil
    ) {
        self._htmlContent = htmlContent
        self._draftStore = StateObject(wrappedValue: RichTextEditorSheetDraftStore(
            htmlContent: htmlContent.wrappedValue, title: title
        ))
        self.navigationTitleBinding = nil
        self.placeholder = placeholder
        self.normalizeOnSave = normalizeOnSave
        self.onCancel = onCancel
        self.onSave = onSave
    }

    /// Creates a rich text editor sheet with a bound navigation title.
    /// - Parameters:
    ///   - htmlContent: Binding to the HTML string to edit.
    ///   - title: Binding to the navigation bar title text.
    ///   - placeholder: Placeholder shown when editor is empty.
    public init(
        htmlContent: Binding<String>,
        title: Binding<String>,
        placeholder: String? = nil,
        normalizeOnSave: @escaping (String) -> String = { $0 },
        onCancel: (() -> Void)? = nil,
        onSave: ((String, String) -> Void)? = nil
    ) {
        self._htmlContent = htmlContent
        self._draftStore = StateObject(wrappedValue: RichTextEditorSheetDraftStore(
            htmlContent: htmlContent.wrappedValue, title: title.wrappedValue
        ))
        self.navigationTitleBinding = title
        self.placeholder = placeholder
        self.normalizeOnSave = normalizeOnSave
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var hasEdits: Bool {
        draftStore.hasEdits
    }

    public var body: some View {
        editorNavigationContainer {
            applyNavigationTitle(editorContent)
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        ZStack {
            RichTextEditorView(
                htmlContent: Binding(
                    get: { draftStore.draftHTMLContent },
                    set: { draftStore.syncFromEditor($0) }
                ),
                placeholder: placeholder,
                editorContext: editorContext,
                onEditorReady: {
                    draftStore.beginTrackingEdits()
                    withAnimation(.easeIn(duration: 0.2)) {
                        isEditorReady = true
                    }
                }
            )
            .opacity(isEditorReady ? 1 : 0)
            .allowsHitTesting(isEditorReady)

            if !isEditorReady {
                ProgressView()
                    .tint(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
#if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .interactiveDismissDisabled(hasEdits)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                cancelButton
                    .accessibilityIdentifier("RichTextEditor.Cancel")
            }
            ToolbarItem(placement: .principal) {
                if navigationTitleBinding != nil {
                    if #available(iOS 16.0, macOS 13.0, *) {
                        HStack(spacing: 6) {
                            Text(draftStore.draftTitle)
                                .font(.headline)
                                .lineLimit(1)
                            RenameButton()
                                .accessibilityIdentifier("RichTextEditor.Rename")
                        }
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                doneButton
                    .accessibilityIdentifier("RichTextEditor.Save")
            }
        }
        .confirmationDialog("Discard Changes?", isPresented: $isPresentingDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                performCancel()
            }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("Your changes haven’t been saved.")
        }

    }

    @ViewBuilder
    private var cancelButton: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(role: .cancel) {
                handleCancel()
            }
            .tint(.primary)
        } else {
            Button("Cancel") {
                handleCancel()
            }
        }
    }

    @ViewBuilder
    private var doneButton: some View {
        if hasEdits {
            if #available(iOS 26.0, macOS 26.0, *) {
                Button(role: .confirm) {
                    performSave()
                }
            } else {
                Button("Done") {
                    performSave()
                }
            }
        }
    }

    private func handleCancel() {
        if hasEdits {
            isPresentingDiscardConfirmation = true
        } else {
            performCancel()
        }
    }

    private func performCancel() {
        draftStore.cancel()
        onCancel?()
        dismiss()
    }

    private func performSave() {
        let savedDraft = draftStore.snapshotForSave(normalizingWith: normalizeOnSave)
        htmlContent = savedDraft.html
        if let navigationTitleBinding {
            navigationTitleBinding.wrappedValue = savedDraft.title
        }
        onSave?(savedDraft.title, savedDraft.html)
        dismiss()
    }

    @ViewBuilder
    private func editorNavigationContainer<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
        }
    }

    @ViewBuilder
    private func applyNavigationTitle<Content: View>(_ content: Content) -> some View {
        if navigationTitleBinding != nil {
            if #available(iOS 16.0, macOS 13.0, *) {
                content
                    .navigationTitle(
                        Binding(
                            get: { draftStore.draftTitle },
                            set: { draftStore.draftTitle = $0 }
                        )
                    )
            } else {
                content.navigationTitle(draftStore.draftTitle)
            }
        } else {
            content.navigationTitle(draftStore.draftTitle)
        }
    }
}

@MainActor
final class RichTextEditorSheetDraftStore: ObservableObject {
    struct SavedDraft: Equatable {
        let title: String
        let html: String
    }

    private(set) var originalHTMLContent: String
    private let originalTitle: String
    @Published var draftHTMLContent: String
    @Published var draftTitle: String
    private var isTrackingEdits = false
    private var editorBaselineHTMLContent: String?

    init(htmlContent: String, title: String = "") {
        self.originalHTMLContent = htmlContent
        self.originalTitle = title
        self.draftHTMLContent = htmlContent
        self.draftTitle = title
    }

    var hasEdits: Bool {
        draftTitle != originalTitle || hasBodyEdits
    }

    private var hasBodyEdits: Bool {
        guard isTrackingEdits else { return false }
        return draftHTMLContent != (editorBaselineHTMLContent ?? originalHTMLContent)
    }

    func syncFromEditor(_ htmlContent: String) {
        if !isTrackingEdits {
            editorBaselineHTMLContent = htmlContent
        }
        draftHTMLContent = htmlContent
    }

    func beginTrackingEdits() {
        guard !isTrackingEdits else { return }
        editorBaselineHTMLContent = draftHTMLContent
        isTrackingEdits = true
    }

    func commit(normalizingWith normalize: (String) -> String = { $0 }) -> String {
        normalize(hasBodyEdits ? draftHTMLContent : originalHTMLContent)
    }

    func snapshotForSave(normalizingWith normalize: (String) -> String = { $0 }) -> SavedDraft {
        SavedDraft(title: draftTitle, html: commit(normalizingWith: normalize))
    }

    func cancel() {
        draftTitle = originalTitle
        draftHTMLContent = originalHTMLContent
        editorBaselineHTMLContent = originalHTMLContent
    }
}
