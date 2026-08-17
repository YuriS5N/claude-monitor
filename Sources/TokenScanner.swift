import Foundation

// MARK: - Token Scanner
//
// Varre os transcripts em ~/.claude/projects/**/*.jsonl e mantém o `UsageDatabase`:
// tokens por dia local, por sessão e por projeto. É a única fonte de uso histórico —
// o stats-cache.json do Claude Code só é reescrito quando o usuário abre `/usage`.
//
// Quatro armadilhas medidas, que a varredura ingênua erra. Não reintroduzir:
//
//  1. Deduplicar por `message.id`. O transcript grava a mesma mensagem ~2x
//     (streaming) — sem dedup o total infla ~2,2x. E a dedup precisa CRUZAR
//     ARQUIVOS: sessões bifurcadas replicam o histórico num arquivo novo (medido:
//     2,2% dos ids aparecem em mais de um transcript).
//  2. Bucket por dia LOCAL. Fatiar o ISO8601 dá dia UTC e joga a noite inteira
//     para o dia seguinte — estamos em UTC negativo.
//  3. A busca é recursiva: 109 transcripts ficam em `<projeto>/<sessão>/subagents/`.
//     Um glob de um nível só perde os subagentes.
//  4. Os transcripts de subagente já carregam o `sessionId` do PAI, então a
//     atribuição por sessão sai de graça — não parsear o caminho.
//
// Incremental e persistido: guarda o offset lido de cada arquivo no próprio banco,
// então uma reabertura do app não relê os ~600MB. Os agregados também sobrevivem à
// limpeza automática de transcripts do Claude Code — que é o que torna possível a
// visão mensal.
final class TokenScanner {
    private(set) var db = UsageDatabase()

    private let storeURL = RateLimitStore.directory.appending(path: "usage.json")
    private static let usageMarker = Data("\"usage\"".utf8)
    private let isoFrac = ISO8601DateFormatter()
    private let isoPlain = ISO8601DateFormatter()
    private let dayFmt = DateFormatter()
    private let hourFmt = DateFormatter()

    /// Set em memória derivado de `db.seenByDay` — evita rebuscar o array a cada linha.
    private var seen = Set<UInt64>()
    private var dirty = false

    init() {
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoPlain.formatOptions = [.withInternetDateTime]
        dayFmt.dateFormat = "yyyy-MM-dd"
        hourFmt.dateFormat = "yyyy-MM-dd HH"
        load()
    }

    // MARK: Persistência

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let loaded = try? JSONDecoder().decode(UsageDatabase.self, from: data),
              loaded.version == UsageDatabase.currentVersion else {
            // Versão diferente (ou banco ausente/corrompido): recomeça do zero.
            // Os cursores zerados forçam uma varredura completa.
            db = UsageDatabase()
            return
        }
        db = loaded
        seen = Set(loaded.seenByDay.values.flatMap { $0 })
    }

    /// Gravação atômica: matar o app no meio não deixa um banco truncado.
    func save() {
        guard dirty else { return }
        try? FileManager.default.createDirectory(at: RateLimitStore.directory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(db) else { return }
        let tmp = storeURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmp)
            dirty = false
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    // MARK: Varredura

    @discardableResult
    func scan(projects: URL) -> UsageDatabase {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]

        var live = Set<String>()
        if let walker = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      let size = v.fileSize else { continue }
                let path = url.path
                live.insert(path)
                var cursor = db.cursors[path] ?? FileCursor(offset: 0, size: 0)
                if UInt64(size) < cursor.offset { cursor.offset = 0 }  // truncado/rotacionado
                guard UInt64(size) > cursor.offset else { continue }
                cursor.offset = ingest(url: url, from: cursor.offset, upTo: UInt64(size))
                cursor.size = UInt64(size)
                db.cursors[path] = cursor
                dirty = true
            }
        }
        // Transcript apagado pela limpeza do Claude Code: some o cursor, mas os
        // agregados FICAM — é justamente para isso que o banco existe.
        if db.cursors.keys.contains(where: { !live.contains($0) }) {
            db.cursors = db.cursors.filter { live.contains($0.key) }
            dirty = true
        }
        pruneDedupHorizon()
        save()
        return db
    }

    /// Lê [start, end) em blocos e devolve o novo offset, sempre parado no último
    /// `\n` — a cauda parcial de um append em curso é relida na próxima passada.
    private func ingest(url: URL, from start: UInt64, upTo end: UInt64) -> UInt64 {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return start }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: start) } catch { return start }

        var consumed = start
        var carry = Data()
        let chunkSize: UInt64 = 4 << 20
        while consumed < end {
            let want = Int(min(chunkSize, end - consumed))
            guard let chunk = try? fh.read(upToCount: want), !chunk.isEmpty else { break }
            consumed += UInt64(chunk.count)
            var parts = (carry + chunk).split(separator: 0x0A, omittingEmptySubsequences: false)
            carry = Data(parts.removeLast())  // última fatia = linha incompleta
            for part in parts { ingest(line: part) }
        }
        return consumed - UInt64(carry.count)
    }

    private func ingest(line: Data.SubSequence) {
        // Só ~1/3 das linhas tem usage; a checagem de bytes evita o JSON parse.
        guard line.count > 40, line.range(of: Self.usageMarker) != nil else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let id = msg["id"] as? String,
              let stamp = obj["timestamp"] as? String,
              let date = isoFrac.date(from: stamp) ?? isoPlain.date(from: stamp) else { return }

        let hash = Self.hash(id)
        guard !seen.contains(hash) else { return }

        let day = dayFmt.string(from: Calendar.current.startOfDay(for: date))
        seen.insert(hash)
        db.seenByDay[day, default: []].append(hash)

        var t = TokenUsage()
        t.input      = usage["input_tokens"] as? Int ?? 0
        t.output     = usage["output_tokens"] as? Int ?? 0
        t.cacheRead  = usage["cache_read_input_tokens"] as? Int ?? 0
        t.cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        guard t.total > 0 else { return }   // descarta "<synthetic>" e afins

        let model = msg["model"] as? String ?? "unknown"
        db.days[day, default: [:]][model, default: TokenUsage()] += t
        db.hours[hourFmt.string(from: date), default: [:]][model, default: TokenUsage()] += t

        // Subagentes carregam o sessionId do pai, então isso já agrega a sessão inteira.
        if let sid = obj["sessionId"] as? String {
            var rec = db.sessions[sid] ?? SessionRecord()
            if rec.project.isEmpty, let cwd = obj["cwd"] as? String {
                rec.project = URL(fileURLWithPath: cwd).lastPathComponent
            }
            if rec.branch.isEmpty, let b = obj["gitBranch"] as? String { rec.branch = b }
            let ts = date.timeIntervalSince1970
            // Só conta como trabalho o intervalo desde a mensagem anterior, e só se
            // for curto — senão uma sessão retomada semanas depois viraria "1000h".
            let gap = ts - rec.lastTs
            if rec.lastTs > 0, gap > 0, gap <= SessionRecord.idleGap { rec.activeSeconds += gap }
            rec.firstTs = rec.firstTs == 0 ? ts : min(rec.firstTs, ts)
            rec.lastTs = max(rec.lastTs, ts)
            rec.byModel[model, default: TokenUsage()] += t
            db.sessions[sid] = rec
        }
        dirty = true
    }

    /// Só precisamos lembrar dos ids que uma sessão bifurcada poderia reproduzir;
    /// os bytes mais antigos nunca são relidos (os cursores já passaram deles).
    private func pruneDedupHorizon() {
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -UsageDatabase.dedupHorizonDays,
                                    to: cal.startOfDay(for: Date())) else { return }
        let oldest = dayFmt.string(from: cutoff)
        for (day, hashes) in db.seenByDay where day < oldest {
            for h in hashes { seen.remove(h) }
            db.seenByDay[day] = nil
            dirty = true
        }
    }

    /// FNV-1a — guardar o hash em vez da string inteira mantém o banco pequeno.
    private static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return h
    }

    // MARK: Consultas

    /// Totais por modelo numa janela de N dias — alimenta o card do popover.
    func totals(windowDays: Int) -> [String: TokenUsage] {
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -(windowDays - 1),
                                    to: cal.startOfDay(for: Date())) else { return [:] }
        let oldest = dayFmt.string(from: cutoff)
        var out: [String: TokenUsage] = [:]
        for (day, models) in db.days where day >= oldest { out += models }
        return out
    }
}
