import Foundation
import Yams

// MARK: - SKILL.md 解析器 + 加载器
//
// 参考 Vera 项目的 skill_loader.py，实现 Swift 版。
// 渐进式加载：
//   1. 启动时：只加载 YAML frontmatter（元数据）
//   2. load_skill 时：加载完整 body（指令体）

// MARK: - 数据模型

struct SkillExample {
    let query: String
    let scenario: String
}

struct SkillMetadata {
    let id: String              // 目录名 "clipboard"
    let name: String            // "剪贴板"
    let description: String
    let version: String
    let icon: String
    let disabled: Bool
    let triggers: [String]
    let allowedTools: [String]
    let examples: [SkillExample]
}

struct SkillDefinition: Identifiable {
    let id: String
    let filePath: URL
    let metadata: SkillMetadata
    var body: String?           // Markdown body（懒加载）
    var isEnabled: Bool

    /// 完整的 SKILL.md 原始内容
    var rawContent: String? {
        try? String(contentsOf: filePath, encoding: .utf8)
    }
}

// MARK: - Skill Loader

class SkillLoader {

    let skillsDirectory: URL
    private var cache: [String: SkillDefinition] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.skillsDirectory = appSupport.appendingPathComponent("PhoneClaw/skills", isDirectory: true)
        ensureDefaultSkills()
    }

    // MARK: - 公开接口

    /// 发现并加载所有 Skill 的元数据
    func discoverSkills() -> [SkillDefinition] {
        cache.removeAll()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var results: [SkillDefinition] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            let skillFile = item.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else { continue }

            let skillId = item.lastPathComponent
            if let def = loadDefinition(skillId: skillId, file: skillFile) {
                cache[skillId] = def
                results.append(def)
            }
        }
        return results
    }

    /// 完整加载 Skill（包括 body）— load_skill 时调用
    func loadBody(skillId: String) -> String? {
        if let cached = cache[skillId], cached.body != nil {
            return cached.body
        }
        let skillFile = skillsDirectory
            .appendingPathComponent(skillId, isDirectory: true)
            .appendingPathComponent("SKILL.md")

        guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
        let body = parseBody(content)
        cache[skillId]?.body = body
        return body
    }

    /// 保存 SKILL.md（编辑后写回）
    func saveSkill(skillId: String, content: String) throws {
        let skillFile = skillsDirectory
            .appendingPathComponent(skillId, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        try content.write(to: skillFile, atomically: true, encoding: .utf8)
        // 清缓存，下次重新解析
        cache.removeValue(forKey: skillId)
    }

    /// 重新加载所有（热更新入口）
    func reloadAll() -> [SkillDefinition] {
        return discoverSkills()
    }

    /// 根据工具名反查 Skill ID
    func findSkillId(forTool toolName: String) -> String? {
        for (id, def) in cache {
            if def.metadata.allowedTools.contains(toolName) {
                return id
            }
        }
        return nil
    }

    /// 获取缓存的 SkillDefinition
    func getDefinition(_ skillId: String) -> SkillDefinition? {
        cache[skillId]
    }

    /// 更新启用状态
    func setEnabled(_ skillId: String, enabled: Bool) {
        cache[skillId]?.isEnabled = enabled
    }

    // MARK: - 解析

    private func loadDefinition(skillId: String, file: URL) -> SkillDefinition? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        guard let frontmatter = parseFrontmatter(content) else { return nil }

        let metadata = SkillMetadata(
            id: skillId,
            name: frontmatter["name"] as? String ?? skillId,
            description: frontmatter["description"] as? String ?? "",
            version: frontmatter["version"] as? String ?? "1.0.0",
            icon: frontmatter["icon"] as? String ?? "wrench",
            disabled: frontmatter["disabled"] as? Bool ?? false,
            triggers: frontmatter["triggers"] as? [String] ?? [],
            allowedTools: frontmatter["allowed-tools"] as? [String] ?? [],
            examples: parseExamples(frontmatter["examples"])
        )

        return SkillDefinition(
            id: skillId,
            filePath: file,
            metadata: metadata,
            body: nil, // 懒加载
            isEnabled: !metadata.disabled
        )
    }

    private func parseFrontmatter(_ content: String) -> [String: Any]? {
        // 匹配 --- ... --- 包裹的 YAML
        guard let regex = try? NSRegularExpression(
            pattern: "^---\\s*\\n(.*?)\\n---\\s*\\n",
            options: .dotMatchesLineSeparators
        ) else { return nil }

        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let yamlRange = Range(match.range(at: 1), in: content) else { return nil }

        let yamlString = String(content[yamlRange])
        // 用 Yams 解析
        guard let parsed = try? Yams.load(yaml: yamlString) as? [String: Any] else { return nil }
        return parsed
    }

    private func parseBody(_ content: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "^---\\s*\\n.*?\\n---\\s*\\n(.*)$",
            options: .dotMatchesLineSeparators
        ) else { return content }

        let range = NSRange(content.startIndex..., in: content)
        if let match = regex.firstMatch(in: content, range: range),
           let bodyRange = Range(match.range(at: 1), in: content) {
            return String(content[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseExamples(_ raw: Any?) -> [SkillExample] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard let query = dict["query"] as? String,
                  let scenario = dict["scenario"] as? String else { return nil }
            return SkillExample(query: query, scenario: scenario)
        }
    }

    // MARK: - 首次启动：写入默认 Skill

    private func ensureDefaultSkills() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: skillsDirectory.path) {
            try? fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        }

        for (dirName, content) in Self.defaultSkills {
            let dir = skillsDirectory.appendingPathComponent(dirName, isDirectory: true)
            let file = dir.appendingPathComponent("SKILL.md")
            if !fm.fileExists(atPath: file.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? content.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - 内置默认 SKILL.md

    static let defaultSkills: [(String, String)] = [
        ("clipboard", """
        ---
        name: Clipboard
        description: '读写系统剪贴板内容。当用户需要读取、复制或操作剪贴板时使用。'
        version: "1.0.0"
        icon: doc.on.clipboard
        disabled: false

        triggers:
          - 剪贴板
          - 粘贴
          - 复制
          - clipboard

        allowed-tools:
          - clipboard-read
          - clipboard-write

        examples:
          - query: "读取我的剪贴板内容"
            scenario: "读取剪贴板"
          - query: "把这段文字复制到剪贴板"
            scenario: "写入剪贴板"
        ---

        # 剪贴板操作

        你负责帮助用户读写系统剪贴板。

        ## 可用工具

        - **clipboard-read**: 读取剪贴板当前内容（无参数）
        - **clipboard-write**: 将文本写入剪贴板（参数: text — 要复制的文本）

        ## 执行流程

        1. 用户要求读取 → 调用 `clipboard-read`
        2. 用户要求复制/写入 → 调用 `clipboard-write`，传入 text 参数
        3. 根据工具返回结果，简洁回答用户

        ## 调用格式

        <tool_call>
        {"name": "工具名", "arguments": {}}
        </tool_call>
        """),

        ("device", """
        ---
        name: Device
        description: '获取设备硬件和系统信息。当用户询问电脑配置、系统版本时使用。'
        version: "1.0.0"
        icon: desktopcomputer
        disabled: false

        triggers:
          - 设备
          - 电脑
          - 系统信息
          - 配置
          - 硬件

        allowed-tools:
          - device-info

        examples:
          - query: "我的电脑是什么配置"
            scenario: "查看设备信息"
          - query: "系统版本是多少"
            scenario: "查看系统版本"
        ---

        # 设备信息查询

        你负责帮助用户查看设备的硬件和系统信息。

        ## 可用工具

        - **device-info**: 获取设备型号、系统版本、内存、处理器信息（无参数）

        ## 执行流程

        1. 调用 `device-info` 获取设备信息
        2. 将返回的 JSON 转换为用户友好的描述

        ## 调用格式

        <tool_call>
        {"name": "device-info", "arguments": {}}
        </tool_call>
        """),

        ("text", """
        ---
        name: Text
        description: '文本处理工具：哈希计算、翻转等。当用户需要对文本进行处理或转换时使用。'
        version: "1.0.0"
        icon: textformat
        disabled: false

        triggers:
          - 哈希
          - hash
          - 翻转
          - 反转
          - 文本处理

        allowed-tools:
          - calculate-hash
          - text-reverse

        examples:
          - query: "计算 Hello World 的哈希值"
            scenario: "哈希计算"
          - query: "把这段文字翻转过来"
            scenario: "文本翻转"
        ---

        # 文本处理

        你负责帮助用户进行文本处理操作。

        ## 可用工具

        - **calculate-hash**: 计算文本的哈希值（参数: text — 要计算哈希的文本）
        - **text-reverse**: 翻转文本（参数: text — 要翻转的文本）

        ## 执行流程

        1. 判断用户需要哪种文本操作
        2. 调用对应工具，传入 text 参数
        3. 返回处理结果

        ## 调用格式

        <tool_call>
        {"name": "工具名", "arguments": {"text": "要处理的文本"}}
        </tool_call>
        """),
    ]
}
