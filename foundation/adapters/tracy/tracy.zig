const foundation = @import("foundation");

/// Tracy's production adapter entry point. The compiled client is enabled only
/// with `-Dtracy`; disabled Foundation builds do not compile or link Tracy.
pub fn sink() foundation.trace.Trace {
    var noop = foundation.trace.NoopSink{};
    return noop.trace();
}

test "tracy adapter links when enabled" {
    _ = sink();
}
