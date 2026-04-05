# PhoneClaw 技术路径分析

> 基于对 Google AI Edge Gallery、LiteRT-LM、Gemma 4 E4B 的实际代码和文档研究

## 关键发现

### 1. 你手机上跑的 App = Google AI Edge Gallery
- App Store: https://apps.apple.com/us/app/google-ai-edge-gallery/id6749645337
- GitHub: https://github.com/google-ai-edge/gallery
- **但 iOS 源码未开源**（GitHub 上只有 Android Kotlin 代码，占 91%）
- iOS 版由 Google 内部开发，未公开 Swift 源码

### 2. Gemma 4 E4B 的推理引擎 = LiteRT-LM
- GitHub: https://github.com/google-ai-edge/LiteRT-LM
- 语言: C++ (76.5%), 有 C API 绑定
- **iOS 支持**: 有（Metal GPU 加速），但 **Swift API 标注 "Coming Soon"**
- 当前可用: C/C++ API → 可通过 Swift Bridging Header 调用
- 内置 Function Calling / Tool Use 支持（核心！）

### 3. Gallery 的 Agent Skills 系统
- skills/ 目录包含模块化技能定义（平台无关的 Markdown 文件）
- 技能格式: SKILL.md (YAML frontmatter + 指令)
- Gallery 支持**通过 URL 加载自定义 Skill**
- Function_Calling_Guide.md 详细说明了工具定义方式

---

## 三条可行路径

### 路径 A：在 Gallery App 上加载自定义 Skill ⭐ 最快
```
成本: 0 代码    时间: 30 分钟
原理: Gallery App 原生支持从 URL 加载 Skill
你只需要写 SKILL.md 文件，托管在 GitHub 上
```

**优点**: 零开发成本，直接用 E4B，Gallery 已处理好所有推理/UI/权限
**缺点**: Gallery 是沙箱 App，不能调用你自定义的 iOS API（相机/日历等）
**适合**: 验证 Skill 提示词和交互设计

---

### 路径 B：Fork Gallery + LiteRT-LM C API → Swift 自定义 App ⭐⭐ 推荐
```
成本: 中等     时间: 1-2 周
原理: 用 LiteRT-LM 的 C API 从 Swift 调用 E4B 推理
     自己实现 Skill Router + iOS API 调用
```

**技术栈**:
```
Swift App
  ├── LiteRT-LM C API (via Bridging Header)
  │     └── 加载 .litertlm 模型文件
  │     └── Conversation API (含 tool use)
  ├── Skill Router (Swift)
  │     └── 解析 function call → 执行 iOS API
  └── iOS Skills (Swift)
        └── 相机/剪贴板/日历/健康...
```

**LiteRT-LM C API 核心接口**:
```c
// 创建引擎
LiteRtLmEngine* engine = LiteRtLmEngineCreate(settings);

// 创建对话
LiteRtLmConversation* conv = LiteRtLmConversationCreate(engine);

// 发送消息（含工具定义）
LiteRtLmConversationSendMessage(conv, message, callback);

// 返回工具结果
LiteRtLmConversationSendToolResult(conv, tool_call_id, result);
```

**优点**: 完全控制，能调用所有 iOS API，真正的端侧 Agent
**缺点**: 需要编译 LiteRT-LM 的 iOS 库（CMake/Bazel）

---

### 路径 C：MediaPipe LLM Inference API (CocoaPods)
```
成本: 中等     时间: 3-5 天
原理: Google 的旧版 API，有 iOS CocoaPods 支持
```

**Podfile**:
```ruby
pod 'MediaPipeTasksGenAI'
pod 'MediaPipeTasksGenAIC'
```

**优点**: 集成简单，CocoaPods 一键安装
**缺点**: 较旧的 API，不确定是否支持 Gemma 4 E4B 格式(.litertlm)
         Google 建议迁移到 LiteRT-LM

---

## 推荐策略：A → B 渐进

### 阶段 1（今天）：路径 A — Skill 验证
- 写一个自定义 SKILL.md
- 在 Gallery App 中加载运行
- 验证 E4B 的 function calling 能力和提示词

### 阶段 2（本周）：路径 B — 搭建独立 App
- 编译 LiteRT-LM iOS 库
- Swift Bridging Header 接入 C API
- 实现第一个真正有 iOS 权限调用的 Skill（clipboard_read）

---

## 接下来你想先走哪一步？

- **A**: 我现在就帮你写一个 SKILL.md，放到 Gallery 里测试
- **B**: 直接开始搭建独立 App（编译 LiteRT-LM）
