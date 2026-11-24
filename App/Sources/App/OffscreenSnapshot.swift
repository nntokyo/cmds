import AppKit

#if DEBUG
/// Tests only: a view drawn into a bitmap without being on screen (`debug.offscreen_snapshot`), so a window's layout can
/// be checked without bringing anything to the front.
@MainActor
enum OffscreenSnapshot {
    static func png(of view: NSView) -> Data? {
        // Light, on white: a transparent bitmap in Dark Mode shows white text on nothing.
        let light = NSAppearance(named: .aqua)
        view.window?.appearance = light
        view.appearance = light
        view.window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        var bounds = view.bounds
        if bounds.isEmpty {
            view.setFrameSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            bounds = view.bounds
        }
        guard !bounds.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        canvas.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        image.draw(in: NSRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }
}
#endif
