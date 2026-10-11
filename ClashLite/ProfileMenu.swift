//
//  ProfileMenu.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI

/// 菜单中的配置管理：新增、切换、编辑/更新当前配置、配置覆写、全局覆写
struct ProfileMenu: View {
    @Bindable var profileStore: ProfileStore
    var core: CoreManager

    @Environment(\.openWindow) private var openWindow

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

            Button("编辑配置…") {
                guard let current else { return }
                open(ProfileEditorView.windowID, value: current.name)
            }
            .disabled(current == nil)

            if let current, let subscription = current.subscription {
                let isUpdating = profileStore.updatingNames.contains(current.name)
                Button(isUpdating ? "正在更新配置…" : "更新配置") {
                    Task { await update(current) }
                }
                .badge(subscription.updatedAt.formatted(.relative(presentation: .named)))
                .disabled(isUpdating)
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

    private func update(_ profile: Profile) async {
        do {
            try await profileStore.update(profile)
            if profileStore.selectedName == profile.name {
                core.reload()
            }
            Notifier.post(id: "profile", title: "配置已更新", body: profile.name)
        } catch {
            Notifier.post(id: "profile", title: "更新配置失败", body: error.localizedDescription)
        }
    }
}
