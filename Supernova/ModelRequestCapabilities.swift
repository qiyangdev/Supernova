import OpenAI

extension Model {
    var contextWindowSize: Int? {
        // Published context windows for the models in the current picker.
        switch self {
        case .gpt6_astra, .gpt6_sol, .gpt6_luna, .gpt5_6_sol, .gpt5_6_terra, .gpt5_6_luna:
            1_050_000
        default:
            nil
        }
    }

    var supportsFastMode: Bool {
        // https://developers.openai.com/api/docs/guides/fast-mode
        switch self {
        case .gpt6_astra, .gpt6_sol, .gpt6_luna, .gpt5_6_sol:
            true
        default:
            false
        }
    }
}

struct ContextWindowUsage: Equatable {
    let model: String
    let totalTokens: Int

    var fraction: Double? {
        guard let limit = model.contextWindowSize else { return nil }
        return Double(totalTokens) / Double(limit)
    }
}
