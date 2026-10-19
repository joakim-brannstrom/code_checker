module code_checker.testing;

/// Marker UDA for unittests that must not run in parallel.
///
/// Nothing consumes it yet: the test runners execute every discovered
/// unittest without UDA support, so it is currently a no-op marker. Kept
/// so the serial-run requirement stays visible at the test sites.
/// (a struct because `enum Serial;` has no initializer, which is not
/// valid D)
struct Serial {
}
