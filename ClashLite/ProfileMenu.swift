//
//  ProfileMenu.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI

/// 菜单中的配置管理：新增、切换、编辑（远程配置仅查看）/更新当前配置、自动更新、配置覆写、全局覆写、查看运行时配置
struct ProfileMenu: View {
    @Bindable var profileStore: ProfileStore
    var core: CoreManager

    @Environment(\.openWindow) private var openWindow

    /// 自动更新间隔选项（小时），nil 表示关闭
    private static let intervals: [Int?] = [nil, 6, 12, 24, 72]

    /// 已删除的配置不可编辑
    private var current: Profile? {
        profileStore.selected.flatMap { $0.isDeleted ? nil : $0 }
    }

    var body: some View {
        Menu("Profile: \(profileStore.selected?.displayName ?? String(localized: "None"))") {
            AddProfileButton()

            if !profileStore.profiles.isEmpty {
                Divider()

                Picker("Profile", selection: $profileStore.selectedName) {
                    ForEach(profileStore.profiles) { profile in
                        Text(profile.displayName).tag(Optional(profile.name))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Divider()

            Button(current?.subscription == nil ? "Edit Profile…" : "View Profile…") {
                guard let current else { return }
                open(ProfileEditorView.windowID, value: current.name)
            }
            .disabled(current == nil)

            if let current, let subscription = current.subscription {
                let isUpdating = profileStore.updatingNames.contains(current.name)
                Button(isUpdating ? "Updating Profile…" : "Update Profile") {
                    Task { await update(current) }
                }
                .badge(subscription.updatedAt.formatted(date: .numeric, time: .shortened))
                .disabled(isUpdating)

                Picker("Auto Update: \(Self.title(of: subscription.interval))", selection: Binding(
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

            Button("Profile Override…") {
                guard let current else { return }
                open(ConfigOverrideView.windowID, value: ConfigOverride.profile(current.name))
            }
            .disabled(current == nil)

            Divider()

            Button("Global Override…") {
                open(ConfigOverrideView.windowID, value: ConfigOverride.global)
            }

            Button("View Runtime Config…") {
                openWindow(id: RuntimeConfigView.windowID)
                NSApplication.shared.activate()
            }
            .disabled(core.runtimeConfig == nil)
        }
    }

    /// 菜单栏应用默认不在前台，需要主动激活才能让窗口获得焦点
    private func open<Value: Codable & Hashable>(_ id: String, value: Value) {
        openWindow(id: id, value: value)
        NSApplication.shared.activate()
    }

    private static func title(of interval: Int?) -> String {
        interval.map { String(localized: "Every \($0) hours") } ?? String(localized: "Off")
    }

    private func update(_ profile: Profile) async {
        do {
            try await profileStore.update(profile)
            Notifier.post(id: "profile", title: "Profile Updated", body: profile.name)
        } catch {
            Notifier.post(id: "profile", title: "Failed to Update Profile", body: error.localizedDescription)
        }
    }
}
