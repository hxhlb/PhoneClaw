---
name: Health
name-zh: 健康数据
description: '读取 HealthKit 里的用户运动/步数数据, 在本地生成摘要。只读不写, 数据不离开本机。'
version: "1.0.0"
icon: heart.fill
disabled: false
type: device
chip_prompt: "今天走了多少步"

triggers:
  - 步数
  - 走了多少
  - 走了多少步
  - 运动
  - 锻炼
  - 健康
  - 健康数据
  - health
  - steps

allowed-tools:
  - health-steps-today

examples:
  - query: "我今天走了多少步"
    scenario: "查询今日步数"
  - query: "今天运动量怎么样"
    scenario: "今日运动概况"
---

# 健康数据查询

你负责读取用户的健康数据并给出简短解读。数据全部在本地处理, 不上传。

## 可用工具

- **health-steps-today**: 读取今日步数 (0 点到当前时间累计)。无参数。

## 执行流程

1. 用户问"今天走了多少步" / "今天运动量" / "健康数据" 这类问题 → 立即调用 `health-steps-today`, 不要追问
2. 拿到步数后, 给一句**简短**自然语言回复, 例如:
   - 步数 < 3000: "今天走了 X 步, 活动量偏少, 可以出去散散步"
   - 3000 ≤ 步数 < 8000: "今天走了 X 步, 活动量一般"
   - 步数 ≥ 8000: "今天走了 X 步, 不错的活动量"
3. **不要**自己编造步数, 必须用 tool 返回的真实数字
4. **不要**在没调用 tool 之前说"我没有权限"或"我不知道" — 先调工具再说

## 权限被拒绝时

如果 tool 返回 failurePayload 且 error 里提到"授权被拒绝"或"设置",告诉用户:

> 我没能读到步数数据。请去设置 → 隐私与安全性 → 健康 → PhoneClaw, 确认开启了步数读取权限,然后再问我一次。

不要反复调用 tool 重试。
