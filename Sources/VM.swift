import SwiftUI
import AppKit
import Foundation

import Security

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
    /// Data do stats-cache.json (dd/MM) quando ele está defasado; vazio se atual.
    @Published var statsStaleDate = ""
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
    /// Serviço do Keychain que rendeu um token válido na última leitura.
    private var cachedKeychainService: String?
    private let tokenScanner = TokenScanner()
    private var isScanning = false
    let rateLimitStore = RateLimitStore()
    /// `rateLimitTier` da conta que respondeu por último — filtra a série histórica.
    @Published var activeTier = ""
    /// Filtro de conta para a série histórica: identidade derivada do config dir,
    /// com o tier como casamento das amostras gravadas antes do campo existir.
    var accountFilter: AccountFilter {
        AccountFilter(id: config.account.id, legacyTier: activeTier)
    }
    /// Banco de uso completo, para a janela de Analytics.
    @Published var usageDB = UsageDatabase()
    @Published var config = ConfigStore.shared.config

    init() {
        // Lê o tier da conta fixada de imediato — é leitura local do Keychain. Sem
        // isso o filtro de conta fica vazio até a 1ª resposta da API, e a série da
        // outra conta apareceria como se fosse desta.
        activeTier = readOAuthToken()?.rateLimitTier ?? ""
        loadLocalData()
        fetchRateLimits()
        scanTokens()
        // Stats locais: refresh a cada 30s
        statsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.loadLocalData() }
        }
        // Rate limits via API + varredura de tokens: a cada 5min
        apiTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchRateLimits()
            self?.scanTokens()
        }
    }

    func refresh() {
        loadLocalData()
        fetchRateLimits()
        scanTokens()
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

            // A API não expõe histórico de utilização — grava cada leitura para
            // que a série exista com o tempo. `tier` vai junto: se o Claude Code
            // trocar a conta ativa, a análise precisa separar as séries.
            if result.error == nil, result.fiveHourReset.timeIntervalSince1970 > 0 {
                self.rateLimitStore.append(RateLimitSample(
                    t: Date().timeIntervalSince1970,
                    u5: result.fiveHourUtilization,
                    u7: result.sevenDayUtilization,
                    r5: result.fiveHourReset.timeIntervalSince1970,
                    r7: result.sevenDayReset.timeIntervalSince1970,
                    tier: token.rateLimitTier ?? "",
                    sub: token.subscriptionType ?? "",
                    overage: result.overageStatus,
                    s7: result.sevenDayStatus,
                    acct: self.config.account.id
                ))
            }

            DispatchQueue.main.async {
                if result.error == nil || result.fiveHourUtilization > 0 {
                    self.limits = result
                } else if let err = result.error {
                    self.limits.error = err
                }
                self.activeTier = token.rateLimitTier ?? ""
                // Auto-configura o plano na 1ª execução, para a janela de Analytics
                // funcionar sem o usuário preencher nada.
                if ConfigStore.shared.seedIfNeeded(detectedTier: self.activeTier,
                                                   firstUsageDay: self.usageDB.days.keys.min()) {
                    self.config = ConfigStore.shared.config
                }
                self.isFetching = false
                self.updateMenuTitle()
            }
        }
    }

    // MARK: - Keychain
    // O Claude Code passou a guardar as credenciais por conta, em serviços
    // "Claude Code-credentials-<sufixo>". O serviço legado "Claude Code-credentials"
    // continua existindo, mas com accessToken vazio — daí o 401 que escondia os
    // cards de limite. Enumeramos todos e escolhemos o token válido mais recente.
    private static let legacyKeychainService = "Claude Code-credentials"

    /// Nomes de serviço candidatos no Keychain. A consulta pede só atributos
    /// (sem `kSecReturnData`), então não dispara prompt de autorização.
    private func keychainServices() -> [String] {
        var services: [String] = []
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let items = out as? [[String: Any]] {
            for item in items {
                if let svc = item[kSecAttrService as String] as? String,
                   svc.hasPrefix(Self.legacyKeychainService) {
                    services.append(svc)
                }
            }
        }
        if !services.contains(Self.legacyKeychainService) {
            services.append(Self.legacyKeychainService)
        }
        return services
    }

    /// Lê e valida o token de um serviço específico. Retorna nil se o token
    /// estiver ausente ou vazio (caso do serviço legado após a migração).
    private func readToken(service: String) -> OAuthToken? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
                  let expiresAt = oauth["expiresAt"] as? Double else { return nil }
            return OAuthToken(
                accessToken: accessToken,
                refreshToken: oauth["refreshToken"] as? String ?? "",
                expiresAt: expiresAt,
                subscriptionType: oauth["subscriptionType"] as? String,
                rateLimitTier: oauth["rateLimitTier"] as? String
            )
        } catch { return nil }
    }

    private func readOAuthToken() -> OAuthToken? {
        // A conta é FIXADA pelo diretório de config, não escolhida por heurística.
        // O serviço do Keychain é derivado do caminho (ver `ClaudeAccount`), então
        // o monitor mede sempre a mesma conta mesmo quando a outra renova o token.
        let pinned = config.account.keychainService
        if let t = readToken(service: pinned) {
            cachedKeychainService = pinned
            return t
        }
        // Só se a conta fixada não tiver credencial (ainda não logou nela, ou o
        // Claude Code mudou o esquema de nomes): cai para a descoberta antiga.
        var best: (service: String, token: OAuthToken)?
        for svc in keychainServices() {
            guard let t = readToken(service: svc) else { continue }
            if best == nil || t.expiresAt > best!.token.expiresAt { best = (svc, t) }
        }
        if let best {
            NSLog("readOAuthToken: conta fixada (%@) sem credencial; usando %@",
                  pinned, best.service)
        }
        cachedKeychainService = best?.service
        return best?.token
    }

    // MARK: - Local Data
    func loadLocalData() {
        let stats = loadJSON(config.account.statsCache, as: ClaudeStats.self)
        loadHistory()
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

    /// Constrói "Hoje" e o gráfico de 7 dias numa única passada pelo history.jsonl.
    /// Antes o gráfico vinha do stats-cache.json, que o Claude Code só reescreve
    /// quando o usuário abre `/usage` — ficava congelado e as barras zeravam.
    /// O history conta prompts (não mensagens), então os números são menores que
    /// os do stats-cache, mas são consistentes entre si e sempre atuais.
    private func loadHistory() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEE"
        dayFmt.locale = Locale(identifier: "pt_BR")
        let todayKey = fmt.string(from: today)
        guard let weekStart = cal.date(byAdding: .day, value: -6, to: today) else { return }

        var counts: [String: Int] = [:]
        var projects = Set<String>()
        if let data = try? String(contentsOf: config.account.historyFile, encoding: .utf8) {
            for line in data.split(separator: "\n") {
                guard let d = try? JSONDecoder().decode(HistoryLine.self, from: Data(line.utf8)),
                      let ts = d.timestamp else { continue }
                let date = Date(timeIntervalSince1970: ts / 1000)
                guard date >= weekStart else { continue }
                let key = fmt.string(from: cal.startOfDay(for: date))
                counts[key, default: 0] += 1
                if key == todayKey, let p = d.project, !p.isEmpty {
                    projects.insert(URL(fileURLWithPath: p).lastPathComponent)
                }
            }
        }

        var result: [DayBar] = []
        var weekTotal = 0
        for i in (0..<7).reversed() {
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            let ds = fmt.string(from: d)
            let label = i == 0 ? "Hoje" : (i == 1 ? "Ontem" : String(dayFmt.string(from: d).prefix(3)).capitalized)
            let msgs = counts[ds] ?? 0
            weekTotal += msgs
            result.append(DayBar(id: ds, label: label, msgs: msgs, tools: 0))
        }
        days = result; weekMsgs = weekTotal; weekAvg = Double(weekTotal) / 7.0
        todayMsgs = counts[todayKey] ?? 0
        todayProjects = Array(projects).sorted()
        todayPct = weekAvg > 0 ? Double(todayMsgs) / weekAvg * 100 : 0
    }

    /// Varre os transcripts em background e publica os tokens dos últimos 7 dias.
    /// A primeira passada custa ~1s; as seguintes só leem os bytes novos.
    func scanTokens() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let db = self.tokenScanner.scan(projects: self.config.account.projectsDir)
            let usage = self.tokenScanner.totals(windowDays: 7)
            let allTotal = usage.totalTokens
            let rows: [ModelRow] = usage.compactMap { name, u in
                guard u.total > 0 else { return nil }
                let short = name.replacingOccurrences(of: "claude-", with: "")
                    .components(separatedBy: "-202").first ?? name
                return ModelRow(id: name, name: short, input: u.input, output: u.output,
                                cache: u.cacheRead + u.cacheWrite, total: u.total,
                                pct: allTotal > 0 ? Double(u.total) / Double(allTotal) * 100 : 0)
            }.sorted { $0.total > $1.total }
            DispatchQueue.main.async {
                self.models = rows
                self.usageDB = db
                self.isScanning = false
            }
        }
    }

    private func loadSessions() {
        let dir = config.account.sessionsDir
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
        // Os totais históricos ainda saem do stats-cache, que o Claude Code só
        // regrava quando o usuário abre `/usage`. Se estiver velho, mostramos a
        // data em vez de fingir que o número é de hoje.
        statsStaleDate = ""
        if let last = stats?.lastComputedDate {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            if let d = fmt.date(from: last), d < Calendar.current.startOfDay(for: Date()) {
                let out = DateFormatter(); out.dateFormat = "dd/MM"
                statsStaleDate = out.string(from: d)
            }
        }
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

