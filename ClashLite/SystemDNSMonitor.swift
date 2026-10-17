//
//  SystemDNSMonitor.swift
//  ClashLite
//
//  Created by Zayrick on 10/17/26.
//

import Foundation
import SystemConfiguration

/// 监听系统 DNS 服务器（State:/Network/Global/DNS），/etc/resolv.conf 由同一份设置生成
final class SystemDNSMonitor {
    private static let key = "State:/Network/Global/DNS" as CFString

    private let onChange: () -> Void
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?

    /// 回调在主线程执行
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<SystemDNSMonitor>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.onChange()
            }
        }
        guard let store = SCDynamicStoreCreate(nil, "ClashLite" as CFString, callback, &context),
              SCDynamicStoreSetNotificationKeys(store, [Self.key] as CFArray, nil),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        else {
            NSLog("监听系统 DNS 失败")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.store = store
        self.source = source
    }

    deinit {
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
    }

    /// 当前的系统 DNS 服务器，无网络时为空
    var servers: [String] {
        guard let store, let dns = SCDynamicStoreCopyValue(store, Self.key) as? [String: Any] else { return [] }
        return dns[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
    }
}
