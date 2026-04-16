import EventKit
import Foundation

enum CalendarTools {

    static func register(into registry: ToolRegistry) {

        // ── calendar-create-event ──
        registry.register(RegisteredTool(
            name: "calendar-create-event",
            description: "创建新的日历事项，可写入标题、开始时间、结束时间、地点和备注",
            // 设计原则: SKILL/TOOL 契约按最低能力的模型 (E2B 2B) 来. 不要求 LLM 把
            // 中文相对时间转成 ISO 8601 — handler 自己解析任何合理时间表达式.
            parameters: "title: 事件标题, start: 开始时间 (ISO 8601 / 中文相对时间如\"明天下午两点\" / 中文绝对时间如\"5月3日15:00\" 都可), end: 结束时间（可选, 同 start 格式）, location: 地点（可选）, notes: 备注（可选）",
            requiredParameters: ["start"]
        ) { args in
            // title 是软参: 没传或为空时使用默认标题, 不阻断流程
            let rawTitle = (args["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = rawTitle.isEmpty ? "新日历事项" : rawTitle

            // start 是日历事项核心硬参. 设计: 若用户只给"日期"没给"几点" (E2B 容易
            // 脑补 "今天" / "明天" 不带时间), tool 强制返失败让模型追问, 不让模型自己
            // 编时间. 完整性检测走通用 parseToolDateTimeDetailed.hasExplicitTime.
            guard let startRaw = args["start"] as? String,
                  let parsed = parseToolDateTimeDetailed(startRaw) else {
                return failurePayload(error: "没听清开始时间, 可以再说一次吗? 例如\"明天下午两点\"或\"5月3日15:00\"")
            }
            guard parsed.hasExplicitTime else {
                return failurePayload(error: "\u{201C}\(startRaw)\u{201D}没说几点, 想约什么时间呢? 例如\"\(startRaw)下午两点\"")
            }
            let startDate = parsed.date

            let endRaw = (args["end"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let endDate = endRaw.flatMap { parseToolDateTime($0) } ?? startDate.addingTimeInterval(3600)
            guard endDate >= startDate else {
                return failurePayload(error: "end 不能早于 start")
            }

            let location = (args["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            // 上层逻辑全真 (parse + validate). 系统副作用 (EKEventStore.save) 在
            // Mac CLI 因 TCC 拒绝服务无法测, 走 mock 返合成 success — harness 验证
            // SKILL flow 端到端正确. 真实写入 iOS Calendar.app 由真机测兜底.
            #if !os(iOS)
            return successPayload(
                result: "已创建日历事项\u{201C}\(title)\u{201D}，开始时间为 \(iso8601String(from: startDate))。",
                extras: [
                    "eventId": "mock-mac-\(UUID().uuidString)",
                    "title": title,
                    "start": iso8601String(from: startDate),
                    "end": iso8601String(from: endDate),
                    "location": location ?? "",
                    "notes": notes ?? "",
                    "_macMock": true
                ]
            )
            #else
            do {
                guard try await ToolRegistry.shared.requestAccess(for: .calendar) else {
                    return failurePayload(error: "未获得日历写入权限")
                }

                guard let calendar = writableEventCalendar() else {
                    return failurePayload(error: "没有可用于新建事项的可写日历，请先在系统日历中启用或创建一个日历")
                }

                let event = EKEvent(eventStore: SystemStores.event)
                event.calendar = calendar
                event.title = title
                event.startDate = startDate
                event.endDate = endDate
                if let location, !location.isEmpty {
                    event.location = location
                }
                if let notes, !notes.isEmpty {
                    event.notes = notes
                }

                try SystemStores.event.save(event, span: .thisEvent, commit: true)

                return successPayload(
                    result: "已创建日历事项\u{201C}\(title)\u{201D}，开始时间为 \(iso8601String(from: startDate))。",
                    extras: [
                        "eventId": event.eventIdentifier ?? "",
                        "title": title,
                        "start": iso8601String(from: startDate),
                        "end": iso8601String(from: endDate),
                        "location": location ?? "",
                        "notes": notes ?? ""
                    ]
                )
            } catch {
                return failurePayload(error: "创建日历事项失败：\(error.localizedDescription)")
            }
            #endif
        })
    }

    // MARK: - Private Helpers

    private static func writableEventCalendar() -> EKCalendar? {
        if let calendar = SystemStores.event.defaultCalendarForNewEvents,
           calendar.allowsContentModifications {
            return calendar
        }

        return SystemStores.event.calendars(for: .event)
            .first(where: \.allowsContentModifications)
    }
}
