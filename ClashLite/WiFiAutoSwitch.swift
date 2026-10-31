//
//  WiFiAutoSwitch.swift
//  ClashLite
//
//  Created by Zayrick on 11/1/26.
//

import AppKit
import CoreLocation
import CoreWLAN
import Observation

/// 切换到某个网络时要应用的设置，nil 表示保持不变
struct WiFiAction: Codable, Hashable {
    var profileName: String?
    var isTunEnabled: Bool?
    var mode: ProxyMode?
}

/// 连接到指定 Wi-Fi 时应用的设置
struct WiFiRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var ssid: String
    var action: WiFiAction
}

/// 参考 sing-box：根据当前 Wi-Fi 同时切换配置、TUN 和代理模式，CoreManager 将同一轮的修改合并为一次热重载。
/// macOS 14 起读取 SSID 需要定位权限，仅在开启此功能时请求。
/// 只在网络变化、开启功能或修改规则时切换，之后手动做的修改保持到下次网络变化
@Observable
final class WiFiAutoSwitch {
    enum Authorization {
        case notDetermined
        case denied
        case authorized
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                startMonitoring()
                if authorization == .notDetermined {
                    locationManager.requestAlwaysAuthorization()
                }
                refresh(force: true)
            } else {
                stopMonitoring()
                currentSSID = nil
            }
        }
    }

    var rules: [WiFiRule] {
        didSet {
            guard rules != oldValue else { return }
            Self.save(rules, forKey: Self.rulesKey)
            refresh(force: true)
        }
    }

    /// 没有规则匹配（包括未连接 Wi-Fi）时应用的设置
    var otherNetworks: WiFiAction {
        didSet {
            guard otherNetworks != oldValue else { return }
            Self.save(otherNetworks, forKey: Self.otherNetworksKey)
            refresh(force: true)
        }
    }

    private(set) var authorization: Authorization = .notDetermined

    /// 当前连接的 Wi-Fi，仅在开启且已授权时读取
    private(set) var currentSSID: String?

    @ObservationIgnored private weak var profileStore: ProfileStore?
    @ObservationIgnored private weak var core: CoreManager?
    @ObservationIgnored private let client = CWWiFiClient()
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let delegate = Delegate()
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private static let enabledKey = "wifiAutoSwitchEnabled"
    @ObservationIgnored private static let rulesKey = "wifiAutoSwitchRules"
    @ObservationIgnored private static let otherNetworksKey = "wifiAutoSwitchOtherNetworks"

    /// 在 CoreManager 之前创建并先切换配置，再通过 attach(_:) 应用 TUN 和代理模式，
    /// 使内核首次启动就使用匹配的设置
    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        rules = Self.load([WiFiRule].self, forKey: Self.rulesKey) ?? []
        otherNetworks = Self.load(WiFiAction.self, forKey: Self.otherNetworksKey) ?? WiFiAction()

        delegate.onWiFiChange = { [weak self] in
            Task { @MainActor [self] in self?.wiFiDidChange() }
        }
        delegate.onAuthorizationChange = { [weak self] in
            Task { @MainActor [self] in self?.authorizationDidChange() }
        }
        client.delegate = delegate
        locationManager.delegate = delegate
        authorization = Self.authorization(of: locationManager)

        if isEnabled {
            startMonitoring()
            refresh(force: true, notify: false)
        }
    }

    /// 须在创建 CoreManager 后立即调用，此时内核尚未开始启动
    func attach(_ core: CoreManager) {
        self.core = core
        refresh(force: true, notify: false)
    }

    /// 打开系统设置中的定位服务，用于拒绝授权之后手动开启
    static func openLocationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    private func startMonitoring() {
        do {
            try client.startMonitoringEvent(with: .ssidDidChange)
            try client.startMonitoringEvent(with: .linkDidChange)
        } catch {
            NSLog("监听 Wi-Fi 变化失败：\(error)")
        }
    }

    private func stopMonitoring() {
        changeTask?.cancel()
        do {
            try client.stopMonitoringAllEvents()
        } catch {
            NSLog("停止监听 Wi-Fi 变化失败：\(error)")
        }
    }

    /// 切换网络时会先断开再连接，稍等片刻再读取，避免中途切到无匹配时的配置
    private func wiFiDidChange() {
        changeTask?.cancel()
        changeTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            refresh(force: false)
        }
    }

    private func authorizationDidChange() {
        let authorization = Self.authorization(of: locationManager)
        guard authorization != self.authorization else { return }
        self.authorization = authorization
        refresh(force: true)
    }

    /// 读取当前 Wi-Fi；网络未变化时不切换，以保留手动做的修改
    private func refresh(force: Bool, notify: Bool = true) {
        guard isEnabled, authorization == .authorized else {
            currentSSID = nil
            return
        }
        let ssid = client.interface()?.ssid()
        guard force || ssid != currentSSID else { return }
        currentSSID = ssid
        let rule = ssid.flatMap { ssid in rules.first { $0.ssid == ssid } }
        perform(rule?.action ?? otherNetworks, network: ssid, notify: notify)
    }

    /// 先切换配置再修改 TUN 和代理模式；引用的配置已被删除时跳过配置，其余照常应用
    private func perform(_ action: WiFiAction, network ssid: String?, notify: Bool) {
        var changes: [String] = []

        if let name = action.profileName, let profileStore, name != profileStore.selectedName,
           profileStore.profiles.contains(where: { !$0.isDeleted && $0.name == name }) {
            profileStore.selectedName = name
            changes.append(name)
        }
        if let core {
            if let mode = action.mode, mode != core.mode {
                core.mode = mode
                changes.append(mode.title)
            }
            if let isTunEnabled = action.isTunEnabled, isTunEnabled != core.isTunEnabled {
                core.setTunEnabled(isTunEnabled)
                changes.append(isTunEnabled ? String(localized: "TUN On") : String(localized: "TUN Off"))
            }
        }

        guard notify, !changes.isEmpty else { return }
        let network = ssid.map { String(localized: "Wi-Fi “\($0)”") } ?? String(localized: "No Wi-Fi")
        Notifier.post(id: "wifi", title: "Switched by Wi-Fi", body: "\(network) → \(changes.formatted(.list(type: .and)))")
    }

    private static func authorization(of manager: CLLocationManager) -> Authorization {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .restricted, .denied: .denied
        default: .authorized
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            NSLog("读取 Wi-Fi 规则失败：\(error)")
            return nil
        }
    }

    private static func save<T: Encodable>(_ value: T, forKey key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            NSLog("保存 Wi-Fi 规则失败：\(error)")
        }
    }

    /// CoreWLAN 和 CoreLocation 的回调不在主线程，转发给主线程处理
    private nonisolated final class Delegate: NSObject, CWEventDelegate, CLLocationManagerDelegate {
        nonisolated(unsafe) var onWiFiChange: (@Sendable () -> Void)?
        nonisolated(unsafe) var onAuthorizationChange: (@Sendable () -> Void)?

        func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
            onWiFiChange?()
        }

        func linkDidChangeForWiFiInterface(withName interfaceName: String) {
            onWiFiChange?()
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            onAuthorizationChange?()
        }
    }
}
