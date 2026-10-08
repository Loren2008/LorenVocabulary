import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var baseURL = "https://api.deepseek.com/v1"
    @State private var revealAPIKey = false
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DeepSeek 设置")
                    .font(.title2.bold())
                Text("密钥只保存在这台 Mac 的钥匙串中，不会写入项目或 App Bundle。")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Form {
                LabeledContent("API Key") {
                    HStack {
                        Group {
                            if revealAPIKey {
                                TextField("输入 DeepSeek API Key", text: $apiKey)
                            } else {
                                SecureField("输入 DeepSeek API Key", text: $apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Toggle("显示", isOn: $revealAPIKey)
                            .toggleStyle(.checkbox)
                    }
                }

                LabeledContent("Base URL") {
                    TextField("https://api.deepseek.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)

            if let statusMessage {
                Label(statusMessage, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundColor(isError ? .red : .green)
            }

            HStack {
                Button("清除密钥", role: .destructive) {
                    apiKey = ""
                    save()
                }
                Spacer()
                Button("完成") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            apiKey = Config.deepseekAPIKey
            baseURL = Config.deepseekBaseURL
        }
    }

    private func save() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            isError = true
            statusMessage = "Base URL 必须是有效的 HTTPS 地址。"
            return
        }

        do {
            try Config.saveDeepSeekSettings(apiKey: apiKey, baseURL: trimmedURL)
            isError = false
            statusMessage = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "API Key 已从钥匙串清除。"
                : "设置已安全保存。"
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }
}
