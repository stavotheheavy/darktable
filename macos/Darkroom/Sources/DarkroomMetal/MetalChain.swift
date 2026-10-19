// The GPU chain in one command buffer (checkpoint T5 work): exposure and white balance, then tone and
// display, then sharpen. The intermediate stages stay in GPU-only buffers.
//
// Two ways out. `run` copies the frame in from Swift and back out to a Swift array: the chain as the
// oracle sees it, with the host copies included. `renderToTexture` takes a source buffer that is already
// on the GPU and leaves the result in a texture, which is what the app shows: no host copies at all.

import Metal
import DarkroomCore

public final class MetalChain {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let exposure: MTLComputePipelineState
    private let tone: MTLComputePipelineState
    private let sharpen: MTLComputePipelineState
    private let tableBuffer: MTLBuffer
    /// GPU execution time of the last render, from the command buffer's own timestamps. Excludes host copies.
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
        // the tone table is the same for every edit with the default ToneMap; built once per chain
        let table = ToneMap().table.map { Float($0) }
        guard let buffer = device.makeBuffer(bytes: table, length: table.count * MemoryLayout<Float>.stride,
                                             options: .storageModeShared) else {
            throw MetalEditError.noFunction
        }
        self.tableBuffer = buffer
    }

    /// Uploads scene pixels once. Keep the buffer for `renderToTexture`, so the edit loop does not copy the frame.
    public func makeSource(_ pixels: [SIMD4<Float>]) -> MTLBuffer? {
        device.makeBuffer(bytes: pixels, length: pixels.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
    }

    /// Exposure and white balance (`scale`), tone and display (`columns` is the Rec.2020 to sRGB matrix),
    /// then sharpen (`amount`). Copies the frame in and out. Returns the display-referred pixels.
    public func run(_ pixels: [SIMD4<Float>], scale: SIMD3<Float>, columns: [SIMD3<Float>], amount: Float) -> [SIMD4<Float>] {
        guard !pixels.isEmpty, let src = makeSource(pixels),
              let dst = device.makeBuffer(length: pixels.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
              encode(src: src, dst: dst, count: pixels.count, scale: scale, columns: columns, amount: amount) else {
            return []
        }
        let out = dst.contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels.count)
        return Array(UnsafeBufferPointer(start: out, count: pixels.count))
    }

    /// The same chain on a source already on the GPU; the result is written to a `width` by `height`
    /// texture the app can show. No host copies. Returns nil if the GPU work could not be set up.
    public func renderToTexture(source: MTLBuffer, width: Int, height: Int, scale: SIMD3<Float>,
                                columns: [SIMD3<Float>], amount: Float) -> MTLTexture? {
        let count = width * height
        let rowBytes = width * MemoryLayout<SIMD4<Float>>.stride
        guard let out = device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate) else {
            return nil
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc),
              encode(src: source, dst: out, count: count, scale: scale, columns: columns, amount: amount, copyTo: (texture, rowBytes, height)) else {
            return nil
        }
        return texture
    }

    /// Encodes the three stages into one command buffer and waits for it. With `copyTo`, a blit then fills
    /// the texture from `dst` in the same buffer. Returns false if the GPU objects could not be made.
    private func encode(src: MTLBuffer, dst: MTLBuffer, count: Int, scale: SIMD3<Float>, columns: [SIMD3<Float>],
                        amount: Float, copyTo: (MTLTexture, Int, Int)? = nil) -> Bool {
        guard columns.count == 3,
              let a = device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate),
              let b = device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            return false
        }
        let grid = MTLSize(width: count, height: 1, depth: 1)
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

        if let (texture, rowBytes, height) = copyTo {
            guard let blit = cmd.makeBlitCommandEncoder() else { return false }
            blit.copy(from: dst, sourceOffset: 0, sourceBytesPerRow: rowBytes,
                      sourceBytesPerImage: rowBytes * height, sourceSize: MTLSize(width: texture.width, height: height, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
        }

        cmd.commit()
        cmd.waitUntilCompleted()
        lastGPUMilliseconds = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000
        return true
    }
}
