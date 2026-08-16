import SwiftUI
import AppKit
import Foundation

// MARK: - Views
struct ContentView: View {
    @ObservedObject var vm: VM
    // When false (snapshot mode), the interactive footer buttons are hidden —
    // ImageRenderer can't render live controls offscreen.
    var interactive: Bool = true

    var body: some View {
        ScrollView {
            cards.padding(16)
        }
        .frame(width: 340, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // The stack of cards, extracted so `--snapshot` can render it at full
    // natural height (no ScrollView clipping) into a product screenshot.
    @ViewBuilder var cards: some View {
        VStack(spacing: 12) {
            header
            // Sempre visível: em erro o card mostra o motivo. Antes ele sumia,
            // e o popover encurtava sem explicar por quê.
            usageLimitsCard
            todayCard
            weekChart
            modelCard
            sessionsCard
            footer
        }
    }

    var header: some View {
        HStack {
            Image(systemName: "brain.head.profile")
                .font(.title2).foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Code Monitor")
                    .font(.headline)
                Text("\(vm.plan) · \(vm.tier)")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if vm.isFetching {
                ProgressView().scaleEffect(0.6)
            }
        }
    }

    // MARK: Usage Limits
    var usageLimitsCard: some View {
        VStack(spacing: 10) {
            if vm.limits.fiveHourUtilization == 0, let err = vm.limits.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Limites indisponíveis").font(.subheadline.bold())
                        Text(err).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else {
            // 5-Hour Session
            UsageLimitRow(
                icon: "clock",
                title: "Sessão (5h)",
                utilization: vm.limits.fiveHourUtilization,
                status: vm.limits.fiveHourStatus,
                resetDate: vm.limits.fiveHourReset,
                windowSeconds: 5 * 3600
            )
            Divider()
            // 7-Day Weekly
            UsageLimitRow(
                icon: "calendar",
                title: "Semanal (7d)",
                utilization: vm.limits.sevenDayUtilization,
                status: vm.limits.sevenDayStatus,
                resetDate: vm.limits.sevenDayReset,
                windowSeconds: 7 * 24 * 3600
            )
            // Overage status
            if vm.limits.overageStatus == "rejected" {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundColor(.orange)
                    Text("Usage credits desativados")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                }
            }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    var todayCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "message").foregroundColor(.blue)
                Text("Hoje").font(.subheadline.bold())
                Spacer()
                Text("\(vm.todayMsgs) msgs")
                    .font(.caption).foregroundColor(.secondary)
            }
            if !vm.todayProjects.isEmpty {
                Text(vm.todayProjects.joined(separator: " · "))
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    var weekChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.bar.fill").foregroundColor(.blue)
                Text("Últimos 7 Dias").font(.subheadline.bold())
                Spacer()
                Text("\(vm.weekMsgs) msgs").font(.caption).foregroundColor(.secondary)
            }
            let maxVal = max(vm.days.map(\.msgs).max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(vm.days) { day in
                    VStack(spacing: 4) {
                        Text(day.msgs > 0 ? fmtTokens(day.msgs) : "")
                            .font(.system(size: 8)).foregroundColor(.secondary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(day.msgs, vm.weekAvg))
                            .frame(height: max(4, CGFloat(day.msgs) / CGFloat(maxVal) * 50))
                        Text(day.label).font(.system(size: 9)).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 80)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    var modelCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "number").foregroundColor(.purple)
                Text("Tokens por Modelo").font(.subheadline.bold())
                Spacer()
                Text("7 dias").font(.system(size: 9)).foregroundColor(.secondary)
            }
            ForEach(vm.models.prefix(4)) { m in
                HStack {
                    Text(m.name).font(.caption).frame(width: 85, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.purple.opacity(0.7))
                                .frame(width: max(2, geo.size.width * m.pct / 100))
                        }
                    }.frame(height: 8)
                    Text(String(format: "%.0f%%", m.pct))
                        .font(.system(size: 9, design: .monospaced)).frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "terminal").foregroundColor(.green)
                Text("Sessões Ativas").font(.subheadline.bold())
                Spacer()
                if !vm.sessions.isEmpty {
                    let totalMem = vm.sessions.reduce(0.0) { $0 + $1.totalMemMB }
                    Text(String(format: "%.0f MB", totalMem))
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }
                Text("\(vm.sessions.count)")
                    .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(vm.sessions.isEmpty ? Color.secondary.opacity(0.3) : Color.green.opacity(0.3)))
            }
            if vm.sessions.isEmpty {
                Text("Nenhuma sessão ativa").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(vm.sessions) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(s.status == "busy" ? Color.orange : Color.green).frame(width: 8, height: 8)
                            Text(s.project).font(.caption)
                            Spacer()
                            Text(String(format: "%.0f MB", s.totalMemMB))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(s.status).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                        }
                        // Processos agrupados por nome
                        let grouped = Dictionary(grouping: s.processes, by: \.name)
                            .map { (name: $0.key, count: $0.value.count, rss: $0.value.reduce(0) { $0 + $1.rss }) }
                            .sorted { $0.rss > $1.rss }
                        let top = grouped.prefix(5)
                        if !top.isEmpty {
                            HStack(spacing: 0) {
                                Text("  ")
                                Text(top.map { g in
                                    let mb = String(format: "%.0f", Double(g.rss) / 1024.0)
                                    return g.count > 1 ? "\(g.name)×\(g.count) \(mb)M" : "\(g.name) \(mb)M"
                                }.joined(separator: " · "))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            }
                        }
                    }
                    if s.id != vm.sessions.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    var footer: some View {
        VStack(spacing: 6) {
            HStack {
                if !vm.sinceDate.isEmpty {
                    // Mesma fonte congelada do card de modelos — rotula igual.
                    let stale = vm.statsStaleDate.isEmpty ? "" : " (até \(vm.statsStaleDate))"
                    Text("\(vm.totalMsgs.formatted()) msgs · \(vm.totalSess) sessões · desde \(vm.sinceDate)\(stale)")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack {
                let timeFmt = { () -> DateFormatter in let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
                Text("Atualizado \(vm.lastUpdate, formatter: timeFmt)")
                    .font(.caption2).foregroundColor(.secondary)
                if let err = vm.limits.error {
                    Text("· \(err)").font(.caption2).foregroundColor(.red)
                }
                Spacer()
                if interactive {
                    Button(action: {
                        NotificationCenter.default.post(name: .openAnalytics, object: nil)
                    }) {
                        Label("Analytics", systemImage: "chart.xyaxis.line").font(.caption2)
                    }.buttonStyle(.borderless)
                    Button(action: { vm.refresh() }) {
                        Label("Refresh", systemImage: "arrow.clockwise").font(.caption2)
                    }.buttonStyle(.borderless)
                    Button(action: { NSApp.terminate(nil) }) {
                        Text("Sair").font(.caption2)
                    }.buttonStyle(.borderless)
                }
            }
        }
    }
}

// MARK: - Usage Limit Row Component
struct UsageLimitRow: View {
    let icon: String
    let title: String
    let utilization: Double
    let status: String
    let resetDate: Date
    let windowSeconds: TimeInterval

    var timePct: Double {
        timePctElapsed(resetDate: resetDate, windowSeconds: windowSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundColor(utilizationColor(utilization)).font(.caption)
                Text(title).font(.subheadline.bold())
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(String(format: "%.0f%%", utilization * 100))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(utilizationColor(utilization))
                        Text("uso").font(.caption2).foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text(String(format: "%.0f%%", timePct * 100))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                        Text("tempo").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            // Progress bar with time marker
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(utilizationColor(utilization))
                        .frame(width: max(2, geo.size.width * min(utilization, 1.0)))
                    // Time marker line
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2, height: 14)
                        .offset(x: max(0, geo.size.width * min(timePct, 1.0) - 1), y: -3)
                }
            }.frame(height: 8)
            HStack {
                Text("Reset em: \(timeUntil(resetDate))")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                let diff = utilization - timePct
                if diff < -0.05 {
                    Text("▼ pode acelerar")
                        .font(.system(size: 9, weight: .medium)).foregroundColor(.green)
                } else if diff > 0.05 {
                    Text("▲ freiar uso")
                        .font(.system(size: 9, weight: .medium)).foregroundColor(.red)
                } else {
                    Text("● no ritmo")
                        .font(.system(size: 9, weight: .medium)).foregroundColor(.orange)
                }
                if status == "allowed" {
                    Text("OK").font(.caption2.bold()).foregroundColor(.green)
                } else if status == "throttled" {
                    Text("Throttled").font(.caption2.bold()).foregroundColor(.red)
                }
            }
        }
    }
}

