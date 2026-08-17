import Foundation
import CryptoKit

// MARK: - Conta ativa
//
// O usuário tem mais de uma conta na máquina, separadas por diretório de config
// (`CLAUDE_CONFIG_DIR`) — no caso do Yuri, `claude-pessoal` → ~/.claude e
// `claude-terra` → ~/.claude-terra. Tudo é por diretório: transcripts, histórico,
// sessões e as credenciais.
//
// Decifrado por medição: o serviço do Keychain é
//   "Claude Code-credentials-" + sha256(<caminho absoluto do config dir>)[:8]
// Confirmado nos dois diretórios desta máquina. Isso substitui a heurística antiga
// de "pegar o token de maior expiresAt", que fazia o monitor pular para a outra
// conta sempre que ela renovava o token — foi o que aconteceu às 19:01 de 16/ago.
struct ClaudeAccount {
    let configDir: URL

    static let defaultDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude")

    var keychainService: String {
        let digest = SHA256.hash(data: Data(configDir.path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    /// E-mail da conta, lido do `.claude.json` do próprio diretório.
    var email: String? {
        guard let data = try? Data(contentsOf: configDir.appending(path: ".claude.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any] else { return nil }
        return oauth["emailAddress"] as? String
    }

    var projectsDir: URL { configDir.appending(path: "projects") }
    var historyFile: URL { configDir.appending(path: "history.jsonl") }
    var sessionsDir: URL { configDir.appending(path: "sessions") }
    var statsCache: URL { configDir.appending(path: "stats-cache.json") }
}

// MARK: - Preço de lista da API
//
// Serve para responder "quanto esse uso custaria se eu pagasse por token?" — a métrica
// que dimensiona o valor da assinatura. NÃO é a fatura, e NÃO prevê utilização de rate
// limit: medimos que a relação entre custo e utilização não é linear (ver o plano).

struct ModelPrice {
    let input: Double   // US$ por milhão de tokens
    let output: Double
}

enum Pricing {
    /// Data da tabela — preço muda; revisar junto com a skill `claude-api`.
    static let asOf = "2026-08-16"

    private static let table: [String: ModelPrice] = [
        "claude-fable-5":    ModelPrice(input: 10, output: 50),
        "claude-mythos-5":   ModelPrice(input: 10, output: 50),
        "claude-opus-5":     ModelPrice(input: 5,  output: 25),
        "claude-opus-4-8":   ModelPrice(input: 5,  output: 25),
        "claude-opus-4-7":   ModelPrice(input: 5,  output: 25),
        "claude-opus-4-6":   ModelPrice(input: 5,  output: 25),
        "claude-opus-4-5":   ModelPrice(input: 5,  output: 25),
        "claude-sonnet-5":   ModelPrice(input: 3,  output: 15),
        "claude-sonnet-4-6": ModelPrice(input: 3,  output: 15),
        "claude-sonnet-4-5": ModelPrice(input: 3,  output: 15),
        "claude-haiku-4-5":  ModelPrice(input: 1,  output: 5),
    ]

    /// Modelo desconhecido cai no preço Opus — mais provável errar para cima num
    /// modelo novo de topo do que para baixo.
    static func price(_ model: String) -> ModelPrice {
        if let p = table[model] { return p }
        let base = model.components(separatedBy: "-202").first ?? model
        return table[base] ?? ModelPrice(input: 5, output: 25)
    }

    /// Cache de leitura sai a 0,1x do input; escrita de cache a 1,25x.
    static func cost(model: String, usage: TokenUsage) -> Double {
        let p = price(model)
        let input = Double(usage.input) * p.input
            + Double(usage.cacheWrite) * p.input * 1.25
            + Double(usage.cacheRead) * p.input * 0.1
        return (input + Double(usage.output) * p.output) / 1_000_000
    }
}

// MARK: - Acumulador de tokens

struct TokenUsage: Codable, Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite += rhs.cacheWrite
    }
}

extension Dictionary where Key == String, Value == TokenUsage {
    /// Custo-equivalente de um mapa modelo → tokens.
    var equivalentCost: Double {
        reduce(0) { $0 + Pricing.cost(model: $1.key, usage: $1.value) }
    }
    var totalTokens: Int { values.reduce(0) { $0 + $1.total } }

    static func += (lhs: inout Self, rhs: Self) {
        for (model, usage) in rhs { lhs[model, default: TokenUsage()] += usage }
    }
}

// MARK: - Banco de uso persistido

struct SessionRecord: Codable {
    var project = ""
    var branch = ""
    var firstTs: Double = 0
    var lastTs: Double = 0
    /// Tempo de trabalho real. Uma sessão do Claude Code é retomável, então
    /// `lastTs - firstTs` chega a mil horas e não significa nada — isso aqui soma
    /// só os intervalos entre mensagens, ignorando as pausas longas.
    var activeSeconds: Double = 0
    var byModel: [String: TokenUsage] = [:]

    /// Intervalo acima disso conta como pausa, não como trabalho.
    static let idleGap: Double = 15 * 60

    var cost: Double { byModel.equivalentCost }
    var tokens: Int { byModel.totalTokens }
    /// Span do calendário — útil para saber quando a sessão viveu, não quanto rendeu.
    var span: TimeInterval { max(0, lastTs - firstTs) }
    var start: Date { Date(timeIntervalSince1970: firstTs) }
    var end: Date { Date(timeIntervalSince1970: lastTs) }
}

/// Cursor de leitura de um transcript, para varredura incremental entre execuções.
struct FileCursor: Codable {
    var offset: UInt64
    var size: UInt64
}

/// Os agregados sobrevivem à limpeza automática de transcripts do Claude Code — é
/// por isso que existem. Uma vez contabilizado, um dia nunca é recalculado.
struct UsageDatabase: Codable {
    /// Subir invalida o banco e força varredura completa.
    /// v2: buckets horários, para a calibração de cota não errar nas bordas da semana.
    static let currentVersion = 2

    var version = UsageDatabase.currentVersion
    /// dia local ("yyyy-MM-dd") → modelo → tokens
    var days: [String: [String: TokenUsage]] = [:]
    /// hora local ("yyyy-MM-dd HH") → modelo → tokens. As janelas de rate limit não
    /// começam à meia-noite (a semanal reseta 04:00), então agregado diário erra a
    /// borda em até um dia — o que numa janela parcial de 1,5 dia é erro grosseiro.
    var hours: [String: [String: TokenUsage]] = [:]
    var sessions: [String: SessionRecord] = [:]
    /// caminho do transcript → quanto já foi lido
    var cursors: [String: FileCursor] = [:]
    /// Hashes de `message.id` já contabilizados, por dia. Sessões bifurcadas replicam
    /// o histórico num arquivo novo (medido: 2,2% dos ids aparecem em >1 arquivo),
    /// então a dedup tem que cruzar arquivos e sobreviver a reinícios. Guardado por
    /// dia para poder expirar — ver `dedupHorizonDays`.
    var seenByDay: [String: [UInt64]] = [:]

    /// Além disso, os bytes antigos nunca são relidos (os cursores já passaram deles),
    /// então só precisamos lembrar dos ids que um fork poderia reproduzir.
    static let dedupHorizonDays = 60
}

// MARK: - Planos

struct PlanTier: Identifiable, Hashable {
    let id: String
    let name: String
    /// Múltiplo de uso em relação ao Pro — é isso que torna a comparação possível.
    let factor: Double
    let defaultPrice: Double
    /// A página da Anthropic mostra "a partir de $100/mês" para a família Max sem
    /// separar os tiers; o preço do 20x não foi confirmado.
    let priceVerified: Bool

    static let pro    = PlanTier(id: "pro",    name: "Pro",     factor: 1,  defaultPrice: 20,  priceVerified: true)
    static let max5x  = PlanTier(id: "max5x",  name: "Max 5x",  factor: 5,  defaultPrice: 100, priceVerified: true)
    static let max20x = PlanTier(id: "max20x", name: "Max 20x", factor: 20, defaultPrice: 200, priceVerified: false)

    static let all = [pro, max5x, max20x]

    /// Deduz o tier a partir do `rateLimitTier` do OAuth, para não exigir configuração.
    static func detect(from rateLimitTier: String) -> PlanTier? {
        let t = rateLimitTier.lowercased()
        if t.contains("max_20x") { return .max20x }
        if t.contains("max_5x") { return .max5x }
        if t.contains("pro") { return .pro }
        return nil
    }
}

/// Um trecho da linha do tempo em que um plano esteve vigente. Manter o histórico
/// evita que trocar de plano reescreva o passado do gráfico "pago vs. utilizado".
struct PlanPeriod: Codable, Identifiable {
    var since: String          // "yyyy-MM-dd"
    var tierId: String
    var monthlyPrice: Double
    var id: String { since }

    var tier: PlanTier? { PlanTier.all.first { $0.id == tierId } }
}

struct AppConfig: Codable {
    var planHistory: [PlanPeriod] = []
    /// Diretório de config da conta a medir. Default `~/.claude` (claude-pessoal).
    /// Trocar para `~/.claude-terra` faz o monitor medir a outra conta inteira —
    /// credenciais, transcripts, sessões e histórico juntos.
    var configDirPath: String?

    var account: ClaudeAccount {
        ClaudeAccount(configDir: configDirPath.map { URL(fileURLWithPath: $0) }
                      ?? ClaudeAccount.defaultDir)
    }

    /// Preço mensal vigente num dia.
    func monthlyPrice(on day: String) -> Double {
        planHistory.filter { $0.since <= day }.max(by: { $0.since < $1.since })?.monthlyPrice
            ?? planHistory.first?.monthlyPrice ?? 0
    }

    var currentTier: PlanTier? {
        planHistory.max(by: { $0.since < $1.since })?.tier
    }
}

/// Config em `~/.claude-monitor/config.json`. Não exige nada do usuário: o tier vem
/// do `rateLimitTier` do OAuth, então o app se auto-configura na primeira execução.
final class ConfigStore {
    static let shared = ConfigStore()
    private let url = RateLimitStore.directory.appending(path: "config.json")
    private(set) var config = AppConfig()

    private init() {
        if let data = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = c
        }
    }

    func save(_ c: AppConfig) {
        config = c
        try? FileManager.default.createDirectory(at: RateLimitStore.directory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Semeia o histórico de planos com o tier detectado, se ainda estiver vazio.
    /// A data de início é o primeiro dia com uso — não "hoje" — para o gráfico de
    /// "pago" cobrir todo o histórico que temos.
    @discardableResult
    func seedIfNeeded(detectedTier: String, firstUsageDay: String?) -> Bool {
        guard config.planHistory.isEmpty,
              let tier = PlanTier.detect(from: detectedTier) else { return false }
        var c = config
        c.planHistory = [PlanPeriod(since: firstUsageDay ?? UsageSeries.dayKey(Date()),
                                    tierId: tier.id,
                                    monthlyPrice: tier.defaultPrice)]
        save(c)
        return true
    }
}

// MARK: - Recomendação de plano

enum PlanVerdict {
    /// Ainda não há janelas semanais suficientes para opinar.
    case collecting(observed: Int, needed: Int)
    /// Tier sem múltiplo definido (Team/Enterprise cobram por assento).
    case notApplicable
    case verdict(current: PlanTier, peak: Double, options: [PlanOption])
}

struct PlanOption: Identifiable {
    let tier: PlanTier
    /// Onde o pico observado cairia neste plano (0…n, pode passar de 1).
    let projectedUtilization: Double
    let fits: Bool
    var id: String { tier.id }
}

enum PlanAdvisor {
    /// Um pico medido não é o pico possível, e estourar o limite semanal custa dias
    /// de trabalho — então a margem é 0,80, não 1,00.
    static let safetyMargin = 0.80
    static let weeksNeeded = 3

    static func evaluate(weeklyPeaks: [WindowPeak], current: PlanTier?) -> PlanVerdict {
        guard let current else { return .notApplicable }
        let usable = weeklyPeaks.filter { $0.isComplete }
        guard usable.count >= weeksNeeded else {
            return .collecting(observed: usable.count, needed: weeksNeeded)
        }
        // O pior caso observado é o que decide — a média esconderia a semana pesada.
        let peak = usable.map(\.peak).max() ?? 0
        let options = PlanTier.all.map { target -> PlanOption in
            let projected = peak * (current.factor / target.factor)
            return PlanOption(tier: target,
                              projectedUtilization: projected,
                              fits: projected < safetyMargin)
        }
        return .verdict(current: current, peak: peak, options: options)
    }

    /// O plano mais barato que ainda comporta o pico observado.
    static func cheapestFitting(_ options: [PlanOption], config: AppConfig) -> PlanOption? {
        options.filter(\.fits).min { a, b in
            a.tier.defaultPrice < b.tier.defaultPrice
        }
    }
}

// MARK: - Aproveitamento da cota
//
// "Usei tudo o que paguei?" é uma pergunta sobre COTA CONSUMIDA (% do limite), não
// sobre valor. São coisas diferentes: dá para ter um retorno de 50x em dinheiro e
// mesmo assim desperdiçar metade da cota — e é justamente esse cruzamento que diz
// se cabe descer de plano.
//
// A janela semanal tem cadência fixa de 7 dias (medido: resets em 15/ago 04:00 e
// 22/ago 04:00), então as fronteiras das semanas passadas são deriváveis. O que
// falta é o mapa custo → utilização, e esse a gente CALIBRA com as janelas que
// foram de fato medidas. Duas calibrações independentes de semanas diferentes
// deram US$ 14,3 e US$ 16,3 por 1% de cota — 12% de diferença, bom o bastante
// para estimar, longe de bom o bastante para afirmar.

struct QuotaCalibration {
    /// Quanto de custo-equivalente corresponde a 1% da cota semanal.
    let dollarsPerPercent: Double
    /// Quantas janelas medidas entraram na calibração.
    let windows: Int
}

struct WeekQuota: Identifiable {
    let start: Date
    let end: Date
    let cost: Double
    /// Fração da cota semanal (0…1+).
    let utilization: Double
    /// `true` quando veio dos headers da API; `false` quando é estimativa calibrada.
    let measured: Bool
    /// A semana corrente ainda vai crescer.
    let isPartial: Bool
    var id: Date { start }
}

/// Um mês de cobrança, com as semanas de cota que couberam nele.
struct MonthQuota: Identifiable {
    let month: String          // "yyyy-MM"
    let date: Date
    let weeks: [WeekQuota]
    let averageUtilization: Double
    let price: Double
    let isPartial: Bool

    /// Quanto do que foi pago virou uso, e quanto evaporou com o reset semanal.
    var effectiveUsed: Double { price * averageUtilization }
    var wasted: Double { max(0, price - effectiveUsed) }
    var id: String { month }
}

enum QuotaAnalysis {
    static let weekSeconds: TimeInterval = 7 * 24 * 3600

    /// Deriva a constante custo→cota a partir das janelas realmente medidas.
    /// Para cada janela: pico de utilização observado ÷ custo acumulado até a
    /// última amostra. Usa a mediana, que aguenta uma janela mal amostrada.
    static func calibrate(store: RateLimitStore, db: UsageDatabase, tier: String?) -> QuotaCalibration? {
        let events = costEvents(db)
        var ratios: [Double] = []
        for peak in store.peaks(.sevenDay, tier: tier) {
            // Utilização muito baixa amplifica qualquer erro de borda na divisão;
            // e uma janela saturada (>=99%) só diz "bateu no teto", não quanto de
            // demanda havia — o cost/util de lá subestimaria o custo por 1%.
            guard peak.peak >= 0.10, peak.peak < 0.99 else { continue }
            let end = peak.resetEpoch - peak.gapToReset  // instante da última amostra
            let start = peak.resetEpoch - weekSeconds
            let cost = costBetween(events, start, end)
            guard cost > 0 else { continue }
            ratios.append(cost / (peak.peak * 100))
        }
        guard !ratios.isEmpty else { return nil }
        let sorted = ratios.sorted()
        return QuotaCalibration(dollarsPerPercent: sorted[sorted.count / 2], windows: ratios.count)
    }

    /// Histórico semanal de aproveitamento. Semanas com medição usam o valor real;
    /// as demais usam a estimativa calibrada e vêm marcadas como tal.
    static func weeklyHistory(store: RateLimitStore, db: UsageDatabase, tier: String?,
                              weeks: Int = 10) -> [WeekQuota] {
        let peaks = store.peaks(.sevenDay, tier: tier)
        // Âncora: qualquer reset conhecido define a grade semanal inteira.
        guard let anchor = peaks.map(\.resetEpoch).max() else { return [] }
        let calibration = calibrate(store: store, db: db, tier: tier)
        let events = costEvents(db)
        let measuredByReset = Dictionary(peaks.map { ($0.resetEpoch, $0) },
                                         uniquingKeysWith: { a, _ in a })
        let now = Date().timeIntervalSince1970

        // Caminha a grade para trás a partir da âncora, pulando janelas futuras.
        var out: [WeekQuota] = []
        var reset = anchor
        while reset - weekSeconds > now { reset -= weekSeconds }
        for _ in 0..<weeks {
            let start = reset - weekSeconds
            guard start > 0 else { break }
            let cost = costBetween(events, start, min(reset, now))
            let measured = measuredByReset[reset]
            let util: Double
            if let measured, measured.peak > 0 {
                util = measured.peak
            } else if let calibration, calibration.dollarsPerPercent > 0 {
                util = cost / calibration.dollarsPerPercent / 100
            } else {
                reset -= weekSeconds
                continue
            }
            out.append(WeekQuota(
                start: Date(timeIntervalSince1970: start),
                end: Date(timeIntervalSince1970: reset),
                cost: cost,
                utilization: util,
                measured: measured != nil && measured!.peak > 0,
                isPartial: reset > now
            ))
            reset -= weekSeconds
        }
        // Semanas sem uso nenhum são "antes de começar", não semanas ociosas —
        // mantê-las afundaria a média e mentiria sobre o aproveitamento.
        return out.reversed().drop { $0.cost <= 0 }.map { $0 }
    }

    /// Concilia as duas cadências: o limite reseta por SEMANA, a cobrança é por MÊS.
    ///
    /// O ponto que isso torna visível: **cota semanal não acumula**. Terminar a semana
    /// em 50% não te dá 150% na seguinte — aquela metade simplesmente evapora. Então o
    /// que você "aproveitou" do mês é a média das semanas dele, não o total do mês
    /// contra um teto mensal (que não existe).
    static func monthlyReconciliation(_ weeks: [WeekQuota], config: AppConfig,
                                      cal: Calendar = .current) -> [MonthQuota] {
        // A semana é atribuída ao mês do seu ponto médio — semanas a cavalo entre
        // dois meses vão inteiras para onde passaram a maior parte do tempo.
        var grouped: [String: [WeekQuota]] = [:]
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM"
        for w in weeks {
            let mid = w.start.addingTimeInterval(w.end.timeIntervalSince(w.start) / 2)
            grouped[fmt.string(from: mid), default: []].append(w)
        }
        return grouped.keys.sorted().compactMap { month in
            guard let ws = grouped[month]?.sorted(by: { $0.start < $1.start }),
                  let anchor = ws.first?.start else { return nil }
            let closed = ws.filter { !$0.isPartial }
            let avg = closed.isEmpty ? 0 : closed.reduce(0) { $0 + $1.utilization } / Double(closed.count)
            let price = config.monthlyPrice(on: month + "-01")
            return MonthQuota(month: month, date: anchor, weeks: ws,
                              averageUtilization: avg, price: price,
                              isPartial: ws.contains { $0.isPartial })
        }
    }

    // Lista (instante, custo) ordenada, para somar custo em qualquer intervalo.
    // Usa os buckets HORÁRIOS: as janelas de rate limit não começam à meia-noite
    // (a semanal reseta 04:00), e com agregado diário a borda erra até um dia —
    // numa janela parcial de 1,5 dia isso destrói a calibração.
    private static func costEvents(_ db: UsageDatabase) -> [(Double, Double)] {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH"
        var out: [(Double, Double)] = []
        for (hour, models) in db.hours {
            guard let d = fmt.date(from: hour) else { continue }
            // Meio da hora, para não enviesar sistematicamente numa direção.
            out.append((d.timeIntervalSince1970 + 1800, models.equivalentCost))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private static func costBetween(_ events: [(Double, Double)], _ a: Double, _ b: Double) -> Double {
        events.reduce(0) { $1.0 >= a && $1.0 < b ? $0 + $1.1 : $0 }
    }
}

// MARK: - Séries para os gráficos

struct DayPoint: Identifiable {
    let day: String            // "yyyy-MM-dd"
    let date: Date
    let byModel: [String: TokenUsage]
    let paid: Double           // custo do plano amortizado no dia
    var used: Double { byModel.equivalentCost }
    var tokens: Int { byModel.totalTokens }
    var id: String { day }
}

struct MonthPoint: Identifiable {
    let month: String          // "yyyy-MM"
    let date: Date
    let used: Double
    let paid: Double
    let tokens: Int
    let isPartial: Bool
    /// Só no mês corrente: fechamento estimado pelo ritmo recente.
    let projected: Double?
    var id: String { month }
}

enum UsageSeries {
    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// Série diária cobrindo todos os dias entre o primeiro registro e hoje —
    /// inclusive os zerados, senão o gráfico mente sobre a cadência de uso.
    static func daily(db: UsageDatabase, config: AppConfig, cal: Calendar = .current) -> [DayPoint] {
        guard let firstKey = db.days.keys.min(), let first = parseDay(firstKey) else { return [] }
        let today = cal.startOfDay(for: Date())
        var out: [DayPoint] = []
        var cursor = cal.startOfDay(for: first)
        while cursor <= today {
            let key = dayKey(cursor)
            let daysInMonth = cal.range(of: .day, in: .month, for: cursor)?.count ?? 30
            out.append(DayPoint(
                day: key,
                date: cursor,
                byModel: db.days[key] ?? [:],
                paid: config.monthlyPrice(on: key) / Double(daysInMonth)
            ))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    /// Série mensal. O mês corrente ganha uma projeção de fechamento a partir do
    /// ritmo dos últimos 7 dias — absorve rampa e férias melhor que a média do mês.
    static func monthly(db: UsageDatabase, config: AppConfig, cal: Calendar = .current) -> [MonthPoint] {
        let days = daily(db: db, config: config, cal: cal)
        guard !days.isEmpty else { return [] }
        let currentMonth = String(dayKey(Date()).prefix(7))

        var grouped: [String: [DayPoint]] = [:]
        for d in days { grouped[String(d.day.prefix(7)), default: []].append(d) }

        // Ritmo diário recente, para projetar o mês em curso.
        let recent = days.suffix(7)
        let dailyPace = recent.isEmpty ? 0 : recent.reduce(0) { $0 + $1.used } / Double(recent.count)

        return grouped.keys.sorted().compactMap { month -> MonthPoint? in
            guard let pts = grouped[month], let anchor = pts.first?.date else { return nil }
            let used = pts.reduce(0) { $0 + $1.used }
            let isPartial = month == currentMonth
            var projected: Double?
            if isPartial {
                let total = cal.range(of: .day, in: .month, for: anchor)?.count ?? 30
                let elapsed = pts.count
                projected = used + dailyPace * Double(max(0, total - elapsed))
            }
            // O "pago" do mês corrente é proporcional ao que já correu dele.
            let monthlyPrice = config.monthlyPrice(on: month + "-01")
            let total = cal.range(of: .day, in: .month, for: anchor)?.count ?? 30
            let paid = isPartial ? monthlyPrice * Double(pts.count) / Double(total) : monthlyPrice

            return MonthPoint(month: month, date: anchor, used: used, paid: paid,
                              tokens: pts.reduce(0) { $0 + $1.tokens },
                              isPartial: isPartial, projected: projected)
        }
    }

    /// Média móvel de N dias sobre o custo-equivalente.
    static func movingAverage(_ points: [DayPoint], window: Int = 7) -> [(Date, Double)] {
        guard points.count >= window else { return [] }
        var out: [(Date, Double)] = []
        for i in (window - 1)..<points.count {
            let slice = points[(i - window + 1)...i]
            out.append((points[i].date, slice.reduce(0) { $0 + $1.used } / Double(window)))
        }
        return out
    }
}
