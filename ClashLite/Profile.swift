//
//  Profile.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import AppKit
import Observation

enum ProfileDirectory {
    /// ~/Library/Application Support/<Bundle ID>/Profiles
    static var url: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "ClashLite", directoryHint: .isDirectory)
            .appending(path: "Profiles", directoryHint: .isDirectory)
    }

    /// 订阅列表索引
    static var indexURL: URL {
        url.appending(path: "profiles.json", directoryHint: .notDirectory)
    }

    @discardableResult
    static func createIfNeeded() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("创建配置目录失败：\(error)")
            return false
        }
    }

    /// 打开配置目录；传入的文件存在时在 Finder 中选中它
    /// 配置文件以名称命名，便于在 Finder 中辨认
    static func fileURL(forName name: String) -> URL {
        url.appending(path: "\(name).yaml", directoryHint: .notDirectory)
    }

    static func open(selecting file: URL? = nil) {
        guard createIfNeeded() else { return }
        if let file, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

struct Profile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// 订阅链接；本地导入的配置为 nil
    var url: URL?
    var updatedAt: Date

    var fileURL: URL {
        ProfileDirectory.fileURL(forName: name)
    }
}

enum ProfileError: LocalizedError {
    case badStatus(Int)
    case invalidContent
    case invalidName
    case duplicateName(String)
    case readFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "订阅请求失败（HTTP \(code)）"
        case .invalidContent: "内容不是有效的 Clash 配置"
        case .invalidName: "名称不能为空，不能以“.”开头，也不能包含“/”或“:”"
        case .duplicateName(let name): "已存在名为“\(name)”的配置"
        case .readFailed: "无法读取所选文件"
        case .saveFailed: "无法保存配置文件"
        }
    }
}

/// 管理配置：持久化列表、当前选中项，以及下载订阅、导入本地文件
@Observable
final class ProfileStore {
    private(set) var profiles: [Profile] = []

    var selectedID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedID?.uuidString, forKey: Self.selectedKey)
        }
    }

    var selected: Profile? {
        profiles.first { $0.id == selectedID }
    }

    @ObservationIgnored private static let selectedKey = "selectedProfileID"

    init() {
        load()
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        if selected == nil {
            selectedID = profiles.first?.id
        }
    }

    /// 下载订阅并保存为新配置
    func addSubscription(url: URL, name: String) async throws {
        try checkName(name)
        let data = try await Self.download(url)
        try add(Profile(id: UUID(), name: name, url: url, updatedAt: .now), data: data)
    }

    /// 复制本地配置文件到配置目录，原文件不受影响
    func importLocal(fileURL: URL, name: String) throws {
        try checkName(name)

        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            NSLog("读取本地配置失败：\(error)")
            throw ProfileError.readFailed
        }
        try Self.validate(data)

        try add(Profile(id: UUID(), name: name, url: nil, updatedAt: .now), data: data)
    }

    /// 名称即文件名：需合法且不与已有配置或目录中的文件重复（APFS 默认不区分大小写）
    private func checkName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            throw ProfileError.invalidName
        }
        let exists = profiles.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            || FileManager.default.fileExists(atPath: ProfileDirectory.fileURL(forName: name).path)
        if exists {
            throw ProfileError.duplicateName(name)
        }
    }

    /// 写入配置文件并加入列表，首个配置会自动选中
    private func add(_ profile: Profile, data: Data) throws {
        // 下载期间可能已添加同名配置，写入前再确认一次
        try checkName(profile.name)
        guard ProfileDirectory.createIfNeeded() else { throw ProfileError.saveFailed }
        do {
            try data.write(to: profile.fileURL, options: .atomic)
        } catch {
            NSLog("写入配置失败：\(error)")
            throw ProfileError.saveFailed
        }

        profiles.append(profile)
        save()
        if selectedID == nil {
            selectedID = profile.id
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: ProfileDirectory.indexURL) else { return }
        do {
            profiles = try JSONDecoder().decode([Profile].self, from: data)
        } catch {
            NSLog("读取订阅列表失败：\(error)")
        }
    }

    private func save() {
        guard ProfileDirectory.createIfNeeded() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: ProfileDirectory.indexURL, options: .atomic)
        } catch {
            NSLog("保存订阅列表失败：\(error)")
        }
    }

    /// 以 clash.meta 的 UA 请求，使订阅服务返回 Clash 格式的 YAML
    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("clash.meta", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProfileError.badStatus(http.statusCode)
        }

        try validate(data)
        return data
    }

    /// 粗略校验：Clash 配置至少包含节点或节点提供者
    private static func validate(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("proxies:") || text.contains("proxy-providers:") else {
            throw ProfileError.invalidContent
        }
    }
}
