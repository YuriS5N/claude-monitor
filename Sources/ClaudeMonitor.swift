import SwiftUI
import AppKit
import Foundation
import Security

// MARK: - Hide from Dock
class AppDelegate: NSObject, NSApplicationDelegate {
    let statusBar = StatusBarController()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBar.setup()
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
    private lazy var analytics = AnalyticsWindowController(vm: vm)
    private var observer: NSObjectProtocol?
    private var analyticsObserver: NSObjectProtocol?
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

        analyticsObserver = NotificationCenter.default.addObserver(
            forName: .openAnalytics, object: nil, queue: .main
        ) { [weak self] _ in
            self?.popover.performClose(nil)
            self?.analytics.show()
        }

        // Mesmo gatilho pelo barramento entre processos, para poder abrir a janela
        // a partir de um atalho/script sem passar pelo popover.
        DistributedNotificationCenter.default().addObserver(
            forName: .openAnalytics, object: nil, queue: .main
        ) { [weak self] _ in
            self?.analytics.show()
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
