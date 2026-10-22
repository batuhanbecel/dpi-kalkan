// Uygulama ikonunu çizer: mavi zemin üzerinde çaprazlamasına bölünüp aralanmış bir kalkan
// (ClientHello'nun parçalanmasını anlatır). Kullanım: swift Scripts/make-icon.swift <çıktı.png>
import AppKit
import SwiftUI

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.displayP3)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// Çizimi y aşağı doğru düşünmek için koordinatları çevir.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha
    )
}

func linear(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

// MARK: Zemin (macOS ikon ızgarası: 824 pt gövde, sürekli köşeler)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = RoundedRectangle(cornerRadius: 186, style: .continuous).path(in: body).cgPath

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.32))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x123A9E))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(
    linear([color(0x3E8BFF), color(0x1D5BE0), color(0x0B2C86)], [0, 0.5, 1]),
    start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: []
)
// Sol üstten yumuşak ışık.
ctx.drawRadialGradient(
    linear([color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)], [0, 1]),
    startCenter: CGPoint(x: 330, y: 200), startRadius: 0,
    endCenter: CGPoint(x: 330, y: 200), endRadius: 620, options: []
)
ctx.restoreGState()

// İnce iç kenar.
ctx.saveGState()
ctx.addPath(RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: body.insetBy(dx: 1.5, dy: 1.5)).cgPath)
ctx.setStrokeColor(color(0xFFFFFF, 0.16))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// MARK: Kalkan

let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 236))
shield.addCurve(to: CGPoint(x: 736, y: 316), control1: CGPoint(x: 590, y: 290), control2: CGPoint(x: 660, y: 312))
shield.addLine(to: CGPoint(x: 736, y: 500))
shield.addCurve(to: CGPoint(x: 512, y: 800), control1: CGPoint(x: 736, y: 650), control2: CGPoint(x: 640, y: 752))
shield.addCurve(to: CGPoint(x: 288, y: 500), control1: CGPoint(x: 384, y: 752), control2: CGPoint(x: 288, y: 650))
shield.addLine(to: CGPoint(x: 288, y: 316))
shield.addCurve(to: CGPoint(x: 512, y: 236), control1: CGPoint(x: 364, y: 312), control2: CGPoint(x: 434, y: 290))
shield.closeSubpath()

// Kesim çizgisi: sağ üstten sol alta, kalkanın ortasından.
let center = CGPoint(x: 512, y: 512)
let angle: CGFloat = -0.52                       // yaklaşık -30°
let dir = CGPoint(x: cos(angle), y: sin(angle))
let normal = CGPoint(x: -dir.y, y: dir.x)        // sağ alt yarıya bakar
let gap: CGFloat = 17

func halfPlane(_ side: CGFloat) -> CGPath {
    let far: CGFloat = 2000
    let a = CGPoint(x: center.x - dir.x * far, y: center.y - dir.y * far)
    let b = CGPoint(x: center.x + dir.x * far, y: center.y + dir.y * far)
    let p = CGMutablePath()
    p.move(to: a)
    p.addLine(to: b)
    p.addLine(to: CGPoint(x: b.x + normal.x * far * side, y: b.y + normal.y * far * side))
    p.addLine(to: CGPoint(x: a.x + normal.x * far * side, y: a.y + normal.y * far * side))
    p.closeSubpath()
    return p
}

let glyphGradient = linear([color(0xFFFFFF), color(0xDCE7FF)], [0, 1])

for side: CGFloat in [-1, 1] {
    ctx.saveGState()
    ctx.translateBy(x: normal.x * gap * side, y: normal.y * gap * side)
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x031645, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(halfPlane(side))
    ctx.clip()
    ctx.addPath(shield)
    ctx.clip()
    ctx.drawLinearGradient(glyphGradient, start: CGPoint(x: 512, y: 236), end: CGPoint(x: 512, y: 800), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Yazıldı: \(output)")
