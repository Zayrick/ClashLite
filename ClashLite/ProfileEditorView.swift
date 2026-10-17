//
//  ProfileEditorView.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI

/// 直接编辑配置文件，保存前由内核校验，正在使用时立即重新加载；远程订阅配置只读，修改需使用配置覆写
struct ProfileEditorView: View {
    static let windowID = "profile-editor"

    let name: String

    @Environment(CoreManager.self) private var core
    @Environment(ProfileStore.self) private var profileStore

    @State private var text: String?
    @State private var loadError: String?

    private var profile: Profile? {
        profileStore.profiles.first { $0.name == name && !$0.isDeleted }
    }

    private var isReadOnly: Bool {
        profile?.subscription != nil
    }

    private var hint: LocalizedStringKey {
        isReadOnly
            ? "Remote profiles are read-only. Use a profile override to make changes."
            : "The profile itself and the result of applying overrides are validated before saving."
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Unable to Open Profile", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(minWidth: 520, minHeight: 360)
            } else if let binding = Binding($text) {
                YAMLEditor(text: binding, hint: hint, save: isReadOnly ? nil : { try await save() })
            } else {
                ProgressView()
                    .frame(minWidth: 520, minHeight: 360)
            }
        }
        .navigationTitle(isReadOnly ? "View Profile - \(name)" : "Edit Profile - \(name)")
        .onAppear(perform: load)
    }

    private func load() {
        guard text == nil else { return }
        guard let profile else {
            loadError = ProfileError.notFound(name).localizedDescription
            return
        }
        do {
            text = try String(contentsOf: profile.fileURL, encoding: .utf8)
        } catch {
            NSLog("读取配置失败：\(error)")
            loadError = ProfileError.readFailed.localizedDescription
        }
    }

    private func save() async throws {
        guard let profile, let text else { throw ProfileError.notFound(name) }
        try await profileStore.saveContent(text, of: profile)
        if profileStore.selectedName == name {
            core.reload()
        }
    }
}
