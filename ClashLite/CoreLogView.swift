//
//  CoreLogView.swift
//  ClashLite
//
//  Created by Zayrick on 11/1/26.
//

import SwiftUI

/// 实时查看内核输出，窗口打开期间持续追加新内容
struct CoreLogView: View {
    static let windowID = "core-log"

    @Environment(\.dismiss) private var dismiss
    @State private var tail = LogTail(url: CoreDirectory.logURL)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LogTextView(text: tail.text, generation: tail.generation)
                .frame(minWidth: 640, minHeight: 400)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("Cleared each time the core starts. Refreshes automatically.")
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Show in Finder") {
                    CoreDirectory.createIfNeeded()
                    if FileManager.default.fileExists(atPath: CoreDirectory.logURL.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([CoreDirectory.logURL])
                    } else {
                        NSWorkspace.shared.open(CoreDirectory.homeURL)
                    }
                }

                Button("Close", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .navigationTitle("Core Log")
        .onAppear { tail.start() }
        .onDisappear { tail.stop() }
    }
}

/// 菜单中的入口按钮；菜单栏应用默认不在前台，需要主动激活才能让窗口获得焦点
struct CoreLogButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Log…") {
            openWindow(id: CoreLogView.windowID)
            NSApplication.shared.activate()
        }
    }
}

/// 定时读取日志文件新增的内容；内核每次启动都会重建日志文件，发现文件被替换或变短时从头读取
@Observable
private final class LogTail {
    /// 只保留末尾这么多字符，避免长时间运行后占用过多内存
    private static let maxLength = 1 << 20

    private(set) var text = ""
    /// 内容被整体替换（而非追加）时递增，供视图区分追加与重建
    private(set) var generation = 0

    @ObservationIgnored private let url: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var fileNumber: UInt64?
    @ObservationIgnored private var offset: UInt64 = 0
    /// 尚未凑成完整一行的字节，避免截断多字节字符
    @ObservationIgnored private var pending = Data()

    init(url: URL) {
        self.url = url
    }

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let number = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        if number != fileNumber || size < offset {
            fileNumber = number
            offset = size > UInt64(Self.maxLength) ? size - UInt64(Self.maxLength) : 0
            pending = Data()
            if !text.isEmpty {
                text = ""
                generation += 1
            }
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }
        offset += UInt64(data.count)
        pending.append(data)

        guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let lines = String(decoding: pending[...lastNewline], as: UTF8.self)
        pending = Data(pending[pending.index(after: lastNewline)...])
        append(lines)
    }

    private func append(_ lines: String) {
        text += lines
        guard text.utf16.count > Self.maxLength else { return }
        // 超出上限时丢掉前一半，从完整的一行开始
        var start = text.index(text.endIndex, offsetBy: -Self.maxLength / 2)
        if let newline = text[start...].firstIndex(of: "\n") {
            start = text.index(after: newline)
        }
        text = String(text[start...])
        generation += 1
    }
}

/// 只读的等宽文本视图；内容只是追加时增量写入，并在原本位于底部时保持滚动到底部
private struct LogTextView: NSViewRepresentable {
    var text: String
    var generation: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        let coordinator = context.coordinator
        let length = text.utf16.count
        guard generation != coordinator.generation || length != coordinator.length else { return }

        let clipView = scrollView.contentView
        let isAtBottom = clipView.bounds.maxY >= textView.frame.maxY - 20

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textView.font as Any,
            .foregroundColor: NSColor.textColor,
        ]
        if generation == coordinator.generation, length > coordinator.length {
            let added = (text as NSString).substring(from: coordinator.length)
            textView.textStorage?.append(NSAttributedString(string: added, attributes: attributes))
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        coordinator.generation = generation
        coordinator.length = length

        if isAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var generation = 0
        var length = 0
    }
}
