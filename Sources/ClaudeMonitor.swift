import SwiftUI
import AppKit
import Foundation

// MARK: - Hide from Dock
class AppDelegate: NSObject, NSApplicationDelegate {
    let statusBar = StatusBarController()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBar.setup()
    }
}

// MARK: - Data Models
struct ClaudeStats: Codable {
    let dailyActivity: [DayActivity]?
    let modelUsage: [String: ModelTokens]?
    let totalSessions: Int?
    let totalMessages: Int?
    let firstSessionDate: String?
}
struct DayActivity: Codable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}
struct ModelTokens: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    var total: Int { inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens }
}
struct HistoryLine: Codable {
    let timestamp: Double?
    let project: String?
}
struct SessionFile: Codable {
    let pid: Int?
    let sessionId: String?
    let cwd: String?
    let status: String?
}
struct OAuthCredentials: Codable {
    let claudeAiOauth: OAuthToken
}
struct OAuthToken: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Double
    let subscriptionType: String?
    let rateLimitTier: String?
}

// Rate limit data from API headers
struct RateLimits {
    var status: String = "unknown"
    var fiveHourStatus: String = "unknown"
    var fiveHourReset: Date = Date()
    var fiveHourUtilization: Double = 0
    var sevenDayStatus: String = "unknown"
    var sevenDayReset: Date = Date()
    var sevenDayUtilization: Double = 0
    var fallbackPct: Double = 0
    var overageStatus: String = "unknown"
    var fetchedAt: Date = Date()
    var error: String? = nil
}

// MARK: - View Model
class VM: ObservableObject {
    struct DayBar: Identifiable {
        let id: String; let label: String; let msgs: Int; let tools: Int
    }
    struct ModelRow: Identifiable {
        let id: String; let name: String; let input: Int; let output: Int
        let cache: Int; let total: Int; let pct: Double
    }
    struct ProcessDetail: Identifiable {
        let id: Int // pid
        let name: String
        let rss: Int // KB
    }
    struct Session: Identifiable {
        let id: String; let status: String; let pid: Int; let project: String
        let processes: [ProcessDetail]
        var totalMemMB: Double { Double(processes.reduce(0) { $0 + $1.rss }) / 1024.0 }
    }

    // Rate limits (from API)
    @Published var limits = RateLimits()
    @Published var plan = "Max"
    @Published var tier = ""

    // Local stats
    @Published var todayMsgs = 0
    @Published var todayProjects: [String] = []
    @Published var days: [DayBar] = []
    @Published var weekMsgs = 0
    @Published var weekAvg = 0.0
    @Published var todayPct = 0.0
    @Published var models: [ModelRow] = []
    @Published var sessions: [Session] = []
    @Published var totalMsgs = 0
    @Published var totalSess = 0
    @Published var sinceDate = ""
    @Published var sinceDays = 0
    @Published var lastUpdate = Date()
    @Published var menuIcon = "◇"
    @Published var menu5hText = "..."
    @Published var menu7dText = ""
    @Published var menu5hColor: NSColor = .secondaryLabelColor
    @Published var menu7dColor: NSColor = .secondaryLabelColor
    @Published var isFetching = false

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var statsTimer: Timer?
    private var apiTimer: Timer?

    init() {
        loadLocalData()
        fetchRateLimits()
        // Stats locais: refresh a cada 30s
        statsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.loadLocalData() }
        }
        // Rate limits via API: refresh a cada 5min
        apiTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchRateLimits()
        }
    }

    func refresh() {
        loadLocalData()
        fetchRateLimits()
    }

    // Deterministic, fixed sample data for `--snapshot` mode.
    // Does NOT read the Keychain, hit the API, or start any timers —
    // the rendered screenshot must never leak real usage.
    init(sample: Bool) {
        plan = "Max 5x"
        tier = "Sonnet 4 5"

        var l = RateLimits()
        l.status = "allowed"
        l.fiveHourStatus = "allowed"
        l.fiveHourUtilization = 0.62
        l.fiveHourReset = Date().addingTimeInterval(2.4 * 3600)
        l.sevenDayStatus = "allowed"
        l.sevenDayUtilization = 0.38
        l.sevenDayReset = Date().addingTimeInterval(4.2 * 24 * 3600)
        l.overageStatus = "allowed"
        l.error = nil
        limits = l

        todayMsgs = 140
        todayProjects = ["yurigda", "petsapp", "gym-app"]

        let sampleDays: [(String, Int)] = [
            ("Qui", 85), ("Sex", 120), ("Sáb", 60), ("Dom", 145),
            ("Seg", 95), ("Ontem", 130), ("Hoje", 140)
        ]
        days = sampleDays.enumerated().map { i, e in
            DayBar(id: "d\(i)", label: e.0, msgs: e.1, tools: e.1 * 3)
        }
        weekMsgs = sampleDays.reduce(0) { $0 + $1.1 }
        weekAvg = Double(weekMsgs) / 7.0
        todayPct = weekAvg > 0 ? Double(todayMsgs) / weekAvg * 100 : 0

        let opus = 45_200_000, sonnet = 30_100_000, haiku = 8_050_000
        let allTotal = opus + sonnet + haiku
        models = [
            ModelRow(id: "opus", name: "opus-4-6", input: 3_100_000, output: 1_800_000,
                     cache: 40_300_000, total: opus, pct: Double(opus) / Double(allTotal) * 100),
            ModelRow(id: "sonnet", name: "sonnet-4-5", input: 2_400_000, output: 1_200_000,
                     cache: 26_500_000, total: sonnet, pct: Double(sonnet) / Double(allTotal) * 100),
            ModelRow(id: "haiku", name: "haiku-4-5", input: 900_000, output: 350_000,
                     cache: 6_800_000, total: haiku, pct: Double(haiku) / Double(allTotal) * 100)
        ]

        sessions = [
            Session(id: "a1b2c3d4", status: "busy", pid: 12345, project: "yurigda",
                    processes: [
                        ProcessDetail(id: 12345, name: "claude", rss: 462_000),
                        ProcessDetail(id: 12346, name: "node", rss: 128_000),
                        ProcessDetail(id: 12347, name: "node", rss: 96_000),
                        ProcessDetail(id: 12348, name: "rg", rss: 18_000)
                    ]),
            Session(id: "e5f6g7h8", status: "idle", pid: 23456, project: "petsapp",
                    processes: [
                        ProcessDetail(id: 23456, name: "claude", rss: 388_000),
                        ProcessDetail(id: 23457, name: "node", rss: 74_000)
                    ])
        ]

        totalMsgs = 28_450
        totalSess = 342
        sinceDate = "15/01/2026"
        sinceDays = 169
        lastUpdate = Date()
    }

    // MARK: - API Rate Limits
    func fetchRateLimits() {
        guard !isFetching else { return }
        DispatchQueue.main.async { self.isFetching = true }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let token = self.readOAuthToken() else {
                DispatchQueue.main.async {
                    self.limits.error = "Token não encontrado"
                    self.isFetching = false
                }
                return
            }

            // Ler plano e tier
            DispatchQueue.main.async {
                self.plan = token.subscriptionType?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Max"
                self.tier = token.rateLimitTier?.replacingOccurrences(of: "default_claude_", with: "")
                    .replacingOccurrences(of: "_", with: " ").capitalized ?? ""
            }

            // Minimal API call com Haiku (1 token)
            let url = URL(string: "https://api.anthropic.com/v1/messages")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 1,
                "messages": [["role": "user", "content": "1"]]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let sem = DispatchSemaphore(value: 0)
            var result = RateLimits()

            let task = URLSession.shared.dataTask(with: request) { _, response, error in
                defer { sem.signal() }
                if let error = error {
                    result.error = error.localizedDescription
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    result.error = "Resposta inválida"
                    return
                }

                let headers = httpResponse.allHeaderFields
                let h = { (key: String) -> String? in
                    headers[key] as? String ?? headers[key.lowercased()] as? String
                }

                result.status = h("anthropic-ratelimit-unified-status") ?? "unknown"
                result.fiveHourStatus = h("anthropic-ratelimit-unified-5h-status") ?? "unknown"
                result.sevenDayStatus = h("anthropic-ratelimit-unified-7d-status") ?? "unknown"
                result.overageStatus = h("anthropic-ratelimit-unified-overage-status") ?? "unknown"

                if let v = h("anthropic-ratelimit-unified-5h-utilization"), let d = Double(v) {
                    result.fiveHourUtilization = d
                }
                if let v = h("anthropic-ratelimit-unified-7d-utilization"), let d = Double(v) {
                    result.sevenDayUtilization = d
                }
                if let v = h("anthropic-ratelimit-unified-5h-reset"), let t = TimeInterval(v) {
                    result.fiveHourReset = Date(timeIntervalSince1970: t)
                }
                if let v = h("anthropic-ratelimit-unified-7d-reset"), let t = TimeInterval(v) {
                    result.sevenDayReset = Date(timeIntervalSince1970: t)
                }
                if let v = h("anthropic-ratelimit-unified-fallback-percentage"), let d = Double(v) {
                    result.fallbackPct = d
                }

                result.fetchedAt = Date()
                result.error = httpResponse.statusCode == 200 ? nil : "HTTP \(httpResponse.statusCode)"

                // Se 429 sem headers de ratelimit, ainda é útil saber
                if httpResponse.statusCode == 429 && result.fiveHourUtilization == 0 {
                    result.error = "Rate limited (429)"
                }
            }
            task.resume()
            sem.wait()

            DispatchQueue.main.async {
                if result.error == nil || result.fiveHourUtilization > 0 {
                    self.limits = result
                } else if let err = result.error {
                    self.limits.error = err
                }
                self.isFetching = false
                self.updateMenuTitle()
            }
        }
    }

    private func readOAuthToken() -> OAuthToken? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let accessToken = oauth["accessToken"] as? String,
                  let refreshToken = oauth["refreshToken"] as? String,
                  let expiresAt = oauth["expiresAt"] as? Double else { return nil }
            return OAuthToken(
                accessToken: accessToken, refreshToken: refreshToken,
                expiresAt: expiresAt,
                subscriptionType: oauth["subscriptionType"] as? String,
                rateLimitTier: oauth["rateLimitTier"] as? String
            )
        } catch { return nil }
    }

    // MARK: - Local Data
    func loadLocalData() {
        let stats = loadJSON(home.appending(path: ".claude/stats-cache.json"), as: ClaudeStats.self)
        loadDailyActivity(stats)
        loadToday()
        loadModels(stats)
        loadSessions()
        loadTotals(stats)
        lastUpdate = Date()
        updateMenuTitle()
    }

    private func updateMenuTitle() {
        let pct5h = Int(limits.fiveHourUtilization * 100)
        let pct7d = Int(limits.sevenDayUtilization * 100)
        let busy = sessions.filter { $0.status == "busy" }.count
        menuIcon = busy > 0 ? "◆" : (sessions.isEmpty ? "○" : "◇")
        if limits.error != nil && limits.fiveHourUtilization == 0 {
            menu5hText = "\(todayMsgs)m"
            menu7dText = ""
            menu5hColor = .secondaryLabelColor
            menu7dColor = .secondaryLabelColor
        } else {
            let r5h = shortTimeUntil(limits.fiveHourReset)
            let r7d = shortTimeUntil(limits.sevenDayReset)
            let time5h = Int(timePctElapsed(resetDate: limits.fiveHourReset, windowSeconds: 5 * 3600) * 100)
            let time7d = Int(timePctElapsed(resetDate: limits.sevenDayReset, windowSeconds: 7 * 24 * 3600) * 100)
            menu5hText = "5h:\(pct5h)/\(time5h)% \(r5h)"
            menu7dText = "7d:\(pct7d)/\(time7d)% \(r7d)"
            menu5hColor = nsUtilizationColor(limits.fiveHourUtilization)
            menu7dColor = nsUtilizationColor(limits.sevenDayUtilization)
        }
        NotificationCenter.default.post(name: NSNotification.Name("VMUpdated"), object: nil)
    }

    private func loadDailyActivity(_ stats: ClaudeStats?) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var result: [DayBar] = []
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEE"
        dayFmt.locale = Locale(identifier: "pt_BR")
        var weekTotal = 0
        for i in (0..<7).reversed() {
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            let ds = fmt.string(from: d)
            let label = i == 0 ? "Hoje" : (i == 1 ? "Ontem" : String(dayFmt.string(from: d).prefix(3)).capitalized)
            let entry = stats?.dailyActivity?.first(where: { $0.date == ds })
            let msgs = entry?.messageCount ?? 0
            let tools = entry?.toolCallCount ?? 0
            weekTotal += msgs
            result.append(DayBar(id: ds, label: label, msgs: msgs, tools: tools))
        }
        days = result; weekMsgs = weekTotal; weekAvg = Double(weekTotal) / 7.0
    }

    private func loadToday() {
        let historyURL = home.appending(path: ".claude/history.jsonl")
        guard let data = try? String(contentsOf: historyURL, encoding: .utf8) else { return }
        let cal = Calendar.current; let todayStart = cal.startOfDay(for: Date())
        var msgs = 0; var projects = Set<String>()
        for line in data.split(separator: "\n") {
            guard let d = try? JSONDecoder().decode(HistoryLine.self, from: Data(line.utf8)),
                  let ts = d.timestamp else { continue }
            if Date(timeIntervalSince1970: ts / 1000) >= todayStart {
                msgs += 1
                if let p = d.project, !p.isEmpty { projects.insert(URL(fileURLWithPath: p).lastPathComponent) }
            }
        }
        todayMsgs = msgs; todayProjects = Array(projects).sorted()
        if !days.isEmpty {
            let last = days[days.count - 1]
            days[days.count - 1] = DayBar(id: last.id, label: last.label, msgs: max(last.msgs, msgs), tools: last.tools)
        }
        todayPct = weekAvg > 0 ? Double(todayMsgs) / weekAvg * 100 : 0
    }

    private func loadModels(_ stats: ClaudeStats?) {
        guard let usage = stats?.modelUsage else { models = []; return }
        let allTotal = usage.values.reduce(0) { $0 + $1.total }
        models = usage.compactMap { name, u in
            guard u.total > 0 else { return nil }
            let short = name.replacingOccurrences(of: "claude-", with: "").components(separatedBy: "-202").first ?? name
            return ModelRow(id: name, name: short, input: u.inputTokens, output: u.outputTokens,
                          cache: u.cacheReadInputTokens, total: u.total,
                          pct: allTotal > 0 ? Double(u.total) / Double(allTotal) * 100 : 0)
        }.sorted { $0.total > $1.total }
    }

    private func loadSessions() {
        let dir = home.appending(path: ".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { sessions = []; return }

        let validSessions = files.filter { $0.pathExtension == "json" }.compactMap { f -> (String, String, Int, String)? in
            guard let s = loadJSON(f, as: SessionFile.self),
                  let status = s.status, ["idle", "busy"].contains(status),
                  let pid = s.pid, kill(Int32(pid), 0) == 0 else { return nil }
            let project = s.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            return (String((s.sessionId ?? "?").prefix(8)), status, pid, project)
        }

        // Rodar ps em background para não bloquear a UI
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let allProcs = self.getAllProcesses()
            let result = validSessions.map { (id, status, pid, project) in
                let procs = self.findDescendants(rootPid: pid, allProcs: allProcs)
                return Session(id: id, status: status, pid: pid, project: project, processes: procs)
            }
            DispatchQueue.main.async {
                self.sessions = result
            }
        }
    }

    private func getAllProcesses() -> [(pid: Int, ppid: Int, rss: Int, name: String)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["axo", "pid,ppid,rss,comm"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch { return [] }

        // Ler ANTES de waitUntilExit para evitar deadlock do pipe buffer
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n").dropFirst().compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 3)
            guard parts.count >= 4,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let rss = Int(parts[2]) else { return nil }
            let name = (String(parts[3]) as NSString).lastPathComponent
            return (pid, ppid, rss, name)
        }
    }

    private func findDescendants(rootPid: Int, allProcs: [(pid: Int, ppid: Int, rss: Int, name: String)]) -> [ProcessDetail] {
        var pids = Set<Int>([rootPid])
        var changed = true
        while changed {
            changed = false
            for p in allProcs where !pids.contains(p.pid) && pids.contains(p.ppid) {
                pids.insert(p.pid)
                changed = true
            }
        }
        return allProcs.filter { pids.contains($0.pid) && $0.rss > 0 }
            .map { ProcessDetail(id: $0.pid, name: $0.name, rss: $0.rss) }
            .sorted { $0.rss > $1.rss }
    }

    private func loadTotals(_ stats: ClaudeStats?) {
        totalMsgs = stats?.totalMessages ?? 0; totalSess = stats?.totalSessions ?? 0
        if let fs = stats?.firstSessionDate {
            let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fmt.date(from: fs) {
                let dfmt = DateFormatter(); dfmt.dateFormat = "dd/MM/yyyy"
                sinceDate = dfmt.string(from: d)
                sinceDays = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
            }
        }
    }

    private func loadJSON<T: Codable>(_ url: URL, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
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
            if vm.limits.error == nil || vm.limits.fiveHourUtilization > 0 {
                usageLimitsCard
            }
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
                    Text("\(vm.totalMsgs.formatted()) msgs · \(vm.totalSess) sessões · desde \(vm.sinceDate)")
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

// MARK: - Render combined menu bar image (memory graph + claude usage)
func renderCombinedMenuBarImage(
    memGraph: NSImage, memPct: Int, memColor: NSColor,
    icon: String, claudeText: String, claudeColor: NSColor,
    showMem: Bool
) -> NSImage {
    let fontSmall = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    let fontMed = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    let dimAttrs: [NSAttributedString.Key: Any] = [.font: fontMed, .foregroundColor: NSColor.secondaryLabelColor]

    let iconStr = NSAttributedString(string: "\(icon) ", attributes: dimAttrs)
    let claudeStr = NSAttributedString(string: claudeText, attributes: [.font: fontMed, .foregroundColor: claudeColor])
    let memStr: NSAttributedString? = showMem
        ? NSAttributedString(string: " \(memPct)% · ", attributes: [.font: fontSmall, .foregroundColor: memColor])
        : nil

    let totalH: CGFloat = 18
    let totalW = memGraph.size.width + (memStr?.size().width ?? 2)
        + iconStr.size().width + claudeStr.size().width

    let img = NSImage(size: NSSize(width: ceil(totalW), height: totalH))
    img.lockFocus()

    var x: CGFloat = 0
    memGraph.draw(at: NSPoint(x: x, y: (totalH - memGraph.size.height) / 2),
                  from: .zero, operation: .sourceOver, fraction: 1)
    x += memGraph.size.width

    if let ms = memStr {
        ms.draw(at: NSPoint(x: x, y: (totalH - ms.size().height) / 2))
        x += ms.size().width
    } else {
        x += 2
    }
    iconStr.draw(at: NSPoint(x: x, y: (totalH - iconStr.size().height) / 2))
    x += iconStr.size().width
    claudeStr.draw(at: NSPoint(x: x, y: (totalH - claudeStr.size().height) / 2))

    img.unlockFocus()
    img.isTemplate = false
    return img
}

// MARK: - Memory Pressure Monitor
class MemoryMonitor {
    struct Sample {
        let pressure: Double // 0.0 - 1.0
        let color: NSColor
    }

    private(set) var samples: [Sample] = []
    private let maxSamples = 120 // 2 min at 1s interval
    private var timer: Timer?

    func start() {
        sample() // first sample immediately
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func sample() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory

        // Calculo igual ao Activity Monitor: used = total - free - inactive
        let used = total - free - inactive
        let pressure = min(1.0, Double(used) / Double(total))

        // Cor do sistema real via kern.memorystatus_vm_pressure_level
        // 1 = normal (green), 2 = warn (yellow), 4 = critical (red)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)

        let color: NSColor
        switch level {
        case 4: color = .systemRed
        case 2: color = .systemYellow
        default: color = .systemGreen
        }

        samples.append(Sample(pressure: pressure, color: color))
        if samples.count > maxSamples { samples.removeFirst() }
    }

    var currentPressure: Double {
        samples.last?.pressure ?? 0
    }

    var currentColor: NSColor {
        samples.last?.color ?? .systemGreen
    }

    func renderGraph(width: CGFloat = 80, height: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()

        // Background
        NSColor.black.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: 2, yRadius: 2).fill()

        let barWidth: CGFloat = 1
        let gap: CGFloat = 0
        let totalBars = Int(width / (barWidth + gap))
        let startIdx = max(0, samples.count - totalBars)
        let visibleSamples = Array(samples.suffix(totalBars))

        for (i, sample) in visibleSamples.enumerated() {
            let x = CGFloat(totalBars - visibleSamples.count + i) * (barWidth + gap)
            let barHeight = max(1, sample.pressure * (height - 2))
            sample.color.withAlphaComponent(0.85).setFill()
            NSRect(x: x, y: 1, width: barWidth, height: barHeight).fill()
        }

        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

// MARK: - App
class StatusBarController: NSObject, ObservableObject {
    private enum MenuBarMode { case full, compact }
    private var menuBarMode: MenuBarMode = .full
    private var pendingDetect = false

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let vm = VM()
    private var observer: NSObjectProtocol?
    private let memMonitor = MemoryMonitor()
    private var memTimer: Timer?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        memMonitor.start()
        updateIcon()
        memTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }

        let contentView = ContentView(vm: vm)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 580)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("VMUpdated"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateIcon()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.detectMenuBarMode()
        }

        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.detectMenuBarMode() }
        }
    }

    func updateIcon() {
        let full = menuBarMode == .full
        let hasData = vm.limits.error == nil || vm.limits.fiveHourUtilization > 0
        let claudeText: String
        if full {
            if hasData {
                claudeText = vm.menu7dText.isEmpty
                    ? vm.menu5hText
                    : "\(vm.menu5hText) · \(vm.menu7dText)"
            } else {
                claudeText = "\(vm.todayMsgs)m"
            }
        } else {
            claudeText = hasData ? "\(Int(vm.limits.fiveHourUtilization * 100))%" : "\(vm.todayMsgs)m"
        }
        let claudeColor = hasData ? vm.menu5hColor : NSColor.secondaryLabelColor

        // CoreText pode lançar NSException intermitente (fontd/cache de fontes);
        // capturar para não derrubar o app — mantém o ícone anterior e tenta no próximo tick
        var img: NSImage?
        if let exc = AGTryBlock({
            img = renderCombinedMenuBarImage(
                memGraph: self.memMonitor.renderGraph(width: 40, height: 12),
                memPct: Int(self.memMonitor.currentPressure * 100),
                memColor: self.memMonitor.currentColor,
                icon: self.vm.menuIcon,
                claudeText: claudeText, claudeColor: claudeColor,
                showMem: full
            )
        }) {
            NSLog("updateIcon: exceção capturada ao renderizar menu bar: %@ — %@",
                  exc.name.rawValue, exc.reason ?? "sem reason")
            return
        }
        statusItem.button?.image = img
        scheduleDetect()
    }

    private func estimatedFullModeWidth() -> CGFloat {
        let fontSmall = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let fontMed = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let hasData = vm.limits.error == nil || vm.limits.fiveHourUtilization > 0
        let claudeText = hasData
            ? (vm.menu7dText.isEmpty ? vm.menu5hText : "\(vm.menu5hText) · \(vm.menu7dText)")
            : "\(vm.todayMsgs)m"
        let memStr = NSAttributedString(string: " 99% · ", attributes: [.font: fontSmall, .foregroundColor: NSColor.secondaryLabelColor])
        let iconStr = NSAttributedString(string: "\(vm.menuIcon) ", attributes: [.font: fontMed, .foregroundColor: NSColor.secondaryLabelColor])
        let claudeStr = NSAttributedString(string: claudeText, attributes: [.font: fontMed, .foregroundColor: NSColor.white])
        // Mesmo risco de NSException do CoreText que no updateIcon
        var width: CGFloat = 300 // fallback conservador
        if let exc = AGTryBlock({
            width = 40 + memStr.size().width + iconStr.size().width + claudeStr.size().width
        }) {
            NSLog("estimatedFullModeWidth: exceção capturada: %@", exc.reason ?? exc.name.rawValue)
        }
        return width
    }

    private func scheduleDetect() {
        guard !pendingDetect else { return }
        pendingDetect = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingDetect = false
            self?.detectMenuBarMode()
        }
    }

    private func detectMenuBarMode() {
        guard let button = statusItem.button,
              let window = button.window else { return }

        let x = window.frame.origin.x
        let rightEdge = x + window.frame.width
        let minSafeLeft: CGFloat = 200

        let newMode: MenuBarMode
        switch menuBarMode {
        case .full:
            newMode = x < minSafeLeft ? .compact : .full
        case .compact:
            // Project where the left edge would land if we switched to full
            let projectedLeft = rightEdge - estimatedFullModeWidth()
            newMode = projectedLeft > minSafeLeft ? .full : .compact
        }

        if newMode != menuBarMode {
            menuBarMode = newMode
            updateIcon()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Snapshot rendering (--snapshot)
// Renders the popover UI with FIXED sample data to a retina PNG, then exits.
// Never touches the Keychain, the API, or live local files.
enum SnapshotRenderer {
    static let outDir = "/Users/yuri/Developer/AgapeHolding/claude-monitor/docs"

    @MainActor
    static func run() {
        // Ensure AppKit is initialized so system fonts/colors resolve offscreen.
        _ = NSApplication.shared

        let vm = VM(sample: true)
        let content = ContentView(vm: vm, interactive: false).cards
            .padding(16)
            .frame(width: 340)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2 // retina

        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: ImageRenderer produced no image\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: PNG encoding failed\n".utf8))
            exit(1)
        }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let path = outDir + "/screenshot.png"
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("snapshot written: \(path) (\(cg.width)x\(cg.height)px)")
        } catch {
            FileHandle.standardError.write(Data("snapshot: write failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

@main
enum AppMain {
    static func main() {
        if CommandLine.arguments.contains("--snapshot") {
            // The process entry point runs on the main thread; ImageRenderer
            // and the SwiftUI views it touches are MainActor-isolated.
            MainActor.assumeIsolated { SnapshotRenderer.run() }
            exit(0)
        }
        ClaudeMonitorApp.main()
    }
}
