import Foundation
import CodexSpeedCore


private var failures=0
func check(_ ok: Bool, _ file: StaticString, _ line: UInt) { if !ok { failures += 1; print("FAIL \(file):\(line)") } }
func expectEqual<T: Equatable>(_ a:T,_ b:T,file:StaticString=#filePath,line:UInt=#line) { check(a==b,file,line) }
func expectTrue(_ a:Bool,file:StaticString=#filePath,line:UInt=#line) { check(a,file,line) }
func expectFalse(_ a:Bool,file:StaticString=#filePath,line:UInt=#line) { check(!a,file,line) }
func expectNil<T>(_ a:T?,file:StaticString=#filePath,line:UInt=#line) { check(a == nil,file,line) }
func expectThrows<T>(_ expression: @autoclosure () throws -> T,file:StaticString=#filePath,line:UInt=#line) { do { _ = try expression(); check(false,file,line) } catch {} }

final class CoreTests {
    func testRecentSpeed() {
        let p=RolloutParser(); start(p)
        let clock=ISO8601DateFormatter().date(from:"2026-09-21T16:00:00Z")!
        func usage(_ output: Double, _ second: Int) {
            p.consume(event("token_usage_record",["turn_id":"a","turn_token_usage":["output_tokens":output]],String(format:"2026-09-21T16:00:%02d.000Z",second)))
        }
        expectNil(p.session.displaySpeed(at:clock))
        usage(100,2)
        expectEqual(p.session.displaySpeed(at:clock.addingTimeInterval(2)),50)
        usage(100,3) // duplicates cannot manufacture fresh telemetry
        expectEqual(p.session.speedObserved,clock.addingTimeInterval(2))
        expectNil(p.session.displaySpeed(at:clock.addingTimeInterval(13)))
        usage(300,4)
        expectEqual(p.session.displaySpeed(at:clock.addingTimeInterval(4)),75)
        usage(10,5) // counter reset must not produce a negative/spiking speed
        expectNil(p.session.displaySpeed(at:clock.addingTimeInterval(5)))
        usage(30,7)
        expectEqual(p.session.displaySpeed(at:clock.addingTimeInterval(7)),10)
        p.consume(event("task_complete",["turn_id":"a","duration_ms":10000]))
        expectEqual(p.session.displaySpeed(at:clock.addingTimeInterval(30)),3)
        start(p,"b")
        expectNil(p.session.displaySpeed(at:clock))
        expectNil(p.session.duration)
    }
    func testLifecycleStatus() {
        let p=RolloutParser()
        expectEqual(p.session.status,.idle)
        p.consume(event("task_started",["turn_id":"a"]))
        expectEqual(p.session.status,.running)
        // Conversation text cannot spoof approval or waiting states.
        p.consume(event("response_item",["type":"message","role":"user","content":[["type":"input_text","text":"request_user_input require_escalated"]]]))
        expectEqual(p.session.status,.running)
        p.consume(event("turn_aborted",["turn_id":"other"]))
        expectEqual(p.session.status,.running)
        p.consume(event("turn_aborted",["turn_id":"a"]))
        expectEqual(p.session.status,.interrupted)
        expectFalse(p.session.running)
        p.consume(event("task_started",["turn_id":"b"]))
        expectEqual(p.session.status,.running)
        p.consume(event("task_complete",["turn_id":"a"]))
        expectEqual(p.session.status,.running)
        p.consume(event("task_complete",["turn_id":"b","duration_ms":123000]))
        expectEqual(p.session.status,.completed)
        expectEqual(p.session.duration,123)
    }
    func testUnsafeNumbers() {
        for value in [Double.infinity,Double.nan,1e100,-1e100] { expectEqual(SafeNumber.integer(value),0) }
        expectEqual(SafeNumber.integer(42.9),42)
        let p=RolloutParser()
        p.consume(Data(#"{"type":"event_msg","timestamp":"2026-09-21T16:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":20,"window_minutes":1e100,"resets_at":2000000000}}}}"#.utf8))
        expectTrue(p.limits.isEmpty)
    }
    func testOversizedLineRecovery() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        var data=Data(repeating:65,count:17*1024*1024)
        // A JSON-looking tail of an oversized line must not be interpreted as a record.
        data.append(event("session_meta",["id":"fake","originator":"Codex Desktop"])); data.append(10)
        try data.write(to:url)
        let f=IncrementalFile(); try f.read(url); expectEqual(f.parser.session.id,"")
        let handle=try FileHandle(forWritingTo:url); try handle.seekToEnd()
        var line=event("session_meta",["id":"real","originator":"Codex Desktop"]); line.append(10)
        try handle.write(contentsOf:line); try handle.close(); try f.read(url)
        expectEqual(f.parser.session.id,"real")
    }
    func testCommandOutputLimitAndEnvironment() throws {
        setenv("CODEXSPEED_AUDIT_SECRET","test-only",1)
        defer { unsetenv("CODEXSPEED_AUDIT_SECRET") }
        let output=try CommandRunner.run(path:"/usr/bin/env",arguments:[])
        expectFalse(String(decoding:output,as:UTF8.self).contains("CODEXSPEED_AUDIT_SECRET"))
        expectThrows(try CommandRunner.run(path:"/bin/dd",arguments:["if=/dev/zero","bs=1048576","count=9"]))
    }
    func testRecentLogWindow() throws {
        let now=ISO8601DateFormatter().date(from:"2026-09-22T12:00:00Z")!
        let cutoff=LogWindow.cutoff(now:now)
        expectEqual(CostReport.dateString(cutoff),"2026-09-09")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("rollout-2020-01-01-old-task.jsonl")
        try Data("{}\n".utf8).write(to:file)
        func included(at date: Date) throws -> Bool {
            try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:file.path)
            return try LogWindow.includes(URL(fileURLWithPath:file.path),cutoff:cutoff)
        }
        expectFalse(try included(at:cutoff.addingTimeInterval(-1)))
        expectTrue(try included(at:cutoff))
        expectTrue(try included(at:now)) // old filename, recently resumed
        expectFalse(try LogWindow.includes(root,cutoff:cutoff))
    }
    func testHotRefreshAndResumedTask() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions=root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at:sessions,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var clock=Date()
        let hot=sessions.appendingPathComponent("rollout-hot.jsonl")
        let cold=sessions.appendingPathComponent("rollout-cold.jsonl")
        let ancient=sessions.appendingPathComponent("rollout-ancient.jsonl")
        for (url,age) in [(hot,0.0),(cold,3.0),(ancient,30.0)] {
            var data=event("session_meta",["id":url.lastPathComponent,"originator":"Codex Desktop"]); data.append(10)
            try data.write(to:url)
            try FileManager.default.setAttributes([.modificationDate:clock.addingTimeInterval(-age*86400)],ofItemAtPath:url.path)
        }
        let monitor=Monitor(home:root,executable:"/missing-audit-ccusage",storage:root.appendingPathComponent("state.json"),now:{clock})
        func tick() -> MonitorSnapshot? {
            var result: MonitorSnapshot?
            monitor.tick { if result == nil { result=$0 } }
            let deadline=Date().addingTimeInterval(5)
            while result == nil && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
            return result
        }
        let initial=tick()
        expectEqual(initial?.fileCount,2); expectEqual(initial?.checkedFileCount,2)
        clock=clock.addingTimeInterval(1)
        let idle=tick()
        expectEqual(idle?.checkedFileCount,1)
        expectEqual(idle?.bytesRead,initial?.bytesRead)
        expectEqual(idle?.sessions.count,2) // historical state is cached
        var extra=event("turn_context",["model":"resumed"]); extra.append(10)
        for url in [cold,ancient] {
            let handle=try FileHandle(forWritingTo:url)
            try handle.seekToEnd(); try handle.write(contentsOf:extra); try handle.close()
            try FileManager.default.setAttributes([.modificationDate:clock],ofItemAtPath:url.path)
        }
        expectEqual(tick()?.bytesRead,idle?.bytesRead) // no historical stat/read on hot ticks
        clock=clock.addingTimeInterval(31)
        let resumed=tick()
        expectEqual(resumed?.fileCount,3); expectEqual(resumed?.checkedFileCount,3)
        expectEqual(resumed?.sessions.filter { $0.model == "resumed" }.count,2)
        try Data().write(to:hot)
        expectEqual(tick()?.sessions.count,2) // truncating an active file clears cached state
        clock=clock.addingTimeInterval(86401)
        expectEqual(tick()?.checkedFileCount,0) // exact rolling 24h expiration
        monitor.stop()
    }
    func testMonitorSkipsOldContents() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions=root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at:sessions,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        for (name,modified) in [("old",LogWindow.cutoff().addingTimeInterval(-1)),("recent",Date())] {
            var line=event("session_meta",["id":name,"originator":"Codex Desktop"]); line.append(10)
            let url=sessions.appendingPathComponent("rollout-\(name).jsonl")
            try line.write(to:url)
            try FileManager.default.setAttributes([.modificationDate:modified],ofItemAtPath:url.path)
        }
        let storage=root.appendingPathComponent("state.json")
        try Data(#"{"since":"2020-01-01","calibrations":{},"signature":"","history":{}}"#.utf8).write(to:storage)
        let monitor=Monitor(home:root,executable:"/missing-audit-ccusage",storage:storage)
        var snapshot: MonitorSnapshot?
        monitor.tick { snapshot=$0 }
        let deadline=Date().addingTimeInterval(5)
        while snapshot == nil && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        expectEqual(snapshot?.fileCount,1)
        expectEqual(snapshot?.sessions.map(\.id),["recent"])
        let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:storage)) as! [String:Any]
        expectEqual(saved["since"] as? String,CostReport.dateString(Date()))
        monitor.stop()
    }
    func event(_ type:String,_ payload:[String:Any],_ time:String="2026-09-21T16:00:00.000Z") -> Data {
        var p=payload
        let top=["session_meta","turn_context","token_usage_record","response_item"].contains(type)
        if !top { p["type"]=type }
        return try! JSONSerialization.data(withJSONObject:["type":top ? type : "event_msg","timestamp":time,"payload":p])
    }
    func start(_ p:RolloutParser,_ id:String="a") { p.consume(event("task_started",["turn_id":id,"model_context_window":10000])) }
    func count(_ p:RolloutParser,_ output:Double) {
        p.consume(event("token_count",["info":["total_token_usage":["output_tokens":output,"reasoning_output_tokens":output/2],"last_token_usage":["input_tokens":1000],"model_context_window":10000]]))
    }
    func limit(_ used:Double,_ time:Double=0,_ reset:Double=100000) -> Limit {
        Limit(id:"codex:primary",used:used,minutes:10080,reset:reset,observed:Date(timeIntervalSince1970:time))
    }
    func testTurnUsageAndDuplicateCounts() {
        let p=RolloutParser(); start(p)
        p.consume(event("token_usage_record",["turn_id":"a","turn_token_usage":["output_tokens":80,"reasoning_output_tokens":20],"usage":["input_tokens":1000]]))
        count(p,80); count(p,80)
        p.consume(event("task_complete",["turn_id":"a","duration_ms":2000,"time_to_first_token_ms":200]))
        expectEqual(p.session.usage.output,80); expectEqual(p.session.speed,40); expectEqual(p.session.ttft,0.2)
        expectEqual(p.session.contextPercent,10)
    }
    func testLegacyDeltaAndMultipleTurns() {
        let p=RolloutParser(); count(p,100); start(p); count(p,150); count(p,170)
        expectEqual(p.session.usage.output,70)
        start(p,"b"); count(p,200); expectEqual(p.session.usage.output,30)
    }
    func testResetDoesNotProduceNegativeTokens() {
        let p=RolloutParser(); count(p,100); start(p); count(p,20)
        expectEqual(p.session.usage.output,0)
        count(p,30); expectEqual(p.session.usage.output,10)
    }
    func testMismatchedTurnAndMissingDuration() {
        let p=RolloutParser(); start(p)
        p.consume(event("task_complete",["turn_id":"other","duration_ms":1000]))
        expectTrue(p.session.running)
        p.consume(event("task_complete",["turn_id":"a"]))
        expectFalse(p.session.running); expectNil(p.session.speed); expectNil(p.session.ttft)
    }
    func testSubagentAndReviewExcluded() {
        let p=RolloutParser()
        p.consume(event("session_meta",["id":"child","originator":"Codex Desktop","source":["subagent":["other":"guardian"]]]))
        expectFalse(p.session.eligible)
        let q=RolloutParser(); q.consume(event("session_meta",["id":"main","originator":"Codex Desktop"]))
        expectTrue(q.session.eligible)
        q.consume(event("turn_context",["model":"codex-auto-review"]))
        expectFalse(q.session.eligible)
    }
    func testWindowLengthNotSlotName() {
        let p=RolloutParser()
        p.consume(event("token_count",["rate_limits":["primary":["used_percent":45,"window_minutes":10080,"resets_at":100000],"secondary":["used_percent":20,"window_minutes":300,"resets_at":90000]]]))
        expectEqual(p.limits.count,2); expectEqual(p.limits[0].name,"7 天额度"); expectEqual(p.limits[1].name,"5 小时额度")
    }
    func testLatestSnapshotRemovesSecondary() {
        let p=RolloutParser()
        p.consume(event("token_count",["rate_limits":["primary":["used_percent":45,"window_minutes":300,"resets_at":100000],"secondary":["used_percent":20,"window_minutes":10080,"resets_at":90000]]]))
        p.consume(event("token_count",["rate_limits":["primary":["used_percent":46,"window_minutes":10080,"resets_at":200000]]],"2026-09-21T16:01:00.000Z"))
        expectEqual(p.limits.count,1); expectEqual(p.limits[0].minutes,10080)
    }
    func testMissingPriceZeroCost() {
        expectThrows(try CostReport.parse(Data(#"{"totals":{"costUSD":0,"totalTokens":100},"daily":[]}"#.utf8)))
    }
    func testIndependentWindows() {
        var a=Calibration(limit:limit(30),cost:20,date:Date(timeIntervalSince1970:0))
        var other=limit(50); other.id="codex:secondary"
        let b=Calibration(limit:other,cost:20,date:Date(timeIntervalSince1970:0))
        a.add(limit:limit(40,600),cost:30,date:Date(timeIntervalSince1970:600))
        expectEqual(b.samples,1); expectEqual(b.limit.used,50); expectEqual(a.limit.used,40)
    }
    func testGPT6SolAndLunaContextBoundary() throws {
        for model in ["gpt-6-sol","gpt-6-luna"] {
            try Pricing.validate(JSONSerialization.data(withJSONObject:
                ["daily":[["models":[model:["totalTokens":100]]]]]))
            for input in [272_000,272_001] {
                let p=RolloutParser()
                p.consume(event("turn_context",["turn_id":"a","model":model]))
                p.consume(event("token_count",["info":["last_token_usage":["input_tokens":input,"output_tokens":100]]]))
                expectEqual(p.session.model,model)
                expectEqual(p.unsupportedPricingDate != nil,input>272_000)
            }
        }
    }
    func testUnknownModelIsRejected() {
        expectThrows(try Pricing.validate(Data(#"{"daily":[{"models":{"future-model":{"totalTokens":100}}}]}"#.utf8)))
    }
    // A fake CLI for exercising probe validation and cache invalidation, without subprocesses.
    func compatibilityReport(_ home: URL) throws -> [String: Any] {
        let data=try Data(contentsOf:home.appendingPathComponent("sessions/rollout-included.jsonl"))
        let lines=try data.split(separator:10).map { try JSONSerialization.jsonObject(with:Data($0)) as! [String:Any] }
        let model=(lines[1]["payload"] as! [String:Any])["model"] as! String
        let settings=(lines[2]["payload"] as! [String:Any])["thread_settings"] as! [String:Any]
        let info=(lines[3]["payload"] as! [String:Any])["info"] as! [String:Any]
        let usage=info["total_token_usage"] as! [String:Int]
        let input=usage["input_tokens"]!, cached=usage["cached_input_tokens"]!
        let prices=["gpt-6-astra":(10.0,1.0,50.0),"gpt-6-sol":(2.0,0.2,10.0),"gpt-6-luna":(0.1,0.01,0.5),"gpt-5.6-sol":(4.0,0.4,20.0),
                    "gpt-5.6-terra":(2.0,0.2,12.0),"gpt-5.6-luna":(0.2,0.02,1.2)]
        let (standard,cache,output)=prices[model]!
        let cost=(Double(input-cached)*standard+Double(cached)*cache+100*output)/1e6
            * (settings["service_tier"] as? String == "priority" ? 2 : 1)
        return ["totals":["costUSD":cost,"totalTokens":input+100],
                "daily":[["date":"2026-09-21","costUSD":cost,
                           "models":[model:["totalTokens":input+100,"cacheReadTokens":cached]]]]]
    }
    func testCompatibilityCacheAndCleanup() throws {
        var calls=0, roots=[URL]()
        let checker=CCUsageCompatibility(report: { _,home,since,timeout in
            calls += 1; roots.append(home)
            expectEqual(since,"2026-09-21")
            expectTrue(timeout > 0 && timeout <= 5)
            expectTrue(FileManager.default.fileExists(atPath:home.appendingPathComponent("sessions/rollout-excluded.jsonl").path))
            return try JSONSerialization.data(withJSONObject:self.compatibilityReport(home))
        })
        try checker.verify(executable:"fixture",signature:"version-1")
        expectEqual(calls,18)
        try checker.verify(executable:"fixture",signature:"version-1")
        expectEqual(calls,18)
        try checker.verify(executable:"fixture",signature:"version-2")
        expectEqual(calls,36)
        expectTrue(roots.allSatisfy { !FileManager.default.fileExists(atPath:$0.path) })
    }
    func testCompatibilityRejectsInvalidReports() throws {
        for mode in ["json","price","date","models","cache","empty","command"] {
            var roots=[URL]()
            let checker=CCUsageCompatibility(report: { _,home,_,_ in
                roots.append(home)
                if mode == "command" { throw TelemetryError.message("unsupported argument") }
                if mode == "json" { return Data("invalid JSON".utf8) }
                var report=try self.compatibilityReport(home)
                if mode == "price" { report["totals"]=["costUSD":100] }
                var days=report["daily"] as! [[String:Any]]
                if mode == "date" { days[0]["date"]="2026-09-20" }
                if mode == "models" { days[0]["models"]=[:] as [String:Any] }
                if mode == "cache" { days[0]["models"]=["gpt-6-astra":["totalTokens":1100,"cacheReadTokens":0]] }
                report["daily"]=mode == "empty" ? [] : days
                return try JSONSerialization.data(withJSONObject:report)
            })
            expectThrows(try checker.verify(executable:"fixture",signature:"same"))
            expectThrows(try checker.verify(executable:"fixture",signature:"same"))
            expectEqual(roots.count,2) // Failed probes must never populate the success cache.
            expectTrue(roots.allSatisfy { !FileManager.default.fileExists(atPath:$0.path) })
        }
    }
    func testCompatibilityDeadline() throws {
        var time=0.0, calls=0, roots=[URL](), timeouts=[TimeInterval]()
        let checker=CCUsageCompatibility(clock:{ time }) { _,home,_,timeout in
            roots.append(home); calls += 1; timeouts.append(timeout)
            time += 4.5
            return try JSONSerialization.data(withJSONObject:self.compatibilityReport(home))
        }
        expectThrows(try checker.verify(executable:"fixture",signature:"slow"))
        expectEqual(calls,5)
        expectEqual(timeouts.last,2)
        expectTrue(roots.allSatisfy { !FileManager.default.fileExists(atPath:$0.path) })
    }
    func testMalformedPricingReports() {
        for json in ["invalid","{}",#"{"daily":[{}]}"#,
                     #"{"daily":[{"models":{"gpt-6-astra":{"totalTokens":true}}}]}"#,
                     #"{"daily":[{"models":{"gpt-6-astra":{"totalTokens":-1}}}]}"#] {
            expectThrows(try Pricing.validate(Data(json.utf8)))
        }
        for json in [
            #"{"totals":{"costUSD":true,"totalTokens":0},"daily":[]}"#,
            #"{"totals":{"costUSD":1,"totalTokens":0},"daily":[]}"#,
            #"{"totals":{"costUSD":0,"totalTokens":0},"daily":[{"date":"bad","costUSD":0,"models":{}}]}"#,
            #"{"totals":{"costUSD":0,"totalTokens":0},"daily":[{"date":"2026-09-21","costUSD":-1,"models":{}}]}"#,
            #"{"totals":{"costUSD":1,"totalTokens":10},"daily":[{"date":"2026-09-21","costUSD":1,"models":{}}]}"#,
            #"{"totals":{"costUSD":0,"totalTokens":0},"daily":[{"date":"2026-09-21","costUSD":0,"models":{}},{"date":"2026-09-21","costUSD":0,"models":{}}]}"#
        ] { expectThrows(try CostReport.parse(Data(json.utf8))) }
    }
    func testCCUsagePricingIntegration() throws {
        let override=ProcessInfo.processInfo.environment["CODEXSPEED_CCUSAGE"]
        let executable=override ?? "/opt/homebrew/bin/ccusage"
        if override != nil && !FileManager.default.isExecutableFile(atPath:executable) {
            throw TelemetryError.message("Configured test executable not found")
        }
        guard FileManager.default.isExecutableFile(atPath:executable) else { print("SKIP ccusage integration: not installed"); return }
        let version=String(decoding:try CommandRunner.run(path:executable,arguments:["--version"]),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let checker=CCUsageCompatibility(), began=ProcessInfo.processInfo.systemUptime
        try checker.verify(executable:executable,signature:version)
        let cold=ProcessInfo.processInfo.systemUptime-began, cachedStart=ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { try checker.verify(executable:executable,signature:version) }
        let cached=ProcessInfo.processInfo.systemUptime-cachedStart
        print(String(format:"Compatibility %@: cold %.3f s; 1000 cached checks %.6f s",version,cold,cached))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions=root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at:sessions,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let tokens:[String:Any]=["input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"reasoning_output_tokens":20,"total_tokens":1100]
        for (model,expected) in [("gpt-6-astra",0.0132),("gpt-6-sol",0.00264),("gpt-6-luna",0.000132),("gpt-5.6-sol",0.00528),("gpt-5.6-terra",0.00284),("gpt-5.6-luna",0.000284)] {
            for (tier,multiplier) in [("default",1.0),("priority",2.0)] {
                let lines=[event("session_meta",["id":"fixture","originator":"Codex Desktop","cli_version":"0.155.0","source":"vscode"]),
                    event("turn_context",["turn_id":"a","model":model]),
                    event("thread_settings_applied",["thread_settings":["model":model,"service_tier":tier]]),
                    event("token_count",["info":["total_token_usage":tokens,"last_token_usage":tokens]])]
                var contents=Data(); for line in lines { contents.append(line); contents.append(10) }
                try contents.write(to:sessions.appendingPathComponent("rollout-fixture.jsonl"),options:.atomic)
                let data=try Pricing.report(executable:executable,home:root,since:"2026-09-21")
                let report=try CostReport.parse(data)
                expectTrue(abs(report.cost-expected*multiplier)<0.00000001)
            }
        }
        // Exercise Monitor too, so a future version gate cannot bypass the probe tests.
        let log=sessions.appendingPathComponent("rollout-fixture.jsonl")
        let currentLog=try String(contentsOf:log,encoding:.utf8)
            .replacingOccurrences(of:"2026-09-21",with:CostReport.dateString(Date()))
        try currentLog.write(to:log,atomically:true,encoding:.utf8)
        let monitor=Monitor(home:root,executable:executable,storage:root.appendingPathComponent("calibration.json"))
        defer { monitor.stop() }
        var finished: MonitorSnapshot?
        monitor.tick { snapshot in
            if snapshot.updated != nil || snapshot.costError != nil { finished=snapshot }
        }
        let deadline=Date().addingTimeInterval(20)
        while finished == nil && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        expectTrue(finished != nil)
        expectNil(finished?.costError)
        expectTrue(abs((finished?.cost ?? -1)-0.000568)<0.00000001)
    }
    func testQuotaExample() {
        var c=Calibration(limit:limit(30),cost:20,date:Date(timeIntervalSince1970:0))
        c.add(limit:limit(35,300),cost:25,date:Date(timeIntervalSince1970:300))
        expectNil(c.total)
        c.add(limit:limit(40,600),cost:30,date:Date(timeIntervalSince1970:600))
        expectEqual(c.total,100); expectEqual(c.remaining,60)
    }
    func testSmallSpanAndUnchangedQuota() {
        var c=Calibration(limit:limit(30),cost:20,date:Date(timeIntervalSince1970:0))
        c.add(limit:limit(30,600),cost:25,date:Date(timeIntervalSince1970:600))
        c.add(limit:limit(30,1200),cost:30,date:Date(timeIntervalSince1970:1200))
        expectNil(c.total)
    }
    func testRepeatedSnapshotIsNotSample() {
        var c=Calibration(limit:limit(30),cost:20,date:Date(timeIntervalSince1970:0))
        c.add(limit:limit(30),cost:20,date:Date(timeIntervalSince1970:1000))
        expectEqual(c.samples,1)
    }
    func testResetCostRollbackPlanChange() {
        var c=Calibration(limit:limit(30),cost:20,date:Date(timeIntervalSince1970:0))
        c.add(limit:limit(35,600),cost:19,date:Date(timeIntervalSince1970:600))
        expectEqual(c.samples,1); expectEqual(c.firstCost,19)
        c.add(limit:limit(1,700,200000),cost:20,date:Date(timeIntervalSince1970:700))
        expectEqual(c.samples,1); expectEqual(c.firstUsed,1)
        var changed=limit(2,800,200000); changed.plan="new"
        c.add(limit:changed,cost:21,date:Date(timeIntervalSince1970:800)); expectEqual(c.samples,1)
    }
    func testResetJitterToleranceAndSnapshot() {
        expectTrue(limit(10).sameWindow(limit(10,1,100001)))
        expectFalse(limit(10).sameSnapshot(limit(11)))
        expectFalse(limit(10).sameWindow(limit(10,1,200000)))
    }
    func testIncrementalPartialTruncatedAndDeleted() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let url=dir.appendingPathComponent("rollout.jsonl"), f=IncrementalFile()
        let line=event("session_meta",["id":"one","originator":"Codex Desktop"])
        try line.prefix(10).write(to:url); expectTrue(try f.read(url)); expectEqual(f.parser.session.id,"")
        var full=line; full.append(10); try full.write(to:url)
        expectTrue(try f.read(url)); expectEqual(f.parser.session.id,"one")
        let bytes=f.bytesRead; expectFalse(try f.read(url)); expectEqual(bytes,f.bytesRead)
        try Data("{}\n".utf8).write(to:url); expectTrue(try f.read(url)); expectEqual(f.parser.session.id,"")
        try FileManager.default.removeItem(at:url); expectThrows(try f.read(url))
    }
    func testInvalidJSONAndFutureEvent() {
        let p=RolloutParser(); p.consume(Data("oops".utf8)); p.consume(event("future",[:]))
        expectEqual(p.malformed,1)
    }
    func testCostParsingAndFallback() throws {
        let data=Data(#"{"totals":{"costUSD":12.5,"totalTokens":100},"daily":[{"date":"2026-09-21","costUSD":12.5,"models":{"m":{"isFallback":true,"totalTokens":100}}}]}"#.utf8)
        let r=try CostReport.parse(data); expectEqual(r.cost,12.5); expectTrue(r.fallback)
        expectThrows(try CostReport.parse(Data(#"{"totals":{},"daily":[]}"#.utf8)))
    }
    func testCommandErrorsAndTimeout() {
        expectThrows(try CommandRunner.run(path:"/missing-ccusage",arguments:[]))
        expectThrows(try CommandRunner.run(path:"/usr/bin/false",arguments:[]))
        expectThrows(try CommandRunner.run(path:"/bin/sleep",arguments:["2"],timeout:0.1))
    }
    func testCrossMidnightSamplesAndPersistence() throws {
        var c=Calibration(limit:limit(30,86000,200000),cost:20,date:Date(timeIntervalSince1970:86000))
        c.add(limit:limit(35,86300,200000),cost:25,date:Date(timeIntervalSince1970:86300))
        c.add(limit:limit(40,86600,200000),cost:30,date:Date(timeIntervalSince1970:86600))
        let restored=try JSONDecoder().decode(Calibration.self,from:JSONEncoder().encode(c))
        expectEqual(restored.total,100)
    }
}

@main struct Checks { static func main() throws {
let tests=CoreTests()
if CommandLine.arguments.contains("--ccusage-only") {
    do { try tests.testCCUsagePricingIntegration() }
    catch { print("FAIL ccusage integration: \(error.localizedDescription)"); exit(1) }
    print("ccusage integration: \(failures) failed assertions")
    exit(failures == 0 ? 0 : 1)
}
tests.testRecentSpeed(); print("PASS testRecentSpeed")
tests.testLifecycleStatus(); print("PASS testLifecycleStatus")
tests.testUnsafeNumbers(); print("PASS testUnsafeNumbers")
try tests.testOversizedLineRecovery(); print("PASS testOversizedLineRecovery")
try tests.testCommandOutputLimitAndEnvironment(); print("PASS testCommandOutputLimitAndEnvironment")
try tests.testHotRefreshAndResumedTask(); print("PASS testHotRefreshAndResumedTask")
try tests.testRecentLogWindow(); print("PASS testRecentLogWindow")
try tests.testMonitorSkipsOldContents(); print("PASS testMonitorSkipsOldContents")
tests.testTurnUsageAndDuplicateCounts(); print("PASS testTurnUsageAndDuplicateCounts")
tests.testLegacyDeltaAndMultipleTurns(); print("PASS testLegacyDeltaAndMultipleTurns")
tests.testResetDoesNotProduceNegativeTokens(); print("PASS testResetDoesNotProduceNegativeTokens")
tests.testMismatchedTurnAndMissingDuration(); print("PASS testMismatchedTurnAndMissingDuration")
tests.testSubagentAndReviewExcluded(); print("PASS testSubagentAndReviewExcluded")
tests.testWindowLengthNotSlotName(); print("PASS testWindowLengthNotSlotName")
tests.testQuotaExample(); print("PASS testQuotaExample")
tests.testSmallSpanAndUnchangedQuota(); print("PASS testSmallSpanAndUnchangedQuota")
tests.testRepeatedSnapshotIsNotSample(); print("PASS testRepeatedSnapshotIsNotSample")
tests.testResetCostRollbackPlanChange(); print("PASS testResetCostRollbackPlanChange")
tests.testResetJitterToleranceAndSnapshot(); print("PASS testResetJitterToleranceAndSnapshot")
try tests.testIncrementalPartialTruncatedAndDeleted(); print("PASS testIncrementalPartialTruncatedAndDeleted")
tests.testInvalidJSONAndFutureEvent(); print("PASS testInvalidJSONAndFutureEvent")
try tests.testCostParsingAndFallback(); print("PASS testCostParsingAndFallback")
tests.testCommandErrorsAndTimeout(); print("PASS testCommandErrorsAndTimeout")
try tests.testCrossMidnightSamplesAndPersistence(); print("PASS testCrossMidnightSamplesAndPersistence")
tests.testLatestSnapshotRemovesSecondary(); print("PASS testLatestSnapshotRemovesSecondary")
tests.testMissingPriceZeroCost(); print("PASS testMissingPriceZeroCost")
tests.testIndependentWindows(); print("PASS testIndependentWindows")
tests.testUnknownModelIsRejected(); print("PASS testUnknownModelIsRejected")
try tests.testCompatibilityCacheAndCleanup(); print("PASS testCompatibilityCacheAndCleanup")
try tests.testCompatibilityRejectsInvalidReports(); print("PASS testCompatibilityRejectsInvalidReports")
try tests.testCompatibilityDeadline(); print("PASS testCompatibilityDeadline")
try tests.testGPT6SolAndLunaContextBoundary(); print("PASS testGPT6SolAndLunaContextBoundary")
tests.testMalformedPricingReports(); print("PASS testMalformedPricingReports")
try tests.testCCUsagePricingIntegration(); print("PASS testCCUsagePricingIntegration")
print("34 checks; \(failures) failed assertions")
if failures>0 { exit(1) }
} }
