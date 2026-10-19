// Metal kernel for sharpen along a line of pixels (checkpoint B3). Same formula and clamping as
// DarkroomCore's Sharpen.line, which is the oracle.

import Metal

public final class MetalSharpen {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    kernel void sharpenLine(device const float4 *src [[buffer(0)]],
                            device float4 *dst [[buffer(1)]],
                            constant float &amount [[buffer(2)]],
                            uint i [[thread_position_in_grid]],
                            uint n [[threads_per_grid]]) {
        float4 c = src[i];
        float4 prev = src[i > 0 ? i - 1 : 0];
        float4 next = src[min(i + 1, n - 1)];
        float3 blur = (prev.rgb + c.rgb + next.rgb) / 3.0f;
        dst[i] = float4(c.rgb + amount * (c.rgb - blur), c.a);
    }
    """#

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalEditError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalEditError.noQueue }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "sharpenLine") else { throw MetalEditError.noFunction }
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Sharpens the pixels as one line on the GPU and returns the result. Alpha is passed through.
    public func run(_ pixels: [SIMD4<Float>], amount: Float) -> [SIMD4<Float>] {
        guard !pixels.isEmpty else { return [] }
        let stride = MemoryLayout<SIMD4<Float>>.stride
        let length = pixels.count * stride
        guard let src = device.makeBuffer(bytes: pixels, length: length, options: .storageModeShared),
              let dst = device.makeBuffer(length: length, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            return []
        }
        var a = amount
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(dst, offset: 0, index: 1)
        enc.setBytes(&a, length: MemoryLayout<Float>.size, index: 2)
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
