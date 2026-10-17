//
//  ConfigValidator.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import Foundation

/// 校验时依次检查的各层配置
nonisolated enum ConfigLayer {
    case profile
    case profileOverride
    case globalOverride

    var title: String {
        switch self {
        case .profile: String(localized: "Profile")
        case .profileOverride: String(localized: "Profile with profile override applied")
        case .globalOverride: String(localized: "Profile with global override applied")
        }
    }
}

nonisolated enum ConfigValidationError: LocalizedError {
    case failed(ConfigLayer, String?)

    var errorDescription: String? {
        switch self {
        case .failed(let layer, let message): String(localized: "Validation failed (\(layer.title)): \(message ?? String(localized: "Unknown error"))")
        }
    }
}

/// 由内核以 `-t` 完整解析配置，与实际加载时的检查一致；覆写为空的层与上一层相同，不再重复检查
enum ConfigValidator {
    /// 导入、编辑、更新配置时：检查配置本身，以及依次应用配置覆写、全局覆写后的配置
    static func validate(profile: Data, profileOverride: String) async throws {
        try await validate(profile: profile, profileOverride: profileOverride, checksProfile: true)
    }

    /// 保存配置覆写时：检查应用配置覆写后的配置，以及再应用全局覆写后的配置
    static func validate(profileOverride: String, of profile: Data) async throws {
        try await validate(profile: profile, profileOverride: profileOverride, checksProfile: false)
    }

    private static func validate(profile: Data, profileOverride: String, checksProfile: Bool) async throws {
        guard FileManager.default.isExecutableFile(atPath: CoreDirectory.binaryURL.path) else {
            throw CoreError.binaryNotFound
        }
        guard CoreDirectory.createIfNeeded() else { throw CoreError.launchFailed }
        try await check(
            profile: profile,
            profileOverride: profileOverride,
            globalOverride: ConfigOverride.global.load(),
            checksProfile: checksProfile,
            binary: CoreDirectory.binaryURL,
            home: CoreDirectory.homeURL
        )
    }

    @concurrent
    private nonisolated static func check(
        profile: Data,
        profileOverride: String,
        globalOverride: String,
        checksProfile: Bool,
        binary: URL,
        home: URL
    ) async throws {
        if checksProfile {
            try test(profile, layer: .profile, binary: binary, home: home)
        }

        var root = try CoreConfig.mapping(from: String(decoding: profile, as: UTF8.self))

        let profileOverride = try ConfigOverride.parse(profileOverride)
        if !checksProfile || !profileOverride.isEmpty {
            ConfigOverride.merge(profileOverride, into: &root)
            try test(Data(CoreConfig.serialize(root).utf8), layer: .profileOverride, binary: binary, home: home)
        }

        let globalOverride = try ConfigOverride.parse(globalOverride)
        if !globalOverride.isEmpty {
            ConfigOverride.merge(globalOverride, into: &root)
            try test(Data(CoreConfig.serialize(root).utf8), layer: .globalOverride, binary: binary, home: home)
        }
    }

    /// 与启动内核一致，经 CLASH_CONFIG_STRING 传入；使用内核工作目录以复用已下载的 Geo 数据
    private nonisolated static func test(_ data: Data, layer: ConfigLayer, binary: URL, home: URL) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["CLASH_CONFIG_STRING"] = data.base64EncodedString()

        let process = Process()
        let pipe = Pipe()
        process.executableURL = binary
        process.arguments = ["-d", home.path, "-t"]
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            NSLog("运行内核失败：\(error)")
            throw CoreError.launchFailed
        }

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConfigValidationError.failed(layer, CoreLog.lastError(in: String(decoding: output, as: UTF8.self)))
        }
    }
}
