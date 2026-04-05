import Foundation

// MARK: - 模型/推理配置

@Observable
class ModelConfig {
    var maxTokens = 4000
    var topK = 64
    var topP = 0.95
    var temperature = 1.0
    var useGPU = true
    var systemPrompt = """
    你是 PhoneClaw，一个运行在本地设备上的私人 AI 助手。你完全离线运行，不联网，保护用户隐私。

    你拥有以下能力（Skill）：

    ___SKILLS___

    当用户的请求需要使用某个能力时，先调用 load_skill 加载该能力的详细指令：
    <tool_call>
    {"name": "load_skill", "arguments": {"skill": "能力名"}}
    </tool_call>

    不需要能力时直接回复。用中文回答，简洁实用。
    """
}

// MARK: - 聊天消息

struct ChatMessage: Identifiable {
    let id: UUID
    var role: Role
    var content: String
    let timestamp = Date()
    var skillName: String? = nil

    init(role: Role, content: String, skillName: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.skillName = skillName
    }

    /// 保持 id 不变地更新内容（避免 SwiftUI 重建视图）
    mutating func update(content: String) {
        // 只在内容真正变化时更新，减少不必要的 SwiftUI 通知
        guard self.content != content else { return }
        self.content = content
    }

    mutating func update(role: Role, content: String, skillName: String? = nil) {
        self.role = role
        self.content = content
        self.skillName = skillName
    }

    enum Role {
        case user, assistant, system, skillResult
    }
}

// MARK: - Agent Engine

@Observable
class AgentEngine {
    
    let llm = LocalLLMService()
    var messages: [ChatMessage] = []
    var isProcessing = false
    var config = ModelConfig()
    
    // 文件驱动的 Skill 系统
    let skillLoader = SkillLoader()
    let toolRegistry = ToolRegistry.shared

    // Skill 条目（给 UI 管理用，可开关）
    var skillEntries: [SkillEntry] = []

    // 默认系统提示
    var defaultSystemPrompt: String {
        ModelConfig().systemPrompt
    }

    /// 已启用的 Skill 概要（只含 Skill 级别信息，不含 Tool 细节）
    /// 用于 system prompt 和 UI chip
    var enabledSkillInfos: [SkillInfo] {
        skillEntries.filter(\.isEnabled).map {
            SkillInfo(name: $0.id, description: $0.description,
                     displayName: $0.name, icon: $0.icon, samplePrompt: $0.samplePrompt)
        }
    }

    init() {
        loadSkillEntries()
    }

    /// 从 SKILL.md 文件加载所有 Skill
    private func loadSkillEntries() {
        let definitions = skillLoader.discoverSkills()
        self.skillEntries = definitions.map { SkillEntry(from: $0, registry: toolRegistry) }
    }

    /// 热重载所有 Skill（编辑/新增 SKILL.md 后调用）
    func reloadSkills() {
        // 保存当前启用状态
        let enabledState = Dictionary(uniqueKeysWithValues: skillEntries.map { ($0.id, $0.isEnabled) })
        loadSkillEntries()
        // 恢复启用状态
        for i in skillEntries.indices {
            if let wasEnabled = enabledState[skillEntries[i].id] {
                skillEntries[i].isEnabled = wasEnabled
                skillLoader.setEnabled(skillEntries[i].id, enabled: wasEnabled)
            }
        }
    }

    // MARK: - Skill 查找（文件驱动）

    /// 根据 Skill ID 或 Tool 名找到 Skill ID
    private func findSkillId(for name: String) -> String? {
        // 先按 Skill ID 匹配
        if skillLoader.getDefinition(name) != nil { return name }
        // 再按 Tool 名反查
        return skillLoader.findSkillId(forTool: name)
    }

    /// 根据 Skill ID 或 Tool 名找到 displayName
    private func findDisplayName(for name: String) -> String {
        if let skillId = findSkillId(for: name),
           let def = skillLoader.getDefinition(skillId) {
            return def.metadata.name
        }
        return name
    }

    /// 处理 load_skill 调用 → 返回 SKILL.md 的 body 作为 instructions
    private func handleLoadSkill(skillName: String) -> String? {
        // 检查是否启用
        guard let entry = skillEntries.first(where: { $0.id == skillName }),
              entry.isEnabled else {
            return nil
        }
        // 加载 SKILL.md body（渐进式披露）
        return skillLoader.loadBody(skillId: skillName)
    }

    /// 处理具体 Tool 调用 → 通过 ToolRegistry 执行
    private func handleToolExecution(toolName: String, args: [String: Any]) async throws -> String {
        return try await toolRegistry.execute(name: toolName, args: args)
    }
    
    // MARK: - 初始化
    
    func setup() {
        applySamplingConfig()
        let backend = config.useGPU ? "gpu" : "cpu"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.llm.loadModel(backend: backend)
        }
    }

    /// 将 config 中的采样参数同步到 LLM
    func applySamplingConfig() {
        llm.samplingTopK = Int32(config.topK)
        llm.samplingTopP = Float(config.topP)
        llm.samplingTemperature = Float(config.temperature)
        llm.maxOutputTokens = config.maxTokens
    }

    /// 重新加载模型（backend 变化时调用）
    func reloadModel() {
        let backend = config.useGPU ? "gpu" : "cpu"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.llm.loadModel(backend: backend)
        }
    }
    
    // MARK: - 处理用户输入（LiteRT-LM C API 流式输出）
    
    func processInput(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessing else { return }
        guard llm.isLoaded else {
            messages.append(ChatMessage(role: .system, content: "⏳ 模型还在加载中..."))
            return
        }
        
        messages.append(ChatMessage(role: .user, content: trimmed))
        isProcessing = true

        // ★ 每次生成前同步采样参数
        applySamplingConfig()

        let activeSkillInfos = enabledSkillInfos
        let prompt = PromptBuilder.build(
            userMessage: trimmed,
            tools: activeSkillInfos,
            history: messages,
            systemPrompt: config.systemPrompt
        )
        
        // 占位消息（▍ 不可见，只显示 spinner）
        messages.append(ChatMessage(role: .assistant, content: "▍"))
        let msgIndex = messages.count - 1

        var detectedToolCall = false
        var buffer = ""           // 缓冲区：积累 token，确认不是 tool_call 后才显示
        var bufferFlushed = false // 一旦 flush 过，后续 token 直接显示

        llm.generateStream(prompt: prompt) { [weak self] token in
            guard let self = self else { return }

            if detectedToolCall {
                buffer += token
                return  // 静默积累，不更新 UI — 由 executeToolChain 统一管理卡片
            }

            buffer += token

            if buffer.contains("<tool_call>") {
                detectedToolCall = true
                return  // 不转换消息角色，保持 assistant "▍" → 显示思考点
            }

            if !bufferFlushed {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return }
                if "<tool_call>".hasPrefix(trimmed) { return }
                bufferFlushed = true
                self.messages[msgIndex].update(content: self.cleanOutputStreaming(buffer))
                return
            }

            // ★ 原地更新 content，保持 id 不变 → 无重排
            // 用 buffer（完整原始文本）做清理，避免累积误差
            let cleaned = self.cleanOutputStreaming(buffer)
            if !cleaned.isEmpty {
                self.messages[msgIndex].update(content: cleaned)
            }
        } onComplete: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let fullText):
                log("[Agent] 1st raw: \(fullText.prefix(300))")

                if self.parseToolCall(fullText) != nil {
                    // ★ 清除原始占位消息（executeToolChain 会创建正确的 skill 卡片）
                    self.messages[msgIndex].update(content: "")
                    // ★ 进入工具链循环（支持多轮）
                    Task {
                        await self.executeToolChain(
                            prompt: prompt,
                            fullText: fullText,
                            userQuestion: trimmed
                        )
                    }
                    return
                } else {
                    let cleaned = self.cleanOutput(fullText)
                    self.messages[msgIndex].update(
                        content: cleaned.isEmpty ? "（无回复）" : cleaned
                    )
                }
            case .failure(let error):
                self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
            }
            self.isProcessing = false
        }
    }
    
    // MARK: - Skill 结果后的后续推理（支持多轮工具链）

    /// 执行一次 LLM 推理并返回原始输出
    private func streamLLM(prompt: String, msgIndex: Int) async -> String? {
        var buffer = ""
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var toolCallDetected = false
            var bufferFlushed = false  // 是否已确认不是 tool_call 前缀
            llm.generateStream(prompt: prompt) { [weak self] token in
                guard let self = self else { return }
                buffer += token

                // 检测到 tool_call 后静默积累
                if toolCallDetected { return }
                if buffer.contains("<tool_call>") {
                    toolCallDetected = true
                    // 清除之前可能已显示的过程文字
                    if bufferFlushed && self.messages[msgIndex].role == .assistant {
                        self.messages[msgIndex].update(content: "")
                    }
                    return
                }

                // 等待确认不是 tool_call 前缀再显示
                if !bufferFlushed {
                    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return }
                    if "<tool_call>".hasPrefix(trimmed) { return }
                    bufferFlushed = true
                }

                // 普通文字流式显示
                let cleaned = self.cleanOutputStreaming(buffer)
                if !cleaned.isEmpty && self.messages[msgIndex].role == .assistant {
                    self.messages[msgIndex].update(content: cleaned)
                }
            } onComplete: { [weak self] result in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                switch result {
                case .success(let text):
                    log("[Agent] LLM raw: \(text.prefix(300))")
                    continuation.resume(returning: text)
                case .failure(let error):
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 执行 tool_call → skill/tool → follow-up 循环（最多 maxRounds 轮）
    ///
    /// 支持两种调用：
    ///   - load_skill: 逐级披露，返回 Skill 的完整 instructions + Tool 定义
    ///   - 具体 tool:  执行原生 API
    private func executeToolChain(
        prompt: String,
        fullText: String,
        userQuestion: String,
        round: Int = 1,
        maxRounds: Int = 10
    ) async {
        guard round <= maxRounds else {
            log("[Agent] 达到最大工具链轮数 \(maxRounds)")
            isProcessing = false
            return
        }

        guard let call = parseToolCall(fullText) else {
            let cleaned = cleanOutput(fullText)
            if let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[lastAssistant].update(content: cleaned.isEmpty ? "（无回复）" : cleaned)
            }
            isProcessing = false
            return
        }

        log("[Agent] Round \(round): tool_call name=\(call.name)")

        // ── load_skill：逐级披露，返回 Skill 指令 ──
        if call.name == "load_skill" {
            // ★ 检查是否有多个 load_skill（模型可能一次请求多个能力）
            let allCalls = parseAllToolCalls(fullText)
            let loadSkillCalls = allCalls.filter { $0.name == "load_skill" }

            var allInstructions = ""
            for lsCall in loadSkillCalls {
                let skillName = (lsCall.arguments["skill"] as? String)
                             ?? (lsCall.arguments["name"] as? String)
                             ?? ""
                log("[Agent] load_skill: \(skillName)")

                let displayName = findDisplayName(for: skillName)
                messages.append(ChatMessage(role: .system, content: "identified", skillName: displayName))
                let cardIdx = messages.count - 1

                guard let instructions = handleLoadSkill(skillName: skillName) else {
                    messages[cardIdx].update(role: .system, content: "done", skillName: displayName)
                    continue
                }

                try? await Task.sleep(for: .milliseconds(300))
                messages[cardIdx].update(role: .system, content: "loaded", skillName: displayName)
                messages.append(ChatMessage(role: .skillResult, content: instructions, skillName: skillName))
                allInstructions += instructions + "\n\n"
            }

            guard !allInstructions.isEmpty else {
                isProcessing = false
                return
            }

            // 构建 follow-up：把所有 instructions 注入 LLM 上下文
            let followUpPrompt = PromptBuilder.buildFollowUp(
                originalPrompt: prompt,
                modelResponse: fullText,
                skillName: "load_skill",
                skillResult: allInstructions,
                userQuestion: userQuestion,
                isLoadSkill: true
            )

            messages.append(ChatMessage(role: .assistant, content: "▍"))
            let followUpIndex = messages.count - 1

            guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex) else {
                isProcessing = false
                return
            }

            if parseToolCall(nextText) != nil {
                log("[Agent] load_skill 后检测到 tool 调用 (round \(round + 1))")
                messages[followUpIndex].update(content: "")
                await executeToolChain(
                    prompt: followUpPrompt, fullText: nextText,
                    userQuestion: userQuestion, round: round + 1, maxRounds: maxRounds
                )
            } else {
                let cleaned = cleanOutput(nextText)
                messages[followUpIndex].update(content: cleaned.isEmpty ? "（无回复）" : cleaned)
                isProcessing = false
            }
            return
        }

        // ── 具体 Tool 调用：执行原生 API ──

        // 定位所属 Skill（用于 UI 展示）
        let ownerSkillId = findSkillId(for: call.name)
        let displayName = findDisplayName(for: call.name)

        // 找已有的 Skill 卡片（load_skill 阶段创建的，状态为 "loaded"）
        // 复用它来继续显示 Step 3: executing
        let cardIndex: Int
        if let idx = messages.lastIndex(where: {
            $0.role == .system && ($0.skillName == displayName || $0.skillName == call.name)
            && ($0.content == "identified" || $0.content == "loaded")
        }) {
            cardIndex = idx
        } else {
            // 没有已有卡片（直接 Tool 调用，跳过 load_skill），创建新卡片
            messages.append(ChatMessage(role: .system, content: "identified", skillName: displayName))
            cardIndex = messages.count - 1
        }

        // ★ 未知工具：关闭卡片 + 报错
        guard ownerSkillId != nil else {
            log("[Agent] 未知工具: \(call.name)")
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .assistant, content: "⚠️ 未知工具: \(call.name)"))
            isProcessing = false
            return
        }

        // ★ Skill 未启用：关闭卡片 + 报错
        let enabledIds = Set(skillEntries.filter(\.isEnabled).map(\.id))
        guard enabledIds.contains(ownerSkillId!) else {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .assistant, content: "⚠️ Skill \(displayName) 未启用"))
            isProcessing = false
            return
        }

        // Step 3: executing（带具体 Tool 名）
        messages[cardIndex].update(role: .system, content: "executing:\(call.name)", skillName: displayName)

        do {
            let toolResult = try await handleToolExecution(toolName: call.name, args: call.arguments)
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .skillResult, content: toolResult, skillName: call.name))
            log("[Agent] Tool \(call.name) round \(round) done")

            let followUpPrompt = PromptBuilder.buildFollowUp(
                originalPrompt: prompt,
                modelResponse: fullText,
                skillName: call.name,
                skillResult: toolResult,
                userQuestion: userQuestion
            )

            messages.append(ChatMessage(role: .assistant, content: "▍"))
            let followUpIndex = messages.count - 1

            guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex) else {
                isProcessing = false
                return
            }

            if !parseAllToolCalls(nextText).isEmpty {
                log("[Agent] 检测到第 \(round + 1) 轮工具调用")
                messages[followUpIndex].update(content: "")
                await executeToolChain(
                    prompt: followUpPrompt, fullText: nextText,
                    userQuestion: userQuestion, round: round + 1, maxRounds: maxRounds
                )
            } else {
                let cleaned = cleanOutput(nextText)
                messages[followUpIndex].update(content: cleaned.isEmpty ? "（无回复）" : cleaned)
                isProcessing = false
            }
        } catch {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .system, content: "❌ Tool 执行失败: \(error)"))
            isProcessing = false
        }
    }

    // MARK: - 工具

    func clearMessages() {
        messages.removeAll()
    }
    
    func setAllSkills(enabled: Bool) {
        for i in skillEntries.indices {
            skillEntries[i].isEnabled = enabled
        }
    }
    
    // MARK: - 解析
    
    private func parseToolCall(_ text: String) -> (name: String, arguments: [String: Any])? {
        return parseAllToolCalls(text).first
    }

    /// 解析所有 tool_call（支持模型在一次回复中输出多个）
    private func parseAllToolCalls(_ text: String) -> [(name: String, arguments: [String: Any])] {
        var results: [(name: String, arguments: [String: Any])] = []
        let patterns = [
            "<tool_call>\\s*(\\{.*?\\})\\s*</tool_call>",
            "```json\\s*(\\{.*?\\})\\s*```",
            "<function_call>\\s*(\\{.*?\\})\\s*</function_call>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                if let jsonRange = Range(match.range(at: 1), in: text) {
                    let json = String(text[jsonRange])
                    if let data = json.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let name = dict["name"] as? String {
                        results.append((name, dict["arguments"] as? [String: Any] ?? [:]))
                    }
                }
            }
            if !results.isEmpty { break }
        }
        return results
    }
    
    /// 从部分流式内容中提取 skill 名（不需要完整 JSON）
    private func extractSkillName(from text: String) -> String? {
        // 匹配 "name": "xxx" 或 "name":"xxx"
        guard let regex = try? NSRegularExpression(pattern: "\"name\"\\s*:\\s*\"([^\"]+)\""),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[nameRange])
    }
    
    /// 流式输出时的轻量清理：只移除已完成的 token，不做尾部裁剪
    /// 保证文本长度单调递增，避免视觉跳动
    private func cleanOutputStreaming(_ text: String) -> String {
        var result = text

        // ★ 截断：遇到 <tool_call> 只保留之前的内容
        if let tcRange = result.range(of: "<tool_call>") {
            result = String(result[result.startIndex..<tcRange.lowerBound])
        }

        // 截断：第一个 end-of-turn token
        let endPatterns = ["<turn|>", "<end_of_turn>", "<eos>"]
        for pat in endPatterns {
            if let range = result.range(of: pat) {
                result = String(result[result.startIndex..<range.lowerBound])
                break
            }
        }

        // 移除完整闭合的 <tool_call>...</tool_call> 块
        if let regex = try? NSRegularExpression(pattern: "<tool_call>.*?</tool_call>", options: .dotMatchesLineSeparators) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // 只移除已完整闭合的 token（不动尾部未闭合的）
        result = result.replacingOccurrences(
            of: "<\\|?[/a-z_]+\\|?>",
            with: "",
            options: .regularExpression
        )

        // 清理开头的 "model\n"
        if result.hasPrefix("model\n") {
            result = String(result.dropFirst(6))
        } else if result == "model" {
            return ""
        }

        // ★ 流式时不做 trimmingCharacters，避免尾部空白被反复移除/恢复
        // 只移除开头空白
        return String(result.drop(while: { $0.isWhitespace || $0.isNewline }))
    }

    /// 完成时的完整清理：包括尾部裁剪和空白处理
    private func cleanOutput(_ text: String) -> String {
        var result = text

        // ★ 移除完整的 <tool_call>...</tool_call> 块
        if let regex = try? NSRegularExpression(pattern: "<tool_call>.*?</tool_call>", options: .dotMatchesLineSeparators) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // ★ 截断：遇到未闭合的 <tool_call 也截断
        if let tcRange = result.range(of: "<tool_call>") {
            result = String(result[result.startIndex..<tcRange.lowerBound])
        }

        // 截断：第一个 end-of-turn token
        let endPatterns = ["<turn|>", "<end_of_turn>", "<eos>"]
        for pat in endPatterns {
            if let range = result.range(of: pat) {
                result = String(result[result.startIndex..<range.lowerBound])
                break
            }
        }

        // 清理所有 Gemma 4 特殊 token
        result = result.replacingOccurrences(
            of: "<\\|?[/a-z_]+\\|?>",
            with: "",
            options: .regularExpression
        )

        // 清理未闭合的尾部 < 残留（仅完成时做）
        if let lastOpen = result.lastIndex(of: "<") {
            let tail = String(result[lastOpen...])
            let tailBody = tail.dropFirst()
            if !tailBody.isEmpty && tailBody.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "/" || $0 == "|" }) {
                result = String(result[result.startIndex..<lastOpen])
            }
        }

        // 清理开头的 "model\n"
        if result.hasPrefix("model\n") {
            result = String(result.dropFirst(6))
        } else if result == "model" {
            result = ""
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
