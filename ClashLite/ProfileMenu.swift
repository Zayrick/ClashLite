//
//  ProfileMenu.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI

/// 菜单中的配置管理：新增、切换、编辑（远程配置仅查看）/更新当前配置、自动更新、配置覆写、全局覆写
struct ProfileMenu: View {
    @Bindable var profileStore: ProfileStore

    @Environment(\.openWindow) private var openWindow

    /// 自动更新间隔选项（小时），nil 表示关闭
    private static let intervals: [Int?] = [nil, 6, 12, 24, 72]

    /// 已删除的配置不可编辑
    private var current: Profile? {
        profileStore.selected.flatMap { $0.isDeleted ? nil : $0 }
    }

    var body: some View {
        Menu("配置：\(profileStore.selected?.displayName ?? "无")") {
            AddProfileButton()

            if !profileStore.profiles.isEmpty {
                Divider()

                Picker("配置", selection: $profileStore.selectedName) {
                    ForEach(profileStore.profiles) { profile in
                        Text(profile.displayName).tag(Optional(profile.name))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Divider()

            Button(current?.subscription == nil ? "编辑配置…" : "查看配置…") {
                guard let current else { return }
                open(ProfileEditorView.windowID, value: current.name)
            }
            .disabled(current == nil)

            if let current, let subscription = current.subscription {
                let isUpdating = profileStore.updatingNames.contains(current.name)
                Button(isUpdating ? "正在更新配置…" : "更新配置") {
                    Task { await update(current) }
                }
                .badge(subscription.updatedAt.formatted(date: .numeric, time: .shortened))
                .disabled(isUpdating)

                Picker("自动更新：\(Self.title(of: subscription.interval))", selection: Binding(
                    get: { subscription.interval },
                    set: { profileStore.setInterval($0, of: current) }
                )) {
                    // 订阅建议的间隔可能不在预设选项中
                    let options = Self.intervals.contains(subscription.interval)
                        ? Self.intervals
                        : Self.intervals + [subscription.interval]
                    ForEach(options, id: \.self) { interval in
                        Text(Self.title(of: interval)).tag(interval)
                    }
                }
            }

            Button("配置覆写…") {
                guard let current else { return }
                open(ConfigOverrideView.windowID, value: ConfigOverride.profile(current.name))
            }
            .disabled(current == nil)

            Divider()

            Button("全局覆写…") {
                open(ConfigOverrideView.windowID, value: ConfigOverride.global)
            }
        }
    }

    /// 菜单栏应用默认不在前台，需要主动激活才能让窗口获得焦点
    private func open<Value: Codable & Hashable>(_ id: String, value: Value) {
        openWindow(id: id, value: value)
        NSApplication.shared.activate()
    }

    private static func title(of interval: Int?) -> String {
        interval.map { "每 \($0) 小时" } ?? "关闭"
    }

    private func update(_ profile: Profile) async {
        do {
            try await profileStore.update(profile)
            Notifier.post(id: "profile", title: "配置已更新", body: profile.name)
        } catch {
            Notifier.post(id: "profile", title: "更新配置失败", body: error.localizedDescription)
        }
    }
}
