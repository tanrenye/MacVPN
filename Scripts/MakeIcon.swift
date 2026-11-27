import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
}

func hexagonVertices(in rect: CGRect) -> [CGPoint] {
    [
        CGPoint(x: rect.midX, y: rect.maxY),
        CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.75),
        CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25),
        CGPoint(x: rect.midX, y: rect.minY),
        CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25),
        CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.75)
    ]
}

func drawIcon(in context: CGContext) {
    let tile = CGPath(roundedRect: CGRect(x: 76, y: 76, width: 872, height: 872),
                      cornerWidth: 194, cornerHeight: 194, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -13), blur: 24, color: color(0x010719, alpha: 0.42))
    context.setFillColor(color(0x080F2A))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(gradient([color(0x192C68), color(0x101A3B), color(0x080F28)]),
                               start: CGPoint(x: 212, y: 890), end: CGPoint(x: 760, y: 150),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.drawRadialGradient(gradient([color(0x1859B7, alpha: 0.72), color(0x1859B7, alpha: 0)]),
                               startCenter: CGPoint(x: 532, y: 577), startRadius: 10,
                               endCenter: CGPoint(x: 532, y: 577), endRadius: 455, options: [])

    // 低对比度网格保留面板质感，缩小时让位于隧道轮廓。
    context.setLineWidth(1.5)
    context.setStrokeColor(color(0x8BC9FF, alpha: 0.10))
    for x in stride(from: 128, through: 896, by: 64) {
        context.move(to: CGPoint(x: x, y: 76))
        context.addLine(to: CGPoint(x: x, y: 948))
    }
    for y in stride(from: 128, through: 896, by: 64) {
        context.move(to: CGPoint(x: 76, y: y))
        context.addLine(to: CGPoint(x: 948, y: y))
    }
    context.strokePath()
    context.setLineWidth(5)
    context.setStrokeColor(color(0xB4D5FF, alpha: 0.27))
    context.addPath(tile)
    context.strokePath()
    context.restoreGState()

    let entranceVertices = hexagonVertices(in: CGRect(x: 251, y: 222, width: 522, height: 580))
    let innerVertices = hexagonVertices(in: CGRect(x: 373, y: 352, width: 304, height: 336))
    let entrance = CGMutablePath()
    entrance.addLines(between: entranceVertices)
    entrance.closeSubpath()
    let innerRing = CGMutablePath()
    innerRing.addLines(between: innerVertices)
    innerRing.closeSubpath()

    // 收拢的轮廓与六条透视线把视线引向隧道中心。
    context.addPath(entrance)
    context.setFillColor(color(0x081A40, alpha: 0.74))
    context.fillPath()
    context.setStrokeColor(color(0x559FFF, alpha: 0.33))
    context.setLineWidth(6)
    for (near, far) in zip(entranceVertices, innerVertices) {
        context.move(to: near)
        context.addLine(to: far)
    }
    context.strokePath()

    context.setLineJoin(.round)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 27, color: color(0x050A21, alpha: 0.87))
    context.setStrokeColor(color(0x284BB7))
    context.setLineWidth(67)
    context.addPath(entrance)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.setLineWidth(59)
    context.addPath(entrance)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(gradient([color(0xE0FFFF), color(0x60EDFF), color(0x5573FF)]),
                               start: CGPoint(x: 324, y: 745), end: CGPoint(x: 671, y: 270),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    context.setStrokeColor(color(0x6ACDFF, alpha: 0.78))
    context.setLineWidth(21)
    context.addPath(innerRing)
    context.strokePath()

    let center = CGPoint(x: 525, y: 520)
    context.drawRadialGradient(gradient([color(0x3BBAFF, alpha: 0.68), color(0x3BBAFF, alpha: 0)]),
                               startCenter: center, startRadius: 19, endCenter: center, endRadius: 108,
                               options: [.drawsBeforeStartLocation])
    let signal = CGPath(roundedRect: CGRect(x: -29, y: -29, width: 58, height: 58),
                        cornerWidth: 9, cornerHeight: 9, transform: nil)
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: .pi / 4)
    context.setFillColor(color(0xD9FFFF))
    context.addPath(signal)
    context.fillPath()
    context.restoreGState()
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for logicalSize in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let size = logicalSize * multiplier
        let suffix = multiplier == 2 ? "@2x" : ""
        let destination = directory.appending(path: "icon_\(logicalSize)x\(logicalSize)\(suffix).png")
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let png = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Cannot create app icon at \(size) × \(size)")
        }
        let scale = CGFloat(size) / 1024
        context.scaleBy(x: scale, y: scale)
        drawIcon(in: context)
        guard let image = context.makeImage() else { fatalError("Cannot render app icon") }
        CGImageDestinationAddImage(png, image, nil)
        guard CGImageDestinationFinalize(png) else { fatalError("Cannot write app icon") }
    }
}
