module my.time;

import core.time : Duration;
import std.conv : text;

/// Formats a duration by tier: `0` → "0ms"; <1s → "<n>ms"; <60s → "<s>.<d>s"
/// (one decimal, truncating); <1h → "<m>m <s>s"; >=1h → "<h>h <m>m" (hours
/// unbounded). Negative values carry a leading minus, magnitude by the same tiers.
string prettyDuration(Duration d) pure nothrow {
    auto ms = d.total!"msecs";
    auto sign = "";
    if (ms < 0) {
        sign = "-";
        ms = -ms;
    }
    if (ms < 1000)
        return sign ~ text(ms, "ms");
    auto totalSeconds = ms / 1000;
    if (totalSeconds < 60) {
        auto sec = totalSeconds;
        auto tenths = (ms % 1000) / 100;
        return sign ~ text(sec, ".", tenths, "s");
    }
    if (totalSeconds < 3600) {
        auto min = totalSeconds / 60;
        auto sec = totalSeconds % 60;
        return sign ~ text(min, "m ", sec, "s");
    }
    auto hr = totalSeconds / 3600;
    auto min = (totalSeconds % 3600) / 60;
    return sign ~ text(hr, "h ", min, "m");
}

unittest {
    import std.datetime : dur;

    // ms tier + boundaries
    assert(prettyDuration(0.dur!"msecs") == "0ms");
    assert(prettyDuration(999.dur!"msecs") == "999ms");
    // s tier (one decimal, truncating) + boundaries
    assert(prettyDuration(1000.dur!"msecs") == "1.0s");
    assert(prettyDuration(1099.dur!"msecs") == "1.0s");
    assert(prettyDuration(1100.dur!"msecs") == "1.1s");
    assert(prettyDuration(1200.dur!"msecs") == "1.2s");
    assert(prettyDuration(59999.dur!"msecs") == "59.9s");
    // m tier + boundary
    assert(prettyDuration(60000.dur!"msecs") == "1m 0s");
    assert(prettyDuration(90000.dur!"msecs") == "1m 30s");
    assert(prettyDuration(3599999.dur!"msecs") == "59m 59s");
    // h tier, hours unbounded + boundary
    assert(prettyDuration(3600000.dur!"msecs") == "1h 0m");
    assert(prettyDuration(7200000.dur!"msecs") == "2h 0m");
    assert(prettyDuration(193.dur!"minutes") == "3h 13m");
    // negatives: leading minus, same tiers on the magnitude
    assert(prettyDuration(-999.dur!"msecs") == "-999ms");
    assert(prettyDuration(-1200.dur!"msecs") == "-1.2s");
    assert(prettyDuration(-60000.dur!"msecs") == "-1m 0s");
    assert(prettyDuration(-3600000.dur!"msecs") == "-1h 0m");
}
