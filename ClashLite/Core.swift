//
//  Core.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import AppKit
import Observation

enum CoreDirectory {
    /// ~/Library/Application Support/<Bundle ID>/Core
    /// 启用 App Sandbox 时会被重定向到 ~/Library/Containers/<Bundle ID>/Data/Library/Application Support/...
    static var url: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "ClashLite", directoryHint: .isDirectory)
            .appending(path: "Core", directoryHint: .isDirectory)
    }

    /// 内核可执行文件，固定命名为 mihomo
    static var binaryURL: URL {
        url.appending(path: "mihomo", directoryHint: .notDirectory)
    }

    @discardableResult
    static func createIfNeeded() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("创建内核目录失败：\(error)")
            return false
        }
    }

    static func open() {
        guard createIfNeeded() else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 读取内核版本，并监听内核目录变化以自动刷新
@Observable
final class CoreVersionMonitor {
    private(set) var version: String?

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init() {
        startMonitoring()
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            let version = await Self.readVersion(at: CoreDirectory.binaryURL)
            guard !Task.isCancelled else { return }
            self.version = version
        }
    }

    private func startMonitoring() {
        guard CoreDirectory.createIfNeeded() else { return }
        let fd = open(CoreDirectory.url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.refresh()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }

    /// 执行 `mihomo -v`，解析 `Mihomo Meta v1.19.30 darwin arm64 with go1.22.12 ...` 中的版本号
    @concurrent
    private nonisolated static func readVersion(at binary: URL) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = binary
        process.arguments = ["-v"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("运行内核失败：\(error)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(decoding: data, as: UTF8.self)
        let fields = output.split(whereSeparator: \.isWhitespace)
        return fields.count > 2 ? String(fields[2]) : nil
    }
}
