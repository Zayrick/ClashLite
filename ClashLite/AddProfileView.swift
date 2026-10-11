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
        case .subscription: "订阅"
        case .local: "本地文件"
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

    private var canAdd: Bool {
        guard !isLoading else { return false }
        switch source {
        case .subscription: return subscriptionURL != nil
        case .local: return fileURL != nil
        }
    }

    private var namePrompt: String {
        switch source {
        case .subscription: "可选，默认使用订阅提供的名称"
        case .local: "可选，默认使用文件名"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("类型", selection: $source) {
                    ForEach(ProfileSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                switch source {
                case .subscription:
                    TextField("订阅链接", text: $urlString, prompt: Text("https://"))
                case .local:
                    LabeledContent("配置文件") {
                        HStack {
                            Text(fileURL?.lastPathComponent ?? "未选择")
                                .foregroundStyle(fileURL == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("选择…") {
                                isImporterPresented = true
                            }
                        }
                    }
                }

                TextField("名称", text: $name, prompt: Text(namePrompt))

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
                    Text("正在下载…")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("取消", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("添加") {
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
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func add() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? nil : trimmedName
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
                try profileStore.importLocal(fileURL: fileURL, name: name)
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
        Button("新增配置…") {
            openWindow(id: AddProfileView.windowID)
            NSApplication.shared.activate()
        }
    }
}

#Preview {
    AddProfileView()
        .environment(ProfileStore())
}
