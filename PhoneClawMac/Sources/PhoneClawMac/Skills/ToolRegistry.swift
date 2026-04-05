import AppKit
import Foundation

// MARK: - 原生工具注册表
//
// 所有原生 API 封装集中注册在这里。
// SKILL.md 通过 allowed-tools 字段引用工具名。

struct RegisteredTool {
    let name: String
    let description: String
    let parameters: String
    let execute: ([String: Any]) async throws -> String
}

class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: RegisteredTool] = [:]

    init() {
        registerBuiltInTools()
    }

    // MARK: - 公开接口

    func register(_ tool: RegisteredTool) {
        tools[tool.name] = tool
    }

    func find(name: String) -> RegisteredTool? {
        tools[name]
    }

    func execute(name: String, args: [String: Any]) async throws -> String {
        guard let tool = tools[name] else {
            return "{\"success\": false, \"error\": \"未知工具: \(name)\"}"
        }
        return try await tool.execute(args)
    }

    /// 根据名称列表获取工具（用于 SKILL.md 的 allowed-tools）
    func toolsFor(names: [String]) -> [RegisteredTool] {
        names.compactMap { tools[$0] }
    }

    /// 根据工具名反查：它属于哪些 allowed-tools 列表
    /// 返回 true 如果该工具已注册
    func hasToolNamed(_ name: String) -> Bool {
        tools[name] != nil
    }

    /// 所有已注册的工具名
    var allToolNames: [String] {
        Array(tools.keys).sorted()
    }

    // MARK: - 内置工具注册

    private func registerBuiltInTools() {
        // ── Clipboard ──
        register(RegisteredTool(
            name: "clipboard-read",
            description: "读取剪贴板当前内容",
            parameters: "无"
        ) { _ in
            let content = NSPasteboard.general.string(forType: .string)
            if let raw = content, !raw.isEmpty {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return "{\"success\": false, \"error\": \"剪贴板为空\"}" }
                return "{\"success\": true, \"type\": \"text\", \"content\": \"\(jsonEscape(String(text.prefix(500))))\", \"length\": \(text.count)}"
            }
            return "{\"success\": false, \"error\": \"剪贴板为空\"}"
        })

        register(RegisteredTool(
            name: "clipboard-write",
            description: "将文本写入剪贴板",
            parameters: "text: 要复制的文本内容"
        ) { args in
            guard let text = args["text"] as? String else {
                return "{\"success\": false, \"error\": \"缺少 text 参数\"}"
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return "{\"success\": true, \"copied_length\": \(text.count)}"
        })

        // ── Device ──
        register(RegisteredTool(
            name: "device-info",
            description: "获取设备型号、系统版本、内存、处理器信息",
            parameters: "无"
        ) { _ in
            let info = ProcessInfo.processInfo
            let hostname = Host.current().localizedName ?? "Unknown"
            let osVersion = info.operatingSystemVersionString
            let physicalMemory = info.physicalMemory / (1024 * 1024 * 1024)
            let processorCount = info.processorCount

            var size: size_t = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            let modelStr = String(cString: model)

            return "{\"success\": true, \"name\": \"\(hostname)\", \"model\": \"\(modelStr)\", \"system\": \"macOS \(osVersion)\", \"memory_gb\": \(physicalMemory), \"processors\": \(processorCount)}"
        })

        // ── Text ──
        register(RegisteredTool(
            name: "calculate-hash",
            description: "计算文本的哈希值",
            parameters: "text: 要计算哈希的文本"
        ) { args in
            guard let text = args["text"] as? String else {
                return "{\"success\": false, \"error\": \"缺少 text 参数\"}"
            }
            let hash = text.hashValue
            return "{\"success\": true, \"input\": \"\(jsonEscape(text))\", \"hash\": \(hash)}"
        })

        register(RegisteredTool(
            name: "text-reverse",
            description: "翻转文本",
            parameters: "text: 要翻转的文本"
        ) { args in
            guard let text = args["text"] as? String else {
                return "{\"success\": false, \"error\": \"缺少 text 参数\"}"
            }
            let reversed = String(text.reversed())
            return "{\"success\": true, \"original\": \"\(jsonEscape(text))\", \"reversed\": \"\(jsonEscape(reversed))\"}"
        })
    }
}

// MARK: - Helpers

func jsonEscape(_ str: String) -> String {
    str.replacingOccurrences(of: "\\", with: "\\\\")
       .replacingOccurrences(of: "\"", with: "\\\"")
       .replacingOccurrences(of: "\n", with: "\\n")
       .replacingOccurrences(of: "\t", with: "\\t")
}
