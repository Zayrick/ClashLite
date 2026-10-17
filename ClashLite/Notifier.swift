//
//  Notifier.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import UserNotifications

enum Notifier {
    private static let delegate = Delegate()

    static func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        Task {
            do {
                try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                NSLog("请求通知权限失败：\(error)")
            }
        }
    }

    /// 同一类通知使用相同标识，新通知会替换旧的
    static func post(id: String, title: LocalizedStringResource, body: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: title)
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// 打开菜单时应用处于前台，默认不会展示通知
    private nonisolated final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list]
        }
    }
}
