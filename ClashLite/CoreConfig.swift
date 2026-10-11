//
//  CoreConfig.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import Foundation
import Yams

enum CoreConfigError: LocalizedError {
    case readFailed
    case invalidContent

    var errorDescription: String? {
        switch self {
        case .readFailed: "无法读取配置文件"
        case .invalidContent: "配置文件不是有效的 YAML 映射"
        }
    }
}

/// 在配置文件之上依次合并用户覆写和应用内的设置，生成交给内核的最终配置
nonisolated struct CoreConfig {
    var mode: ProxyMode
    var isTunEnabled: Bool
    var controller: CoreController

    func render(profileURL: URL) throws -> String {
        let text: String
        do {
            text = try String(contentsOf: profileURL, encoding: .utf8)
        } catch {
            NSLog("读取配置失败：\(error)")
            throw CoreConfigError.readFailed
        }

        guard case .mapping(var root) = try Yams.compose(yaml: text) else {
            throw CoreConfigError.invalidContent
        }

        ConfigOverride.merge(try ConfigOverride.parse(ConfigOverride.load()), into: &root)

        root["mode"] = Node(mode.rawValue)
        root["external-controller"] = Node(controller.address)
        root["secret"] = Node(controller.secret, .implicit, .doubleQuoted)
        applyTun(to: &root)

        return try Yams.serialize(node: .mapping(root), width: -1, allowUnicode: true)
    }

    /// 参考 clash-verge-rev 的 use_tun：开启 TUN 时确保 DNS 以 fake-ip 模式工作
    private func applyTun(to root: inout Node.Mapping) {
        var tun = root["tun"]?.mapping ?? [:]
        tun["enable"] = Node(String(isTunEnabled))
        root["tun"] = .mapping(tun)

        guard isTunEnabled else { return }

        var dns = root["dns"]?.mapping ?? [:]
        let enhancedMode = dns["enhanced-mode"]?.string
        guard enhancedMode == nil || enhancedMode == "fake-ip" else { return }

        let ipv6 = root["ipv6"]?.bool ?? false
        dns["enable"] = Node("true")
        dns["ipv6"] = Node(String(ipv6))
        if enhancedMode == nil {
            dns["enhanced-mode"] = Node("fake-ip")
        }
        if dns["fake-ip-range"] == nil {
            dns["fake-ip-range"] = Node("198.18.0.1/16")
        }
        if ipv6, dns["fake-ip-range6"] == nil {
            dns["fake-ip-range6"] = Node("2001:2::0/64")
        }
        root["dns"] = .mapping(dns)
    }
}
