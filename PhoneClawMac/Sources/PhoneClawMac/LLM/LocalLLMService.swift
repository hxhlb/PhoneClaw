import Foundation
import CLiteRtLm

// MARK: - LiteRT-LM C API (engine.h) → Swift 桥接
//
// 使用 Session API（非 Conversation API），因为 PromptBuilder 已经
// 构建了完整的 Gemma 4 格式 prompt。Session API 直接处理原始文本。

@Observable
class LocalLLMService {

    private var engine: OpaquePointer?
    /// 当前活跃的 session（引擎同时只支持一个）
    private var activeSession: OpaquePointer?
    private let sessionLock = NSLock()

    var isLoaded = false
    var isGenerating = false
    var statusMessage = "等待加载模型..."

    static let modelFileName = "gemma-4-E4B-it"
    static let modelFileExtension = "litertlm"

    deinit {
        cleanupSession()
        if let eng = engine {
            litert_lm_engine_delete(eng)
        }
    }

    // MARK: - Session 生命周期

    /// 安全清理上一个 session（在回调外部调用）
    private func cleanupSession() {
        sessionLock.lock()
        if let sess = activeSession {
            litert_lm_session_delete(sess)
            activeSession = nil
            log("[LLM] Session 已清理")
        }
        sessionLock.unlock()
    }

    // MARK: - 加载模型

    /// 当前使用的 backend
    var currentBackend = "cpu"

    func loadModel(backend: String = "cpu") {
        DispatchQueue.main.async {
            self.statusMessage = "正在加载 E4B 模型..."
            self.isLoaded = false
        }

        let modelPath = findModelPath()
        guard let path = modelPath else {
            DispatchQueue.main.async { self.statusMessage = "❌ 模型文件不存在" }
            log("[LLM] 找不到模型文件")
            return
        }

        // 如果已有引擎，先销毁
        cleanupSession()
        if let eng = engine {
            litert_lm_engine_delete(eng)
            engine = nil
        }

        currentBackend = backend
        log("[LLM] 开始加载: \(path) (backend: \(backend))")
        let startTime = CFAbsoluteTimeGetCurrent()

        let cPath = strdup(path)!
        let cBackend = strdup(backend)!
        let settings = litert_lm_engine_settings_create(cPath, cBackend, nil, nil)
        free(cPath)
        free(cBackend)

        guard let settings = settings else {
            DispatchQueue.main.async { self.statusMessage = "❌ 创建引擎设置失败" }
            return
        }

        litert_lm_engine_settings_set_max_num_tokens(settings, 4096)

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.path
        let cCacheDir = strdup(cacheDir)!
        litert_lm_engine_settings_set_cache_dir(settings, cCacheDir)
        free(cCacheDir)

        let eng = litert_lm_engine_create(settings)
        litert_lm_engine_settings_delete(settings)

        if let eng = eng {
            self.engine = eng
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            DispatchQueue.main.async {
                self.isLoaded = true
                self.statusMessage = "模型已就绪 ✅"
            }
            log("[LLM] Engine 创建成功，耗时: \(String(format: "%.1f", elapsed))秒")
        } else {
            DispatchQueue.main.async { self.statusMessage = "❌ Engine 创建失败" }
            log("[LLM] Engine 创建失败")
        }
    }

    // MARK: - Session API 流式生成

    /// 采样参数（每次 generate 前由 AgentEngine 设置）
    var samplingTopK: Int32 = 64
    var samplingTopP: Float = 0.95
    var samplingTemperature: Float = 1.0
    var maxOutputTokens: Int = 4000

    func generateStream(
        prompt: String,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        guard let engine = engine else {
            onComplete(.failure(LLMError.notLoaded))
            return
        }

        DispatchQueue.main.async { self.isGenerating = true }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // ★ 清理上一个 session
            self.cleanupSession()

            // 创建 session config（应用采样参数）
            let sessionConfig = litert_lm_session_config_create()
            if let cfg = sessionConfig {
                litert_lm_session_config_set_max_output_tokens(cfg, Int32(self.maxOutputTokens))
                var params = LiteRtLmSamplerParams()
                params.top_k = self.samplingTopK
                params.top_p = self.samplingTopP
                params.temperature = self.samplingTemperature
                params.seed = 0
                litert_lm_session_config_set_sampler_params(cfg, &params)
                log("[LLM] Session config: topK=\(params.top_k) topP=\(params.top_p) temp=\(params.temperature) maxTokens=\(self.maxOutputTokens)")
            }

            // 创建新 session（传入 config）
            let session = litert_lm_engine_create_session(engine, sessionConfig)
            if let cfg = sessionConfig { litert_lm_session_config_delete(cfg) }
            guard let session = session else {
                DispatchQueue.main.async {
                    self.isGenerating = false
                    onComplete(.failure(LLMError.sessionFailed))
                }
                log("[LLM] Session 创建失败")
                return
            }

            self.sessionLock.lock()
            self.activeSession = session
            self.sessionLock.unlock()
            log("[LLM] Session 创建成功")

            // 构建 InputData（原始文本）
            let cPrompt = strdup(prompt)!
            var input = InputData()
            input.type = kInputText
            input.data = UnsafeRawPointer(cPrompt)
            input.size = strlen(cPrompt)

            // 创建流式回调上下文
            let context = StreamContext(onToken: onToken, onComplete: { [weak self] result in
                DispatchQueue.main.async {
                    self?.isGenerating = false
                    onComplete(result)
                }
                // ★ 不在回调中删除 session，由下次 generateStream 清理
            })
            let contextPtr = Unmanaged.passRetained(context).toOpaque()

            let result = litert_lm_session_generate_content_stream(
                session,
                &input,
                1,
                { callbackData, chunk, isFinal, errorMsg in
                    guard let ctx = callbackData else { return }
                    let context = Unmanaged<StreamContext>.fromOpaque(ctx).takeUnretainedValue()

                    if let err = errorMsg {
                        let errStr = String(cString: err)
                        context.finish(with: .failure(LLMError.inferenceError(errStr)))
                        Unmanaged<StreamContext>.fromOpaque(ctx).release()
                        return
                    }

                    if let chunk = chunk {
                        let token = String(cString: chunk)
                        // Session API 返回纯文本 token（不是 JSON）
                        context.fullResponse += token
                        DispatchQueue.main.async {
                            context.onToken(token)
                        }
                    }

                    if isFinal {
                        context.finish(with: .success(context.fullResponse))
                        Unmanaged<StreamContext>.fromOpaque(ctx).release()
                    }
                },
                contextPtr
            )

            free(cPrompt)

            if result != 0 {
                Unmanaged<StreamContext>.fromOpaque(contextPtr).release()
                DispatchQueue.main.async {
                    self.isGenerating = false
                    onComplete(.failure(LLMError.predictFailed))
                }
                log("[LLM] 流式生成启动失败, code=\(result)")
            }
        }
    }

    // MARK: - Helpers

    private func findModelPath() -> String? {
        let candidates = [
            Bundle.main.path(forResource: Self.modelFileName, ofType: Self.modelFileExtension),
            "/Users/zxw/AITOOL/phoneclaw/Models/\(Self.modelFileName).\(Self.modelFileExtension)",
        ]
        for path in candidates {
            if let p = path, FileManager.default.fileExists(atPath: p) {
                return p
            }
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let docFile = docs.appendingPathComponent("\(Self.modelFileName).\(Self.modelFileExtension)")
        if FileManager.default.fileExists(atPath: docFile.path) {
            return docFile.path
        }
        return nil
    }

    static func jsonEscape(_ str: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [str])
        let arrayStr = String(data: data, encoding: .utf8)!
        let start = arrayStr.index(after: arrayStr.startIndex)
        let end = arrayStr.index(before: arrayStr.endIndex)
        return String(arrayStr[start..<end])
    }

    enum LLMError: LocalizedError {
        case notLoaded, sessionFailed, addChunkFailed, predictFailed
        case inferenceError(String)
        var errorDescription: String? {
            switch self {
            case .notLoaded: return "模型尚未加载"
            case .sessionFailed: return "Session 创建失败"
            case .addChunkFailed: return "Prompt 添加失败"
            case .predictFailed: return "推理失败"
            case .inferenceError(let msg): return "推理错误: \(msg)"
            }
        }
    }
}

// MARK: - Stream Context

private class StreamContext {
    var fullResponse = ""
    var completed = false
    let onToken: (String) -> Void
    let onComplete: (Result<String, Error>) -> Void

    init(onToken: @escaping (String) -> Void, onComplete: @escaping (Result<String, Error>) -> Void) {
        self.onToken = onToken
        self.onComplete = onComplete
    }

    func finish(with result: Result<String, Error>) {
        guard !completed else { return }
        completed = true
        onComplete(result)
    }
}
