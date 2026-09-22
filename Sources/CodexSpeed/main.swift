import AppKit
import CodexSpeedCore

if CommandLine.arguments.contains("--export-pricing") {
    FileHandle.standardOutput.write(Pricing.configData); exit(0)
}
if CommandLine.arguments.contains("--diagnose") {
    let home=URL(fileURLWithPath:NSHomeDirectory()+"/.codex")
    let m=Monitor(home:home,executable:"/opt/homebrew/bin/ccusage",storage:FileManager.default.temporaryDirectory.appendingPathComponent("codexspeed-diagnose-\(UUID().uuidString).json"))
    var done=false
    m.tick { s in
        if s.updated != nil || s.costError != nil {
            print("sessions=\(s.sessions.count) files=\(s.fileCount) limits=\(s.limits.count) bytes=\(s.bytesRead) cost=\(s.cost.map(String.init(describing:)) ?? "nil") error=\(s.costError ?? s.error ?? "none")")
            for l in s.limits { print("\(l.name): used=\(l.used)% reset=\(l.reset)") }
            done=true
        }
    }
    let end=Date().addingTimeInterval(40)
    while !done && Date()<end { RunLoop.current.run(until:Date().addingTimeInterval(0.1)) }
    exit(done ? 0 : 1)
}
let app=NSApplication.shared
let delegate=AppDelegate(); app.delegate=delegate; app.run()
