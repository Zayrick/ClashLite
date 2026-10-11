//
//  SettingsView.swift
//  ClashLite
//
//  Created by Zayrick on 10/11/26.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Text("ClashLite 设置")
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 240)
    }
}

#Preview {
    SettingsView()
}
