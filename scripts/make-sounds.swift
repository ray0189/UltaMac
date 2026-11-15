// Synthesises UltaMac's original sound palette (soft bells, glides and ticks) into 16-bit WAV files.
// Usage: swift scripts/make-sounds.swift <output-dir>
// Every sound is generated from first principles here: no samples or third-party audio.
import Foundation

let rate = 44_100.0
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

struct Voice {
    var freq: Double            // start frequency (Hz)
    var endFreq: Double? = nil  // optional glide target
    var start: Double = 0       // seconds
    var decay: Double = 0.6     // seconds to ~-60 dB
    var gain: Double = 1
    var partials: [(ratio: Double, gain: Double)] = [(1, 1), (2.01, 0.28), (3.98, 0.08), (5.43, 0.04)]
    var attack: Double = 0.006
}

func render(_ voices: [Voice], length: Double, noise: (start: Double, len: Double, gain: Double)? = nil) -> [Double] {
    let n = Int(length * rate)
    var buf = [Double](repeating: 0, count: n)
    for v in voices {
        let s0 = Int(v.start * rate)
        var phases = [Double](repeating: 0, count: v.partials.count)
        for i in s0..<n {
            let t = Double(i - s0) / rate
            let env = min(1, t / v.attack) * exp(-6.9 * t / v.decay)
            if env < 0.0005 && t > v.attack { break }
            let f = v.endFreq.map { v.freq + ($0 - v.freq) * min(1, t / max(v.decay * 0.6, 0.01)) } ?? v.freq
            var sample = 0.0
            for (k, p) in v.partials.enumerated() {
                phases[k] += 2 * .pi * f * p.ratio / rate
                // Higher partials decay faster: brighter attack, warm tail.
                sample += sin(phases[k]) * p.gain * exp(-6.9 * t * Double(k) * 0.9 / v.decay)
            }
            buf[i] += sample * env * v.gain
        }
    }
    if let nz = noise { // soft filtered noise "air" for sweeps
        var lp = 0.0
        var seed: UInt64 = 0x5EED
        for i in Int(nz.start * rate)..<min(n, Int((nz.start + nz.len) * rate)) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let white = Double(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1
            let t = Double(i) / rate - nz.start
            let cutoff = 0.02 + 0.25 * (t / nz.len) // opening filter
            lp += cutoff * (white - lp)
            let env = sin(.pi * min(1, t / nz.len))
            buf[i] += lp * env * nz.gain
        }
    }
    // Normalise to -6 dBFS with a short fade-out.
    let peak = buf.map(abs).max() ?? 1
    let fade = Int(0.01 * rate)
    return buf.enumerated().map { i, s in
        let f = i > n - fade ? Double(n - i) / Double(fade) : 1
        return s / max(peak, 1e-9) * 0.5 * f
    }
}

func writeWAV(_ samples: [Double], _ name: String) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
    data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
    for s in samples { append(Int16(max(-1, min(1, s)) * 32_767)) }
    try data.write(to: out.appendingPathComponent(name + ".wav"))
}

// Notes (Hz)
let C5 = 523.25, E5 = 659.25, G5 = 783.99, B5 = 987.77, C6 = 1046.5, A5 = 880.0, D6 = 1174.7
let A4 = 440.0, F4 = 349.23, G4 = 392.0, E4 = 329.63, C4 = 261.63
let soft: [(Double, Double)] = [(1, 1), (2.0, 0.12)]

let sounds: [String: [Double]] = [
    "launch": render([Voice(freq: C5, decay: 1.0, gain: 0.8), Voice(freq: G5, start: 0.09, decay: 1.0, gain: 0.7),
                      Voice(freq: D6, start: 0.18, decay: 1.2, gain: 0.55)], length: 1.4),
    "scanStart": render([Voice(freq: 420, endFreq: 840, decay: 0.55, gain: 0.7, partials: soft, attack: 0.04)],
                        length: 0.6, noise: (0, 0.45, 0.25)),
    "milestone": render([Voice(freq: A5, decay: 0.16, gain: 0.6)], length: 0.2),
    "scanComplete": render([Voice(freq: E5, decay: 0.9), Voice(freq: B5, start: 0.12, decay: 1.1, gain: 0.8)], length: 1.3),
    "found": render([Voice(freq: G4, decay: 0.5, gain: 0.9), Voice(freq: G5, decay: 0.3, gain: 0.25)], length: 0.6),
    "confirm": render([Voice(freq: C6, decay: 0.12, gain: 0.5, partials: soft), Voice(freq: G5, start: 0.04, decay: 0.2, gain: 0.5, partials: soft)], length: 0.3),
    "success": render([Voice(freq: C5, decay: 1.2, gain: 0.7), Voice(freq: E5, start: 0.06, decay: 1.2, gain: 0.6),
                       Voice(freq: G5, start: 0.12, decay: 1.3, gain: 0.55), Voice(freq: C6, start: 0.2, decay: 1.5, gain: 0.5)], length: 1.8),
    "warning": render([Voice(freq: A4, decay: 0.35, partials: soft), Voice(freq: F4, start: 0.16, decay: 0.45, partials: soft)], length: 0.7),
    "error": render([Voice(freq: E4, decay: 0.25, partials: soft), Voice(freq: C4, start: 0.12, decay: 0.35, partials: soft)], length: 0.55),
    "navigate": render([Voice(freq: 1800, decay: 0.03, gain: 0.25, partials: soft, attack: 0.001)], length: 0.05),
    "usbConnect": render([Voice(freq: E5, endFreq: A5, decay: 0.35, gain: 0.7, partials: soft, attack: 0.01)], length: 0.45),
    "writeStart": render([Voice(freq: 300, endFreq: 600, decay: 0.7, gain: 0.6, partials: soft, attack: 0.05)], length: 0.8, noise: (0, 0.6, 0.15)),
    "writeComplete": render([Voice(freq: G4, decay: 1.0), Voice(freq: D6 / 2, start: 0.1, decay: 1.0), Voice(freq: G5, start: 0.2, decay: 1.4)], length: 1.7),
    "verifySuccess": render([Voice(freq: B5, decay: 0.5, gain: 0.6), Voice(freq: E5 * 2, start: 0.08, decay: 0.8, gain: 0.5)], length: 1.0),
]

for (name, samples) in sounds.sorted(by: { $0.key < $1.key }) {
    try writeWAV(samples, name)
    print(name, String(format: "%.2fs", Double(samples.count) / rate))
}
