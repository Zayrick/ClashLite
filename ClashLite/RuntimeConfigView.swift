//
//  RuntimeConfigView.swift
//  ClashLite
//
//  Created by Zayrick on 10/12/26.
//

import SwiftUI

/// 只读查看内核正在使用的配置，即配置文件依次合并配置覆写、全局覆写和应用设置后的结果
struct RuntimeConfigView: View {
    static let windowID = "runtime-config"

    @Environment(CoreManager.self) private var core

    var body: some View {
        Group {
            if let runtimeConfig = core.runtimeConfig {
                YAMLEditor(text: .constant(runtimeConfig), hint: "由配置、覆写和应用设置合并生成，内核重新加载后自动刷新")
            } else {
                ContentUnavailableView("内核未运行", systemImage: "doc.text", description: Text("内核运行后可查看传入内核的配置"))
                    .frame(minWidth: 520, minHeight: 360)
            }
        }
        .navigationTitle("运行时配置")
    }
}
