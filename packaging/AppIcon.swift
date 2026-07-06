// AppIcon.swift — gera o ícone mestre 1024×1024 do Claude Monitor.
// Uso: swiftc -framework AppKit -O -o /tmp/agicon AppIcon.swift && /tmp/agicon <saida.png>
// Desenha um squircle com gradiente coral (paleta Anthropic), um medidor
// (arco de rate-limit) e o glifo losango ◆ que a app usa na menu bar.
import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024

guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("ctx") }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

// --- Squircle de fundo (margem estilo macOS) ---
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2)
let radius: CGFloat = rect.width * 0.2237
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
// Gradiente coral → terracota (diagonal)
let grad = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [color(232, 141, 106), color(193, 95, 60)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// Brilho suave no topo
let sheen = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [color(255, 255, 255, 0.18), color(255, 255, 255, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: S/2, y: rect.maxY - 40), startRadius: 0,
                       endCenter: CGPoint(x: S/2, y: rect.maxY - 40), endRadius: rect.width*0.7, options: [])
ctx.restoreGState()

// --- Medidor: arco de rate-limit (~72% preenchido) ---
let center = CGPoint(x: S/2, y: S/2)
let ringR: CGFloat = 250
let lineW: CGFloat = 54
// Trilha (translúcida)
ctx.setLineWidth(lineW)
ctx.setLineCap(.round)
ctx.setStrokeColor(color(255, 255, 255, 0.22))
ctx.addArc(center: center, radius: ringR, startAngle: -.pi*0.72, endAngle: .pi*1.22, clockwise: false)
ctx.strokePath()
// Preenchimento (branco) — do início até ~72%
let start: CGFloat = -.pi*0.72
let sweep: CGFloat = (.pi*1.22 - (-.pi*0.72)) * 0.72
ctx.setStrokeColor(color(255, 255, 255, 0.95))
ctx.addArc(center: center, radius: ringR, startAngle: start, endAngle: start + sweep, clockwise: false)
ctx.strokePath()

// --- Losango central ◆ ---
let d: CGFloat = 170
let diamond = CGMutablePath()
diamond.move(to: CGPoint(x: center.x, y: center.y + d))
diamond.addLine(to: CGPoint(x: center.x + d, y: center.y))
diamond.addLine(to: CGPoint(x: center.x, y: center.y - d))
diamond.addLine(to: CGPoint(x: center.x - d, y: center.y))
diamond.closeSubpath()
ctx.addPath(diamond)
ctx.setFillColor(color(255, 255, 255, 1))
ctx.fillPath()

guard let img = ctx.makeImage() else { fatalError("img") }
let rep = NSBitmapImageRep(cgImage: img)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("icon written: \(outPath) (1024x1024)")
