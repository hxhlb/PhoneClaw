import Foundation
import MediaPipeTasksGenAI

// MARK: - 使用 MediaPipe 高级 Swift API（和 Google Gallery 相同）

@Observable
class LocalLLMService {

    private var inference: LlmInference?
    private var currentSession: LlmInference.Session?
    var isLoaded = false
    var isGenerating = false
    var statusMessage = "等待加载模型..."

    // MARK: - 后端与采样参数（AgentEngine 可动态修改）
    var useGPU: Bool = false  // 需要 extended-virtual-addressing entitlement 才能开启
    var samplingTopK: Int = 40
    var samplingTopP: Float = 0.95
    var samplingTemperature: Float = 0.8
    var maxOutputTokens: Int = 2048

    static let modelFileName = "gemma-4-E4B-it"
    static let modelFileExtension = "litertlm"

    deinit {
        currentSession = nil
        inference = nil
    }

    // MARK: - 加载模型

    func loadModel() {
        DispatchQueue.main.async { self.statusMessage = "正在加载 E4B 模型..." }

        var modelPath = Bundle.main.path(forResource: Self.modelFileName, ofType: Self.modelFileExtension)
        if modelPath == nil {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let docFile = docs.appendingPathComponent("\(Self.modelFileName).\(Self.modelFileExtension)")
            if FileManager.default.fileExists(atPath: docFile.path) {
                modelPath = docFile.path
            }
        }
        guard let path = modelPath else {
            DispatchQueue.main.async { self.statusMessage = "❌ 模型文件不存在" }
            print("[LLM] 找不到模型")
            return
        }

        print("[LLM] 开始加载: \(path)")
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let options = LlmInference.Options(modelPath: path)
            // GPU 需要 extended-virtual-addressing entitlement，否则 E4B 模型会 OOM
            // 获得 entitlement 后改为 .gpu 即可启用 Metal 加速
            options.preferredBackend = useGPU ? .gpu : .cpu
            options.maxTokens = 512
            options.maxTopk = useGPU ? 40 : 1
            options.waitForWeightUploads = false
            options.sequenceBatchSize = 0

            let label = useGPU ? "GPU" : "CPU"
            print("[LLM] 使用 \(label) 后端加载...")
            let llm = try LlmInference(options: options)
            self.inference = llm

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            DispatchQueue.main.async {
                self.isLoaded = true
                self.statusMessage = "\(label) 模型已就绪 ✅"
            }
            print("[LLM] Engine 创建成功 (\(label))，耗时: \(String(format: "%.1f", elapsed))秒")
        } catch {
            DispatchQueue.main.async { self.statusMessage = "❌ \(error.localizedDescription)" }
            print("[LLM] Engine 创建失败: \(error)")
        }
    }

    // MARK: - Session 管理

    private func createSession() -> Bool {
        currentSession = nil
        guard let llm = inference else { return false }

        do {
            let sessionOptions = LlmInference.Session.Options()
            sessionOptions.topk = min(samplingTopK, useGPU ? 40 : 1)  // 不能超过 maxTopk
            sessionOptions.topp = samplingTopP
            sessionOptions.temperature = samplingTemperature
            sessionOptions.randomSeed = 0

            self.currentSession = try LlmInference.Session(llmInference: llm, options: sessionOptions)
            return true
        } catch {
            print("[LLM] Session 创建失败: \(error)")
            return false
        }
    }

    // MARK: - 流式生成

    func generateStream(prompt: String, onToken: @escaping (String) -> Void, onComplete: @escaping (Result<String, Error>) -> Void) {
        guard inference != nil else {
            onComplete(.failure(LLMError.notLoaded))
            return
        }

        DispatchQueue.main.async { self.isGenerating = true }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            guard self.createSession(), let sess = self.currentSession else {
                DispatchQueue.main.async {
                    self.isGenerating = false
                    onComplete(.failure(LLMError.sessionFailed))
                }
                return
            }

            do {
                try sess.addQueryChunk(inputText: prompt)
            } catch {
                print("[LLM] AddQueryChunk 失败: \(error)")
                DispatchQueue.main.async {
                    self.isGenerating = false
                    onComplete(.failure(LLMError.addChunkFailed))
                }
                return
            }

            var fullResponse = ""

            do {
                try sess.generateResponseAsync { [weak self] partialResponse, error in
                    // progress callback — 每个 token
                    if let err = error {
                        print("[LLM] 流式错误: \(err)")
                        return
                    }
                    if let token = partialResponse {
                        fullResponse += token
                        DispatchQueue.main.async {
                            onToken(token)
                        }
                    }
                } completion: { [weak self] in
                    // 完成回调
                    print("[LLM] 流式完成，长度: \(fullResponse.count)")
                    DispatchQueue.main.async {
                        self?.isGenerating = false
                        onComplete(.success(fullResponse))
                    }
                }
            } catch {
                print("[LLM] GenerateResponseAsync 失败: \(error)")
                DispatchQueue.main.async {
                    self.isGenerating = false
                    onComplete(.failure(LLMError.predictFailed))
                }
            }
        }
    }

    // MARK: - 同步生成（备用）

    func generate(prompt: String) throws -> String {
        guard inference != nil else { throw LLMError.notLoaded }
        guard createSession(), let sess = currentSession else { throw LLMError.sessionFailed }

        try sess.addQueryChunk(inputText: prompt)
        let response = try sess.generateResponse()
        return response
    }

    enum LLMError: LocalizedError {
        case notLoaded, sessionFailed, addChunkFailed, predictFailed
        var errorDescription: String? {
            switch self {
            case .notLoaded: return "模型尚未加载"
            case .sessionFailed: return "Session 创建失败"
            case .addChunkFailed: return "Prompt 添加失败"
            case .predictFailed: return "推理失败"
            }
        }
    }
}
