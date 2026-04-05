import SwiftUI

// MARK: - Configurations 弹窗（macOS 版，适配 Theme 暖色系）

struct ConfigurationsView: View {
    @Bindable var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0  // 0=Model Configs, 1=System Prompt

    // 本地编辑状态（确认后才应用）
    @State private var maxTokens: Double = 4000
    @State private var topK: Double = 64
    @State private var topP: Double = 0.95
    @State private var temperature: Double = 1.0
    @State private var selectedBackend = 1  // 0=CPU, 1=GPU
    @State private var systemPrompt: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            Text("Configurations")
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            // Tab 切换
            HStack(spacing: 0) {
                tabButton("Model Configs", tag: 0)
                tabButton("System Prompt", tag: 1)
            }
            .padding(.horizontal)

            Rectangle().fill(Theme.border).frame(height: 1)

            Group {
                if selectedTab == 0 {
                    modelConfigsTab
                } else {
                    systemPromptTab
                }
            }
            .frame(height: 360)

            Rectangle().fill(Theme.border).frame(height: 1)

            // 底部按钮
            HStack(spacing: 20) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .foregroundStyle(Theme.textSecondary)
                    .buttonStyle(.plain)
                Button("OK") {
                    applySettings()
                    dismiss()
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Theme.accent.opacity(0.15), in: Capsule())
                .buttonStyle(.plain)
            }
            .padding()
        }
        .frame(width: 420)
        .background(Theme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .preferredColorScheme(.dark)
        .onAppear { loadCurrentSettings() }
    }

    // MARK: - Tab 按钮

    private func tabButton(_ title: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tag }
        } label: {
            VStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(selectedTab == tag ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tag ? Theme.textPrimary : Theme.textTertiary)

                Rectangle()
                    .fill(selectedTab == tag ? Theme.accent : .clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Model Configs

    private var modelConfigsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                configSlider(
                    title: "Max Tokens",
                    value: $maxTokens,
                    range: 128...8192,
                    displayValue: "\(Int(maxTokens))"
                )
                configSlider(
                    title: "TopK",
                    value: $topK,
                    range: 1...128,
                    displayValue: "\(Int(topK))"
                )
                configSlider(
                    title: "TopP",
                    value: $topP,
                    range: 0...1,
                    displayValue: String(format: "%.2f", topP)
                )
                configSlider(
                    title: "Temperature",
                    value: $temperature,
                    range: 0...2,
                    displayValue: String(format: "%.2f", temperature)
                )

                // Accelerator
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose accelerator")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    HStack(spacing: 0) {
                        acceleratorButton("CPU", tag: 0)
                        acceleratorButton("GPU", tag: 1)
                    }
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
        .frame(maxHeight: 360)
    }

    // MARK: - System Prompt

    private var systemPromptTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $systemPrompt)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
                .frame(maxHeight: 280)

            Button("Restore default") {
                systemPrompt = engine.defaultSystemPrompt
            }
            .font(.subheadline)
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
        }
        .padding()
    }



    // MARK: - 配置 Slider

    private func configSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        displayValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 12) {
                Slider(value: value, in: range)
                    .tint(Theme.accent)

                Text(displayValue)
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.textPrimary.opacity(0.8))
                    .frame(width: 56)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Accelerator 按钮

    private func acceleratorButton(_ title: String, tag: Int) -> some View {
        Button {
            selectedBackend = tag
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    selectedBackend == tag ? Theme.bgHover : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 加载 / 应用

    private func loadCurrentSettings() {
        maxTokens = Double(engine.config.maxTokens)
        topK = Double(engine.config.topK)
        topP = engine.config.topP
        temperature = engine.config.temperature
        selectedBackend = engine.config.useGPU ? 1 : 0
        systemPrompt = engine.config.systemPrompt
    }

    private func applySettings() {
        let oldBackend = engine.config.useGPU
        engine.config.maxTokens = Int(maxTokens)
        engine.config.topK = Int(topK)
        engine.config.topP = topP
        engine.config.temperature = temperature
        engine.config.useGPU = selectedBackend == 1
        engine.config.systemPrompt = systemPrompt

        // 同步采样参数到 LLM（下次生成立即生效）
        engine.applySamplingConfig()

        // 如果 backend 变了，需要重载模型
        if oldBackend != engine.config.useGPU {
            engine.reloadModel()
        }
    }
}
