import Foundation

public struct Calibration: Codable {
    public var limit: Limit
    public var firstCost: Double, lastCost: Double, firstUsed: Double
    public var firstDate: Date, lastDate: Date
    public var samples: Int
    public var total: Double? {
        let delta=limit.used-firstUsed
        guard samples>=3, lastDate.timeIntervalSince(firstDate)>=600, delta>=5, lastCost>firstCost else { return nil }
        let value=100*(lastCost-firstCost)/delta
        return value.isFinite ? value : nil
    }
    public var remaining: Double? { total.map { $0 * limit.remaining/100 } }
    public init(limit: Limit, cost: Double, date: Date) {
        self.limit=limit; firstCost=cost; lastCost=cost; firstUsed=limit.used; firstDate=date; lastDate=date; samples=1
    }
    public mutating func add(limit next: Limit, cost: Double, date: Date) {
        guard cost.isFinite, cost>=0, date>=lastDate else { return }
        if !limit.sameWindow(next) || next.used<limit.used || cost<lastCost || next.reset<=date.timeIntervalSince1970 {
            self=Calibration(limit:next,cost:cost,date:date); return
        }
        // Never turn repeated stale snapshots into independent observations.
        guard next.observed>limit.observed, date>lastDate else { return }
        limit=next; lastCost=cost; lastDate=date; samples += 1
    }
}
public struct CostReport {
    public var cost: Double
    public var fallback: Bool
    public var fingerprint: String
    public static func parse(_ data: Data) throws -> CostReport {
        guard let d=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let totals=d["totals"] as? [String:Any], let cost=totals["costUSD"] as? Double,
              cost.isFinite, cost>=0, let days=d["daily"] as? [[String:Any]] else { throw TelemetryError.message("ccusage JSON 格式不兼容或费用缺失") }
        let fallback=days.contains { day in
            (day["models"] as? [String:[String:Any]] ?? [:]).values.contains { $0["isFallback"] as? Bool == true }
        }
        if (totals["totalTokens"] as? Double ?? 0)>0 && cost==0 {
            throw TelemetryError.message("ccusage 有用量但费用为零，价格可能缺失；暂停额度估算")
        }
        // Closed days are stable: repricing or removed history invalidates calibration.
        let today=Self.dateString(Date())
        let historical=days.filter { ($0["date"] as? String ?? "") != today }.sorted { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }
        let fingerprint=historical.map { "\($0["date"] ?? ""):\($0["costUSD"] ?? "")" }.joined(separator:"|")
        return CostReport(cost:cost,fallback:fallback,fingerprint:fingerprint)
    }
    public static func dateString(_ date: Date) -> String {
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=TimeZone(secondsFromGMT:0); f.dateFormat="yyyy-MM-dd"; return f.string(from:date)
    }
}
public enum TelemetryError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let s): return s } }
}
public enum CommandRunner {
    public static func runtimePath(_ path: String) -> String {
        let script=URL(fileURLWithPath:path).resolvingSymlinksInPath()
        guard script.lastPathComponent == "cli.js",script.deletingLastPathComponent().lastPathComponent == "src" else { return path }
        let package=script.deletingLastPathComponent().deletingLastPathComponent()
        guard let data=try? Data(contentsOf:package.appendingPathComponent("package.json")),
              let metadata=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],metadata["name"] as? String == "ccusage" else { return path }
        #if arch(arm64)
        let arch="arm64"
        #else
        let arch="x64"
        #endif
        let native=package.appendingPathComponent("node_modules/@ccusage/ccusage-darwin-\(arch)/bin/ccusage").path
        return FileManager.default.isExecutableFile(atPath:native) ? native : path
    }
    public static func run(path: String, arguments: [String], environment: [String:String] = [:], timeout: TimeInterval = 30) throws -> Data {
        let process=Process(); process.executableURL=URL(fileURLWithPath:runtimePath(path)); process.arguments=arguments
        let inherited=ProcessInfo.processInfo.environment
        var env=[String:String]()
        for key in ["HOME","TMPDIR","LANG","LC_ALL","LC_CTYPE"] { env[key]=inherited[key] }
        env["PATH"]="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["NO_COLOR"]="1"
        for (key,value) in environment { env[key]=value }
        process.environment=env
        // Files avoid pipe backpressure when reports exceed a pipe buffer.
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:temp) }
        let out=temp.appendingPathComponent("out"), err=temp.appendingPathComponent("err")
        FileManager.default.createFile(atPath:out.path,contents:nil,attributes:[.posixPermissions:0o600]); FileManager.default.createFile(atPath:err.path,contents:nil,attributes:[.posixPermissions:0o600])
        let output=try FileHandle(forWritingTo:out), errors=try FileHandle(forWritingTo:err)
        defer { try? output.close(); try? errors.close() }
        process.standardOutput=output; process.standardError=errors
        try process.run()
        let deadline=Date().addingTimeInterval(timeout)
        func oversized() -> Bool {
            for (url,limit) in [(out,8*1024*1024),(err,1024*1024)] {
                if let size=(try? FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber, size.int64Value>limit { return true }
            }
            return false
        }
        while process.isRunning && Date()<deadline && !oversized() { Thread.sleep(forTimeInterval:0.05) }
        let exceeded=oversized()
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval:0.15)
            if process.isRunning { kill(process.processIdentifier,SIGKILL) }
            process.waitUntilExit()
            if exceeded { throw TelemetryError.message("ccusage 输出超过安全上限") }
            throw TelemetryError.message("ccusage 超时（\(SafeNumber.integer(timeout)) 秒）")
        }
        guard !exceeded else { throw TelemetryError.message("ccusage 输出超过安全上限") }
        guard process.terminationStatus == 0 else { throw TelemetryError.message("ccusage 执行失败（退出码 \(process.terminationStatus)）") }
        return try Data(contentsOf:out)
    }
}
