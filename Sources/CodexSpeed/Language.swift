import Foundation
import CodexSpeedCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }
    var title: String { self == .english ? "English" : "简体中文" }
    var locale: Locale { Locale(identifier: self == .english ? "en_US" : "zh_CN") }

    func text(_ english: String, _ chinese: String) -> String {
        self == .english ? english : chinese
    }

    func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, SafeNumber.integer(interval))
        if seconds >= 86400 { return text("\(seconds / 86400)d \(seconds % 86400 / 3600)h", "\(seconds / 86400)天 \(seconds % 86400 / 3600)时") }
        if seconds >= 3600 { return text("\(seconds / 3600)h \(seconds % 3600 / 60)m", "\(seconds / 3600)时 \(seconds % 3600 / 60)分") }
        if seconds >= 60 { return text("\(seconds / 60)m \(seconds % 60)s", "\(seconds / 60)分 \(seconds % 60)秒") }
        return text("\(seconds)s", "\(seconds)秒")
    }

    func windowName(minutes: Double) -> String {
        minutes >= 1440 ? text("\(SafeNumber.integer(minutes / 1440))-day", "\(SafeNumber.integer(minutes / 1440)) 天额度") : text("\(SafeNumber.integer(minutes / 60))-hour", "\(SafeNumber.integer(minutes / 60)) 小时额度")
    }

    func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // Keep engine diagnostics out of the HUD; present concise, actionable localized errors.
    func error(_ diagnostic: String) -> String {
        let messages: [(String, String, String)] = [
            ("未找到 Codex 日志", "Choose a Codex folder in Settings", "请在设置中选择 Codex 目录"),
            ("部分日志", "Some logs are unreadable", "部分日志无法读取"),
            ("找不到 ccusage", "Choose ccusage in Settings", "请在设置中选择 ccusage"),
            ("ccusage 版本未适配", "ccusage 20.0.20 required", "需要 ccusage 20.0.20"),
            ("ccusage JSON", "Invalid ccusage report", "ccusage 报告格式异常"),
            ("ccusage 有用量", "Pricing unavailable", "价格数据不可用"),
            ("模型价格未验证", "Unverified model pricing", "模型价格尚未验证"),
            ("检测到超过 272K", "Long-context pricing unavailable", "长上下文计价暂不可用"),
            ("ccusage 输出超过", "Usage report exceeds size limit", "用量报告超过大小限制"),
            ("ccusage 超时", "ccusage timed out", "ccusage 超时"),
            ("ccusage 执行失败", "ccusage failed", "ccusage 执行失败"),
            ("无法保存校准记录", "Could not save calibration", "无法保存校准记录")
        ]
        for (prefix, english, chinese) in messages where diagnostic.hasPrefix(prefix) {
            return text(english, chinese)
        }
        return text("Usage data unavailable", "用量数据暂不可用")
    }
}
