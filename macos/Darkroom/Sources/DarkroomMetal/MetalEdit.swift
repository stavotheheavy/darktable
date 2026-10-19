// Metal kernels for the clean engine (checkpoint B1: exposure and white balance).
//
// The kernel is compiled from source at run time, so the package needs no shader resources.
// Each pixel is RGBA float, scene-linear. Exposure and white balance are both per-channel gains,
// so they combine into one multiplier per channel, computed on the CPU side with DarkroomCore.
// Checked against the CPU oracle in DarkroomCore by darkroom-metal-check.

import Metal

public enum MetalEditError: Error {
    case noDevice
    case noQueue
    case noFunction
}

public final class MetalExposureWB {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    kernel void exposureWB(device const float4 *src [[buffer(0)]],
                           device float4 *dst [[buffer(1)]],
                           constant float4 &scale [[buffer(2)]],
                           uint i [[thread_position_in_grid]]) {
        float4 c = src[i];
        dst[i] = float4(c.rgb * scale.rgb, c.a);
    }
    """#

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalEditError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalEditError.noQueue }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "exposureWB") else { throw MetalEditError.noFunction }
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Multiplies every pixel's RGB by `scale` on the GPU and returns the result. Alpha is passed through.
    public func run(_ pixels: [SIMD4<Float>], scale: SIMD3<Float>) -> [SIMD4<Float>] {
        guard !pixels.isEmpty else { return [] }
        let stride = MemoryLayout<SIMD4<Float>>.stride
        let length = pixels.count * stride
        guard let src = device.makeBuffer(bytes: pixels, length: length, options: .storageModeShared),
              let dst = device.makeBuffer(length: length, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            return []
        }
        var s = SIMD4<Float>(scale.x, scale.y, scale.z, 1)
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(dst, offset: 0, index: 1)
        enc.setBytes(&s, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        let width = pipeline.threadExecutionWidth
        enc.dispatchThreads(MTLSize(width: pixels.count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let out = dst.contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels.count)
        return Array(UnsafeBufferPointer(start: out, count: pixels.count))
    }
}
