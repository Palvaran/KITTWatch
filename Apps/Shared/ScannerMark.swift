import SwiftUI
import CoreGraphics

/// Shared artwork for the home header, companion app, and launcher icons.
enum ScannerArtwork {
    static func draw(in context: CGContext, bounds: CGRect) {
        let width = bounds.width
        let gap = width * 0.036
        let segment = (width - gap * 3) / 4
        let height = min(bounds.height, width * 0.085)
        context.setFillColor(CGColor(srgbRed: 1, green: 0.16, blue: 0.19, alpha: 1))
        for index in 0..<4 {
            let rect = CGRect(x: bounds.minX + CGFloat(index) * (segment + gap),
                              y: bounds.midY - height / 2, width: segment, height: height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: height * 0.12,
                                   cornerHeight: height * 0.12, transform: nil))
            context.fillPath()
        }
    }
}

struct ScannerMark: View {
    var body: some View {
        Canvas { context, size in
            context.withCGContext { ScannerArtwork.draw(in: $0, bounds: CGRect(origin: .zero, size: size)) }
        }
        .aspectRatio(5, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
