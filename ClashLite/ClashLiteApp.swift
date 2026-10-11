//
//  ClashLiteApp.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI

enum ProxyMode: String, CaseIterable, Identifiable {
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
    @State private var isSystemProxyEnabled = false
    @State private var mode: ProxyMode = .rule
    @State private var coreVersion = CoreVersionMonitor()
    @State private var profileStore = ProfileStore()

    var body: some Scene {
        MenuBarExtra("ClashLite", systemImage: "bolt.horizontal.circle") {
            Toggle("网卡代理", isOn: $isSystemProxyEnabled)

            Divider()

            Picker("模式：\(mode.title)", selection: $mode) {
                ForEach(ProxyMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Menu("配置：\(profileStore.selected?.name ?? "无")") {
                if !profileStore.profiles.isEmpty {
                    Picker("配置", selection: $profileStore.selectedID) {
                        ForEach(profileStore.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Divider()
                }

                AddProfileButton()
            }

            Divider()

            Menu("更多") {
                Text("内核版本：\(coreVersion.version ?? "未找到")")

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
