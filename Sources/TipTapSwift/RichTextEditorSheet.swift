//
//  RichTextEditorSheet.swift
//  TipTapSwift
//
//  A ready-to-use sheet for editing HTML content with the TipTap editor.
//  Formatting toolbar appears as a native input accessory view above the keyboard.
//

import SwiftUI

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

    @State private var isEditorReady = false
    @StateObject private var editorContext = EditorContext()
    @State private var linkURL = ""
    @State private var imageURL = ""

    private let title: String
    private let placeholder: String

    /// Creates a rich text editor sheet.
    /// - Parameters:
    ///   - htmlContent: Binding to the HTML string to edit.
    ///   - title: Navigation bar title.
    ///   - placeholder: Placeholder shown when editor is empty.
    public init(
        htmlContent: Binding<String>,
        title: String = "Description",
        placeholder: String = "Start typing..."
    ) {
        self._htmlContent = htmlContent
        self.title = title
        self.placeholder = placeholder
    }

    public var body: some View {
        NavigationView {
            ZStack {
                RichTextEditorView(
                    htmlContent: $htmlContent,
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
                    ProgressView("Loading editor...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
#if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        dismiss()
                    }
                }
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
#if canImport(UIKit)
        .navigationViewStyle(.stack)
#endif
    }
}
