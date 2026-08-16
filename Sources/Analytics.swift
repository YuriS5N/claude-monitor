import Foundation

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
    static let currentVersion = 1

    var version = UsageDatabase.currentVersion
    /// dia local ("yyyy-MM-dd") → modelo → tokens
    var days: [String: [String: TokenUsage]] = [:]
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
