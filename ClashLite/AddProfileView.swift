//
//  AddProfileView.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI
import UniformTypeIdentifiers

enum ProfileSource: String, CaseIterable, Identifiable {
    case subscription
    case local

    var id: Self { self }

    var title: String {
        switch self {
        case .subscription: String(localized: "Subscription")
        case .local: String(localized: "Local File")
        }
    }
}

struct AddProfileView: View {
    static let windowID = "add-profile"

    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.dismiss) private var dismiss

    @State private var source: ProfileSource = .subscription
    @State private var urlString = ""
    @State private var fileURL: URL?
    @State private var isImporterPresented = false
    @State private var name = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var subscriptionURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        guard !isLoading, !trimmedName.isEmpty else { return false }
        switch source {
        case .subscription: return subscriptionURL != nil
        case .local: return fileURL != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Type", selection: $source) {
                    ForEach(ProfileSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                switch source {
                case .subscription:
                    TextField("Subscription URL", text: $urlString, prompt: Text(verbatim: "https://"))
                case .local:
                    LabeledContent("Config File") {
                        HStack {
                            Text(fileURL?.lastPathComponent ?? String(localized: "None Selected"))
                                .foregroundStyle(fileURL == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") {
                                isImporterPresented = true
                            }
                        }
                    }
                }

                TextField("Name", text: $name, prompt: Text("Required, also used as the file name"))

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .disabled(isLoading)

            HStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    Task { await add() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 420)
        .onChange(of: source) {
            errorMessage = nil
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.yaml]) { result in
            switch result {
            case .success(let url):
                fileURL = url
                // 默认沿用原始文件名，用户可再修改
                name = url.deletingPathExtension().lastPathComponent
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func add() async {
        let name = trimmedName
        errorMessage = nil

        do {
            switch source {
            case .subscription:
                guard let url = subscriptionURL else { return }
                isLoading = true
                defer { isLoading = false }
                try await profileStore.addSubscription(url: url, name: name)
            case .local:
                guard let fileURL else { return }
                isLoading = true
                defer { isLoading = false }
                try await profileStore.importLocal(fileURL: fileURL, name: name)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 菜单中的入口按钮；菜单栏应用默认不在前台，需要主动激活才能让窗口获得焦点
struct AddProfileButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Add Profile…") {
            openWindow(id: AddProfileView.windowID)
            NSApplication.shared.activate()
        }
    }
}

#Preview {
    AddProfileView()
        .environment(ProfileStore())
}
