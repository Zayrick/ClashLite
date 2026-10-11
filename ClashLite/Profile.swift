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

    /// 配置的附加信息（订阅链接等），以配置名称为键；配置列表本身以目录中的文件为准
    static var metadataURL: URL {
        url.appending(path: "profiles.json", directoryHint: .notDirectory)
    }

    static let fileExtensions: Set<String> = ["yaml", "yml"]

    /// 新配置以名称命名，便于在 Finder 中辨认
    static func fileURL(forName name: String) -> URL {
        url.appending(path: "\(name).yaml", directoryHint: .notDirectory)
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
    static func open(selecting file: URL? = nil) {
        guard createIfNeeded() else { return }
        if let file, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

struct Profile: Identifiable, Hashable {
    var name: String
    var fileURL: URL
    /// 订阅信息；本地配置为 nil
    var subscription: Subscription?
    /// 当前选中的配置文件已被删除时为 true，仅在切换前保留在列表中
    var isDeleted = false

    var id: String { name }

    var displayName: String {
        isDeleted ? "\(name)（已删除）" : name
    }
}

struct Subscription: Codable, Hashable {
    var url: URL
    var updatedAt: Date
    /// 自动更新间隔（小时）；nil 表示不自动更新
    var interval: Int?

    var nextUpdate: Date? {
        interval.map { updatedAt.addingTimeInterval(TimeInterval($0) * 3600) }
    }
}

enum ProfileError: LocalizedError {
    case badStatus(Int)
    case invalidName
    case duplicateName(String)
    case notFound(String)
    case readFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "订阅请求失败（HTTP \(code)）"
        case .invalidName: "名称不能为空，不能以“.”开头，也不能包含“/”或“:”"
        case .duplicateName(let name): "已存在名为“\(name)”的配置"
        case .notFound(let name): "配置“\(name)”已不存在"
        case .readFailed: "无法读取所选文件"
        case .saveFailed: "无法保存配置文件"
        }
    }
}

/// 管理配置：以配置目录中的文件为准生成列表，监听目录变化自动刷新
@Observable
final class ProfileStore {
    private(set) var profiles: [Profile] = []

    var selectedName: String? {
        didSet {
            guard selectedName != oldValue else { return }
            UserDefaults.standard.set(selectedName, forKey: Self.selectedKey)
            // 切换后不再保留已删除的旧配置
            reload()
        }
    }

    var selected: Profile? {
        profiles.first { $0.name == selectedName }
    }

    /// 正在更新的订阅配置名称
    private(set) var updatingNames: Set<String> = []

    @ObservationIgnored private var subscriptions: [String: Subscription] = [:]
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var autoUpdateTask: Task<Void, Never>?
    @ObservationIgnored private static let autoUpdateCheckInterval = Duration.seconds(600)
    /// 订阅未提供 profile-update-interval 时的默认自动更新间隔（小时）
    @ObservationIgnored private static let defaultInterval = 24

    /// 订阅配置更新完成后调用，参数为配置名称
    @ObservationIgnored var onUpdate: ((String) -> Void)?
    @ObservationIgnored private static let selectedKey = "selectedProfileName"

    init() {
        loadSubscriptions()
        reload()

        // 启动时选中的文件已不存在，则保持未选中状态
        let stored = UserDefaults.standard.string(forKey: Self.selectedKey)
        selectedName = profiles.contains { $0.name == stored } ? stored : nil

        startMonitoring()
        startAutoUpdate()
    }

    /// 下载订阅并保存为新配置
    func addSubscription(url: URL, name: String) async throws {
        try checkName(name)
        let (data, interval) = try await Self.download(url)
        let subscription = Subscription(url: url, updatedAt: .now, interval: interval ?? Self.defaultInterval)
        try await add(name: name, data: data, subscription: subscription)
    }

    /// 复制本地配置文件到配置目录，原文件不受影响
    func importLocal(fileURL: URL, name: String) async throws {
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
        try await add(name: name, data: data, subscription: nil)
    }

    /// 重新下载订阅并覆盖配置文件，配置覆写保留
    func update(_ profile: Profile) async throws {
        guard let subscription = profile.subscription, !updatingNames.contains(profile.name) else { return }
        updatingNames.insert(profile.name)
        defer { updatingNames.remove(profile.name) }

        let (data, _) = try await Self.download(subscription.url)
        try await ConfigValidator.validate(profile: data, profileOverride: ConfigOverride.profile(profile.name).load())
        try write(data, to: profile)

        // 下载期间可能修改了自动更新间隔，以最新的为准
        subscriptions[profile.name]?.updatedAt = .now
        saveSubscriptions()
        reload()
        onUpdate?(profile.name)
    }

    /// 设置订阅的自动更新间隔（小时），nil 表示关闭
    func setInterval(_ interval: Int?, of profile: Profile) {
        guard subscriptions[profile.name] != nil else { return }
        subscriptions[profile.name]?.interval = interval
        saveSubscriptions()
        reload()
    }

    /// 校验后保存编辑过的配置内容
    func saveContent(_ text: String, of profile: Profile) async throws {
        let data = Data(text.utf8)
        try await ConfigValidator.validate(profile: data, profileOverride: ConfigOverride.profile(profile.name).load())
        try write(data, to: profile)
    }

    /// 校验应用覆写后的配置，通过后保存配置覆写
    func saveOverride(_ text: String, of profile: Profile) async throws {
        let data: Data
        do {
            data = try Data(contentsOf: profile.fileURL)
        } catch {
            NSLog("读取配置失败：\(error)")
            throw ProfileError.readFailed
        }
        try await ConfigValidator.validate(profileOverride: text, of: data)
        try checkExists(profile)
        try ConfigOverride.profile(profile.name).save(text)
    }

    /// 下载和校验期间配置可能已被删除，写入前确认，避免重新创建
    private func write(_ data: Data, to profile: Profile) throws {
        try checkExists(profile)
        do {
            try data.write(to: profile.fileURL, options: .atomic)
        } catch {
            NSLog("写入配置失败：\(error)")
            throw ProfileError.saveFailed
        }
    }

    private func checkExists(_ profile: Profile) throws {
        guard FileManager.default.fileExists(atPath: profile.fileURL.path) else {
            throw ProfileError.notFound(profile.name)
        }
    }

    /// 名称即文件名：需合法且不与目录中已有配置重复（APFS 默认不区分大小写）
    private func checkName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            throw ProfileError.invalidName
        }
        let exists = profiles.contains { !$0.isDeleted && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            || FileManager.default.fileExists(atPath: ProfileDirectory.fileURL(forName: name).path)
        if exists {
            throw ProfileError.duplicateName(name)
        }
    }

    /// 校验配置本身和应用全局覆写后的配置，通过后写入配置文件，首个配置会自动选中
    private func add(name: String, data: Data, subscription: Subscription?) async throws {
        try await ConfigValidator.validate(profile: data, profileOverride: "")

        // 下载和校验期间可能已添加同名配置，写入前再确认一次
        try checkName(name)

        guard ProfileDirectory.createIfNeeded() else { throw ProfileError.saveFailed }
        do {
            try data.write(to: ProfileDirectory.fileURL(forName: name), options: .atomic)
        } catch {
            NSLog("写入配置失败：\(error)")
            throw ProfileError.saveFailed
        }

        subscriptions[name] = subscription
        saveSubscriptions()
        reload()
        if selectedName == nil {
            selectedName = name
        }
    }

    /// 扫描配置目录重建列表；选中的配置文件被删除时以“已删除”状态保留
    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: ProfileDirectory.url,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []

        var profiles = files
            .filter { ProfileDirectory.fileExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                return Profile(name: name, fileURL: url, subscription: subscriptions[name])
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // 此状态表示“内核仍在运行已删除的配置”，切换配置后才从列表移除（见 CoreManager）
        if let selectedName, !profiles.contains(where: { $0.name == selectedName }) {
            profiles.append(Profile(
                name: selectedName,
                fileURL: ProfileDirectory.fileURL(forName: selectedName),
                isDeleted: true
            ))
        }

        self.profiles = profiles

        // 清理文件已不存在的订阅信息和配置覆写，避免之后同名的本地文件被误认为订阅或沿用旧覆写
        let existing = Set(profiles.lazy.filter { !$0.isDeleted }.map(\.name))
        ConfigOverride.removeProfileOverrides(except: existing)
        let stale = subscriptions.keys.filter { !existing.contains($0) }
        if !stale.isEmpty {
            stale.forEach { subscriptions[$0] = nil }
            saveSubscriptions()
        }
    }

    private func startMonitoring() {
        guard ProfileDirectory.createIfNeeded() else { return }
        let fd = open(ProfileDirectory.url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reload()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }

    /// 定时检查到期的订阅；ContinuousClock 在睡眠期间继续计时，唤醒后会尽快检查
    private func startAutoUpdate() {
        autoUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateDueSubscriptions()
                try? await Task.sleep(for: Self.autoUpdateCheckInterval)
            }
        }
    }

    /// 自动更新失败只记录日志，下次检查时重试，避免断网时反复通知
    private func updateDueSubscriptions() async {
        let due = profiles.filter { profile in
            guard !profile.isDeleted, let next = profile.subscription?.nextUpdate else { return false }
            return next <= .now
        }
        for profile in due {
            do {
                try await update(profile)
            } catch {
                NSLog("自动更新配置“\(profile.name)”失败：\(error)")
            }
        }
    }

    private func loadSubscriptions() {
        guard let data = try? Data(contentsOf: ProfileDirectory.metadataURL) else { return }
        do {
            subscriptions = try JSONDecoder().decode([String: Subscription].self, from: data)
        } catch {
            NSLog("读取配置信息失败：\(error)")
        }
    }

    private func saveSubscriptions() {
        guard ProfileDirectory.createIfNeeded() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(subscriptions).write(to: ProfileDirectory.metadataURL, options: .atomic)
        } catch {
            NSLog("保存配置信息失败：\(error)")
        }
    }

    /// 以 clash.meta 的 UA 请求，使订阅服务返回 Clash 格式的 YAML；同时返回订阅建议的更新间隔（小时）
    private static func download(_ url: URL) async throws -> (Data, Int?) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("clash.meta", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProfileError.badStatus(http.statusCode)
        }
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "profile-update-interval")
        guard let hours = header.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), hours > 0 else {
            return (data, nil)
        }
        return (data, max(1, Int(hours.rounded())))
    }
}
