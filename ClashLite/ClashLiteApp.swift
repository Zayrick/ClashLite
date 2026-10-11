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
        _profileStore = State(initialValue: profileStore)
        _core = State(initialValue: CoreManager(profileStore: profileStore))
    }

    var body: some Scene {
        MenuBarExtra("ClashLite", systemImage: "bolt.horizontal.circle") {
            Toggle("网卡代理", isOn: Binding(get: { core.isTunEnabled }, set: { core.setTunEnabled($0) }))

            Divider()

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

            Menu("配置：\(profileStore.selected?.displayName ?? "无")") {
                if !profileStore.profiles.isEmpty {
                    Picker("配置", selection: $profileStore.selectedName) {
                        ForEach(profileStore.profiles) { profile in
                            Text(profile.displayName).tag(Optional(profile.name))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Divider()
                }

                AddProfileButton()
            }

            Button("打开面板") {
                NSWorkspace.shared.open(core.controller.panelURL)
            }
            .disabled(core.status != .running)

            Divider()

            Menu("更多") {
                Text("内核版本：\(coreVersion.version ?? "未找到")")
                Text("内核状态：\(core.status.title)")

                Button("重启内核") {
                    core.restart()
                }
                .disabled(profileStore.selected == nil)

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
    }
}
