/**
 A module with tests to test the compile-time reflection
 */

module unit_threaded.ut.modules.module_with_tests;

import unit_threaded.runner.attrs;

import std.meta;
import unit_threaded.should;

//test functions
void testFoo() {}
void testBar() {}
private void testPrivate() { } //should not show up

//non-test functions
private void someFun() {}
private void testosterone() {}
private void tes() {}

//non-test non-functions
int testInt;

//non-test classes
class NotATest { void tes() { } }
class AlsoNotATest { void testosterone() { } }

@HiddenTest void withHidden() {}
void withoutHidden() { }

//other non-test members
alias seq = AliasSeq!(int, float, string);


unittest {
    //1st block
    assert(true);
}

unittest {
    //2nd block
    assert(true);
}

@Name("myUnitTest")
unittest {
    assert(true);
}

struct StructWithUnitTests{
    alias SelfSoDontRecurseForever = StructWithUnitTests;

    @Name("InStruct")
    unittest{
        assert(false);
    }
    unittest{
        // 2nd inner block.
        assert(true);
    }
}

// github issue #26 - template instance GetTypes!uint does not match template declaration
alias RGB = uint;
