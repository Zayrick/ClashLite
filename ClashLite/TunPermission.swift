//
//  TunPermission.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import Foundation

enum TunPermissionError: LocalizedError {
    case cancelled
    case failed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .cancelled: "已取消授权"
        case .failed(let message): message
        case .verificationFailed: "授权后内核权限仍不正确"
        }
    }
}

/// 参考 ClashBar：创建虚拟网卡需要 root，将内核设为 root 所有并加上 setuid 位，
/// 之后内核总以 root 运行；只需授权一次，替换内核文件后需重新授权
enum TunPermission {
    static var isGranted: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: CoreDirectory.binaryURL.path) else {
            return false
        }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return owner == 0 && mode & 0o4000 != 0 && mode & 0o100 != 0
    }

    /// 弹出系统的管理员授权对话框
    static func grant() async throws {
        try await runAsAdministrator(command(for: CoreDirectory.binaryURL.path))
        guard isGranted else { throw TunPermissionError.verificationFailed }
    }

    private nonisolated static func command(for path: String) -> String {
        let quoted = "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        return "/usr/sbin/chown root:admin \(quoted) && /bin/chmod u+s \(quoted)"
    }

    @concurrent
    private nonisolated static func runAsAdministrator(_ command: String) async throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw TunPermissionError.failed(error.localizedDescription)
        }

        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }

        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // 用户点击取消时 osascript 返回 -128
        if message.contains("-128") {
            throw TunPermissionError.cancelled
        }
        throw TunPermissionError.failed(message.isEmpty ? "授权失败" : message)
    }
}
