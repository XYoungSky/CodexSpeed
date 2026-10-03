import Foundation
import CoreFoundation
import CryptoKit

/// A local snapshot. Network access happens only from the Settings action.
public struct PricingCatalog: Codable {
    public static let source = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    public var updated: Date?
    public var overrides: [String: [String: Double]] = [:]
    public init() {}

    public var configData: Data {
        let builtIn = try! JSONSerialization.jsonObject(with: Pricing.configData) as! [String: Any]
        let codex = builtIn["codex"] as! [String: Any]
        let defaults = codex["defaults"] as! [String: Any]
        var prices = defaults["pricingOverrides"] as! [String: [String: Double]]
        prices.merge(overrides) { _, downloaded in downloaded }
        return try! JSONSerialization.data(withJSONObject: ["codex": ["defaults": ["pricingOverrides": prices]]], options: [.sortedKeys])
    }
    public var signature: String {
        SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined()
    }

    public static func parse(_ data: Data, date: Date = Date()) throws -> PricingCatalog {
        guard data.count <= 20 * 1024 * 1024,
              let models = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TelemetryError.message("价格数据格式无效")
        }
        var result = PricingCatalog()
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 1 else { return nil }
            return n.doubleValue
        }
        for (key, value) in models {
            guard let row = value as? [String: Any], row["litellm_provider"] as? String == "openai",
                  ["chat", "responses"].contains(row["mode"] as? String ?? "") else { continue }
            let model = key.hasPrefix("openai/") ? String(key.dropFirst(7)) : key
            guard model.hasPrefix("gpt-"), !model.contains("/"), model.count < 150,
                  let input = number(row["input_cost_per_token"]), input > 0,
                  let output = number(row["output_cost_per_token"]), output > 0 else { continue }
            let cached: Double
            if let value = row["cache_read_input_token_cost"] {
                guard let valid = number(value) else { continue }; cached = valid
            } else { cached = input }
            let write: Double
            if let value = row["cache_creation_input_token_cost"] {
                guard let valid = number(value) else { continue }; write = valid
            } else { write = input }
            var price = ["inputCostPerToken": input, "outputCostPerToken": output,
                         "cacheReadInputTokenCost": cached, "cacheCreationInputTokenCost": write,
                         "fastMultiplier": 2.0]
            // ccusage's legacy tier boundary is 200K. Modern 272K requests are
            // guarded by the log parser; new models above 200K remain unverified.
            for (field, rate) in [("inputCostPerToken", input), ("outputCostPerToken", output),
                                  ("cacheReadInputTokenCost", cached), ("cacheCreationInputTokenCost", write)] {
                let sourceFields = ["inputCostPerToken": "input_cost_per_token", "outputCostPerToken": "output_cost_per_token",
                                    "cacheReadInputTokenCost": "cache_read_input_token_cost", "cacheCreationInputTokenCost": "cache_creation_input_token_cost"]
                let longRate = number(row[sourceFields[field]! + "_above_200k_tokens"])
                price[field + "Above200kTokens"] = Pricing.modernModels.contains(model) ? rate : (longRate ?? rate)
            }
            // Prefer canonical entries when both prefixed and bare keys exist.
            if result.overrides[model] == nil || key == model { result.overrides[model] = price }
        }
        guard !result.overrides.isEmpty else { throw TelemetryError.message("未找到有效的 OpenAI 模型价格") }
        result.updated = date
        return result
    }

    public static func load(from url: URL) -> PricingCatalog {
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(PricingCatalog.self, from: data),
              catalog.overrides.values.allSatisfy({ row in
                  row.values.allSatisfy { $0.isFinite && $0 >= 0 } &&
                  (row["inputCostPerToken"] ?? 0) > 0 && (row["outputCostPerToken"] ?? 0) > 0
              }) else { return PricingCatalog() }
        return catalog
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    public static func download() async throws -> PricingCatalog {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: source)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TelemetryError.message("价格下载失败，请稍后重试")
        }
        return try parse(data)
    }
}
