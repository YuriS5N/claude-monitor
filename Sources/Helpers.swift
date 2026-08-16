import SwiftUI
import AppKit
import Foundation

extension Notification.Name {
    /// Postada pelo botão do popover; ouvida pelo StatusBarController.
    static let openAnalytics = Notification.Name("ClaudeMonitorOpenAnalytics")
}

// MARK: - Helpers
func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n)/1e9) }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n)/1e6) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n)/1e3) }
    return "\(n)"
}

func utilizationColor(_ pct: Double) -> Color {
    if pct < 0.5 { return .green }
    if pct < 0.8 { return .orange }
    return .red
}

func nsUtilizationColor(_ pct: Double) -> NSColor {
    if pct < 0.5 { return .systemGreen }
    if pct < 0.8 { return .systemOrange }
    return .systemRed
}

func shortTimeUntil(_ date: Date) -> String {
    let secs = max(0, date.timeIntervalSinceNow)
    let days = Int(secs) / 86400
    let hours = (Int(secs) % 86400) / 3600
    let mins = (Int(secs) % 3600) / 60
    if days > 0 { return "\(days)d\(hours)h" }
    if hours > 0 { return "\(hours)h\(mins)m" }
    return "\(mins)m"
}

func timeUntil(_ date: Date) -> String {
    let secs = max(0, date.timeIntervalSinceNow)
    let days = Int(secs) / 86400
    let hours = (Int(secs) % 86400) / 3600
    let mins = (Int(secs) % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h \(mins)m" }
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}

func barColor(_ msgs: Int, _ avg: Double) -> Color {
    guard avg > 0 else { return .green }
    let r = Double(msgs) / avg
    if r < 0.8 { return .green }; if r < 1.2 { return .orange }; return .red
}

func timePctElapsed(resetDate: Date, windowSeconds: TimeInterval) -> Double {
    let remaining = max(0, resetDate.timeIntervalSinceNow)
    let elapsed = windowSeconds - remaining
    return max(0, min(1, elapsed / windowSeconds))
}

