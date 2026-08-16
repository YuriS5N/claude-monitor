import SwiftUI
import AppKit
import Foundation

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

