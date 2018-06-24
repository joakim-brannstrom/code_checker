module state_machine.base;

/// State machine using an integer or string state variable.
mixin template StateMachine(alias variable, states...)
        if (((is(typeof(variable) : int) || is(typeof(variable) : string)) && states.length > 0)
            || (is(typeof(variable) == enum) && states.length == 0)) {
    import state_machine.util;

    import std.algorithm;
    import std.meta;
    import std.traits;

    private {
        static if (is(typeof(variable()))) {
            // For properties, .stringof ends with parentheses.
            enum __name__ = variable.stringof[0 .. $ - 2];
        } else {
            enum __name__ = variable.stringof;
        }

        static if (is(typeof(variable) == enum)) {
            // States on enum types are derived from their members.
            enum __states__ = __traits(allMembers, typeof(variable));
        } else {
            enum __states__ = states;
        }

        struct BeforeTransition {
            string state;
        }

        struct AfterTransition {
            string state;
        }

        typeof(variable) __prevState__;
    }

    @property static string[] opDispatch(string op : __name__ ~ "Names")() {
        return [__states__];
    }

    @property static typeof(variable)[string] opDispatch(string op : __name__ ~ "Values")() {
        typeof(variable)[string] values;

        static if (is(typeof(variable) == enum)) {
            foreach (string state; __states__) {
                values[state] = __traits(getMember, typeof(variable), state);
            }
        } else static if (is(typeof(variable) : int)) {
            foreach (typeof(variable) index, string state; __states__) {
                values[state] = index;
            }
        } else {
            foreach (string state; __states__) {
                // The most useful.
                values[state] = state;
            }
        }

        return values;
    }

    @property bool opDispatch(string state)()
            if ([__states__].countUntil(state) != -1) {
        // Compare state variable.
        static if (is(typeof(variable) == enum)) {
            return variable == __traits(getMember, typeof(variable), state);
        } else static if (is(typeof(variable) : int)) {
            // Ensure countUntil happens at compile-time.
            enum index = [__states__].countUntil(state);
            return variable == index;
        } else {
            return variable == state;
        }
    }

    typeof(variable) opDispatch(string op : "prev" ~ __name__)() {
        return __prevState__;
    }

    void opDispatch(string op : "revert" ~ __name__)() {
        variable = __prevState__;
    }

    bool opDispatch(string op)()
            if (op.length > 2 && op[0 .. 2] == "to"
                && [__states__].map!toTitle.countUntil(op[2 .. $]) != -1) {
        enum index = [__states__].map!toTitle.countUntil(op[2 .. $]);

        // Fire and check any BeforeTransition callbacks.
        foreach (name; __traits(allMembers, typeof(this))) {
            alias member = Alias!(__traits(getMember, typeof(this), name));

            static if (is(typeof(member) == function)) {
                static if (arity!member <= 1) {
                    foreach (attribute; __traits(getAttributes, member)) {
                        static if (is(attribute == BeforeTransition)
                                || (is(typeof(attribute) == BeforeTransition)
                                    && attribute.state == __states__[index])) {
                            static if (is(typeof(member()) : bool)) {
                                static if (arity!member == 1) {
                                    // Callback can accept destination state.
                                    bool result = member(__states__[index]);
                                } else {
                                    bool result = member();
                                }

                                if (!result) {
                                    return false;
                                }
                            } else {
                                static if (arity!member == 1) {
                                    member(__states__[index]);
                                } else {
                                    member();
                                }
                            }
                        }
                    }
                }
            }
        }

        // Save previous state.
        __prevState__ = variable;

        // Update state variable.
        static if (is(typeof(variable) == enum)) {
            enum string constant = __states__[index];
            variable = __traits(getMember, typeof(variable), constant);
        } else static if (is(typeof(variable) : int)) {
            variable = index;
        } else {
            variable = __states__[index];
        }

        // Fire any AfterTransition callbacks.
        foreach (name; __traits(allMembers, typeof(this))) {
            alias member = Alias!(__traits(getMember, typeof(this), name));

            static if (is(typeof(member) == function)) {
                static if (arity!member <= 1) {
                    foreach (attribute; __traits(getAttributes, member)) {
                        static if (is(attribute == AfterTransition)
                                || (is(typeof(attribute) == AfterTransition)
                                    && attribute.state == __states__[index])) {
                            static if (arity!member == 1) {
                                // Callback can accept destination state.
                                member(__states__[index]);
                            } else {
                                member();
                            }
                        }
                    }
                }
            }
        }

        return true;
    }
}
