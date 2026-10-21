import CoreGraphics
import Metal
import Foundation

public struct EngineError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One edit to apply on top of the image's imported state.
public struct StackEntry: Sendable {
    public var operation: String
    public var multiPriority: Int
    public var params: [String: ParamValue]
    public var blend: [String: ParamValue]
    public var enabled: Bool

    public init(operation: String, multiPriority: Int = 0, params: [String: ParamValue] = [:],
                blend: [String: ParamValue] = [:], enabled: Bool = true) {
        self.operation = operation
        self.multiPriority = multiPriority
        self.params = params
        self.blend = blend
        self.enabled = enabled
    }
}

/// A painted or detected mask as the engine takes it: a grey picture of the upright photo (row 0 on top, 0...255), named by an
/// id the edit's `mask_raster` blend option refers to.
public struct MaskPicture: Sendable, Equatable {
    public let id: String
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public init(id: String, width: Int, height: Int, pixels: [UInt8]) {
        self.id = id; self.width = width; self.height = height; self.pixels = pixels
    }
}

/// A session render stopped by `cancelRender()` because a newer edit superseded it.
public struct RenderCanceled: Error, Sendable {
    public init() {}
}

/// A frame rendered straight into a Metal texture the app presents without reading it back: 16-bit float, linear, in extended Display P3
/// (`PresentedFrame.colorSpaceName`), top row first. `thumbnail` is a small 8-bit sRGB copy for the scopes and anything else that needs
/// pixels on the CPU; `width` and `height` are the picture's, the texture's size. The engine reuses a few textures in turn, so a frame stays
/// valid for the next couple of renders.
public struct PresentedFrame: @unchecked Sendable {
    public static let colorSpaceName = "kCGColorSpaceExtendedLinearDisplayP3"
    public let texture: MTLTexture
    public let width: Int
    public let height: Int
    public let milliseconds: Double
    public let thumbnail: CGImage

    public init(texture: MTLTexture, width: Int, height: Int, milliseconds: Double, thumbnail: CGImage) {
        self.texture = texture; self.width = width; self.height = height; self.milliseconds = milliseconds; self.thumbnail = thumbnail
    }
}

public struct RenderedFrame: @unchecked Sendable {
    public let image: CGImage
    public let width: Int
    public let height: Int
    public let milliseconds: Double

    public init(image: CGImage, width: Int, height: Int, milliseconds: Double) {
        self.image = image
        self.width = width
        self.height = height
        self.milliseconds = milliseconds
    }
}
