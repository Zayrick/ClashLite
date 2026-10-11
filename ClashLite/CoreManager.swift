//
//  CoreManager.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import AppKit
import Observation

/// 管理内核进程：以覆写后的配置（base64）启动 mihomo，设置变化时通过 RESTful API 同步
@Observable
final class CoreManager {
    enum Status {
        case stopped
        case starting
        case running
        case failed

        var title: String {
            switch self {
            case .stopped: "未运行"
            case .starting: "启动中"
            case .running: "运行中"
            case .failed: "启动失败"
            }
        }
    }

    private(set) var status: Status = .stopped {
        didSet {
            guard status != oldValue else { return }
            status == .running ? startSync() : stopSync()
            if status != .running {
                proxies = [:]
            }
        }
    }

    var mode: ProxyMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            updateProxyGroups()
            // 从内核同步来的修改无需再推回内核
            guard !isSyncing else { return }
            enqueue { await self.patch(["mode": self.mode.rawValue]) }
        }
    }

    /// 通过 setTunEnabled(_:) 修改，授权失败时会被关闭
    private(set) var isTunEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isTunEnabled, forKey: Self.tunKey)
        }
    }

    /// 菜单中可快捷切换的策略组，随 proxies 和 mode 更新
    private(set) var proxyGroups: [ProxyGroup] = []

    let controller = CoreController.load()

    @ObservationIgnored private var proxies: [String: CoreController.Proxy] = [:] {
        didSet { updateProxyGroups() }
    }

    @ObservationIgnored private var profileURL: URL?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private static let syncInterval = Duration.seconds(3)
    @ObservationIgnored private static let modeKey = "proxyMode"
    @ObservationIgnored private static let tunKey = "tunEnabled"

    private var config: CoreConfig {
        CoreConfig(mode: mode, isTunEnabled: isTunEnabled, controller: controller)
    }

    init(profileStore: ProfileStore) {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(ProxyMode.init) ?? .rule
        isTunEnabled = UserDefaults.standard.bool(forKey: Self.tunKey)

        Notifier.setUp()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.process?.terminate()
            }
        }

        Task { [weak self] in
            for await profile in Observations({ profileStore.selected }) {
                self?.select(profile)
            }
        }
    }

    /// TUN 会影响 DNS 覆写，需要以完整配置重新加载
    func setTunEnabled(_ enabled: Bool) {
        guard enabled != isTunEnabled else { return }
        isTunEnabled = enabled
        enqueue {
            guard await self.ensureTunPermission() else { return }
            await self.apply()
        }
    }

    /// 重新生成配置并应用，例如修改覆写之后
    func reload() {
        guard profileURL != nil else { return }
        enqueue { await self.apply() }
    }

    /// 手动重启，例如放入内核文件之后
    func restart() {
        enqueue { await self.start() }
    }

    /// 切换策略组选中的节点，先更新菜单再同步给内核
    func selectProxy(_ name: String, in group: String) {
        guard let index = proxyGroups.firstIndex(where: { $0.name == group }) else { return }
        proxyGroups[index].now = name
        enqueue {
            guard self.status == .running else { return }
            do {
                try await self.controller.selectProxy(name, in: group)
            } catch {
                Notifier.post(id: "proxy", title: "切换节点失败", body: error.localizedDescription)
            }
            await self.refreshProxies()
        }
    }

    /// 解除策略组的锁定，恢复自动选择
    func unfixProxy(in group: String) {
        guard let index = proxyGroups.firstIndex(where: { $0.name == group }) else { return }
        proxyGroups[index].fixed = nil
        enqueue {
            guard self.status == .running else { return }
            do {
                try await self.controller.unfixProxy(in: group)
            } catch {
                Notifier.post(id: "proxy", title: "解除锁定失败", body: error.localizedDescription)
            }
            await self.refreshProxies()
        }
    }

    /// 关闭当前所有连接，例如切换节点后让旧连接立即走新节点
    func closeAllConnections() {
        enqueue {
            guard self.status == .running else { return }
            do {
                try await self.controller.closeAllConnections()
            } catch {
                Notifier.post(id: "connections", title: "关闭连接失败", body: error.localizedDescription)
            }
        }
    }

    /// 选中的配置被删除时，内核继续运行原配置直到切换
    private func select(_ profile: Profile?) {
        guard let profile else {
            profileURL = nil
            enqueue { await self.stop() }
            return
        }
        guard !profile.isDeleted, profile.fileURL != profileURL else { return }
        profileURL = profile.fileURL
        enqueue { await self.apply() }
    }

    /// 操作依次执行，避免启动、重载交错
    @discardableResult
    private func enqueue(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let previous = operation
        let task = Task {
            await previous?.value
            await work()
        }
        operation = task
        return task
    }

    /// 内核不会推送设置变化，运行期间定时读取，以同步在面板中做的修改
    private func startSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.syncInterval)
                guard let self, !Task.isCancelled else { return }
                // 等本次同步完成再计时，队列被授权对话框等阻塞时不会堆积
                await self.enqueue { await self.sync() }.value
            }
        }
    }

    private func stopSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    /// 以内核当前设置为准更新并保存，之后重载、重启都会沿用；同时刷新策略组
    private func sync() async {
        await syncConfigs()
        await refreshProxies()
    }

    private func syncConfigs() async {
        guard status == .running else { return }
        let (mode, isTunEnabled) = (self.mode, self.isTunEnabled)
        guard let config = try? await controller.configs() else { return }
        // 请求期间本地又有修改时以本地为准，排在后面的操作会推给内核
        guard status == .running, self.mode == mode, self.isTunEnabled == isTunEnabled else { return }

        isSyncing = true
        defer { isSyncing = false }
        if let remote = ProxyMode(rawValue: config.mode.lowercased()) {
            self.mode = remote
        }
        if let tun = config.tun {
            self.isTunEnabled = tun.enable
        }
    }

    /// 读取策略组，内核未运行或请求失败时保持原样
    private func refreshProxies() async {
        guard status == .running, let proxies = try? await controller.proxies(), status == .running else { return }
        self.proxies = proxies
    }

    /// 内容未变时不赋值，避免菜单无谓刷新
    private func updateProxyGroups() {
        let groups = ProxyGroup.list(from: proxies, mode: mode)
        if groups != proxyGroups {
            proxyGroups = groups
        }
    }

    /// 内核运行中则热重载，否则启动
    private func apply() async {
        guard status == .running, let profileURL else {
            await start()
            return
        }

        do {
            let payload = try await Self.render(config, profileURL: profileURL)
            try await controller.reloadConfigs(payload: payload)
            await refreshProxies()
        } catch {
            Notifier.post(id: "core", title: "配置加载失败", body: error.localizedDescription)
        }
    }

    /// 开启 TUN 时确保内核已授权，未授权则请求一次；失败时关闭 TUN 并返回 false
    @discardableResult
    private func ensureTunPermission() async -> Bool {
        guard isTunEnabled, !TunPermission.isGranted else { return true }
        do {
            try await TunPermission.grant()
            return true
        } catch {
            isTunEnabled = false
            if case TunPermissionError.cancelled = error {} else {
                Notifier.post(id: "tun", title: "网卡代理授权失败", body: error.localizedDescription)
            }
            return false
        }
    }

    private func patch(_ body: [String: Any]) async {
        guard status == .running else { return }
        do {
            try await controller.patchConfigs(body)
        } catch {
            Notifier.post(id: "core", title: "内核设置失败", body: error.localizedDescription)
        }
    }

    private func start() async {
        await stop()
        guard let profileURL else { return }

        status = .starting
        do {
            guard FileManager.default.isExecutableFile(atPath: CoreDirectory.binaryURL.path) else {
                throw CoreError.binaryNotFound
            }
            // 内核文件被替换后权限会丢失，启动前重新确认
            await ensureTunPermission()
            let payload = try await Self.render(config, profileURL: profileURL)
            let process = try launch(payload: payload)
            self.process = process

            let version = try await waitUntilReady(process)
            status = .running
            await refreshProxies()
            Notifier.post(id: "core", title: "内核已启动", body: "mihomo \(version)，\(mode.title)模式")
        } catch {
            await stop()
            status = .failed
            Notifier.post(id: "core", title: "内核启动失败", body: error.localizedDescription)
        }
    }

    private func stop() async {
        guard let process else { return }
        // 先移除引用，使退出回调忽略这次主动停止
        self.process = nil
        status = .stopped
        await Self.terminate(process)
    }

    /// 配置通过 CLASH_CONFIG_STRING 环境变量（等同 -config）以 base64 传入，
    /// 避免密钥和节点信息出现在进程参数中
    private func launch(payload: String) throws -> Process {
        guard CoreDirectory.createIfNeeded() else { throw CoreError.launchFailed }

        let logURL = CoreDirectory.logURL
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }

        var environment = ProcessInfo.processInfo.environment
        environment["CLASH_CONFIG_STRING"] = Data(payload.utf8).base64EncodedString()

        let process = Process()
        process.executableURL = CoreDirectory.binaryURL
        process.arguments = ["-d", CoreDirectory.homeURL.path]
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] process in
            let pid = process.processIdentifier
            let code = process.terminationStatus
            Task { @MainActor in
                self?.processDidExit(pid: pid, code: code)
            }
        }

        do {
            try process.run()
        } catch {
            NSLog("启动内核失败：\(error)")
            throw CoreError.launchFailed
        }
        return process
    }

    /// 轮询 RESTful API，可访问即视为启动成功
    private func waitUntilReady(_ process: Process) async throws -> String {
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(200))
            guard process.isRunning else { break }
            if let version = try? await controller.version() {
                return version
            }
        }
        if process.isRunning {
            throw CoreError.timeout
        }
        throw CoreError.exited(Self.lastLogError())
    }

    /// 运行中意外退出时提示；启动阶段的退出由 waitUntilReady 处理
    private func processDidExit(pid: Int32, code: Int32) {
        guard let process, process.processIdentifier == pid, status == .running else { return }
        self.process = nil
        status = .failed
        Notifier.post(id: "core", title: "内核已退出", body: Self.lastLogError() ?? "退出代码 \(code)")
    }

    @concurrent
    private nonisolated static func render(_ config: CoreConfig, profileURL: URL) async throws -> String {
        try config.render(profileURL: profileURL)
    }

    /// 先发送 SIGTERM 让内核清理 TUN 路由等，超时后强制结束
    private static func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<30 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// 从日志中取最后一条错误，例如 `level=fatal msg="Parse config error: ..."`
    private static func lastLogError() -> String? {
        guard let text = try? String(contentsOf: CoreDirectory.logURL, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).last {
            $0.contains("level=fatal") || $0.contains("level=error")
        }
        guard let line, let start = line.range(of: "msg=\"") else { return nil }
        var message = line[start.upperBound...]
        if message.hasSuffix("\"") {
            message = message.dropLast()
        }
        return message.replacingOccurrences(of: "\\\"", with: "\"")
    }
}

enum CoreError: LocalizedError {
    case binaryNotFound
    case launchFailed
    case timeout
    case exited(String?)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: "未找到内核，请将 mihomo 放入内核目录"
        case .launchFailed: "无法运行内核"
        case .timeout: "等待内核响应超时"
        case .exited(let message): message ?? "内核意外退出"
        }
    }
}
