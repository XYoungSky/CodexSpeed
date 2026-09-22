import Foundation

public enum SafeNumber {
    public static func integer(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(exactly:value.rounded(.towardZero)) ?? 0
    }
}

public struct Usage: Codable, Equatable {
    public var input: Double = 0, output: Double = 0, reasoning: Double = 0
    init(_ d: [String: Any]) {
        input = (d["input_tokens"] as? NSNumber)?.doubleValue ?? 0
        output = (d["output_tokens"] as? NSNumber)?.doubleValue ?? 0
        reasoning = (d["reasoning_output_tokens"] as? NSNumber)?.doubleValue ?? 0
    }
    public init() {}
}
public struct Limit: Codable, Equatable, Identifiable {
    public var id: String, plan: String
    public var used: Double, minutes: Double, reset: Double
    public var observed: Date
    public var remaining: Double { max(0, min(100, 100-used)) }
    public var name: String { minutes >= 1440 ? "\(SafeNumber.integer(minutes/1440)) 天额度" : "\(SafeNumber.integer(minutes/60)) 小时额度" }
    public init(id: String, plan: String = "", used: Double, minutes: Double, reset: Double, observed: Date) {
        self.id=id; self.plan=plan; self.used=used; self.minutes=minutes; self.reset=reset; self.observed=observed
    }
    public func sameWindow(_ other: Limit) -> Bool {
        id == other.id && plan == other.plan && minutes == other.minutes && abs(reset-other.reset) <= 5
    }
    public func sameSnapshot(_ other: Limit) -> Bool { sameWindow(other) && used == other.used }
}
public struct Session: Identifiable {
    public var id = "", project = "", model = "未知模型", origin = ""
    public var subagent = false, running = false
    public var status = TaskPhase.idle
    public var activity = Date.distantPast
    public var turn = "", usage = Usage(), context: Double?, lastInput: Double?
    public var speed: Double?, ttft: Double?, started: Date?
    public var duration: TimeInterval?
    public var recentSpeed: Double?, speedObserved: Date?
    public func displaySpeed(at date: Date) -> Double? {
        guard running else { return speed }
        guard let observed=speedObserved, (0...10).contains(date.timeIntervalSince(observed)) else { return nil }
        return recentSpeed
    }
    public var eligible: Bool { origin == "Codex Desktop" && !subagent && model != "codex-auto-review" }
    public var contextPercent: Double? { guard let input=lastInput, let c=context, c>0 else { return nil }; return input/c*100 }
}
public struct RateSnapshot {
    public var observed: Date
    public var limits: [Limit]
}
public final class RolloutParser {
    public private(set) var session = Session()
    public private(set) var limits: [Limit] = []
    public private(set) var rateSnapshots: [String:RateSnapshot] = [:]
    public private(set) var malformed = 0
    public private(set) var unsupportedPricingDate: Date?
    private var total: Usage?, baseline: Usage?, hasTurnUsage = false
    private var completed = Set<String>()
    private var speedSamples: [(date:Date, output:Double)] = []
    private static let iso = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = { let f=ISO8601DateFormatter(); f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]; return f }()
    private static let typePattern=try! NSRegularExpression(pattern:"\"type\"\\s*:\\s*\"([^\"]+)\"")
    private static let payloadPattern=try! NSRegularExpression(pattern:"\"payload\"\\s*:")
    private static let acceptedTop: Set<String>=["session_meta","turn_context","token_usage_record","event_msg"]
    private static let acceptedEvents: Set<String>=["task_started","task_complete","token_count","turn_aborted"]
    public init() {}
    public func consume(_ data: Data) {
        // Inspect only the envelope before decoding. Conversation/tool bodies may be megabytes.
        // If a nonstandard key order makes the envelope ambiguous, use the full JSON decoder.
        let prefix=String(decoding:data.prefix(768),as:UTF8.self)
        let range=NSRange(prefix.startIndex...,in:prefix)
        if let match=Self.typePattern.firstMatch(in:prefix,range:range),
           let payload=Self.payloadPattern.firstMatch(in:prefix,range:range),match.range.location<payload.range.location,
           let capture=Range(match.range(at:1),in:prefix) {
            let top=String(prefix[capture])
            if !Self.acceptedTop.contains(top) { return }
            if top == "event_msg" {
                let nested=NSRange(location:payload.range.upperBound,length:(prefix as NSString).length-payload.range.upperBound)
                if let m=Self.typePattern.firstMatch(in:prefix,range:nested),let r=Range(m.range(at:1),in:prefix),!Self.acceptedEvents.contains(String(prefix[r])) { return }
            }
        }
        guard let e=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any], let d=e["payload"] as? [String:Any] else { malformed += 1; return }
        let kind=e["type"] as? String ?? ""
        let type=kind == "event_msg" ? d["type"] as? String ?? kind : kind
        let ts=e["timestamp"] as? String ?? ""
        let date=Self.fractional.date(from:ts) ?? Self.iso.date(from:ts) ?? .distantPast
        switch type {
        case "session_meta":
            session.id=d["id"] as? String ?? session.id
            session.project=(d["cwd"] as? String).map { URL(fileURLWithPath:$0).lastPathComponent } ?? "未知项目"
            session.origin=d["originator"] as? String ?? ""
            session.subagent=(d["source"] as? [String:Any])?["subagent"] != nil
        case "task_started":
            let turn=d["turn_id"] as? String ?? ""
            guard turn != session.turn else { return }
            session.turn=turn; session.running=true; session.started=date; session.usage=Usage(); session.ttft=nil; session.duration=nil
            baseline=total; hasTurnUsage=false; session.status = .running
            speedSamples=[(date,0)]; session.recentSpeed=nil; session.speedObserved=nil
            session.context=(d["model_context_window"] as? NSNumber)?.doubleValue ?? session.context
            session.activity=date
        case "turn_context":
            session.model=d["model"] as? String ?? session.model
        case "token_usage_record":
            guard d["turn_id"] as? String == session.turn, let u=d["turn_token_usage"] as? [String:Any] else { return }
            session.usage=Usage(u); hasTurnUsage=true
            if let u=d["usage"] as? [String:Any] { session.lastInput=Usage(u).input }
            if let u=d["thread_token_usage"] as? [String:Any] { total=Usage(u) }
            session.activity=date
        case "token_count":
            if let info=d["info"] as? [String:Any] {
                session.context=(info["model_context_window"] as? NSNumber)?.doubleValue ?? session.context
                if let u=info["last_token_usage"] as? [String:Any] { session.lastInput=Usage(u).input }
                if let u=info["total_token_usage"] as? [String:Any] {
                    let next=Usage(u)
                    if !hasTurnUsage && session.running {
                        let base=baseline ?? Usage()
                        if next.output >= base.output && next.reasoning >= base.reasoning {
                            session.usage.output=next.output-base.output; session.usage.reasoning=next.reasoning-base.reasoning
                        } else { session.usage=Usage(); baseline=next; session.speed=nil }
                    }
                    total=next
                }
            }
            if let rates=d["rate_limits"] as? [String:Any] {
                let bucket=rates["limit_id"] as? String ?? "codex"
                var updated: [Limit] = []
                for slot in ["primary","secondary"] {
                    if let l=rates[slot] as? [String:Any], let used=l["used_percent"] as? Double, let minutes=l["window_minutes"] as? Double, let reset=l["resets_at"] as? Double, (0...100).contains(used), minutes.isFinite, (0...5_256_000).contains(minutes), minutes>0, reset.isFinite, (0...253_402_300_799).contains(reset) {
                        updated.append(Limit(id:bucket+":"+slot, plan:rates["plan_type"] as? String ?? "", used:used, minutes:minutes, reset:reset, observed:date))
                    }
                }
                if date >= (rateSnapshots[bucket]?.observed ?? .distantPast) {
                    rateSnapshots[bucket]=RateSnapshot(observed:date,limits:updated)
                    limits=rateSnapshots.values.flatMap { $0.limits }
                }
            }
            session.activity=date
        case "task_complete":
            guard let turn=d["turn_id"] as? String, turn == session.turn, completed.insert(turn).inserted else { return }
            session.running=false; session.activity=date; session.status = .completed
            let elapsed=session.started.map { max(0,date.timeIntervalSince($0)) }
            if let ms=d["duration_ms"] as? Double, ms.isFinite, ms>0 {
                session.duration=ms/1000; session.speed=session.usage.output/(ms/1000)
            } else { session.duration=elapsed; session.speed=nil }
            session.ttft=(d["time_to_first_token_ms"] as? Double).map { $0/1000 }
        case "turn_aborted":
            if let turn=d["turn_id"] as? String, turn != session.turn { return }
            session.running=false; session.activity=date; session.status = .interrupted
            session.duration=session.started.map { max(0,date.timeIntervalSince($0)) }

        default: break
        }
        if ["token_count","token_usage_record"].contains(type), session.running {
            updateSpeed(at:date)
        }
        if ["token_count","token_usage_record"].contains(type),Pricing.modernModels.contains(session.model),
           let input=session.lastInput,input>272_000 { unsupportedPricingDate=date }
    }
    private func updateSpeed(at date: Date) {
        let output=session.usage.output
        guard output.isFinite, output>=0, let last=speedSamples.last, date>=last.date else { return }
        if output<last.output {
            speedSamples=[(date,output)]; session.recentSpeed=nil; session.speedObserved=nil; return
        }
        guard output>last.output else { return } // duplicate counters do not refresh stale rates
        if date == last.date { speedSamples[speedSamples.count-1].output=output }
        else { speedSamples.append((date,output)) }
        // Keep the point immediately before the ten-second window as its baseline.
        while speedSamples.count>2 && speedSamples[1].date < date.addingTimeInterval(-10) { speedSamples.removeFirst() }
        if speedSamples.count>32 { speedSamples.removeFirst(speedSamples.count-32) }
        guard let first=speedSamples.first else { return }
        let seconds=date.timeIntervalSince(first.date)
        guard seconds>0 else { return }
        let rate=(output-first.output)/seconds
        guard rate.isFinite, rate>=0 else { return }
        session.recentSpeed=rate; session.speedObserved=date
    }

}

public final class IncrementalFile {
    public private(set) var parser=RolloutParser()
    private var offset: UInt64=0, buffer=Data(), inode: UInt64=0
    private var discardingLine=false
    private let maxLineBytes=16*1024*1024
    public private(set) var bytesRead: UInt64=0
    public init() {}
    @discardableResult public func read(_ url: URL) throws -> Bool {
        let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
        let size=(attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let current=(attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let reset=size<offset || current != inode
        if reset { offset=0; buffer=Data(); discardingLine=false; parser=RolloutParser(); inode=current }
        guard size>offset else { return reset }
        let file=try FileHandle(forReadingFrom:url); defer { try? file.close() }
        try file.seek(toOffset:offset)
        while offset<size {
            let data=try file.read(upToCount:Int(min(256*1024,size-offset))) ?? Data()
            if data.isEmpty { break }
            offset += UInt64(data.count); bytesRead += UInt64(data.count)
            // Scan each incoming byte once; never rescan the accumulated partial line.
            var start=data.startIndex
            while start<data.endIndex {
                let end=data[start...].firstIndex(of:10)
                let stop=end ?? data.endIndex
                if !discardingLine {
                    if buffer.count + (stop-start) > maxLineBytes {
                        buffer.removeAll(keepingCapacity:false); discardingLine=true
                    } else { buffer.append(contentsOf:data[start..<stop]) }
                }
                if let end=end {
                    if !discardingLine && !buffer.isEmpty { parser.consume(buffer) }
                    buffer.removeAll(keepingCapacity:true); discardingLine=false
                    start=end+1
                } else { break }
            }
        }
        return true
    }
}
