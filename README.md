# PhoneClaw — 操作指南（你现在就能做的事）

## ✅ 已完成

| 项目 | 状态 |
|------|------|
| Xcode 项目 (PhoneClaw.xcworkspace) | ✅ 已创建 |
| MediaPipe SDK (CocoaPods) | ✅ 已安装 v0.10.33 |
| E4B 模型 (.litertlm, 3.4GB) | ✅ 已下载到 Models/ |
| LLM 推理层 (LocalLLMService.swift) | ✅ 基于 MediaPipe API |
| Agent 引擎 (AgentEngine.swift) | ✅ 双轮推理 + Skill 执行 |
| Skills (剪贴板读/写, 设备信息) | ✅ 3 个 Skill |
| 聊天 UI (ContentView.swift) | ✅ SwiftUI 气泡界面 |
| 内存权限 (entitlements) | ✅ increased-memory-limit |

## 📱 部署到 iPhone 的 3 步

### Step 1：打开项目
```bash
open /Users/zxw/AITOOL/phoneclaw/PhoneClaw.xcworkspace
```
⚠️ 必须打开 .xcworkspace，不是 .xcodeproj

### Step 2：放入模型文件
模型已下载到：
```
/Users/zxw/AITOOL/phoneclaw/Models/gemma-4-E4B-it.litertlm
```

在 Xcode 中：
1. 左侧 Navigator → 右键 PhoneClaw → "Add Files to PhoneClaw..."
2. 选择 `Models/gemma-4-E4B-it.litertlm`
3. ✅ 勾选 "Copy items if needed"
4. ✅ 确认 Target: PhoneClaw 被选中
5. 在 Build Phases → Copy Bundle Resources 确认文件在内

### Step 3：签名并编译
1. Xcode 左侧选 PhoneClaw 项目 → Signing & Capabilities
2. Team: 选你的 Apple ID
3. Bundle Identifier: 改成唯一的（如 com.zxw.phoneclaw）
4. USB 连接 iPhone
5. 顶部选择你的 iPhone 设备
6. **Command + R** 编译运行

首次安装需要在 iPhone 上：
设置 → 通用 → VPN与设备管理 → 信任你的开发者证书

## 🏗️ 项目结构
```
phoneclaw/
├── PhoneClaw.xcworkspace     ← 打开这个！
├── PhoneClaw/
│   ├── App/PhoneClawApp.swift          ← 入口
│   ├── UI/ContentView.swift            ← 聊天界面
│   ├── Agent/AgentEngine.swift         ← Agent 核心循环
│   ├── LLM/LocalLLMService.swift       ← E4B 推理（MediaPipe）
│   ├── LLM/PromptBuilder.swift         ← Prompt 模板
│   ├── Skills/Skills.swift             ← 剪贴板/设备 Skills
│   ├── Info.plist
│   └── PhoneClaw.entitlements          ← 内存权限
├── Models/
│   └── gemma-4-E4B-it.litertlm        ← E4B 模型 3.4GB
├── Pods/                               ← MediaPipe SDK
├── Podfile
└── project.yml
```

## ⚡ 测试指令
App 运行后，输入以下试试：
- "看看我的剪贴板有什么"  → 调用 clipboard_read
- "我的手机信息"          → 调用 device_info
- "帮我复制：Hello"       → 调用 clipboard_write
- "你好"                  → 直接对话（不调用 Skill）

## 🔄 关于 LiteRT-LM 原生方案

你说得对，Gallery App 用的是 LiteRT-LM C API + .litertlm，不是 MediaPipe。
当前代码用 MediaPipe（内部也封装了 LiteRT），作为先跑通的路径。

后续升级路径：
1. LiteRT-LM C API 头文件已在: LiteRT-LM/c/engine.h  
2. iOS 预编译 GPU 库已在: LiteRT-LM/prebuilt/ios_arm64/
3. 等 Google 发布 Swift API 后直接切换
