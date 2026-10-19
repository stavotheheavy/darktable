// A linear chain of edit stages with a parameter-hash cache (plan P4, chart test T4).
//
// Each stage's key covers its own name and parameters plus the key of the stage before it. So
// changing a stage invalidates that stage and every stage after it, and nothing upstream. A stage
// whose key matches its cached entry returns the cached pixels without running.

import Foundation

public struct Stage {
    public let name: String
    /// Parameters as a string: any change to them changes the key.
    public let params: String
    public let run: ([SIMD3<Double>]) -> [SIMD3<Double>]

    public init(name: String, params: String, run: @escaping ([SIMD3<Double>]) -> [SIMD3<Double>]) {
        self.name = name
        self.params = params
        self.run = run
    }
}

public final class StageGraph {
    private var cache: [(key: String, pixels: [SIMD3<Double>])?]
    /// How many times each stage actually ran, by name. Read by chart tests.
    public private(set) var executions: [String: Int] = [:]

    public init(stageCount: Int) {
        cache = Array(repeating: nil, count: stageCount)
    }

    /// Runs the chain on `input`, reusing cached stages whose keys still match.
    public func render(_ stages: [Stage], input: [SIMD3<Double>]) -> [SIMD3<Double>] {
        if cache.count != stages.count { cache = Array(repeating: nil, count: stages.count) }
        var key = "input"
        var pixels = input
        for (i, stage) in stages.enumerated() {
            key += "|\(stage.name)(\(stage.params))"
            if let hit = cache[i], hit.key == key {
                pixels = hit.pixels
                continue
            }
            pixels = stage.run(pixels)
            executions[stage.name, default: 0] += 1
            cache[i] = (key, pixels)
        }
        return pixels
    }
}
