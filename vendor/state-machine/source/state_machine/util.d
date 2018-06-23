module state_machine.util;

import std.string;

@property string toTitle(string input) {
    if (input.length == 0) {
        return input;
    } else {
        return input[0 .. 1].toUpper ~ input[1 .. $];
    }
}
