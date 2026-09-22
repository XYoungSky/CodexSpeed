import AppKit
import SwiftUI
import Combine
import CodexSpeedCore

final class HUDModel: ObservableObject {
    @Published var snapshot=MonitorSnapshot()
    @Published var locked: String?=UserDefaults.standard.string(forKey:"lockedTask")
    @Published var expanded=UserDefaults.standard.bool(forKey:"expanded")
    @Published var compact=UserDefaults.standard.bool(forKey:"compact") {
        didSet { UserDefaults.standard.set(compact,forKey:"compact") }
    }
    @Published var now=Date()
    @Published var theme=AppTheme(rawValue:UserDefaults.standard.string(forKey:"theme") ?? "system") ?? .system {
        didSet { UserDefaults.standard.set(theme.rawValue,forKey:"theme"); NSApp.appearance=theme.appearance }
    }
    @Published var background=HUDBackground.saved() {
        didSet { UserDefaults.standard.set(background.rawValue,forKey:"background") }
    }
    @Published var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "en") ?? .english {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }
    func text(_ english: String, _ chinese: String) -> String { language.text(english, chinese) }
    private var monitor: Monitor!
    private var timer: Timer?
    var home: String { UserDefaults.standard.string(forKey:"codexHome") ?? NSHomeDirectory()+"/.codex" }
    var executable: String { UserDefaults.standard.string(forKey:"ccusage") ?? "/opt/homebrew/bin/ccusage" }
    var selected: Session? { locked.flatMap { id in snapshot.sessions.first { $0.id==id } } ?? (locked == nil ? snapshot.sessions.first : nil) }
    init() { NSApp.appearance=theme.appearance; restart(); timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.tick() }; timer?.tolerance=0.2; tick() }
    private func restart() {
        monitor?.stop()
        let storage=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CodexSpeed/calibration.json")
        monitor=Monitor(home:URL(fileURLWithPath:home),executable:executable,storage:storage)
    }
    private func tick() {
        now=Date(); let current=monitor
        current?.tick { [weak self, weak current] state in
            guard let self=self, current === self.monitor else { return }; self.snapshot=state
        }
    }
    func lock(_ id: String?) { locked=id; UserDefaults.standard.set(id,forKey:"lockedTask") }
    func toggleDetails() { expanded.toggle(); UserDefaults.standard.set(expanded,forKey:"expanded") }
    func chooseHome() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=false; panel.showsHiddenFiles=true
        panel.title=text("Codex Folder", "Codex 目录"); panel.prompt=text("Select", "选择"); panel.message=text("Choose the folder containing sessions", "选择包含 sessions 的目录"); panel.directoryURL=URL(fileURLWithPath:home)
        if panel.runModal() == .OK,let url=panel.url { UserDefaults.standard.set(url.path,forKey:"codexHome"); restart(); monitor.reset(); tick() }
    }
    func chooseExecutable() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=false; panel.canChooseFiles=true; panel.directoryURL=URL(fileURLWithPath:"/opt/homebrew/bin")
        panel.title=text("ccusage Executable", "ccusage 可执行文件"); panel.prompt=text("Select", "选择"); panel.message=text("Choose ccusage 20.0.20", "选择 ccusage 20.0.20")
        if panel.runModal() == .OK,let url=panel.url { UserDefaults.standard.set(url.path,forKey:"ccusage"); restart(); monitor.reset(); tick() }
    }
    func reset() { monitor.reset(); tick() }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    var resize: (CGSize) -> Void = { _ in }
    var hideToMenuBar: () -> Void = {}
    private let accent = Color(red: 0.20, green: 0.75, blue: 0.66)
    private func t(_ english: String, _ chinese: String) -> String { model.text(english, chinese) }

    var body: some View {
        Group {
            if model.compact {
                compactView.frame(height:108).padding(12)
            } else {
                fullView.padding(17)
            }
        }
        .frame(width: model.compact ? 154 : 290)
        .fixedSize(horizontal: true, vertical: true)
        // Measure intrinsic content, never the intermediate animated window height.
        .background(GeometryReader { geometry in
            Color.clear.onAppear { resize(geometry.size) }.onChange(of: geometry.size) { resize($0) }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(HUDSurface(style:model.background))
        .environment(\.locale, model.language.locale)
    }

    private var fullView: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            if let session = model.selected {
                telemetry(session)
            } else {
                Text(compactStatus)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            Divider()
            if model.snapshot.limits.isEmpty {
                Text(t("No quota data", "暂无额度数据")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.limits) { quota($0) }
            if let error = model.snapshot.error ?? model.snapshot.costError {
                Label(model.language.error(error), systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.expanded { details }
        }
    }

    private var compactView: some View {
        VStack(alignment:.leading, spacing:8) {
            HStack(spacing:4) {
                Text(model.selected?.model ?? "—")
                    .font(.system(size:11,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength:0)
                HUDIconButton(symbol:"menubar.arrow.up.rectangle", title:t("Hide to Menu Bar", "收至菜单栏"), action:hideToMenuBar)
                HUDIconButton(symbol:"arrow.up.left.and.arrow.down.right", title:t("Restore full view", "恢复正常大小")) {
                    model.compact=false
                }
            }
            Spacer(minLength:0)
            HStack(alignment:.firstTextBaseline, spacing:3) {
                Text(speedText(model.selected))
                    .font(.system(size:30,weight:.medium,design:.rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("tok/s").font(.system(size:10)).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength:0)
            HStack(spacing:4) {
                Circle().fill(statusColor(model.selected?.status ?? .idle)).frame(width:5,height:5)
                Text(verbatim:compactStatus).lineLimit(1)
                Spacer(minLength:2)
                Text(compactDuration).monospacedDigit().fixedSize()
            }.font(.system(size:9)).foregroundStyle(.secondary)
        }
    }
    private func speedText(_ session: Session?) -> String {
        guard let session, let speed=session.displaySpeed(at:model.now) else { return "—" }
        return (session.running ? "≈" : "") + String(format:"%.1f",speed)
    }
    private var compactDuration: String {
        guard let session=model.selected else { return "—" }
        let elapsed=session.running ? session.started.map { max(0,model.now.timeIntervalSince($0)) } : session.duration
        return elapsed.map { model.language.duration($0) } ?? "—"
    }
    private var compactStatus: String {
        guard let session=model.selected else {
            return model.snapshot.loading ? t("Loading…", "读取中…") : model.locked == nil ? t("Waiting for Codex", "等待 Codex 任务") : t("Pinned task unavailable", "锁定任务暂不可用")
        }
        return statusTitle(session.status)
    }
    private func statusColor(_ phase: TaskPhase) -> Color {
        switch phase {
        case .running: return accent
        case .interrupted: return .orange
        case .completed: return .green
        case .idle: return .secondary
        }
    }
    private func statusTitle(_ phase: TaskPhase) -> String {
        switch phase {
        case .idle: return t("Idle", "空闲")
        case .running: return t("Running", "运行中")
        case .completed: return t("Done", "已完成")
        case .interrupted: return t("Interrupted", "已中断")
        }
    }

    private var header: some View {
        HStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path").font(.system(size:11,weight:.medium))
                Text("CodexSpeed").font(.system(size: 12, weight: .semibold))
            }.foregroundStyle(.secondary)
            Spacer()
            HUDIconButton(symbol:"arrow.down.right.and.arrow.up.left", title:t("Compact mode", "极简模式")) {
                model.compact=true
            }
            Menu {
                Button(t("Follow latest task", "跟随最近任务")) { model.lock(nil) }
                Divider()
                ForEach(model.snapshot.sessions.prefix(30)) { session in
                    Button("\(model.locked == session.id ? "✓ " : "")\(session.project) · \(session.id.suffix(6))") { model.lock(session.id) }
                }
            } label: {
                HUDControlIcon(symbol: model.locked == nil ? "square.stack" : "lock")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width:24,height:24).background(WindowControlArea())
            .help(t("Select task", "选择任务"))
            Menu {
                Menu(t("Theme", "主题")) {
                    Picker(t("Appearance", "外观"), selection:$model.theme) {
                        ForEach(AppTheme.allCases) { Text($0.title(model.language)).tag($0) }
                    }
                    Divider()
                    Picker(t("Background", "背景"), selection:$model.background) {
                        ForEach(HUDBackground.allCases) { Text($0.title(model.language)).tag($0) }
                    }
                    if #unavailable(macOS 26.0) {
                        Text(t("Liquid Glass uses solid on this macOS version", "当前系统的 Liquid Glass 使用实色回退"))
                    }
                }
                Picker(t("Language", "语言"), selection: $model.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button(t("Codex folder…", "Codex 目录…"), action: model.chooseHome)
                Button(t("ccusage executable…", "ccusage 路径…"), action: model.chooseExecutable)
                Button(t("Recalibrate quota", "重新校准额度"), action: model.reset)
                Divider()
                Button(t("Quit CodexSpeed", "退出 CodexSpeed")) { NSApp.terminate(nil) }
            } label: { HUDControlIcon(symbol: "gearshape") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width:24,height:24).background(WindowControlArea())
            .help(t("Settings", "设置"))
            HUDIconButton(symbol:"menubar.arrow.up.rectangle", title:t("Hide to Menu Bar", "收至菜单栏"), action:hideToMenuBar)
        }.foregroundStyle(.secondary)
    }

    private func telemetry(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.model.replacingOccurrences(of: "gpt-", with: ""))
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Circle().fill(statusColor(session.status)).frame(width: 6, height: 6)
                    Text(statusTitle(session.status))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("\(session.project) · \(session.id.suffix(6))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(speedText(session))
                    .font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
                Text("tok/s").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(session.running ? t("Recent estimate", "近期估算") : t("Turn average", "整轮平均"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.help(t("Running: recent logged output delta / elapsed time; stale after 10s. Completed: output / total turn time, including tools and waits", "运行中：近期日志输出增量 ÷ 间隔，10 秒无更新则隐藏。完成后：输出 ÷ 整轮耗时，包含工具和等待"))
            HStack {
                metric("TTFT", session.ttft.map { String(format: "%.2fs", $0) } ?? "—")
                Spacer()
                metric(t("Output", "输出"), short(session.usage.output))
                Spacer()
                metric(t("Reasoning", "推理"), short(session.usage.reasoning))
            }
            HStack {
                Text(t("Context", "上下文") + " ≈ " + (session.contextPercent.map { String(format: "%.1f%%", $0) } ?? "—"))
                Spacer()
                if session.running, let start = session.started {
                    Text(model.language.duration(model.now.timeIntervalSince(start)))
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func quota(_ limit: Limit) -> some View {
        let expired = limit.reset <= model.now.timeIntervalSince1970
        let calibration = model.snapshot.calibrations[limit.id]
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(model.language.windowName(minutes: limit.minutes)).fontWeight(.medium)
                Spacer()
                Text(expired ? t("Pending", "待更新") : String(format: t("%.0f%% left", "剩余 %.0f%%"), limit.remaining)).monospacedDigit()
                Button(action: model.toggleDetails) {
                    Image(systemName: model.expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(.secondary).background(WindowControlArea()).help(t("Details", "详情"))
            }.font(.system(size: 11))
            ProgressView(value: expired ? 0 : limit.remaining, total: 100).tint(accent)
            HStack {
                if expired {
                    Text(t("Awaiting update", "等待更新"))
                } else if model.snapshot.costError != nil {
                    Text(t("Estimate paused", "估算已暂停"))
                } else if let total = calibration?.total {
                    Text(t("Est. left", "预计剩余") + " ≈ " + money(total * limit.remaining / 100))
                        .help(t("API-equivalent estimate, not a subscription balance", "API 等价估算，非订阅余额"))
                } else {
                    Text(calibrationStatus(calibration))
                        .help(calibrationHelp(calibration))
                }
                Spacer()
                if !expired {
                    Text(t("Resets in ", "重置于 ") + model.language.duration(limit.reset - model.now.timeIntervalSince1970))
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ForEach(model.snapshot.limits) { limit in
                let total = model.snapshot.costError == nil ? model.snapshot.calibrations[limit.id]?.total : nil
                detailRow(t("Est. total", "预计总额") + (model.snapshot.limits.count > 1 ? " · " + model.language.windowName(minutes: limit.minutes) : ""), total.map { "≈ " + money($0) } ?? "—")
                    .help(t("API-equivalent capacity at your recent model mix", "按近期模型组合估算的 API 等价容量"))
            }
            if let cost = model.snapshot.cost {
                detailRow(t("Tracked spend", "累计费用"), money(cost))
                    .help(t("API-equivalent usage since calibration started", "校准起始日期以来的 API 等价费用"))
            }
            if let date = model.snapshot.updated {
                detailRow(t("Updated", "更新于"), model.language.timestamp(date))
            }
            if model.snapshot.fallback {
                Label(t("Approximate pricing", "含近似计价"), systemImage: "info.circle")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help(t("Some model prices use ccusage fallbacks", "部分模型使用 ccusage 回退价格"))
            }
        }.font(.system(size: 10))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
    }
    private func calibrationStatus(_ calibration: Calibration?) -> String {
        guard let c = calibration else { return t("Awaiting sample", "等待采样") }
        if c.samples < 3 { return t("Sampling", "采样") + " \(c.samples)/3" }
        let minutes = SafeNumber.integer(c.lastDate.timeIntervalSince(c.firstDate) / 60)
        if minutes < 10 { return t("Calibrating", "校准") + " \(minutes)/10m" }
        let change = c.limit.used - c.firstUsed
        if change < 5 { return t("Calibrating", "校准") + String(format: " %.0f/5pp", change) }
        return t("Awaiting usage", "等待用量更新")
    }
    private func calibrationHelp(_ calibration: Calibration?) -> String {
        guard let c = calibration else { return t("Waiting for a fresh quota snapshot and matching cost report", "等待新的额度快照及匹配的费用报告") }
        let minutes = SafeNumber.integer(c.lastDate.timeIntervalSince(c.firstDate) / 60)
        let change = String(format: "%.0f", c.limit.used - c.firstUsed)
        return t("\(c.samples)/3 samples · \(minutes)/10 min · \(change)/5 percentage points of usage", "\(c.samples)/3 个样本 · \(minutes)/10 分钟 · \(change)/5 个百分点消耗")
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }
    private func short(_ value: Double) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", value / 1_000_000) : value >= 1000 ? String(format: "%.1fk", value / 1000) : String(format: "%.0f", value)
    }
    private func money(_ value: Double) -> String { String(format: "$%.2f", value) }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.18 }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let contentView,
           !WindowControlArea.contains(event.locationInWindow, in:contentView) {
            performDrag(with:event)
            return
        }
        super.sendEvent(event)
    }

}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: FloatingPanel!
    var model: HUDModel!
    private var backgroundSubscription: AnyCancellable?
    private var menuBar: MenuBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model=HUDModel()
        panel=FloatingPanel(contentRect:NSRect(x:100,y:100,width:290,height:350),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title="CodexSpeed"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent=true
        panel.standardWindowButton(.closeButton)?.isHidden=true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden=true
        panel.standardWindowButton(.zoomButton)?.isHidden=true
        panel.isFloatingPanel=true; panel.level = .floating; panel.hidesOnDeactivate=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.isMovableByWindowBackground=false; panel.isReleasedWhenClosed=false
        panel.backgroundColor = .clear; panel.isOpaque=false; panel.hasShadow=true; panel.delegate=self
        let hosting=NSHostingView(rootView:HUDView(model:model,resize:{ [weak self] size in
            DispatchQueue.main.async {
                guard let panel=self?.panel else { return }
                var frame=panel.frame
                let target=NSSize(width:ceil(size.width),height:ceil(size.height))
                guard abs(frame.height-target.height)>1 || abs(frame.width-target.width)>1 else { return }
                frame.origin.y += frame.height-target.height
                frame.size=target
                panel.setFrame(self?.visibleFrame(frame) ?? frame,display:true,
                    animate:!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }, hideToMenuBar:{ [weak self] in self?.hideHUD() }))
        // NSHostingView must not resize the panel before our animation starts.
        // The measured content height above is the only window-size authority.
        hosting.sizingOptions = []
        hosting.focusRingType = .none
        hosting.wantsLayer=true
        hosting.layer?.backgroundColor=NSColor.clear.cgColor
        hosting.layer?.cornerRadius=16
        hosting.layer?.masksToBounds=true
        hosting.layer?.borderWidth=0
        panel.contentView=hosting
        backgroundSubscription=model.$background.removeDuplicates().sink { [weak panel] style in
            panel?.hasShadow = style != .transparent
            panel?.invalidateShadow()
        }
        panel.setFrameAutosaveName("CodexSpeedHUD")
        if !panel.setFrameUsingName("CodexSpeedHUD"),let screen=NSScreen.main { panel.setFrameTopLeftPoint(NSPoint(x:screen.visibleFrame.maxX-315,y:screen.visibleFrame.maxY-60)) }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }),let screen=NSScreen.main { panel.setFrameTopLeftPoint(NSPoint(x:screen.visibleFrame.maxX-315,y:screen.visibleFrame.maxY-60)) }
        panel.setFrame(visibleFrame(panel.frame),display:true)
        menuBar=MenuBarController(model:model)
        menuBar?.isHUDVisible={ [weak self] in self?.panel.isVisible ?? false }
        menuBar?.toggleHUD={ [weak self] in
            guard let self else { return }
            if self.panel.isVisible { self.hideHUD() } else { self.showHUD() }
        }
        if !UserDefaults.standard.bool(forKey:"hiddenToMenuBar") { showHUD() }
    }
    private func hideHUD() {
        panel.saveFrame(usingName:"CodexSpeedHUD")
        panel.orderOut(nil)
        UserDefaults.standard.set(true,forKey:"hiddenToMenuBar")
    }
    private func showHUD() {
        panel.setFrame(visibleFrame(panel.frame),display:true)
        panel.orderFrontRegardless()
        UserDefaults.standard.set(false,forKey:"hiddenToMenuBar")
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHUD()
        return true
    }
    private func visibleFrame(_ frame: NSRect) -> NSRect {
        guard let screen=panel?.screen ?? NSScreen.main else { return frame }
        let bounds=screen.visibleFrame
        var result=frame
        result.origin.x=max(bounds.minX,min(result.origin.x,bounds.maxX-result.width))
        result.origin.y=max(bounds.minY,min(result.origin.y,bounds.maxY-result.height))
        return result
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideHUD(); return false }
    // NSPanel does not count as a normal window. Closing a menu must not quit the HUD.
    // Only explicit Quit actions terminate the monitor.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
