import Foundation

/// Verify the CLI contract with synthetic logs before reading the user's cost data.
/// A successful probe is reused until the executable, version, or pricing changes.
public final class CCUsageCompatibility {
    public typealias Report = (String, URL, String, TimeInterval) throws -> Data
    private let report: Report
    private let clock: () -> TimeInterval
    private var validatedSignature: String?

    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                report: @escaping Report = { try Pricing.report(executable: $0, home: $1, since: $2, timeout: $3) }) {
        self.report = report
        self.clock = clock
    }

    public func verify(executable: String, signature: String) throws {
        guard signature != validatedSignature else { return }
        do {
            try probe(executable: executable)
            validatedSignature = signature
        } catch {
            throw TelemetryError.message("ccusage 兼容性检查失败：\(error.localizedDescription)")
        }
    }

    private func probe(executable: String) throws {
        let deadline = clock() + 20
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codexspeed-compat-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)

        let cases: [(String, Int, Int, Double)] = [
            ("gpt-6-astra", 1000, 200, 0.0132),
            ("gpt-5.6-sol", 1000, 200, 0.00528),
            ("gpt-5.6-terra", 1000, 200, 0.00284),
            ("gpt-5.6-luna", 1000, 200, 0.000284),
            // Overrides must also hold above ccusage's legacy 200K tier boundary.
            ("gpt-6-astra", 250_000, 50_000, 2.055)
        ]
        for (model, input, cached, cost) in cases {
            for (tier, multiplier) in [("default", 1.0), ("priority", 2.0)] {
                let remaining = deadline - clock()
                guard remaining > 0 else { throw TelemetryError.message("检查超时；请重试") }
                try fixture(model: model, input: input, cached: cached, tier: tier, date: "2026-09-21", id: "included")
                    .write(to: sessions.appendingPathComponent("rollout-included.jsonl"), options: .atomic)
                try fixture(model: model, input: input, cached: cached, tier: tier, date: "2026-09-20", id: "excluded")
                    .write(to: sessions.appendingPathComponent("rollout-excluded.jsonl"), options: .atomic)
                let data = try report(executable, root, "2026-09-21", min(5, remaining))
                guard clock() <= deadline else { throw TelemetryError.message("检查超时；请重试") }
                let parsed = try CostReport.parse(data)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let daily = object["daily"] as? [[String: Any]], daily.count == 1,
                      daily[0]["date"] as? String == "2026-09-21",
                      let models = daily[0]["models"] as? [String: [String: Any]],
                      models.count == 1, let usage = models[model],
                      usage["totalTokens"] as? Int == input + 100,
                      usage["cacheReadTokens"] as? Int == cached,
                      abs(parsed.cost - cost * multiplier) < 0.00000001 else {
                    throw TelemetryError.message("命令参数、日期筛选、JSON 或价格覆盖不兼容；请更新 ccusage")
                }
            }
        }
    }

    private func fixture(model: String, input: Int, cached: Int, tier: String, date: String, id: String) throws -> Data {
        let usage: [String: Any] = ["input_tokens": input, "cached_input_tokens": cached,
                                    "output_tokens": 100, "reasoning_output_tokens": 20, "total_tokens": input + 100]
        let records: [(String, [String: Any])] = [
            ("session_meta", ["id": id, "originator": "Codex Desktop", "cli_version": "0.155.0", "source": "vscode"]),
            ("turn_context", ["turn_id": "a", "model": model]),
            ("event_msg", ["type": "thread_settings_applied", "thread_settings": ["model": model, "service_tier": tier]]),
            ("event_msg", ["type": "token_count", "info": ["total_token_usage": usage, "last_token_usage": usage]])
        ]
        var data = Data()
        for (type, payload) in records {
            data.append(try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "\(date)T16:00:00.000Z", "payload": payload]))
            data.append(10)
        }
        return data
    }
}
