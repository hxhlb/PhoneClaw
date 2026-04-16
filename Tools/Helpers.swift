import Foundation

// MARK: - JSON Utilities

func jsonEscape(_ str: String) -> String {
    str.replacingOccurrences(of: "\\", with: "\\\\")
       .replacingOccurrences(of: "\"", with: "\\\"")
       .replacingOccurrences(of: "\n", with: "\\n")
       .replacingOccurrences(of: "\t", with: "\\t")
}

func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let string = String(data: data, encoding: .utf8) else {
        return "{\"success\": false, \"error\": \"JSON 编码失败\"}"
    }
    return string
}

// MARK: - Tool Result Payloads

func successPayload(
    result: String,
    extras: [String: Any] = [:]
) -> String {
    var payload = extras
    payload["success"] = true
    payload["status"] = "succeeded"
    payload["result"] = result
    return jsonString(payload)
}

func failurePayload(error: String, extras: [String: Any] = [:]) -> String {
    var payload = extras
    payload["success"] = false
    payload["status"] = "failed"
    payload["error"] = error
    return jsonString(payload)
}

// MARK: - Date Helpers

func parseISO8601Date(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let isoFormatters: [ISO8601DateFormatter] = [
        {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }(),
        {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
    ]

    for formatter in isoFormatters {
        if let date = formatter.date(from: trimmed) {
            return date
        }
    }

    let formats = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm"
    ]

    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmed) {
            return date
        }
    }

    return nil
}

func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

// MARK: - Flexible Tool DateTime Parsing
//
// 设计原则: SKILL/TOOL 契约按**最低能力的模型**来设计. 弱模型 (E2B 2B) 不会
// 把"明天下午两点"算成 ISO 8601, 但能复制原字符串; tool 自己接住任何合理的
// 时间表达式.
//
// 这里**不写规则化的中文解析器** (上一版尝试过 — 几百行 regex/数字/时段映射,
// 覆盖不全 + 维护成本高). 改用 Apple 自带的 NSDataDetector — 跨语言 (中/英)、
// 系统级、零维护. 它处理不了的就让 tool 返失败, 让模型问用户.
//
// 解析顺序:
//   1. parseISO8601Date — 强模型 (E4B+) 直接给 ISO 8601, 0 开销
//   2. NSDataDetector — Apple 内置, 处理常见自然语言时间表达
//
// 任何一步成功就返回, 都失败才返回 nil → tool 走 failurePayload → 模型问用户.

func parseToolDateTime(_ raw: String, anchor: Date = Date()) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let date = parseISO8601Date(trimmed) { return date }
    if let date = parseDateTimeWithDataDetector(trimmed, anchor: anchor) { return date }
    return nil
}

private func parseDateTimeWithDataDetector(_ raw: String, anchor: Date) -> Date? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    else { return nil }
    let range = NSRange(raw.startIndex..., in: raw)
    let matches = detector.matches(in: raw, range: range)
    // 取第一个匹配 (最高置信度). NSDataDetector 内部用 anchor=now 做相对计算.
    return matches.first?.date
}
