import AppKit
import DarkroomEngineAPI
import Metal
import QuartzCore
import SwiftUI

/// The canvas picture as a Metal layer: the engine's 16-bit frame texture is copied into the layer's drawable and presented, with no
/// read-back of the full frame and no 8-bit CGImage in between (Apple: CAMetalLayer, and WWDC21 10161 "Explore HDR rendering with EDR" for
/// the extended-range pixel format). The layer is rgba16Float in extended linear Display P3 with the texture's own size as its drawable, so
/// SwiftUI's layout and zoom scale it as it scales an image. Values stay in 0...1: the display transform already maps to the SDR range, and
/// `wantsExtendedDynamicRangeContent` stays off.
struct MetalFrameView: NSViewRepresentable {
    let frame: PresentedFrame
    let serial: Int

    func makeNSView(context: Context) -> MetalFrameNSView { MetalFrameNSView() }

    func updateNSView(_ view: MetalFrameNSView, context: Context) { view.present(frame, serial: serial) }
}

final class MetalFrameNSView: NSView {
    private let metal = CAMetalLayer()
    private var queue: MTLCommandQueue?
    private var shown = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metal
        metal.pixelFormat = .rgba16Float
        metal.framebufferOnly = false   // the drawable is the target of a blit
        metal.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metal.wantsExtendedDynamicRangeContent = false
        metal.isOpaque = true
        metal.contentsGravity = .resize
        metal.magnificationFilter = .linear
        metal.minificationFilter = .trilinear
        metal.presentsWithTransaction = true   // the new frame and the SwiftUI layout change land together
        metal.maximumDrawableCount = 3
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Copies `frame`'s texture into a drawable and presents it. Once per new frame; a resize of the view is the compositor's to scale.
    func present(_ frame: PresentedFrame, serial: Int) {
        guard serial != shown else { return }
        let device = frame.texture.device
        if metal.device !== device || queue == nil {
            metal.device = device
            queue = device.makeCommandQueue()
        }
        metal.drawableSize = CGSize(width: frame.width, height: frame.height)
        guard let queue, let drawable = metal.nextDrawable(), let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder(),
              drawable.texture.width == frame.texture.width, drawable.texture.height == frame.texture.height else { return }
        blit.copy(from: frame.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: frame.texture.width, height: frame.texture.height, depth: 1),
                  to: drawable.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilScheduled()
        drawable.present()
        shown = serial
    }
}
