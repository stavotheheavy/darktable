// Method: a rotation of every colour's hue about the grey axis in OkLab (Björn Ottosson, 2020): (a, b) is turned by the angle, lightness and chroma are kept,
// greys stay grey. 0 degrees is the identity and 360 is the same as 0.

import Foundation

public enum HueRotate {
    public static func apply(_ rgb: SIMD3<Double>, degrees: Double) -> SIMD3<Double> {
        var lab = OkLab.fromWorking(rgb)
        let t = degrees * .pi / 180, c = cos(t), s = sin(t)
        let a = lab.y * c - lab.z * s, b = lab.y * s + lab.z * c
        lab.y = a
        lab.z = b
        return OkLab.toWorking(lab)
    }
}
