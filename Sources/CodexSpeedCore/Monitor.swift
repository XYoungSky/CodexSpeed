import Foundation
import CryptoKit

public struct MonitorSnapshot {
    public init() {}
    public var sessions: [Session] = [], limits: [Limit] = []
    public var calibrations: [String:Calibration] = [:]
    public var error: String?, costError: String?, cost: Double?, updated: Date?
    public var checkedFileCount=0
    public var fallback=false, loading=true, fileCount=0, bytesRead: UInt64=0
}
private struct Saved: Codable {
    var since: String
    var calibrations: [String:Calibration]
    var signature: String
    var history: [String:Double]
}
public final class Monitor {
    public var home: URL, executable: String
    private var files: [URL:IncrementalFile]=[:], lastScan=Date.distantPast, lastCost=Date.distantPast
    private var activeFiles: [URL:Date]=[:]
    private let now: () -> Date
    private var dirty=true, costRunning=false
    private var state=MonitorSnapshot()
    private var since=CostReport.dateString(Date()), signature="", history: [String:Double]=[:]
    private let storage: URL
    private let worker=DispatchQueue(label:"CodexSpeed.logs",qos:.utility)
    private let costWorker=DispatchQueue(label:"CodexSpeed.cost",qos:.utility)
    private let compatibility=CCUsageCompatibility()
    private var generation=0
    private var stopped=false
    private let tickLock=NSLock()
    private var tickPending=false
    public init(home: URL, executable: String, storage: URL, now: @escaping () -> Date = Date.init) {
        self.home=home; self.executable=executable; self.storage=storage; self.now=now
        if let data=try? Data(contentsOf:storage), let saved=try? JSONDecoder().decode(Saved.self,from:data) {
            since=saved.since; state.calibrations=saved.calibrations; signature=saved.signature; history=saved.history
        }
    }
    public func tick(deliver: @escaping (MonitorSnapshot)->Void) {
        tickLock.lock()
        guard !tickPending else { tickLock.unlock(); return }
        tickPending=true; tickLock.unlock()
        worker.async {
            defer { self.tickLock.lock(); self.tickPending=false; self.tickLock.unlock() }
            guard !self.stopped else { return }
            self.refresh()
            if self.dirty && !self.costRunning && Date().timeIntervalSince(self.lastCost)>=60 { self.startCost(deliver:deliver) }
            let snapshot=self.state; DispatchQueue.main.async { deliver(snapshot) }
        }
    }
    public func stop() { worker.async { self.stopped=true; self.generation += 1 } }
    public func reset() {
        worker.async {
            self.generation += 1; self.since=CostReport.dateString(Date())
            self.state.calibrations=[:]; self.history=[:]
            self.state.cost=nil; self.state.updated=nil; self.state.costError=nil; self.state.fallback=false
            self.lastCost = .distantPast; self.dirty=true; self.save()
        }
    }
    private func refresh() {
        state.error=nil
        let date=now()
        let activeCutoff=LogWindow.activeCutoff(now:date)
        var pending=Set<URL>(), changed=false
        let initial=state.loading
        if date.timeIntervalSince(lastScan)>=30 {
            let cutoff=LogWindow.cutoff(now:date)
            // Keep a fixed cost baseline within the retention window. Roll it forward
            // as a new calibration, never subtract reports with different date ranges.
            if since < CostReport.dateString(cutoff) {
                generation += 1; since=CostReport.dateString(Date())
                state.calibrations=[:]; history=[:]; state.cost=nil; state.updated=nil
                dirty=true; save()
            }
            lastScan=date; var found=Set<URL>(), active=[URL:Date]()
            let roots=[home.appendingPathComponent("sessions"),home.appendingPathComponent("archived_sessions")]
            var activeRelative=Set<String>()
            for (index,root) in roots.enumerated() {
                guard FileManager.default.fileExists(atPath:root.path) else { continue }
                let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.contentModificationDateKey],options:[.skipsHiddenFiles],errorHandler:{ _,_ in self.state.error="部分日志目录无法读取"; return true })
                while let url=enumerator?.nextObject() as? URL {
                    guard url.lastPathComponent.hasPrefix("rollout-"),url.pathExtension == "jsonl" else { continue }
                    do { guard try LogWindow.includes(url,cutoff:cutoff) else { continue } }
                    catch { state.error="部分日志无法读取：\(url.lastPathComponent)"; continue }
                    let relative=String(url.path.dropFirst(root.path.count))
                    if index==0 { activeRelative.insert(relative) } else if activeRelative.contains(relative) { continue }
                    let modified=(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let isActive=modified >= activeCutoff
                    // Bootstrap historical state once. Thereafter only newly active files
                    // need content reads; cached historical sessions remain available.
                    guard initial || isActive || files[url] != nil else { continue }
                    found.insert(url)
                    if isActive { active[url]=modified }
                    if files[url]==nil { files[url]=IncrementalFile(); pending.insert(url); dirty=true; changed=true }
                }
            }
            if found.isEmpty { state.error="未找到 Codex 日志；请在设置中选择 Codex 主目录" }
            if !Set(files.keys).subtracting(found).isEmpty { dirty=true; changed=true }
            files=files.filter { found.contains($0.key) }
            activeFiles=active
        }
        activeFiles=activeFiles.filter { $0.value >= activeCutoff }
        pending.formUnion(activeFiles.keys)
        state.checkedFileCount=pending.count
        for url in pending {
            guard let file=files[url] else { continue }
            do { if try file.read(url) {
                dirty=true; changed=true
            } } catch { state.error="部分日志无法读取：\(url.lastPathComponent)" }
        }
        if changed || initial {
            var rates: [String:RateSnapshot]=[:]
            for file in files.values {
                for (bucket,snapshot) in file.parser.rateSnapshots where snapshot.observed > (rates[bucket]?.observed ?? .distantPast) { rates[bucket]=snapshot }
            }
            state.sessions=files.values.map { $0.parser.session }.filter { $0.eligible && !$0.id.isEmpty }.sorted { $0.activity>$1.activity }
            // Deduplicate resumed or archived copies of a task for selection.
            var seen=Set<String>(); state.sessions=state.sessions.filter { seen.insert($0.id).inserted }
            // Take the complete latest account snapshot: a null secondary removes an old window.
            // Model-specific quotas cannot be calibrated against account-wide ccusage costs.
            state.limits=(rates["codex"]?.limits ?? []).sorted { $0.minutes<$1.minutes }
            state.fileCount=files.count; state.bytesRead=files.values.reduce(0) { $0+$1.bytesRead }
        }
        state.loading=false
        for l in state.limits {
            if let c=state.calibrations[l.id], (!c.limit.sameWindow(l) || l.used<c.limit.used || l.reset<=Date().timeIntervalSince1970) { state.calibrations.removeValue(forKey:l.id) }
        }
    }
    private func priceSignature() -> String {
        // Pricing uses our explicit config and ccusage's offline catalog, not Codex settings.
        var entries=[String]()
        let resolved=URL(fileURLWithPath:executable).resolvingSymlinksInPath()
        let package=resolved.deletingLastPathComponent().deletingLastPathComponent()
        let explicitFiles=[resolved,package.appendingPathComponent("package.json"),
            package.appendingPathComponent("node_modules/@ccusage/ccusage-darwin-arm64/bin/ccusage"),
            package.appendingPathComponent("node_modules/@ccusage/ccusage-darwin-x64/bin/ccusage")]
        for file in explicitFiles {
            if let data=try? Data(contentsOf:file,options:.mappedIfSafe) {
                entries.append(file.path+SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined())
            }
        }
        return entries.sorted().joined(separator:"|")
    }
    private func startCost(deliver: @escaping (MonitorSnapshot)->Void) {
        costRunning=true; dirty=false; lastCost=Date()
        let before=state.limits, start=Date(), home=self.home, executable=self.executable, since=self.since, generation=self.generation
        let longContext=files.values.contains { file in file.parser.unsupportedPricingDate.map { CostReport.dateString($0)>=since } ?? false }
        costWorker.async {
            let result: Result<(CostReport,String,[String:Double]),Error>=Result {
                guard FileManager.default.isExecutableFile(atPath:executable) else { throw TelemetryError.message("找不到 ccusage；请在设置中指定可执行文件") }
                guard !longContext else { throw TelemetryError.message("检测到超过 272K 的新模型请求；当前 ccusage 无法准确计价，暂停额度校准") }
                let version=String(data:try CommandRunner.run(path:executable,arguments:["--version"],timeout:5),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                let sig=home.path+"|"+executable+"|"+version+"|"+Pricing.revision+"|"+self.priceSignature()
                try self.compatibility.verify(executable:executable,signature:sig)
                let data=try Pricing.report(executable:executable,home:home,since:since)
                let report=try CostReport.parse(data)
                let d=try JSONSerialization.jsonObject(with:data) as? [String:Any]
                var history=[String:Double]()
                for day in d?["daily"] as? [[String:Any]] ?? [] {
                    if let date=day["date"] as? String,let cost=day["costUSD"] as? Double,date<CostReport.dateString(start) { history[date]=cost }
                }
                return (report,sig,history)
            }
            self.worker.async {
                self.costRunning=false
                guard generation==self.generation else { return }
                self.refresh()
                guard generation==self.generation else { return }
                switch result {
                case .failure(let error):
                    self.state.costError=error.localizedDescription; self.dirty=true
                    // A transient command failure is not evidence that prior samples are invalid.
                    // Suspend display until a successful report validates the signature/window.
                case .success(let (report,sig,newHistory)):
                    if sig != self.signature || self.history.contains(where:{ newHistory[$0.key] != $0.value }) { self.state.calibrations=[:] }
                    self.signature=sig; self.history=newHistory
                    self.state.cost=report.cost; self.state.fallback=report.fallback; self.state.updated=Date(); self.state.costError=nil
                    for l in self.state.limits {
                        guard let old=before.first(where:{$0.id==l.id}),old.sameSnapshot(l),l.reset>Date().timeIntervalSince1970,
                              start.timeIntervalSince(l.observed)<120 else { continue }
                        if var c=self.state.calibrations[l.id] { c.add(limit:l,cost:report.cost,date:start); self.state.calibrations[l.id]=c }
                        else { self.state.calibrations[l.id]=Calibration(limit:l,cost:report.cost,date:start) }
                    }
                    self.save()
                }
                let snapshot=self.state; DispatchQueue.main.async { deliver(snapshot) }
            }
        }
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at:storage.deletingLastPathComponent(),withIntermediateDirectories:true)
            let data=try JSONEncoder().encode(Saved(since:since,calibrations:state.calibrations,signature:signature,history:history))
            try data.write(to:storage,options:.atomic)
        } catch { state.costError="无法保存校准记录：\(error.localizedDescription)" }
    }
}
