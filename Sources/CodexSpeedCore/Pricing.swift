import Foundation

/// Snapshot verified 2026-09-23 against https://developers.openai.com/api/docs/pricing
/// ccusage 20.0.20's offline catalog predates these models and silently prices them at zero.
public enum Pricing {
    public static let revision="openai-standard-2026-09-23-v1"
    public static let modernModels: Set<String>=["gpt-6-astra","gpt-6-sol","gpt-6-luna","gpt-5.6-sol","gpt-5.6-terra","gpt-5.6-luna"]
    public static let supportedModels=modernModels.union(["gpt-5.5","gpt-5.4","gpt-5.4-mini","gpt-5.4-nano","gpt-5.3-codex","gpt-5.2","gpt-5.2-codex","gpt-5.1","gpt-5.1-codex","gpt-5.1-codex-max","gpt-5.1-codex-mini","gpt-5","gpt-5-codex","gpt-5-mini","gpt-5-nano"])
    public static var configData: Data {
        var overrides=[String:[String:Double]]()
        for (model,input,cached,output) in [("gpt-6-astra",10.0,1.0,50.0),("gpt-6-sol",2.0,0.2,10.0),("gpt-6-luna",0.1,0.01,0.5),("gpt-5.6-sol",4.0,0.4,20.0),("gpt-5.6-terra",2.0,0.2,12.0),("gpt-5.6-luna",0.2,0.02,1.2)] {
            overrides[model]=["inputCostPerToken":input/1e6,"cacheReadInputTokenCost":cached/1e6,"cacheCreationInputTokenCost":input*1.25/1e6,"outputCostPerToken":output/1e6,"fastMultiplier":2,
                // ccusage's old schema fixes its tier threshold at 200K; avoid applying it
                // to these models, whose threshold is 272K. Such requests are gated below.
                "inputCostPerTokenAbove200kTokens":input/1e6,"cacheReadInputTokenCostAbove200kTokens":cached/1e6,"cacheCreationInputTokenCostAbove200kTokens":input*1.25/1e6,"outputCostPerTokenAbove200kTokens":output/1e6]
        }
        return try! JSONSerialization.data(withJSONObject:["codex":["defaults":["pricingOverrides":overrides]]],options:[.sortedKeys,.prettyPrinted])
    }
    public static func validate(_ data: Data) throws {
        guard let report=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let days=report["daily"] as? [[String:Any]] else {
            throw TelemetryError.message("ccusage JSON 格式不兼容或模型用量缺失")
        }
        var unknown=Set<String>()
        for day in days {
            guard let models=day["models"] as? [String:[String:Any]] else {
                throw TelemetryError.message("ccusage JSON 格式不兼容或模型用量缺失")
            }
            for (name,usage) in models {
                guard let tokens=CostReport.nonnegativeNumber(usage["totalTokens"]) else {
                    throw TelemetryError.message("ccusage JSON 格式不兼容或模型用量缺失")
                }
                if !supportedModels.contains(name), tokens>0 { unknown.insert(name) }
            }
        }
        if !unknown.isEmpty { throw TelemetryError.message("模型价格未验证："+unknown.sorted().joined(separator:", ")+"；暂停额度校准") }
    }
    public static func report(executable: String, home: URL, since: String, timeout: TimeInterval = 30) throws -> Data {
        let config=FileManager.default.temporaryDirectory.appendingPathComponent("codexspeed-pricing-\(UUID().uuidString).json")
        try configData.write(to:config,options:.atomic)
        defer { try? FileManager.default.removeItem(at:config) }
        let data=try CommandRunner.run(path:executable,arguments:["codex","daily","--json","--offline","--speed","auto","--since",since,"--timezone","UTC","--config",config.path],environment:["CODEX_HOME":home.path],timeout:timeout)
        try validate(data)
        return data
    }
}
