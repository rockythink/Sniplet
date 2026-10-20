import SwiftUI

struct OCRResultView: View {
    let result: OCRResult?
    let isRecognizing: Bool
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("文字识别", systemImage: "text.viewfinder")
                    .font(.headline)
                Spacer()
                if isRecognizing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在本机识别文字")
                    Text("正在识别…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if isRecognizing {
                Text("正在识别当前最终图像，文字仅在本机处理。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("文字识别失败：\(errorMessage)")
                Button("重试识别", systemImage: "arrow.clockwise", action: retry)
                    .help("重新在本机识别当前图像中的文字")
            } else if let result {
                if !result.missingLanguages.isEmpty {
                    Text("本机不支持以下首选识别语言：\(languageNames(result.missingLanguages))。结果可能缺少对应文字。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if result.text.isEmpty {
                    Text("未识别到文字")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("识别完成，未识别到文字")
                } else {
                    LocalSelectableText(text: result.text)
                        .frame(minHeight: 96, idealHeight: 140, maxHeight: 200)
                        .accessibilityLabel("识别结果，可选择并复制文字")
                }
            } else {
                Text("点击“复制文字”可在本机识别当前图像。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func languageNames(_ languages: [String]) -> String {
        languages.map { language in
            switch language {
            case "zh-Hans": "简体中文"
            case "zh-Hant": "繁體中文"
            case "en-US": "英语"
            default: language
            }
        }.joined(separator: "、")
    }
}
