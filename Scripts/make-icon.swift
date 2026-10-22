// Liquid Glass ikonunun katmanlarını üretir: çaprazlamasına bölünüp aralanmış kalkanın iki parçası
// (ClientHello'nun parçalanmasını anlatır). Zemin rengi, köşe maskesi, cam, gölge ve parlamayı
// Resources/AppIcon.icon/icon.json üzerinden sistem uygular; katmanlar düz beyazdır.
// Kullanım: swift Scripts/make-icon.swift Resources/AppIcon.icon/Assets
import AppKit

let size: CGFloat = 1024
let outDir = CommandLine.arguments.dropFirst().first ?? "."

// Kalkan, 1024'lük tuval üzerinde y aşağı doğru koordinatlarla.
let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 236))
shield.addCurve(to: CGPoint(x: 736, y: 316), control1: CGPoint(x: 590, y: 290), control2: CGPoint(x: 660, y: 312))
shield.addLine(to: CGPoint(x: 736, y: 500))
shield.addCurve(to: CGPoint(x: 512, y: 800), control1: CGPoint(x: 736, y: 650), control2: CGPoint(x: 640, y: 752))
shield.addCurve(to: CGPoint(x: 288, y: 500), control1: CGPoint(x: 384, y: 752), control2: CGPoint(x: 288, y: 650))
shield.addLine(to: CGPoint(x: 288, y: 316))
shield.addCurve(to: CGPoint(x: 512, y: 236), control1: CGPoint(x: 364, y: 312), control2: CGPoint(x: 434, y: 290))
shield.closeSubpath()

// Kesim: sağ üstten sol alta, kalkanın ortasından; parçalar kesime dik yönde aralanır.
let center = CGPoint(x: 512, y: 518)
let angle: CGFloat = -0.52                       // yaklaşık -30°
let dir = CGPoint(x: cos(angle), y: sin(angle))
let normal = CGPoint(x: -dir.y, y: dir.x)        // sağ alt parçaya bakar
let gap: CGFloat = 20
let scale: CGFloat = 1.08                        // cam kenarları için tuvalde biraz daha yer kaplasın

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

func render(side: CGFloat, to name: String) {
    let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -512, y: -518)
    ctx.translateBy(x: normal.x * gap * side, y: normal.y * gap * side)
    ctx.addPath(halfPlane(side))
    ctx.clip()
    ctx.addPath(shield)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("Yazıldı: \(url.path)")
}

render(side: -1, to: "shield-top.png")
render(side: 1, to: "shield-bottom.png")
