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
        case .invalidYAML(let detail): String(localized: "Invalid YAML: \(detail)")
        case .notMapping: String(localized: "The override must be a YAML mapping (key: value)")
        case .saveFailed: String(localized: "Unable to save the override file")
        }
    }
}

/// 用户自定义的覆写：配置覆写只对单个配置生效，全局覆写对所有配置生效；
/// 生成最终配置时先合并配置覆写，再合并全局覆写
nonisolated enum ConfigOverride: Codable, Hashable {
    case global
    /// 以配置名称区分
    case profile(String)

    private static var rootURL: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "ClashLite", directoryHint: .isDirectory)
    }

    /// 配置覆写所在目录，文件以配置名称命名
    private static var profileDirectoryURL: URL {
        rootURL.appending(path: "Overrides", directoryHint: .isDirectory)
    }

    /// 都放在配置目录之外，不会被当成配置
    var url: URL {
        switch self {
        case .global:
            Self.rootURL.appending(path: "Override.yaml", directoryHint: .notDirectory)
        case .profile(let name):
            Self.profileDirectoryURL.appending(path: "\(name).yaml", directoryHint: .notDirectory)
        }
    }

    var title: String {
        switch self {
        case .global: String(localized: "Global Override")
        case .profile(let name): String(localized: "Profile Override - \(name)")
        }
    }

    func load() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 检查 YAML 格式后保存，内容无效时不写入
    func save(_ text: String) throws {
        _ = try Self.parse(text)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("保存覆写失败：\(error)")
            throw ConfigOverrideError.saveFailed
        }
    }

    /// 合并到配置中
    func apply(to root: inout Node.Mapping) throws {
        Self.merge(try Self.parse(load()), into: &root)
    }

    /// 删除配置已不存在的配置覆写，避免之后同名的配置沿用未经校验的覆写
    static func removeProfileOverrides(except names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: profileDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for file in files where !names.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
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

    let target: ConfigOverride

    @Environment(CoreManager.self) private var core
    @Environment(ProfileStore.self) private var profileStore

    @State private var text: String

    init(target: ConfigOverride) {
        self.target = target
        _text = State(initialValue: target.load())
    }

    private var hint: LocalizedStringKey {
        switch target {
        case .global: "Applies to all profiles, merged after the profile override. For lists, use +key to prepend and key+ to append."
        case .profile: "Applies only to this profile, merged before the global override. For lists, use +key to prepend and key+ to append."
        }
    }

    var body: some View {
        YAMLEditor(text: $text, hint: hint, save: save)
            .navigationTitle(target.title)
    }

    /// 全局覆写只检查 YAML 格式；配置覆写由内核校验合并后的配置
    private func save() async throws {
        switch target {
        case .global:
            try ConfigOverride.global.save(text)
            core.reload()
        case .profile(let name):
            guard let profile = profileStore.profiles.first(where: { $0.name == name && !$0.isDeleted }) else {
                throw ProfileError.notFound(name)
            }
            try await profileStore.saveOverride(text, of: profile)
            if profileStore.selectedName == name {
                core.reload()
            }
        }
    }
}
