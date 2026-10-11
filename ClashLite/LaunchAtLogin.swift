//
//  LaunchAtLogin.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import Observation
import ServiceManagement

/// 通过 SMAppService 将应用注册为登录项
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = false

    init() {
        refresh()
    }

    /// 用户可能在系统设置中修改登录项，需要时重新读取
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("\(enabled ? "注册" : "取消")登录项失败：\(error)")
        }
        // 登录项被用户在系统设置中禁用时，注册后状态为需要批准
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }
}
