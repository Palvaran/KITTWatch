import Foundation
import KITTCore
import llama

/// CPU-only llama.cpp engine. The same source runs on the Series 5, the Mac, and Linux.
///
/// Written against llama.cpp at the revision pinned in scripts/versions.env
/// (llama_batch_ext + llama_process API). If you move the pin, re-check this file.
///
/// The engine keeps no conversation of its own: every call receives the full prompt,
/// rebuilt from the saved record. What it does keep is the evaluated tokens of the
/// previous call. Only the part of the new prompt that differs is evaluated again, so
/// the fixed system text and earlier turns cost nothing after the first question. On
/// the S5, where prompt evaluation runs at roughly 25 tokens per second, that is most
/// of the wait before the first word.
public final class LlamaEngine: TextGenerating {
    public struct Config: Sendable {
        public var contextTokens: UInt32 = 1024
        /// Prompt tokens per decode call. Small batches keep scratch memory low on the watch.
        public var batchTokens: UInt32 = 32
        public var threads: Int32 = 2
        /// Used only when a prompt is not `deterministic`.
        public var temperature: Float = 0.6
        public var topK: Int32 = 40
        public var topP: Float = 0.9
        public var repeatPenalty: Float = 1.1
        public var seed: UInt32 = LLAMA_DEFAULT_SEED
        /// Repack weights into CPU-specific layouts at load. llama.cpp only does this
        /// with dot-product or int8-matmul instructions, which the S5 lacks, so it has
        /// no effect on the watch and stays off to keep the weights memory-mapped.
        public var repackWeights = false
        public init() {}
    }

    public enum EngineError: Error, CustomStringConvertible {
        case modelLoadFailed(String), contextFailed, templateFailed, tokenizeFailed, promptTooLong(Int), decodeFailed(Int32)
        public var description: String {
            switch self {
            case .modelLoadFailed(let p): return "Could not load model at \(p)"
            case .contextFailed: return "Could not create llama context"
            case .templateFailed: return "Could not apply chat template"
            case .tokenizeFailed: return "Could not tokenize prompt"
            case .promptTooLong(let n): return "Prompt is \(n) tokens, too long for the context"
            case .decodeFailed(let r): return "Decode failed (\(r))"
            }
        }
    }

    public let modelID: String
    public let config: Config
    public let loadMilliseconds: Double

    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let greedySampler: UnsafeMutablePointer<llama_sampler>
    private let creativeSampler: UnsafeMutablePointer<llama_sampler>
    private let batch: OpaquePointer
    private let template: String?
    private let abortFlag = AbortFlag()
    private let lock = NSLock()  // one generation at a time
    /// Tokens whose state is in the context memory, at positions 0..<count.
    private var cached: [llama_token] = []

    private static let backendOnce: Void = {
        llama_log_set({ level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text else { return }
            fputs(String(cString: text), stderr)
        }, nil)
        llama_backend_init()
    }()

    public init(modelURL: URL, modelID: String, config: Config = Config()) throws {
        _ = Self.backendOnce
        self.modelID = modelID
        self.config = config
        let start = DispatchTime.now()

        var mp = llama_model_default_params()
        mp.n_gpu_layers = 0
        mp.load_mode = LLAMA_LOAD_MODE_MMAP
        mp.use_extra_bufts = config.repackWeights
        guard let m = llama_model_load_from_file(modelURL.path, mp) else {
            throw EngineError.modelLoadFailed(modelURL.path)
        }

        var cp = llama_context_default_params()
        cp.n_ctx = config.contextTokens
        cp.n_batch = config.batchTokens
        cp.n_ubatch = config.batchTokens
        cp.n_seq_max = 1
        cp.n_threads = config.threads
        cp.n_threads_batch = config.threads
        cp.no_perf = true
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw EngineError.contextFailed
        }

        let v = llama_model_get_vocab(m)!
        let nVocab = llama_vocab_n_tokens(v)

        let greedy = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(greedy, llama_sampler_init_penalties(nVocab, 64, config.repeatPenalty, 0, 0))
        llama_sampler_chain_add(greedy, llama_sampler_init_greedy())

        let creative = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(creative, llama_sampler_init_penalties(nVocab, 64, config.repeatPenalty, 0, 0))
        llama_sampler_chain_add(creative, llama_sampler_init_top_k(config.topK))
        llama_sampler_chain_add(creative, llama_sampler_init_top_p(config.topP, 1))
        llama_sampler_chain_add(creative, llama_sampler_init_temp(config.temperature))
        llama_sampler_chain_add(creative, llama_sampler_init_dist(config.seed))

        model = m
        ctx = c
        vocab = v
        greedySampler = greedy
        creativeSampler = creative
        batch = llama_batch_ext_init(c)!
        template = llama_model_chat_template(m, nil).map { String(cString: $0) }

        llama_set_abort_callback(c, { data in
            guard let data else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(data).takeUnretainedValue().isSet
        }, Unmanaged.passUnretained(abortFlag).toOpaque())

        loadMilliseconds = Self.ms(since: start)
    }

    deinit {
        llama_batch_ext_free(batch)
        llama_sampler_free(greedySampler)
        llama_sampler_free(creativeSampler)
        llama_free(ctx)
        llama_model_free(model)
    }

    public func cancel() { abortFlag.set(true) }

    /// Number of tokens the prompt occupies once the chat template is applied.
    public func countTokens(_ prompt: ModelPrompt) throws -> Int {
        try tokenize(try format(prompt.turns, startAssistant: true)).count
    }

    public func prewarm(_ prompt: ModelPrompt) throws {
        lock.lock(); defer { lock.unlock() }
        abortFlag.set(false)
        // Only the leading system turn is fixed across questions.
        let fixed = prompt.turns.prefix { $0.role == .system }
        guard !fixed.isEmpty else { return }
        let tokens = try tokenize(try format(Array(fixed), startAssistant: false))
        _ = try evaluate(tokens, needLogits: false)
    }

    public func generate(_ prompt: ModelPrompt, onText: (String) -> Void) throws -> GenerationStats {
        lock.lock(); defer { lock.unlock() }
        abortFlag.set(false)
        let start = DispatchTime.now()

        let sampler = prompt.deterministic ? greedySampler : creativeSampler
        llama_sampler_reset(sampler)

        let tokens = try tokenize(try format(prompt.turns, startAssistant: true))
        let nCtx = Int(llama_n_ctx(ctx))
        guard tokens.count + 8 < nCtx else { throw EngineError.promptTooLong(tokens.count) }
        let maxNew = min(prompt.maxNewTokens, nCtx - tokens.count - 1)

        guard let reused = try evaluate(tokens, needLogits: true) else {
            return GenerationStats(promptTokens: tokens.count, generatedTokens: 0, prefillMilliseconds: Self.ms(since: start),
                                   timeToFirstTokenMilliseconds: nil, generationMilliseconds: 0, stop: .cancelled)
        }
        let prefillMs = Self.ms(since: start)

        var acc = UTF8Accumulator()
        var sentences = SentenceCounter()
        var ttft: Double?
        var generated = 0
        var stop = GenerationStats.Stop.maxTokens
        let genStart = DispatchTime.now()
        var piece = [CChar](repeating: 0, count: 64)

        while generated < maxNew {
            if abortFlag.isSet { stop = .cancelled; break }
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { stop = .endOfTurn; break }
            generated += 1

            var n = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, false)
            if n < 0 {
                piece = [CChar](repeating: 0, count: Int(-n))
                n = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, false)
            }
            if n > 0 {
                let out = acc.append(piece[0..<Int(n)].map { UInt8(bitPattern: $0) })
                if !out.isEmpty {
                    if ttft == nil { ttft = Self.ms(since: start) }
                    onText(out)
                    sentences.append(out)
                    if prompt.maxSentences > 0, sentences.countIncludingTrailing >= prompt.maxSentences {
                        stop = .maxSentences
                        break
                    }
                }
            }

            if cached.count + 1 >= nCtx { stop = .contextFull; break }
            llama_batch_ext_clear(batch)
            let idx = llama_batch_ext_add_token(batch, 0, tok)
            var p = llama_pos(cached.count)
            _ = llama_batch_ext_set_pos(batch, idx, &p)
            _ = llama_batch_ext_set_output_logits(batch, idx, true)
            let r = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
            if r == 2 || abortFlag.isSet { dropUnconfirmed(); stop = .cancelled; break }
            guard r == 0 else { resetCache(); throw EngineError.decodeFailed(r) }
            cached.append(tok)
        }
        let rest = acc.finish()
        if !rest.isEmpty { onText(rest) }

        return GenerationStats(promptTokens: tokens.count, reusedTokens: reused, generatedTokens: generated,
                               prefillMilliseconds: prefillMs, timeToFirstTokenMilliseconds: ttft,
                               generationMilliseconds: Self.ms(since: genStart), stop: stop)
    }

    // MARK: Evaluation with prefix reuse

    /// Bring the context memory to exactly `tokens`, evaluating only what differs from
    /// the previous call. Returns the number of reused tokens, or nil if cancelled.
    private func evaluate(_ tokens: [llama_token], needLogits: Bool) throws -> Int? {
        var keep = 0
        while keep < cached.count, keep < tokens.count, cached[keep] == tokens[keep] { keep += 1 }
        // The sampler needs fresh logits for the last prompt token.
        if needLogits, keep == tokens.count { keep -= 1 }

        if keep < cached.count {
            let memory = llama_get_memory(ctx)
            if keep == 0 || !llama_memory_seq_rm(memory, 0, llama_pos(keep), -1) {
                llama_memory_clear(memory, true)
                keep = 0
            }
            cached.removeSubrange(keep...)
        }

        let step = Int(config.batchTokens)
        var i = keep
        while i < tokens.count {
            let end = min(i + step, tokens.count)
            llama_batch_ext_clear(batch)
            for t in i..<end {
                let idx = llama_batch_ext_add_token(batch, 0, tokens[t])
                var p = llama_pos(t)
                _ = llama_batch_ext_set_pos(batch, idx, &p)
            }
            if needLogits, end == tokens.count { _ = llama_batch_ext_set_output_logits(batch, Int32(end - i - 1), true) }
            let r = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)
            if r == 2 || abortFlag.isSet { dropUnconfirmed(); return nil }
            guard r == 0 else { resetCache(); throw EngineError.decodeFailed(r) }
            cached.append(contentsOf: tokens[i..<end])
            i = end
        }
        return keep
    }

    /// After an abort llama.cpp may have stored part of the interrupted batch. Remove
    /// anything beyond what this class knows to be complete.
    private func dropUnconfirmed() {
        let memory = llama_get_memory(ctx)
        if cached.isEmpty || !llama_memory_seq_rm(memory, 0, llama_pos(cached.count), -1) { resetCache() }
    }

    private func resetCache() {
        llama_memory_clear(llama_get_memory(ctx), true)
        cached.removeAll()
    }

    // MARK: Helpers

    private func format(_ turns: [ChatTurn], startAssistant: Bool) throws -> String {
        // C strings must outlive the call.
        let roles = turns.map { strdup($0.role.rawValue)! }
        let contents = turns.map { strdup($0.content)! }
        defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
        var msgs = zip(roles, contents).map { llama_chat_message(role: $0, content: $1) }

        var buf = [CChar](repeating: 0, count: max(1024, turns.reduce(0) { $0 + $1.content.utf8.count } * 2))
        var n = llama_chat_apply_template(template, &msgs, msgs.count, startAssistant, &buf, Int32(buf.count))
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(template, &msgs, msgs.count, startAssistant, &buf, Int32(buf.count))
        }
        guard n >= 0 else { throw EngineError.templateFailed }
        return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let len = Int32(text.utf8.count)
        let needed = -llama_tokenize(vocab, text, len, nil, 0, true, true)
        guard needed > 0 else { throw EngineError.tokenizeFailed }
        var out = [llama_token](repeating: 0, count: Int(needed))
        let n = llama_tokenize(vocab, text, len, &out, needed, true, true)
        guard n >= 0 else { throw EngineError.tokenizeFailed }
        return Array(out.prefix(Int(n)))
    }

    private static func ms(since t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
    }
}

/// Read from llama.cpp's compute threads via the abort callback.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}
