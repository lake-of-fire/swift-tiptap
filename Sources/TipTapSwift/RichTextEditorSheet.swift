//
//  RichTextEditorSheet.swift
//  TipTapSwift
//
//  A ready-to-use sheet for editing HTML content with the TipTap editor.
//  Formatting toolbar appears as a native input accessory view above the keyboard.
//

import SwiftUI
import Combine
import NavigationBackport

/// A sheet that wraps ``RichTextEditorView`` with Cancel / Done toolbar buttons.
///
/// A native formatting toolbar appears above the keyboard automatically via
/// the ``EditorContext`` input accessory view.
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
    @State private var draftTitle: String
    @State private var isEditorReady = false
    @State private var isPresentingDiscardConfirmation = false
    @StateObject private var editorContext = EditorContext()
    @State private var linkURL = ""
    @State private var imageURL = ""

    private let originalTitle: String
    private let navigationTitleBinding: Binding<String>?
    private let placeholder: String?
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
        onCancel: (() -> Void)? = nil,
        onSave: ((String, String) -> Void)? = nil
    ) {
        self._htmlContent = htmlContent
        self._draftStore = StateObject(wrappedValue: RichTextEditorSheetDraftStore(htmlContent: htmlContent.wrappedValue))
        self._draftTitle = State(initialValue: title)
        self.originalTitle = title
        self.navigationTitleBinding = nil
        self.placeholder = placeholder
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
        onCancel: (() -> Void)? = nil,
        onSave: ((String, String) -> Void)? = nil
    ) {
        self._htmlContent = htmlContent
        self._draftStore = StateObject(wrappedValue: RichTextEditorSheetDraftStore(htmlContent: htmlContent.wrappedValue))
        self._draftTitle = State(initialValue: title.wrappedValue)
        self.originalTitle = title.wrappedValue
        self.navigationTitleBinding = title
        self.placeholder = placeholder
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var hasEdits: Bool {
        draftStore.hasEdits || draftTitle != originalTitle
    }

    public var body: some View {
        applyNavigationTitle(
            editorNavigationContainer {
                editorContent
            }
        )
    }

    @ViewBuilder
    private var editorContent: some View {
        ZStack {
            RichTextEditorView(
                htmlContent: Binding(
                    get: { draftStore.draftHTMLContent },
                    set: { draftStore.draftHTMLContent = $0 }
                ),
                placeholder: placeholder,
                editorContext: editorContext,
                onEditorReady: {
                    withAnimation(.easeIn(duration: 0.2)) {
                        isEditorReady = true
                    }
                }
            )
            .opacity(isEditorReady ? 1 : 0)

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
            }
            ToolbarItem(placement: .confirmationAction) {
                doneButton
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
        .alert("Add Link", isPresented: $editorContext.isLinkAlertPresented) {
            TextField("URL, email, or phone number", text: $linkURL)
#if canImport(UIKit)
                .textInputAutocapitalization(.never)
#endif
            Button("Add") {
                if !linkURL.isEmpty {
                    editorContext.setLink(url: linkURL.autoDetectedLink)
                }
                linkURL = ""
            }
            Button("Remove Link", role: .destructive) {
                editorContext.removeLink()
                linkURL = ""
            }
            Button("Cancel", role: .cancel) {
                linkURL = ""
            }
        } message: {
            Text("Auto-detects links, emails, and phone numbers")
        }
        .alert("Add Image", isPresented: $editorContext.isImageAlertPresented) {
            TextField("https://example.com/image.jpg", text: $imageURL)
#if canImport(UIKit)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
#endif
            Button("Insert") {
                if !imageURL.isEmpty {
                    editorContext.insertImage(url: imageURL)
                }
                imageURL = ""
            }
            Button("Cancel", role: .cancel) {
                imageURL = ""
            }
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
        let committedHTML = draftStore.commit()
        htmlContent = committedHTML
        if let navigationTitleBinding {
            navigationTitleBinding.wrappedValue = draftTitle
        }
        onSave?(draftTitle, committedHTML)
        dismiss()
    }

    @ViewBuilder
    private func editorNavigationContainer<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NBNavigationStack {
                content()
            }
        }
    }

    @ViewBuilder
    private func applyNavigationTitle<Content: View>(_ content: Content) -> some View {
        if navigationTitleBinding != nil {
            if #available(iOS 16.0, macOS 13.0, *) {
                content.navigationTitle(
                    Binding(
                        get: { draftTitle },
                        set: { draftTitle = $0 }
                    )
                )
            } else {
                content.navigationTitle(draftTitle)
            }
        } else {
            content.navigationTitle(draftTitle)
        }
    }
}

@MainActor
final class RichTextEditorSheetDraftStore: ObservableObject {
    let originalHTMLContent: String
    @Published var draftHTMLContent: String

    init(htmlContent: String) {
        self.originalHTMLContent = htmlContent
        self.draftHTMLContent = htmlContent
    }

    var hasEdits: Bool {
        draftHTMLContent != originalHTMLContent
    }

    func commit() -> String {
        draftHTMLContent
    }

    func cancel() {
        draftHTMLContent = originalHTMLContent
    }
}
