/// DEBUG-time diagnostics for programmer-error conditions (set-after-present, double
/// attachment, provider returning a view inside the destination's own hierarchy, ...).
///
/// Unlike `precondition`/`fatalError`, these never crash a release build — Zoomy's own
/// design principle is "quiet fallback/no-op over crash" (see `docs/TECH_SPEC.md` §10). The
/// `handler` indirection also makes these conditions unit-testable: tests swap in a recording
/// closure instead of tripping `assertionFailure` (which would abort the test process in a
/// debug-configured test target).
enum ZoomyAssert {
    /// Test-replaceable handler. Default: DEBUG `assertionFailure` (itself a no-op when
    /// compiled without assertions, i.e. typical release builds).
    static var handler: (@MainActor (String) -> Void) = { message in
        assertionFailure(message)
    }

    @MainActor
    static func fail(_ message: String) {
        handler(message)
    }

    /// Unlike Swift's `precondition`, a false condition calls `handler` rather than crashing —
    /// callers keep running afterward (release: quiet no-op; tests: observable via `handler`).
    @MainActor
    static func precondition(_ condition: Bool, _ message: String) {
        if !condition {
            handler(message)
        }
    }
}
