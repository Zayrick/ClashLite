//
//  WiFiAutoSwitchView.swift
//  ClashLite
//
//  Created by Zayrick on 11/1/26.
//

import SwiftUI

/// 设置按 Wi-Fi 自动切换配置、TUN 和代理模式的规则
struct WiFiAutoSwitchView: View {
    static let windowID = "wifi-auto-switch"

    @Environment(WiFiAutoSwitch.self) private var autoSwitch
    @Environment(ProfileStore.self) private var profileStore
    @Environment(CoreManager.self) private var core

    private var profileNames: [String] {
        profileStore.profiles.filter { !$0.isDeleted }.map(\.name)
    }

    /// 当前 Wi-Fi 尚无规则时才可快速添加
    private var canAddCurrent: Bool {
        guard let ssid = autoSwitch.currentSSID else { return false }
        return !autoSwitch.rules.contains { $0.ssid == ssid }
    }

    var body: some View {
        @Bindable var autoSwitch = autoSwitch

        Form {
            Section {
                Toggle("Switch by Wi-Fi", isOn: $autoSwitch.isEnabled)

                if autoSwitch.isEnabled {
                    switch autoSwitch.authorization {
                    case .notDetermined:
                        Text("Waiting for Location Services permission…")
                            .foregroundStyle(.secondary)
                    case .denied:
                        LabeledContent {
                            Button("Open System Settings") {
                                WiFiAutoSwitch.openLocationSettings()
                            }
                        } label: {
                            Text("Location Services permission is required to read the Wi-Fi name")
                                .foregroundStyle(.red)
                        }
                    case .authorized:
                        LabeledContent("Current Wi-Fi", value: autoSwitch.currentSSID ?? String(localized: "Not Connected"))
                    }
                }
            } footer: {
                Text("When the Wi-Fi network changes, apply the matching profile, TUN mode, and proxy mode, then reload the core once. macOS requires Location Services permission to read the Wi-Fi name; your location is not used.")
                    .foregroundStyle(.secondary)
            }

            Section("Rules") {
                ForEach($autoSwitch.rules) { $rule in
                    HStack {
                        TextField("Wi-Fi Name", text: $rule.ssid, prompt: Text("Wi-Fi Name"))
                            .labelsHidden()

                        actionPickers($rule.action)

                        Button("Remove Rule", systemImage: "minus.circle.fill") {
                            autoSwitch.rules.removeAll { $0.id == rule.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }

                HStack {
                    Button("Add Current Wi-Fi") {
                        guard let ssid = autoSwitch.currentSSID else { return }
                        addRule(ssid: ssid)
                    }
                    .disabled(!canAddCurrent)

                    Button("Add Rule") {
                        addRule(ssid: "")
                    }
                }
            }

            Section {
                HStack {
                    Text("Other Networks")
                    Spacer()
                    actionPickers($autoSwitch.otherNetworks)
                }
            } footer: {
                Text("Other Networks applies when no rule matches, including when not connected to Wi-Fi. “Keep” leaves the setting unchanged.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 680)
        .frame(minHeight: 360)
        .navigationTitle("Switch by Wi-Fi")
    }

    /// 一行内同时设置配置、TUN 和代理模式，选项文字自带含义，无需表头
    private func actionPickers(_ action: Binding<WiFiAction>) -> some View {
        HStack {
            Picker("Profile", selection: action.profileName) {
                Text("Keep Profile").tag(String?.none)
                ForEach(options(including: action.wrappedValue.profileName), id: \.self) { name in
                    Text(title(of: name)).tag(Optional(name))
                }
            }

            Picker("TUN Mode", selection: action.isTunEnabled) {
                Text("Keep TUN").tag(Bool?.none)
                Text("TUN On").tag(Optional(true))
                Text("TUN Off").tag(Optional(false))
            }

            Picker("Mode", selection: action.mode) {
                Text("Keep Mode").tag(ProxyMode?.none)
                ForEach(ProxyMode.allCases) { mode in
                    Text(mode.title).tag(Optional(mode))
                }
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// 规则引用的配置被删除后仍保留在选项中，以免选择被清空
    private func options(including name: String?) -> [String] {
        guard let name, !profileNames.contains(name) else { return profileNames }
        return profileNames + [name]
    }

    private func title(of name: String) -> String {
        profileNames.contains(name) ? name : String(localized: "\(name) (Deleted)")
    }

    /// 新规则默认沿用当前的配置、TUN 和代理模式
    private func addRule(ssid: String) {
        let profileName = profileStore.selected.flatMap { $0.isDeleted ? nil : $0.name }
        let action = WiFiAction(profileName: profileName, isTunEnabled: core.isTunEnabled, mode: core.mode)
        autoSwitch.rules.append(WiFiRule(ssid: ssid, action: action))
    }
}

/// 菜单中的入口按钮；菜单栏应用默认不在前台，需要主动激活才能让窗口获得焦点
struct WiFiAutoSwitchButton: View {
    var autoSwitch: WiFiAutoSwitch

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Switch by Wi-Fi…") {
            openWindow(id: WiFiAutoSwitchView.windowID)
            NSApplication.shared.activate()
        }
        .badge(autoSwitch.isEnabled ? String(localized: "On") : nil)
    }
}
