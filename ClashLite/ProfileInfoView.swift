//
//  ProfileInfoView.swift
//  ClashLite
//
//  Created by Zayrick on 11/15/26.
//

import SwiftUI

/// 配置信息：重命名、修改订阅链接、删除配置。
/// 修改订阅链接时先下载并校验新链接的配置，通过后才替换，避免填错链接导致配置不可用
struct ProfileInfoView: View {
    static let windowID = "profile-info"

    let name: String

    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.dismiss) private var dismiss

    @State private var newName: String
    @State private var urlString: String?
    @State private var isSaving = false
    @State private var isDeleteConfirmationPresented = false
    @State private var errorMessage: String?

    init(name: String) {
        self.name = name
        _newName = State(initialValue: name)
    }

    private var profile: Profile? {
        profileStore.profiles.first { $0.name == name && !$0.isDeleted }
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 与新增配置一致，只接受 http(s) 链接
    private var subscriptionURL: URL? {
        guard let urlString else { return nil }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }

    /// 订阅链接有改动时为新链接
    private var changedURL: URL? {
        guard let url = subscriptionURL, url != profile?.subscription?.url else { return nil }
        return url
    }

    private var isBusy: Bool {
        isSaving || profileStore.updatingNames.contains(name)
    }

    private var canSave: Bool {
        guard !isBusy, !trimmedName.isEmpty else { return false }
        if urlString != nil, subscriptionURL == nil { return false }
        return trimmedName != name || changedURL != nil
    }

    var body: some View {
        Group {
            if let profile {
                form(profile)
            } else {
                ContentUnavailableView(
                    "Unable to Open Profile",
                    systemImage: "exclamationmark.triangle",
                    description: Text(ProfileError.notFound(name).localizedDescription)
                )
                .frame(width: 420, height: 240)
            }
        }
        .navigationTitle("Profile Info - \(name)")
        .onAppear {
            if urlString == nil, let url = profile?.subscription?.url {
                urlString = url.absoluteString
            }
        }
    }

    private func form(_ profile: Profile) -> some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("Type", value: profile.subscription == nil ? ProfileSource.local.title : ProfileSource.subscription.title)

                if let subscription = profile.subscription {
                    TextField("Subscription URL", text: Binding(
                        get: { urlString ?? "" },
                        set: { urlString = $0 }
                    ), prompt: Text(verbatim: "https://"))

                    LabeledContent("Last Updated", value: subscription.updatedAt.formatted(date: .numeric, time: .shortened))
                }

                TextField("Name", text: $newName, prompt: Text("Required, also used as the file name"))

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .disabled(isBusy)

            HStack {
                Button("Delete Profile…", role: .destructive) {
                    isDeleteConfirmationPresented = true
                }
                .disabled(isBusy)

                Spacer()

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .foregroundStyle(.secondary)
                }

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    Task { await save(profile) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 420)
        .confirmationDialog(
            "Delete “\(name)”?",
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button("Move to Trash", role: .destructive) {
                delete(profile)
            }
        } message: {
            Text("The profile file will be moved to the Trash, and its profile override will be removed.")
        }
    }

    /// 先检查新名称，再在原名称下更新订阅，最后重命名，避免订阅已更新而名称不可用
    private func save(_ profile: Profile) async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }

        do {
            if trimmedName != name {
                try profileStore.checkName(trimmedName, excluding: name)
            }
            if let url = changedURL {
                try await profileStore.update(profile, from: url)
            }
            if trimmedName != name, let current = profileStore.profiles.first(where: { $0.name == name && !$0.isDeleted }) {
                try profileStore.rename(current, to: trimmedName)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ profile: Profile) {
        do {
            try profileStore.delete(profile)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    ProfileInfoView(name: "Example")
        .environment(ProfileStore())
}
