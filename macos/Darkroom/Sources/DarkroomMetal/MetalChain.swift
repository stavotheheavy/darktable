// The GPU chain in one command buffer (checkpoint T5 work): exposure and white balance, then tone and
// display, then sharpen. The intermediate stages stay in GPU-only buffers; the frame is copied in once
// and out once. The three kernels are the same ones the single-stage checks use.

import Metal
import DarkroomCore

public final class MetalChain {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let exposure: MTLComputePipelineState
    private let tone: MTLComputePipelineState
    private let sharpen: MTLComputePipelineState
    private let tableBuffer: MTLBuffer
    /// GPU execution time of the last `run`, from the command buffer's own timestamps. Excludes host copies.
    public private(set) var lastGPUMilliseconds = 0.0

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalEditError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalEditError.noQueue }
        // one library holding all three kernels; each source carries its own includes
        let source = [MetalExposureWB.source, MetalToneDisplay.source, MetalSharpen.source].joined(separator: "\n")
        let library = try device.makeLibrary(source: source, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw MetalEditError.noFunction }
            return try device.makeComputePipelineState(function: f)
        }
        self.device = device
        self.queue = queue
        self.exposure = try pipeline("exposureWB")
        self.tone = try pipeline("toneDisplay")
        self.sharpen = try pipeline("sharpenLine")
        // the tone table is the same for every edit with the same ToneMap; built once per chain
        let table = ToneMap().table.map { Float($0) }
        guard let buffer = device.makeBuffer(bytes: table, length: table.count * MemoryLayout<Float>.stride,
                                             options: .storageModeShared) else {
            throw MetalEditError.noFunction
        }
        self.tableBuffer = buffer
    }

    /// Exposure and white balance (`scale`), tone and display (`columns` is the Rec.2020 to sRGB matrix),
    /// then sharpen (`amount`). Returns the display-referred pixels.
    public func run(_ pixels: [SIMD4<Float>], scale: SIMD3<Float>, columns: [SIMD3<Float>], amount: Float) -> [SIMD4<Float>] {
        guard !pixels.isEmpty, columns.count == 3 else { return [] }
        let stride = MemoryLayout<SIMD4<Float>>.stride
        let length = pixels.count * stride
        guard let src = device.makeBuffer(bytes: pixels, length: length, options: .storageModeShared),
              let a = device.makeBuffer(length: length, options: .storageModePrivate),
              let b = device.makeBuffer(length: length, options: .storageModePrivate),
              let dst = device.makeBuffer(length: length, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            return []
        }
        let grid = MTLSize(width: pixels.count, height: 1, depth: 1)
        let group = MTLSize(width: exposure.threadExecutionWidth, height: 1, depth: 1)

        var s = SIMD4<Float>(scale.x, scale.y, scale.z, 1)
        enc.setComputePipelineState(exposure)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(a, offset: 0, index: 1)
        enc.setBytes(&s, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)

        var p = SIMD4<Float>(Float(ToneMap.grey), Float(ToneMap.minEV), Float(ToneMap.maxEV), Float(ToneMap.tableSize - 1))
        let cols = columns.map { SIMD4<Float>($0.x, $0.y, $0.z, 0) }
        enc.setComputePipelineState(tone)
        enc.setBuffer(a, offset: 0, index: 0)
        enc.setBuffer(b, offset: 0, index: 1)
        enc.setBytes(&p, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        enc.setBytes(cols, length: cols.count * MemoryLayout<SIMD4<Float>>.stride, index: 3)
        enc.setBuffer(tableBuffer, offset: 0, index: 4)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)

        var amt = amount
        enc.setComputePipelineState(sharpen)
        enc.setBuffer(b, offset: 0, index: 0)
        enc.setBuffer(dst, offset: 0, index: 1)
        enc.setBytes(&amt, length: MemoryLayout<Float>.size, index: 2)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)

        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        lastGPUMilliseconds = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000
        let out = dst.contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels.count)
        return Array(UnsafeBufferPointer(start: out, count: pixels.count))
    }
}
