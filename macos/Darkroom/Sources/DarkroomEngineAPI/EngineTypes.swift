import CoreGraphics
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

/// A session render stopped by `cancelRender()` because a newer edit superseded it.
public struct RenderCanceled: Error, Sendable {
    public init() {}
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
