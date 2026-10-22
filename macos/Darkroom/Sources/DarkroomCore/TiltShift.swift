// Method: the tilt-shift look (a lens that moves in front of the sensor so only a band of the picture is in focus, which makes a scene look like a miniature): a
// band across the frame stays sharp and the picture is blended toward a wide blur (`Blur`) with distance from it. With p the pixel centre (x + 0.5, y + 0.5), the
// band's centre line through (W/2, position H) at `angle` degrees from horizontal, d = the signed distance of p from that line in units of the frame height,
// the blur weight is w = amount * smoothstep(0, transition, |d| - width / 2): 0 inside the band, rising to `amount` over `transition`. out = rgb + w (blur - rgb).
// Amount 0 is the identity.

import Foundation

public enum TiltShift {
    public static func weight(x: Int, y: Int, width: Int, height: Int, position: Double, angleDegrees: Double, bandWidth: Double, transition: Double, amount: Double) -> Double {
        let t = angleDegrees * .pi / 180
        let px = Double(x) + 0.5 - Double(width) / 2, py = Double(y) + 0.5 - position * Double(height)
        let d = (-px * sin(t) + py * cos(t)) / Double(height)
        return amount * ColorCommon.smoothstep(0, transition, abs(d) - bandWidth / 2)
    }

    public static func apply(_ rgb: [SIMD3<Double>], width: Int, height: Int, radius: Double, position: Double, angleDegrees: Double,
                            bandWidth: Double, transition: Double, amount: Double) -> [SIMD3<Double>] {
        guard amount != 0, radius > 0 else { return rgb }
        let blurred = Blur.apply(rgb, width: width, height: height, radius: radius)
        return rgb.indices.map { i in
            let wgt = weight(x: i % width, y: i / width, width: width, height: height, position: position, angleDegrees: angleDegrees,
                             bandWidth: bandWidth, transition: transition, amount: amount)
            return rgb[i] + wgt * (blurred[i] - rgb[i])
        }
    }
}
