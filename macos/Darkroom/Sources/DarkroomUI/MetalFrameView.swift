import DarkroomEngineAPI
import Metal
import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The canvas picture as a Metal layer: the engine's 16-bit frame texture is copied into the layer's drawable and presented, with no
/// read-back of the full frame and no 8-bit CGImage in between (Apple: CAMetalLayer, and WWDC21 10161 "Explore HDR rendering with EDR" for
/// the extended-range pixel format). The layer is rgba16Float in extended linear Display P3 with the texture's own size as its drawable, so
/// SwiftUI's layout and zoom scale it as it scales an image. Values stay in 0...1 (the display transform maps to the SDR range), and
/// `wantsExtendedDynamicRangeContent` is on only for a frame rendered with HDR headroom (PresentedFrame.peak above 1).
///
/// The Mac and the iPad/iPhone share `FramePresenter`, which does the copy; each platform only supplies the view that owns the layer.
final class FramePresenter {
    /// What the last presented frame asked of the layer, for the test rig to read back.
    nonisolated(unsafe) static var lastWantsEDR = false
    nonisolated(unsafe) static var lastColorSpaceName = ""
    private var queue: MTLCommandQueue?
    private var shown = -1

    static func configure(_ layer: CAMetalLayer) {
        layer.pixelFormat = .rgba16Float
        layer.framebufferOnly = false   // the drawable is the target of a blit
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = false   // switched on per frame (see present)
        layer.isOpaque = true
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        layer.presentsWithTransaction = true   // the new frame and the SwiftUI layout change land together
        layer.maximumDrawableCount = 3
    }

    /// Copies `frame`'s texture into a drawable on `layer` and presents it. Once per new frame; a resize of the view is the compositor's to scale.
    func present(_ frame: PresentedFrame, serial: Int, on layer: CAMetalLayer) {
        guard serial != shown else { return }
        let device = frame.texture.device
        if layer.device !== device || queue == nil {
            layer.device = device
            queue = device.makeCommandQueue()
        }
        // a frame rendered for headroom holds values above 1: the layer must ask for extended-range content for them to show brighter than SDR white
        layer.wantsExtendedDynamicRangeContent = frame.peak > 1
        Self.lastWantsEDR = layer.wantsExtendedDynamicRangeContent
        Self.lastColorSpaceName = (layer.colorspace?.name as String?) ?? ""
        layer.drawableSize = CGSize(width: frame.width, height: frame.height)
        guard let queue, let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder(),
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

#if os(macOS)
struct MetalFrameView: NSViewRepresentable {
    let frame: PresentedFrame
    let serial: Int

    func makeNSView(context: Context) -> MetalFrameNSView { MetalFrameNSView() }

    func updateNSView(_ view: MetalFrameNSView, context: Context) { view.present(frame, serial: serial) }
}

final class MetalFrameNSView: NSView {
    static var lastWantsEDR: Bool { FramePresenter.lastWantsEDR }
    static var lastColorSpaceName: String { FramePresenter.lastColorSpaceName }
    private let metal = CAMetalLayer()
    private let presenter = FramePresenter()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metal
        FramePresenter.configure(metal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func present(_ frame: PresentedFrame, serial: Int) { presenter.present(frame, serial: serial, on: metal) }
}
#else
struct MetalFrameView: UIViewRepresentable {
    let frame: PresentedFrame
    let serial: Int

    func makeUIView(context: Context) -> MetalFrameUIView { MetalFrameUIView() }

    func updateUIView(_ view: MetalFrameUIView, context: Context) { view.present(frame, serial: serial) }
}

/// A view whose layer is the Metal layer itself, so the drawable fills the view with no sublayer in between.
final class MetalFrameUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metal: CAMetalLayer { layer as! CAMetalLayer }
    private let presenter = FramePresenter()

    override init(frame: CGRect) {
        super.init(frame: frame)
        FramePresenter.configure(metal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present(_ frame: PresentedFrame, serial: Int) { presenter.present(frame, serial: serial, on: metal) }
}
#endif
