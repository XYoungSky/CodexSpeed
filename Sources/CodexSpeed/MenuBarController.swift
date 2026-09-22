import AppKit
import Combine
import CodexSpeedCore

/// Reuses the HUD's monitor and clock; no extra polling or global event hooks.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: HUDModel
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var subscription: AnyCancellable?
    var toggleHUD: (() -> Void)?
    var isHUDVisible: (() -> Bool)?

    init(model: HUDModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "CodexSpeedStatus"
        item.button?.image = Self.icon()
        item.button?.setAccessibilityLabel("CodexSpeed")
        menu.delegate = self
        item.menu = menu
        subscription = model.objectWillChange.sink { [weak self] _ in
            // Published notifications precede the property update.
            DispatchQueue.main.async { self?.updateTooltip() }
        }
        updateTooltip()
    }

    private func updateTooltip() {
        let text = "CodexSpeed · " + speed
        if item.button?.toolTip != text { item.button?.toolTip = text }
    }

    private var speed: String {
        guard let session = model.selected, let value = session.displaySpeed(at: model.now) else { return "— tok/s" }
        return (session.running ? "≈" : "") + String(format: "%.1f tok/s", value)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        label("CodexSpeed")
        if let session = model.selected {
            label(session.model + " · " + session.project)
            label(speed + " · " + phase(session.status))
        } else {
            label(model.text("Waiting for task data", "等待任务数据"))
        }
        menu.addItem(.separator())
        if model.snapshot.limits.isEmpty { label(model.text("No quota data", "暂无额度数据")) }
        for limit in model.snapshot.limits {
            let expired = limit.reset <= model.now.timeIntervalSince1970
            let remaining = expired ? model.text("Pending", "待更新") : String(format: model.text("%.0f%% left", "剩余 %.0f%%"), limit.remaining)
            label(model.language.windowName(minutes: limit.minutes) + " · " + remaining)
            if !expired {
                label(model.text("Resets in ", "重置倒计时 ") + model.language.duration(limit.reset - model.now.timeIntervalSince1970))
            }
        }
        if let error = model.snapshot.error ?? model.snapshot.costError { label(model.language.error(error)) }
        menu.addItem(.separator())
        action(isHUDVisible?() == true ? model.text("Hide to Menu Bar", "收至菜单栏") : model.text("Show Floating Window", "显示悬浮窗"), #selector(toggleWindow))
        let compact = action(model.text("Compact mode", "极简模式"), #selector(toggleCompact))
        compact.state = model.compact ? .on : .off
        menu.addItem(.separator())
        action(model.text("Quit CodexSpeed", "退出 CodexSpeed"), #selector(quit), key: "q")
    }

    private func phase(_ value: TaskPhase) -> String {
        switch value {
        case .running: return model.text("Running", "运行中")
        case .completed: return model.text("Done", "已完成")
        case .interrupted: return model.text("Interrupted", "已中断")
        case .idle: return model.text("Idle", "空闲")
        }
    }
    private func label(_ title: String) {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.isEnabled = false
        menu.addItem(row)
    }
    @discardableResult private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let row = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        row.target = self
        menu.addItem(row)
        return row
    }
    @objc private func toggleWindow() { toggleHUD?() }
    @objc private func toggleCompact() { model.compact.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    private static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9, y: 8), radius: 6.5, startAngle: 215, endAngle: -35, clockwise: true)
            arc.lineWidth = 1.8; arc.lineCapStyle = .round; arc.stroke()
            let needle = NSBezierPath()
            needle.move(to: NSPoint(x: 7.2, y: 6.2)); needle.line(to: NSPoint(x: 12, y: 11))
            needle.lineWidth = 2; needle.lineCapStyle = .round; needle.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
