import Foundation

// MARK: - Prompt 构造器（Gemma 4 对话模板 + Function Calling）
//
// Gemma 4 E4B 使用新 token 格式：
//   <|turn>system\n ... <turn|>
//   <|turn>user\n ... <turn|>
//   <|turn>model\n ... <turn|>

struct PromptBuilder {

    static let defaultSystemPrompt = "你是 PhoneClaw，一个运行在本地的私人 AI 助手。你完全运行在设备上，不联网。"

    /// 构造完整 Prompt（包含工具定义 + 对话历史）
    static func build(
        userMessage: String,
        tools: [SkillInfo],
        history: [ChatMessage] = [],
        systemPrompt: String? = nil
    ) -> String {
        var prompt = "<|turn>system\n"

        // ★ 使用自定义 system prompt（如果有），否则用默认
        let basePrompt = systemPrompt ?? defaultSystemPrompt

        // 构建 Skill 概要列表（只列名称 + 一句话描述，不暴露 Tool）
        var skillListText = ""
        for skill in tools {
            skillListText += "- **\(skill.name)**: \(skill.description)\n"
        }

        // 处理 ___SKILLS___ 占位符
        if basePrompt.contains("___SKILLS___") {
            prompt += basePrompt.replacingOccurrences(of: "___SKILLS___", with: skillListText)
        } else {
            prompt += basePrompt
            if !tools.isEmpty {
                prompt += "\n\n你拥有以下能力（Skill）：\n\n" + skillListText
                prompt += "\n当用户的请求需要使用某个能力时，先调用 load_skill：\n<tool_call>\n{\"name\": \"load_skill\", \"arguments\": {\"skill\": \"能力名\"}}\n</tool_call>\n\n不需要能力时直接回复。用中文回答，简洁实用。"
            }
        }

        prompt += "\n<turn|>\n"

        // 对话历史（最近几轮，排除最后一条当前用户消息，避免重复）
        let recentHistory = history.suffix(12)
        for msg in recentHistory {
            // ★ 跳过最后一条 user 消息（等下面单独加）
            if msg.role == .user && msg.id == recentHistory.last?.id { continue }
            switch msg.role {
            case .user:
                prompt += "<|turn>user\n\(msg.content)<turn|>\n"
            case .assistant:
                prompt += "<|turn>model\n\(msg.content)<turn|>\n"
            case .system:
                if let skillName = msg.skillName {
                    prompt += "<|turn>model\n<tool_call>\n{\"name\": \"\(skillName)\", \"arguments\": {}}\n</tool_call><turn|>\n"
                }
            case .skillResult:
                let skillLabel = msg.skillName ?? "tool"
                prompt += "<|turn>user\n工具 \(skillLabel) 的执行结果：\(msg.content)<turn|>\n"
            }
        }

        // 当前用户消息
        prompt += "<|turn>user\n\(userMessage)<turn|>\n"
        prompt += "<|turn>model\n"

        return prompt
    }

    /// 构造工具/Skill 结果后的 follow-up prompt
    ///
    /// - isLoadSkill=true: load_skill 返回了 instructions，LLM 应按指令继续执行
    /// - isLoadSkill=false: Tool 执行完毕，LLM 应根据结果回答用户
    static func buildFollowUp(
        originalPrompt: String,
        modelResponse: String,
        skillName: String,
        skillResult: String,
        userQuestion: String,
        isLoadSkill: Bool = false
    ) -> String {
        var cleanedResponse = modelResponse
        for pat in ["<turn|>", "<end_of_turn>", "<eos>"] {
            cleanedResponse = cleanedResponse.replacingOccurrences(of: pat, with: "")
        }

        if isLoadSkill {
            // load_skill 返回的是 Skill instructions → 让 LLM 按指令继续
            return originalPrompt + cleanedResponse + """
            <turn|>
            <|turn>user
            Skill 指令已加载：
            \(skillResult)

            请根据以上指令，调用对应的工具来完成用户的请求："\(userQuestion)"
            <turn|>
            <|turn>model

            """
        } else {
            // Tool 执行结果 → 让 LLM 生成自然语言回复
            return originalPrompt + cleanedResponse + """
            <turn|>
            <|turn>user
            工具 \(skillName) 执行结果：
            \(skillResult)

            请根据以上结果简洁回答我的问题："\(userQuestion)"
            <turn|>
            <|turn>model

            """
        }
    }
}
