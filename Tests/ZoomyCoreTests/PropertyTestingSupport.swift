import XCTest
import CoreGraphics

/// Deterministic seeded PRNG (SplitMix64) so fuzz and property runs are reproducible across
/// machines/CI. Shared by the state-machine fuzz test and the pure-core property tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Default seed for property runs. Fixed so failures are reproducible; each iteration derives
/// its own sub-seed from this, and a failure message reports that sub-seed for pinpoint replay.
let defaultPropertySeed: UInt64 = 0x1234_5678_9ABC_DEF0

/// Minimal in-house property-based test runner (no external dependencies). Runs `holds` against
/// `iterations` randomly generated inputs. Each iteration uses its own generator seeded from a
/// deterministic sub-seed derived from `seed`, so a failing case can be reproduced exactly by
/// re-running with that reported sub-seed. On the first failure it reports the iteration index,
/// the reproducing sub-seed, and the offending input, then stops.
func checkProperty<T>(
    _ name: String,
    iterations: Int = 500,
    seed: UInt64 = defaultPropertySeed,
    generate: (inout SeededGenerator) -> T,
    holds: (T) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for iteration in 0..<iterations {
        let iterationSeed = seed &+ UInt64(iteration) &* 0x9E3779B97F4A7C15
        var rng = SeededGenerator(seed: iterationSeed)
        let input = generate(&rng)
        if !holds(input) {
            XCTFail(
                """
                Property "\(name)" failed at iteration \(iteration) of \(iterations).
                Reproduce with seed \(iterationSeed). Failing input: \(input)
                """,
                file: file,
                line: line
            )
            return
        }
    }
}

// MARK: - Range-bounded random helpers

func randomCGFloat(in range: ClosedRange<CGFloat>, using rng: inout SeededGenerator) -> CGFloat {
    CGFloat.random(in: range, using: &rng)
}

func randomDouble(in range: ClosedRange<Double>, using rng: inout SeededGenerator) -> Double {
    Double.random(in: range, using: &rng)
}

func randomPoint(
    x xRange: ClosedRange<CGFloat>,
    y yRange: ClosedRange<CGFloat>,
    using rng: inout SeededGenerator
) -> CGPoint {
    CGPoint(x: randomCGFloat(in: xRange, using: &rng), y: randomCGFloat(in: yRange, using: &rng))
}

// MARK: - Approximate equality (relative + absolute tolerance)

func approxEqual(_ a: CGFloat, _ b: CGFloat, relTol: CGFloat = 1e-6, absTol: CGFloat = 1e-9) -> Bool {
    abs(a - b) <= max(absTol, relTol * max(abs(a), abs(b)))
}

func approxEqual(_ a: Double, _ b: Double, relTol: Double = 1e-9, absTol: Double = 1e-12) -> Bool {
    abs(a - b) <= max(absTol, relTol * max(abs(a), abs(b)))
}
