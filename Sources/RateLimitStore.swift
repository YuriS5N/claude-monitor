import Foundation

// MARK: - Rate limit history
//
// A Anthropic não expõe histórico de utilização: cada chamada devolve só o estado
// atual da janela corrente. O monitor consulta a cada 5min — então basta gravar cada
// leitura para, com o tempo, ter a série que a API não dá.
//
// Duas propriedades das janelas (ambas medidas, ver o plano) moldam este arquivo:
//  1. São janelas FIXAS com reset, não deslizantes. O epoch do reset identifica a
//     janela: amostras com o mesmo `r5` pertencem à mesma janela de 5h.
//  2. A utilização é monótona dentro da janela (só sobe até resetar), então o pico
//     de uma janela é o máximo das amostras — e a amostra mais tardia é a melhor.
//     Por isso a confiança de um pico depende de quão perto do reset foi a última
//     amostra, não de quantas amostras existem.

/// Uma leitura dos headers de rate limit, gravada como uma linha de JSON.
struct RateLimitSample: Codable {
    let t: Double        // quando lemos (epoch)
    let u5: Double       // utilização da janela de 5h (0…1)
    let u7: Double       // utilização da janela de 7d (0…1)
    let r5: Double       // epoch do reset 5h — identifica a janela
    let r7: Double       // epoch do reset 7d — identifica a janela
    let tier: String     // rateLimitTier da conta (ex.: default_claude_max_5x)
    let sub: String      // subscriptionType (ex.: max)
    let overage: String
    /// Status da janela 7d: allowed / allowed_warning / throttled. É a prova
    /// direta de ter chegado perto ou batido no teto — a utilização sozinha
    /// satura em 100% e não distingue "encostou" de "bateu e ficou bloqueado".
    var s7: String?
    /// Identidade da conta (`ClaudeAccount.id`). É por aqui que a série é
    /// filtrada; `tier` sozinho é proxy e colidiria com duas contas no mesmo plano.
    var acct: String?
}

/// Qual conta considerar ao ler a série.
struct AccountFilter {
    let id: String
    /// Casa as amostras gravadas antes de `acct` existir, pelo plano.
    let legacyTier: String?

    func matches(_ s: RateLimitSample) -> Bool {
        if let acct = s.acct { return acct == id }
        guard let legacyTier, !legacyTier.isEmpty else { return false }
        return s.tier == legacyTier
    }
}

/// Pico consolidado de uma janela.
struct WindowPeak: Identifiable {
    let resetEpoch: Double
    let peak: Double
    let sampleCount: Int
    /// Segundos entre a última amostra e o reset. Como a utilização só sobe, esse é o
    /// tamanho do trecho final da janela que não observamos — ou seja, o quanto o
    /// pico pode estar subestimado.
    let gapToReset: TimeInterval
    let tier: String

    var id: Double { resetEpoch }
    var resetDate: Date { Date(timeIntervalSince1970: resetEpoch) }

    /// Uma janela ainda aberta não tem pico final — o número só cresce.
    var isComplete: Bool { resetEpoch <= Date().timeIntervalSince1970 }

    /// O pico é confiável quando observamos perto do fim da janela.
    func confidence(windowSeconds: TimeInterval) -> PeakConfidence {
        guard isComplete else { return .open }
        if gapToReset <= windowSeconds * 0.05 { return .high }
        if gapToReset <= windowSeconds * 0.25 { return .medium }
        return .low
    }
}

enum PeakConfidence {
    case open      // janela ainda correndo
    case high      // observamos até quase o reset
    case medium
    case low       // app estava fechado boa parte do fim da janela; pico é limite inferior

    var label: String {
        switch self {
        case .open:   return "em curso"
        case .high:   return "confiável"
        case .medium: return "parcial"
        case .low:    return "mínimo observado"
        }
    }
}

enum WindowKind {
    case fiveHour, sevenDay
    var seconds: TimeInterval { self == .fiveHour ? 5 * 3600 : 7 * 24 * 3600 }
}

final class RateLimitStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude-monitor")
    private let url = RateLimitStore.directory.appending(path: "ratelimits.jsonl")

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Cache em memória para não reler o arquivo a cada abertura de aba.
    private var cache: [RateLimitSample]?

    init() {
        try? FileManager.default.createDirectory(at: RateLimitStore.directory,
                                                 withIntermediateDirectories: true)
    }

    // MARK: Escrita

    func append(_ sample: RateLimitSample) {
        guard var line = try? encoder.encode(sample) else { return }
        line.append(0x0A)
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
        cache?.append(sample)
    }

    // MARK: Leitura

    func load() -> [RateLimitSample] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: url) else { cache = []; return [] }
        var out: [RateLimitSample] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let s = try? decoder.decode(RateLimitSample.self, from: Data(line)) {
                out.append(s)
            }
        }
        out.sort { $0.t < $1.t }
        cache = out
        return out
    }

    /// Picos por janela, do mais recente para o mais antigo.
    ///
    /// `account` filtra pela conta. Sem filtro, a série de duas contas se mistura e
    /// uma semana da outra conta apareceria como semana sua.
    func peaks(_ kind: WindowKind, account: AccountFilter?) -> [WindowPeak] {
        var grouped: [Double: [RateLimitSample]] = [:]
        for s in load() where account == nil || account!.matches(s) {
            let reset = kind == .fiveHour ? s.r5 : s.r7
            guard reset > 0 else { continue }
            grouped[reset, default: []].append(s)
        }
        return grouped.map { reset, samples in
            let values = samples.map { kind == .fiveHour ? $0.u5 : $0.u7 }
            let lastSeen = samples.map(\.t).max() ?? 0
            return WindowPeak(
                resetEpoch: reset,
                peak: values.max() ?? 0,
                sampleCount: samples.count,
                gapToReset: max(0, reset - lastSeen),
                tier: samples.last?.tier ?? ""
            )
        }.sorted { $0.resetEpoch > $1.resetEpoch }
    }

    /// Janelas semanais já fechadas — a base da recomendação de plano.
    func completedWeeklyPeaks(account: AccountFilter?) -> [WindowPeak] {
        peaks(.sevenDay, account: account).filter(\.isComplete)
    }

    /// Contas distintas vistas na série. Mais de uma significa que o Claude Code
    /// trocou a conta ativa no meio do caminho — a análise precisa dizer isso, ou
    /// o usuário lê o limite de uma conta achando que é o da outra.
    func observedTiers() -> [String] {
        Array(Set(load().map(\.tier).filter { !$0.isEmpty })).sorted()
    }

    /// Momento da última amostra de um tier — para avisar quando a série esfriou.
    func lastSeen(tier: String) -> Date? {
        load().last { $0.tier == tier }.map { Date(timeIntervalSince1970: $0.t) }
    }
}
