import Foundation
import HealthKit

// MARK: - Health Tools
//
// 读取 HealthKit 里用户的健康数据。只读,不写。
//
// v1 只实现一个最小可用 tool: health-steps-today (今日步数)。
// 验证通过后再扩展 sleep / workout / heart rate 等。
//
// 权限策略: 每次调用时检查授权, 首次会弹系统对话框。用户拒绝后直接返回
// failurePayload, 由 skill body 里的指令让模型给用户一个友好解释。
//
// 为什么放在 Tools/Handlers/ 而不是放在独立 HealthKit 模块:
// - 跟其他 Skill 的 Tool 模式完全对称 (Calendar / Reminders / Contacts)
// - ToolRegistry 是框架白名单入口, 所有工具都走这条路径, 不给 Health 开
//   特殊通道
// - SKILL.md 声明 allowed-tools: [health-steps-today], Router 按同一套
//   机制处理, 没有任何 if model == "..." / if skill == "..." 的硬编

enum HealthTools {

    /// HealthKit store 单例 — Apple 官方建议整个 app 只创建一个
    private static let store = HKHealthStore()

    static func register(into registry: ToolRegistry) {

        // ── health-steps-today ──
        registry.register(RegisteredTool(
            name: "health-steps-today",
            description: "读取用户今日步数 (从本地 0 点到当前时间的累计步数)。仅读取,不修改。",
            parameters: "无",
            isParameterless: true
        ) { _ in
            guard HKHealthStore.isHealthDataAvailable() else {
                return failurePayload(error: "设备不支持 HealthKit")
            }
            guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
                return failurePayload(error: "无法访问 stepCount 数据类型")
            }

            // 请求读权限。如果用户之前已授权, 这个调用是 no-op; 如果没授权过,
            // 会弹系统对话框让用户选。
            do {
                try await store.requestAuthorization(toShare: [], read: [stepType])
            } catch {
                return failurePayload(error: "健康数据授权失败: \(error.localizedDescription)")
            }

            // 注意: HealthKit 的 authorizationStatus(forType:) 只能告诉我们
            // **write** 权限状态, **不能**反映 read 权限 (Apple 隐私设计:
            // 不让 app 知道用户是否拒绝了读, 防止 app 根据是否能读来推断
            // 用户是否有该类数据)。所以即使用户拒绝了读, 这里也返回 authorized;
            // 我们只能通过"实际查询拿不到数据"来间接判断。

            let steps = await fetchTodaySteps(quantityType: stepType)
            guard let steps else {
                return failurePayload(
                    error: "无法读取今日步数。可能是授权被拒绝, 或今天没有步数数据。"
                        + "请在设置 → 隐私与安全性 → 健康 → PhoneClaw 里确认开启了步数读取权限。"
                )
            }

            let rounded = Int(steps.rounded())
            return successPayload(
                result: "今日步数: \(rounded) 步",
                extras: [
                    "steps": rounded,
                    "unit": "步",
                    "date": isoDateString(Date())
                ]
            )
        })
    }

    // MARK: - 私有 helpers

    /// 查询今天 (本地 0 点到现在) 的步数累计总和。
    /// 失败返回 nil, 调用方自己决定是否报错。
    private static func fetchTodaySteps(quantityType: HKQuantityType) async -> Double? {
        await withCheckedContinuation { continuation in
            let calendar = Calendar.current
            let now = Date()
            let start = calendar.startOfDay(for: now)
            let predicate = HKQuery.predicateForSamples(
                withStart: start, end: now, options: .strictStartDate
            )

            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                let sum = stats?.sumQuantity()?.doubleValue(for: .count())
                continuation.resume(returning: sum)
            }

            store.execute(query)
        }
    }

    private static func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
