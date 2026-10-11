//
//  ProxyGroup.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import Foundation

/// 菜单中展示的策略组
nonisolated struct ProxyGroup: Identifiable, Equatable {
    struct Member: Identifiable, Equatable {
        var name: String
        /// 最近一次测速结果，0 表示超时，nil 表示未测速
        var delay: Int?

        var id: String { name }

        var title: String {
            switch delay {
            case nil: name
            case 0: "\(name)   | 超时"
            case let delay?: "\(name)   | \(delay)ms"
            }
        }
    }

    var name: String
    var now: String?
    var members: [Member]
    /// 内核只允许手动切换 Selector、URLTest、Fallback，LoadBalance、Relay 等会被拒绝
    var isSelectable: Bool

    var id: String { name }

    /// 参考 clash-verge-rev 的托盘菜单：按 GLOBAL 中的顺序（即配置文件顺序）排列，
    /// 全局模式只显示 GLOBAL，其余模式显示除 GLOBAL 外未隐藏的策略组
    static func list(from proxies: [String: CoreController.Proxy], mode: ProxyMode) -> [ProxyGroup] {
        let global = "GLOBAL"
        let names: [String]
        if mode == .global {
            names = [global]
        } else {
            let ordered = proxies[global]?.all ?? []
            let rest = proxies.keys.filter { !ordered.contains($0) }.sorted()
            names = (ordered + rest).filter { $0 != global }
        }

        return names.compactMap { name in
            guard let proxy = proxies[name], let all = proxy.all, !all.isEmpty, proxy.hidden != true else { return nil }
            let members = all.map { Member(name: $0, delay: delay(of: $0, in: proxies)) }
            let isSelectable = ["Selector", "URLTest", "Fallback"].contains(proxy.type)
            return ProxyGroup(name: name, now: proxy.now, members: members, isSelectable: isSelectable)
        }
    }

    /// 内核不会为策略组记录延迟，沿 now 找到实际选中的节点
    private static func delay(of name: String, in proxies: [String: CoreController.Proxy]) -> Int? {
        var current = name
        for _ in 0..<8 {
            guard let proxy = proxies[current] else { return nil }
            guard proxy.all != nil, let now = proxy.now, !now.isEmpty, now != current else {
                return proxy.history?.last?.delay
            }
            current = now
        }
        return nil
    }
}
