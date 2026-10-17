//
//  YAMLEditor.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI

/// 编辑 YAML 的窗口内容：保存期间显示进度，失败时在底部显示错误，成功后关闭窗口；不提供 save 时为只读查看
struct YAMLEditor: View {
    @Binding var text: String
    var hint: LocalizedStringKey
    var save: (() async throws -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CodeEditor(text: $text, isEditable: save != nil && !isSaving)
                .frame(minWidth: 520, minHeight: 360)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating…")
                        .foregroundStyle(.secondary)
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else {
                    Text(hint)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let save {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Save") {
                        Task { await performSave(save) }
                    }
                    .keyboardShortcut("s")
                    .disabled(isSaving)
                } else {
                    Button("Close", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding()
        }
        .onChange(of: text) {
            errorMessage = nil
        }
    }

    private func performSave(_ save: () async throws -> Void) async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 基于 NSTextView 的等宽编辑器，关闭智能引号等替换，避免破坏 YAML
private struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
