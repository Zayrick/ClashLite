//
//  ClashLiteApp.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI

nonisolated enum ProxyMode: String, CaseIterable, Identifiable {
    case rule
    case global
    case direct

    var id: Self { self }

    var title: String {
        switch self {
        case .rule: "规则"
        case .global: "全局"
        case .direct: "直连"
        }
    }
}

@main
struct ClashLiteApp: App {
    @State private var coreVersion = CoreVersionMonitor()
    @State private var profileStore: ProfileStore
    @State private var core: CoreManager

    init() {
        let profileStore = ProfileStore()
        let core = CoreManager(profileStore: profileStore)
        // 手动或自动更新正在使用的订阅后，重新加载内核
        profileStore.onUpdate = { [weak profileStore, weak core] name in
            if profileStore?.selectedName == name {
                core?.reload()
            }
        }
        _profileStore = State(initialValue: profileStore)
        _core = State(initialValue: core)
    }

    var body: some Scene {
        MenuBarExtra("ClashLite", systemImage: "bolt.horizontal.circle") {
            Text("内核\(core.status.title)")
                .badge(coreVersion.version)

            Button("打开面板") {
                core.openPanel()
            }
            .disabled(core.status != .running || core.isUpdatingPanel)

            Button(core.isUpdatingPanel ? "正在下载面板…" : "更新面板") {
                core.updatePanel()
            }
            .disabled(core.status != .running || core.isUpdatingPanel)

            Toggle("网卡代理", isOn: Binding(get: { core.isTunEnabled }, set: { core.setTunEnabled($0) }))

            Divider()

            ProfileMenu(profileStore: profileStore)

            Picker("模式：\(core.mode.title)", selection: $core.mode) {
                ForEach(ProxyMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Menu("策略组") {
                ForEach(core.proxyGroups) { group in
                    Menu(group.name) {
                        if group.fixed != nil {
                            Button("解除锁定") {
                                core.unfixProxy(in: group.name)
                            }

                            Divider()
                        }

                        // 用 Toggle 而非 Picker，菜单项才能带 badge
                        ForEach(group.members) { member in
                            Toggle(member.name, isOn: Binding(
                                get: { group.now == member.name },
                                set: { isOn in
                                    if isOn { core.selectProxy(member.name, in: group.name) }
                                }
                            ))
                            .badge(member.delayText)
                        }
                        .disabled(!group.isSelectable)
                    }
                    // 菜单中的 badge 对应 NSMenuItem.badge，显示在右侧且颜色较淡
                    .badge(group.now)
                }
            }
            .disabled(core.proxyGroups.isEmpty)

            Divider()

            Menu("更多") {
                Button("重启内核") {
                    core.restart()
                }
                .disabled(profileStore.selected == nil)

                Button("关闭所有连接") {
                    core.closeAllConnections()
                }
                .disabled(core.status != .running)

                Divider()

                Button("打开内核目录") {
                    CoreDirectory.open()
                }

                Button("打开配置目录") {
                    ProfileDirectory.open(selecting: profileStore.selected?.fileURL)
                }
            }

            SettingsLink {
                Text("设置…")
            }
            .keyboardShortcut(",")

            Button("退出 ClashLite") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Settings {
            SettingsView()
        }

        Window("新增配置", id: AddProfileView.windowID) {
            AddProfileView()
                .environment(profileStore)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("编辑配置", id: ProfileEditorView.windowID, for: String.self) { $name in
            if let name {
                ProfileEditorView(name: name)
                    .environment(core)
                    .environment(profileStore)
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("覆写", id: ConfigOverrideView.windowID, for: ConfigOverride.self) { $target in
            if let target {
                ConfigOverrideView(target: target)
                    .environment(core)
                    .environment(profileStore)
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
