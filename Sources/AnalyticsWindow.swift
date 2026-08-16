import SwiftUI
import AppKit
import Charts

// MARK: - Janela de Analytics
//
// O popover tem 340x580 e não comporta gráfico mensal — isto abre numa janela
// própria. Quatro abas em vez de um scroll longo; a primeira é a que responde a
// pergunta central ("estou aproveitando o que pago?") e por isso é a default.

final class AnalyticsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let vm: VM

    init(vm: VM) { self.vm = vm }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "Claude Monitor — Uso e Plano"
        w.contentViewController = NSHostingController(rootView: AnalyticsView(vm: vm))
        let autosave = "ClaudeMonitorAnalytics"
        let hadSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosave)") != nil
        w.setFrameAutosaveName(autosave)
        // O NSHostingController encolhe a janela para o mínimo do SwiftUI — só
        // vale refazer o tamanho quando não há um que o usuário já escolheu.
        if !hadSavedFrame {
            w.setContentSize(NSSize(width: 940, height: 640))
            w.center()
        }
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

// MARK: - Raiz

struct AnalyticsView: View {
    @ObservedObject var vm: VM

    var body: some View {
        TabView {
            QuotaTab(vm: vm)
                .tabItem { Label("Aproveitamento", systemImage: "gauge.with.needle") }
            PaidVsUsedTab(vm: vm)
                .tabItem { Label("Pago vs. Utilizado", systemImage: "dollarsign.circle") }
            UsageTab(vm: vm)
                .tabItem { Label("Uso", systemImage: "chart.bar") }
            SessionsTab(vm: vm)
                .tabItem { Label("Sessões", systemImage: "list.bullet") }
            PlanTab(vm: vm)
                .tabItem { Label("Plano", systemImage: "checkmark.seal") }
        }
        .padding(12)
        .frame(minWidth: 820, minHeight: 560)
    }
}

// MARK: - Aba: Aproveitamento
//
// Responde "usei tudo o que paguei?" — que é sobre COTA CONSUMIDA, não sobre valor.
// A aba "Pago vs. Utilizado" diz que o plano vale a pena; esta diz se sobra plano.

struct QuotaTab: View {
    @ObservedObject var vm: VM

    private var tier: String? { vm.activeTier.isEmpty ? nil : vm.activeTier }

    var body: some View {
        let weeks = QuotaAnalysis.weeklyHistory(store: vm.rateLimitStore, db: vm.usageDB, tier: tier)
        let closed = weeks.filter { !$0.isPartial }
        let avg = closed.isEmpty ? 0 : closed.reduce(0) { $0 + $1.utilization } / Double(closed.count)
        let peak = closed.map(\.utilization).max() ?? 0
        let calibration = QuotaAnalysis.calibrate(store: vm.rateLimitStore, db: vm.usageDB, tier: tier)

        return VStack(alignment: .leading, spacing: 16) {
            gauges
            headline(avg: avg, peak: peak, closed: closed.count)
            weeklyChart(weeks)
            footnote(calibration: calibration, weeks: weeks)
            Spacer(minLength: 0)
        }
    }

    // O agora: quanto da cota desta semana e desta sessão já foi.
    private var gauges: some View {
        HStack(spacing: 30) {
            QuotaGauge(title: "Semana atual",
                       value: vm.limits.sevenDayUtilization,
                       caption: "reseta em \(timeUntil(vm.limits.sevenDayReset))")
            QuotaGauge(title: "Sessão atual (5h)",
                       value: vm.limits.fiveHourUtilization,
                       caption: "reseta em \(timeUntil(vm.limits.fiveHourReset))")
            Spacer()
        }
    }

    private func headline(avg: Double, peak: Double, closed: Int) -> some View {
        let price = vm.config.planHistory.last?.monthlyPrice ?? 0
        let used = price * avg
        return VStack(alignment: .leading, spacing: 6) {
            if closed == 0 {
                Text("Sem semanas fechadas ainda.").font(.title3.bold())
            } else {
                Text(String(format: "Nas últimas %d semanas você usou em média %.0f%% da cota, "
                            + "com pico de %.0f%%.", closed, avg * 100, peak * 100))
                    .font(.title3.bold())
                Text(String(format: "Em dinheiro: dos US$ %.0f/mês que você paga, a média equivale "
                            + "a aproveitar ~US$ %.0f e deixar ~US$ %.0f na mesa. "
                            + "Mas é o PICO que decide se cabe um plano menor — não a média.",
                            price, used, max(0, price - used)))
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func weeklyChart(_ weeks: [WeekQuota]) -> some View {
        Chart {
            ForEach(weeks) { w in
                BarMark(x: .value("Semana", w.start, unit: .weekOfYear),
                        y: .value("Cota", w.utilization))
                    .foregroundStyle(by: .value("Origem", w.measured ? "Medido" : "Estimado"))
                    .opacity(w.isPartial ? 0.45 : 1)
            }
            RuleMark(y: .value("Cota", 1.0))
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .chartForegroundStyleScale(["Medido": Color.blue, "Estimado": Color.blue.opacity(0.45)])
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text("\(Int(d * 100))%") }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartLegend(position: .bottom)
        .frame(minHeight: 200)
        .overlay(alignment: .topTrailing) {
            Text("linha vermelha = 100% da cota")
                .font(.caption2).foregroundColor(.red)
        }
    }

    @ViewBuilder
    private func footnote(calibration: QuotaCalibration?, weeks: [WeekQuota]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let calibration {
                Text(String(format: "Semanas “estimadas” vêm do custo-equivalente convertido em "
                            + "cota (US$ %.0f por 1%%), calibrado com %d semana(s) que a API "
                            + "realmente mediu. É estimativa, não leitura — a barra vira "
                            + "“medido” conforme as semanas passam com o monitor rodando.",
                            calibration.dollarsPerPercent, calibration.windows))
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Duas contas na série significa que o Claude Code trocou a conta ativa;
            // sem dizer isso, o usuário lê o limite de uma achando que é o da outra.
            let tiers = vm.rateLimitStore.observedTiers()
            if tiers.count > 1 {
                let others = tiers.filter { $0 != vm.activeTier }
                    .map { $0.replacingOccurrences(of: "default_claude_", with: "") }
                Label("O monitor viu mais de uma conta (\(others.joined(separator: ", "))). "
                      + "Os números acima são só da conta ativa; o uso feito nas outras não "
                      + "aparece aqui.", systemImage: "person.2.badge.gearshape")
                    .font(.caption2).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Medidor de cota: a leitura de relance de "quanto do que paguei já usei".
struct QuotaGauge: View {
    let title: String
    let value: Double
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.0f%%", value * 100))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(utilizationColor(value))
                Text("da cota").font(.caption).foregroundColor(.secondary)
            }
            // Barra própria em vez de ProgressView: precisa acomodar >100% e
            // colorir pela faixa de utilização.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(utilizationColor(value))
                        .frame(width: geo.size.width * min(max(value, 0), 1))
                }
            }
            .frame(width: 210, height: 8)
            Text(caption).font(.caption2).foregroundColor(.secondary)
        }
    }
}

// MARK: - Aba 1: Pago vs. Utilizado

struct PaidVsUsedTab: View {
    @ObservedObject var vm: VM
    enum Granularity: String, CaseIterable { case day = "Dia", month = "Mês", cumulative = "Acumulado" }
    @State private var granularity: Granularity

    init(vm: VM, granularity: Granularity = .day) {
        self.vm = vm
        _granularity = State(initialValue: granularity)
    }

    private var days: [DayPoint] { UsageSeries.daily(db: vm.usageDB, config: vm.config) }
    private var months: [MonthPoint] { UsageSeries.monthly(db: vm.usageDB, config: vm.config) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline
            Picker("", selection: $granularity) {
                ForEach(Granularity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            switch granularity {
            case .day:        dayChart
            case .month:      monthChart
            case .cumulative: cumulativeChart
            }

            Text("“Utilizado” é o custo-equivalente: quanto esse uso custaria pagando por "
                 + "token na API (tabela de \(Pricing.asOf)). Não é a sua fatura, e não "
                 + "prevê consumo de rate limit.")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Números do mês corrente, que é o que a pergunta original pede.
    private var headline: some View {
        let m = months.last
        let used = m?.used ?? 0
        let paid = m?.paid ?? 0
        let ratio = paid > 0 ? used / paid : 0
        let elapsed = days.filter { $0.day.hasPrefix(m?.month ?? "") }.count
        let inMonth = Calendar.current.range(of: .day, in: .month, for: m?.date ?? Date())?.count ?? 30
        return HStack(spacing: 26) {
            // Proporcional aos dias já corridos — é a comparação maçã-com-maçã
            // contra o uso de um mês incompleto.
            StatTile(label: "Pago no mês", value: String(format: "US$ %.2f", paid), color: .secondary,
                     subtitle: (m?.isPartial ?? false) ? "proporcional a \(elapsed)/\(inMonth) dias" : nil)
            StatTile(label: "Utilizado no mês", value: String(format: "US$ %.0f", used), color: .green)
            StatTile(label: "Retorno", value: ratio > 0 ? String(format: "%.0fx", ratio) : "—",
                     color: ratio >= 1 ? .green : .orange,
                     subtitle: "o plano devolve isso")
            if let proj = m?.projected {
                StatTile(label: "Projeção do mês", value: String(format: "US$ %.0f", proj),
                         color: .secondary, subtitle: "ritmo dos últimos 7 dias")
            }
            Spacer()
        }
    }

    private var dayChart: some View {
        // Barra empilhada por modelo + linha do custo diário do plano. Barra acima da
        // linha = dia que se pagou.
        let flat = days.flatMap { d in
            d.byModel.map { (day: d.date, model: shortModel($0.key),
                             cost: Pricing.cost(model: $0.key, usage: $0.value)) }
        }
        let avgPaid = days.isEmpty ? 0 : days.reduce(0) { $0 + $1.paid } / Double(days.count)
        let trend = UsageSeries.movingAverage(days)
        return Chart {
            ForEach(Array(flat.enumerated()), id: \.offset) { _, e in
                BarMark(x: .value("Dia", e.day, unit: .day), y: .value("US$", e.cost))
                    .foregroundStyle(by: .value("Modelo", e.model))
            }
            ForEach(Array(trend.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Dia", p.0, unit: .day), y: .value("Média 7d", p.1))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            // A linha do plano fica rente ao zero nesta escala — o rótulo vai para a
            // legenda abaixo, senão colide com as barras em qualquer alinhamento.
            RuleMark(y: .value("Plano/dia", avgPaid))
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartLegend(position: .bottom)
        .overlay(alignment: .bottomLeading) {
            Text(String(format: "— linha vermelha: custo do plano por dia (US$ %.2f)", avgPaid))
                .font(.caption2).foregroundColor(.red)
                .offset(y: 16)
        }
    }

    private var monthChart: some View {
        Chart {
            ForEach(months) { m in
                BarMark(x: .value("Mês", m.date, unit: .month), y: .value("US$", m.used))
                    .foregroundStyle(by: .value("Série", "Utilizado"))
                    .position(by: .value("Série", "Utilizado"))
                BarMark(x: .value("Mês", m.date, unit: .month), y: .value("US$", m.paid))
                    .foregroundStyle(by: .value("Série", "Pago"))
                    .position(by: .value("Série", "Pago"))
                // Projeção do mês em curso: fantasma sobre o realizado.
                if let proj = m.projected, proj > m.used {
                    BarMark(x: .value("Mês", m.date, unit: .month),
                            yStart: .value("US$", m.used),
                            yEnd: .value("US$", proj))
                        .foregroundStyle(by: .value("Série", "Projeção"))
                        .position(by: .value("Série", "Utilizado"))
                }
            }
        }
        .chartForegroundStyleScale(["Utilizado": Color.green,
                                    "Projeção": Color.green.opacity(0.28),
                                    "Pago": Color.orange])
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).year())
            }
        }
        .chartLegend(position: .bottom)
    }

    private var cumulativeChart: some View {
        var runUsed = 0.0, runPaid = 0.0
        let series = days.map { d -> (Date, Double, Double) in
            runUsed += d.used; runPaid += d.paid
            return (d.date, runUsed, runPaid)
        }
        return Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Dia", p.0), y: .value("US$", p.1))
                    .foregroundStyle(by: .value("Série", "Utilizado (acumulado)"))
                LineMark(x: .value("Dia", p.0), y: .value("US$", p.2))
                    .foregroundStyle(by: .value("Série", "Pago (acumulado)"))
            }
        }
        .chartForegroundStyleScale(["Utilizado (acumulado)": Color.green,
                                    "Pago (acumulado)": Color.orange])
        .chartLegend(position: .bottom)
    }
}

// MARK: - Aba 2: Uso (volume bruto)

struct UsageTab: View {
    @ObservedObject var vm: VM
    enum Grain: String, CaseIterable { case day = "Dia", month = "Mês" }
    @State private var grain: Grain = .day

    var body: some View {
        let days = UsageSeries.daily(db: vm.usageDB, config: vm.config)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                StatTile(label: "Tokens (total registrado)",
                         value: fmtTokens(days.reduce(0) { $0 + $1.tokens }), color: .purple)
                StatTile(label: "Dias com registro",
                         value: "\(days.filter { $0.tokens > 0 }.count)", color: .secondary)
                Spacer()
            }
            Picker("", selection: $grain) {
                ForEach(Grain.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 220)

            let unit: Calendar.Component = grain == .day ? .day : .month
            let flat = days.flatMap { d in
                d.byModel.map { (day: d.date, model: shortModel($0.key), tokens: $0.value.total) }
            }
            Chart(Array(flat.enumerated()), id: \.offset) { _, e in
                BarMark(x: .value("Período", e.day, unit: unit),
                        y: .value("Tokens", e.tokens))
                    .foregroundStyle(by: .value("Modelo", e.model))
            }
            .chartLegend(position: .bottom)
        }
    }
}

// MARK: - Aba 3: Sessões

struct SessionRow: Identifiable {
    let id: String
    let project: String
    let branch: String
    let start: Date
    let activeHours: Double
    let tokens: Int
    let cost: Double
}

struct SessionsTab: View {
    @ObservedObject var vm: VM
    @State private var sortOrder = [KeyPathComparator(\SessionRow.cost, order: .reverse)]

    private var rows: [SessionRow] {
        vm.usageDB.sessions.map { id, s in
            SessionRow(id: id, project: s.project, branch: s.branch, start: s.start,
                       activeHours: s.activeSeconds / 3600, tokens: s.tokens, cost: s.cost)
        }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(rows.count) sessões registradas. “Ativo” soma só os intervalos entre "
                 + "mensagens — uma sessão retomada semanas depois não vira mil horas.")
                .font(.caption).foregroundColor(.secondary)
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Projeto", value: \.project)
                TableColumn("Branch", value: \.branch)
                TableColumn("Início", value: \.start) { r in
                    Text(r.start, format: .dateTime.day().month().hour().minute())
                }
                TableColumn("Ativo", value: \.activeHours) { r in
                    Text(String(format: "%.1f h", r.activeHours))
                }
                TableColumn("Tokens", value: \.tokens) { r in Text(fmtTokens(r.tokens)) }
                TableColumn("Equivalente", value: \.cost) { r in
                    Text(String(format: "US$ %.2f", r.cost))
                }
            }
        }
    }
}

// MARK: - Aba 4: Plano

struct PlanTab: View {
    @ObservedObject var vm: VM

    var body: some View {
        let peaks = vm.rateLimitStore.completedWeeklyPeaks(tier: vm.activeTier.isEmpty ? nil : vm.activeTier)
        let verdict = PlanAdvisor.evaluate(weeklyPeaks: peaks, current: vm.config.currentTier)
        // O veredito fica fixo no topo; só o histórico rola.
        return VStack(alignment: .leading, spacing: 16) {
            verdictBox(verdict)
            ScrollView { weeklyHistory.frame(maxWidth: .infinity, alignment: .leading) }
            Text("A Anthropic não expõe histórico de utilização — o monitor grava uma "
                 + "amostra a cada 5 min desde a primeira execução. Por isso o veredito "
                 + "leva algumas semanas para existir: não há atalho honesto.")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func verdictBox(_ verdict: PlanVerdict) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch verdict {
            case .collecting(let observed, let needed):
                Label("Coletando dados", systemImage: "hourglass")
                    .font(.title3.bold())
                ProgressView(value: Double(observed), total: Double(needed)) {
                    Text("\(observed) de \(needed) semanas observadas")
                        .font(.caption)
                }
                .frame(maxWidth: 340)
                Text("Uma recomendação com uma semana de amostra seria chute. Enquanto isso, "
                     + "a aba “Pago vs. Utilizado” já responde se a assinatura se paga.")
                    .font(.caption).foregroundColor(.secondary)

            case .notApplicable:
                Label("Sem recomendação para este plano", systemImage: "info.circle")
                    .font(.title3.bold())
                Text("A conta ativa (\(vm.plan)) não é cobrada por múltiplo de uso do Pro, "
                     + "então a comparação de tiers não se aplica.")
                    .font(.caption).foregroundColor(.secondary)

            case .verdict(let current, let peak, let options):
                let cheapest = PlanAdvisor.cheapestFitting(options, config: vm.config)
                let canDrop = cheapest != nil && cheapest!.tier.id != current.id
                Label(canDrop
                        ? "Dá para descer para \(cheapest!.tier.name)"
                        : "Fique no \(current.name)",
                      systemImage: canDrop ? "arrow.down.circle.fill" : "checkmark.seal.fill")
                    .font(.title3.bold())
                    .foregroundColor(canDrop ? .orange : .green)
                Text(String(format: "Seu pior pico semanal observado foi %.0f%% do limite do %@.",
                            peak * 100, current.name))
                    .font(.callout)

                ForEach(options) { opt in
                    HStack(spacing: 10) {
                        Image(systemName: opt.fits ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(opt.fits ? .green : .red)
                        Text(opt.tier.name).frame(width: 80, alignment: .leading)
                        Text(String(format: "te deixaria em %.0f%%", opt.projectedUtilization * 100))
                            .foregroundColor(.secondary)
                        if !opt.tier.priceVerified {
                            Text("preço não confirmado")
                                .font(.caption2).foregroundColor(.orange)
                        }
                        Spacer()
                    }
                    .font(.callout)
                }
                Text(String(format: "Margem de segurança: um plano só é considerado viável "
                            + "abaixo de %.0f%%, porque o pico medido não é o pico possível.",
                            PlanAdvisor.safetyMargin * 100))
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var weeklyHistory: some View {
        let peaks = vm.rateLimitStore.peaks(.sevenDay, tier: vm.activeTier.isEmpty ? nil : vm.activeTier)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Picos semanais observados").font(.subheadline.bold())
            if peaks.isEmpty {
                Text("Nenhuma janela registrada ainda.").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(peaks.prefix(12)) { p in
                    let conf = p.confidence(windowSeconds: WindowKind.sevenDay.seconds)
                    HStack(spacing: 10) {
                        Text(p.resetDate, format: .dateTime.day().month())
                            .frame(width: 70, alignment: .leading)
                        ProgressView(value: min(p.peak, 1))
                            .frame(width: 200)
                        Text(String(format: "%.0f%%", p.peak * 100))
                            .frame(width: 45, alignment: .trailing)
                            .foregroundColor(utilizationColor(p.peak))
                        Text(conf.label)
                            .font(.caption2)
                            .foregroundColor(conf == .high ? .secondary : .orange)
                        Spacer()
                    }
                    .font(.caption)
                }
            }
        }
    }
}

// MARK: - Peças compartilhadas

struct StatTile: View {
    let label: String
    let value: String
    let color: Color
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.title2.bold()).foregroundColor(color)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}

/// "claude-opus-5" → "opus-5", para caber na legenda.
func shortModel(_ name: String) -> String {
    name.replacingOccurrences(of: "claude-", with: "")
        .components(separatedBy: "-202").first ?? name
}
