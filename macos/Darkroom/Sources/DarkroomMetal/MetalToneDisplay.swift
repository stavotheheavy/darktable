// Metal kernel for the tone map and display transform (checkpoint B2).
//
// Mirrors the CPU chain in DarkroomCore: the ToneMap lookup per channel (log-domain index, linear
// interpolation, linear extension below the table), then the display matrix, then the sRGB encode,
// clipped to 0...1. The tone table is uploaded as floats; the matrix as three columns.

import Metal
import DarkroomCore

public final class MetalToneDisplay {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    // p = (grey, minEV, maxEV, tableSize - 1)
    static float toneLookup(float y, constant float4 &p, device const float *table) {
        if (y <= 0.0f) { return 0.0f; }
        float ev = log2(y / p.x);
        float t = clamp((ev - p.y) / (p.z - p.y), 0.0f, 1.0f) * p.w;
        int last = int(p.w) - 1;
        int i = min(int(t), last);
        float f = t - float(i);
        float v = table[i] + (table[i + 1] - table[i]) * f;
        return ev < p.y ? v * (y / (p.x * exp2(p.y))) : v;
    }

    static float encodeSRGB(float v) {
        v = max(v, 0.0f);
        float e = v <= 0.0031308f ? 12.92f * v : 1.055f * pow(v, 1.0f / 2.4f) - 0.055f;
        return clamp(e, 0.0f, 1.0f);
    }

    kernel void toneDisplay(device const float4 *src [[buffer(0)]],
                            device float4 *dst [[buffer(1)]],
                            constant float4 &params [[buffer(2)]],
                            constant float4 *columns [[buffer(3)]],
                            device const float *table [[buffer(4)]],
                            uint i [[thread_position_in_grid]]) {
        float4 c = src[i];
        float3 toned = float3(toneLookup(c.r, params, table),
                              toneLookup(c.g, params, table),
                              toneLookup(c.b, params, table));
        float3x3 m = float3x3(columns[0].xyz, columns[1].xyz, columns[2].xyz);
        float3 s = m * toned;
        dst[i] = float4(encodeSRGB(s.r), encodeSRGB(s.g), encodeSRGB(s.b), c.a);
    }
    """#

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalEditError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalEditError.noQueue }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "toneDisplay") else { throw MetalEditError.noFunction }
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Runs tone (from `tone`'s table), then the matrix given by its three columns, then the sRGB encode.
    public func run(_ pixels: [SIMD4<Float>], tone: ToneMap, columns: [SIMD3<Float>]) -> [SIMD4<Float>] {
        guard !pixels.isEmpty, columns.count == 3 else { return [] }
        let stride = MemoryLayout<SIMD4<Float>>.stride
        let length = pixels.count * stride
        let table = tone.table.map { Float($0) }
        let params = SIMD4<Float>(Float(ToneMap.grey), Float(ToneMap.minEV), Float(ToneMap.maxEV), Float(ToneMap.tableSize - 1))
        let cols = columns.map { SIMD4<Float>($0.x, $0.y, $0.z, 0) }
        guard let src = device.makeBuffer(bytes: pixels, length: length, options: .storageModeShared),
              let dst = device.makeBuffer(length: length, options: .storageModeShared),
              let tableBuffer = device.makeBuffer(bytes: table, length: table.count * MemoryLayout<Float>.stride, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            return []
        }
        var p = params
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(dst, offset: 0, index: 1)
        enc.setBytes(&p, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        enc.setBytes(cols, length: cols.count * MemoryLayout<SIMD4<Float>>.stride, index: 3)
        enc.setBuffer(tableBuffer, offset: 0, index: 4)
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
