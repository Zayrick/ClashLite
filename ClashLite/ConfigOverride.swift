//
//  ConfigOverride.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI
import Yams

enum ConfigOverrideError: LocalizedError {
    case invalidYAML(String)
    case notMapping
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidYAML(let detail): "YAML 格式错误：\(detail)"
        case .notMapping: "覆写内容必须是 YAML 映射（键: 值）"
        case .saveFailed: "无法保存覆写文件"
        }
    }
}

/// 用户自定义的配置覆写，对所有配置生效
nonisolated enum ConfigOverride {
    /// ~/Library/Application Support/<Bundle ID>/Override.yaml；放在配置目录之外，不会被当成配置
    static var url: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "ClashLite", directoryHint: .isDirectory)
            .appending(path: "Override.yaml", directoryHint: .notDirectory)
    }

    static func load() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 校验后保存，内容无效时不写入
    static func save(_ text: String) throws {
        _ = try parse(text)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("保存覆写失败：\(error)")
            throw ConfigOverrideError.saveFailed
        }
    }

    /// 空白或只有注释时返回空映射
    static func parse(_ text: String) throws -> Node.Mapping {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw ConfigOverrideError.invalidYAML(String(describing: error))
        }
        guard let node else { return [:] }
        guard case .mapping(let mapping) = node else { throw ConfigOverrideError.notMapping }
        return mapping
    }

    /// 深度合并：映射逐键递归合并，其余值直接替换；
    /// 列表可用 `+key` 插入到原列表之前、`key+` 追加到原列表之后，例如 `+rules` 让自定义规则优先匹配
    static func merge(_ override: Node.Mapping, into base: inout Node.Mapping) {
        for (keyNode, value) in override {
            guard let key = keyNode.string else {
                base[keyNode] = value
                continue
            }

            if let items = value.sequence, key.count > 1, key.hasPrefix("+") {
                let name = String(key.dropFirst())
                base[name] = .sequence(Node.Sequence(Array(items) + Array(base[name]?.sequence ?? [])))
            } else if let items = value.sequence, key.count > 1, key.hasSuffix("+") {
                let name = String(key.dropLast())
                base[name] = .sequence(Node.Sequence(Array(base[name]?.sequence ?? []) + Array(items)))
            } else if let mapping = value.mapping, var existing = base[key]?.mapping {
                merge(mapping, into: &existing)
                base[key] = .mapping(existing)
            } else {
                base[key] = value
            }
        }
    }
}

/// 编辑覆写内容，保存后立即重新加载内核配置
struct ConfigOverrideView: View {
    static let windowID = "config-override"

    @Environment(CoreManager.self) private var core
    @Environment(\.dismiss) private var dismiss

    @State private var text = ConfigOverride.load()
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CodeEditor(text: $text)
                .frame(minWidth: 520, minHeight: 360)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else {
                    Text("与当前配置深度合并；列表可用 +key 前置、key+ 追加")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("取消", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    save()
                }
                .keyboardShortcut("s")
            }
            .padding()
        }
        .onChange(of: text) {
            errorMessage = nil
        }
    }

    private func save() {
        do {
            try ConfigOverride.save(text)
            core.reload()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 基于 NSTextView 的等宽编辑器，关闭智能引号等替换，避免破坏 YAML
private struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

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

/// 菜单中的入口按钮
struct ConfigOverrideButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("配置覆写…") {
            openWindow(id: ConfigOverrideView.windowID)
            NSApplication.shared.activate()
        }
    }
}
