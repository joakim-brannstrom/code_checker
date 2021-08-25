module unit_threaded.ut.factory;


import unit_threaded.runner.factory;


unittest {
    import unit_threaded.runner.reflection: TestData;
    //existing, wanted
    assert(isWantedTest(TestData("", "tests.server.testSubscribe"), ["tests"]));
    assert(isWantedTest(TestData("", "tests.server.testSubscribe"), ["tests."]));
    assert(isWantedTest(TestData("", "tests.server.testSubscribe"), ["tests.server.testSubscribe"]));
    assert(!isWantedTest(TestData("", "tests.server.testSubscribe"), ["tests.server.testSubscribeWithMessage"]));
    assert(!isWantedTest(TestData("", "tests.stream.testMqttInTwoPackets"), ["tests.server"]));
    assert(isWantedTest(TestData("", "tests.server.testSubscribe"), ["tests.server"]));
    assert(isWantedTest(TestData("", "pass_tests.testEqual"), ["pass_tests"]));
    assert(isWantedTest(TestData("", "pass_tests.testEqual"), ["pass_tests.testEqual"]));
    assert(isWantedTest(TestData("", "pass_tests.testEqual"), []));
    assert(!isWantedTest(TestData("", "pass_tests.testEqual"), ["pass_tests.foo"]));
    assert(!isWantedTest(TestData("", "example.tests.pass.normal.unittest"),
                         ["example.tests.pass.io.TestFoo"]));
    assert(isWantedTest(TestData("", "example.tests.pass.normal.unittest"), []));
    assert(!isWantedTest(TestData("", "tests.pass.attributes.testHidden", null, true /*hidden*/), ["tests.pass"]));
    assert(!isWantedTest(TestData("", "", null, false /*hidden*/, false /*shouldFail*/, false /*singleThreaded*/,
                                  false /*builtin*/, "" /*suffix*/),
                         ["@foo"]));
    assert(isWantedTest(TestData("", "", null, false /*hidden*/, false /*shouldFail*/, false /*singleThreaded*/,
                                 false /*builtin*/, "" /*suffix*/, ["foo"]),
                        ["@foo"]));

    assert(!isWantedTest(TestData("", "", null, false /*hidden*/, false /*shouldFail*/, false /*singleThreaded*/,
                                 false /*builtin*/, "" /*suffix*/, ["foo"]),
                        ["~@foo"]));

    assert(isWantedTest(TestData("", "", null, false /*hidden*/, false /*shouldFail*/, false /*singleThreaded*/,
                                  false /*builtin*/, "" /*suffix*/),
                         ["~@foo"]));

    assert(isWantedTest(TestData("", "", null, false /*hidden*/, false /*shouldFail*/, false /*singleThreaded*/,
                                 false /*builtin*/, "" /*suffix*/, ["bar"]),
                         ["~@foo"]));

    // if hidden, don't run by default
    assert(!isWantedTest(TestData("", "", null, true /*hidden*/, false /*shouldFail*/, false /*singleThreaded*/,
                                  false /*builtin*/, "" /*suffix*/, ["bar"]),
                        ["~@foo"]));

    TestData suffixData;
    suffixData.name = "foo.bar.types";
    suffixData.suffix = "int";
    assert(isWantedTest(suffixData, ["foo.bar.types.int"]));
}


@("issue242")
@safe unittest {
    import unit_threaded.asserts;
    import unit_threaded.runner.reflection;
    import unit_threaded.runner.testcase;
    import unit_threaded.ut.modules.issue242;
    import std.algorithm: map;
    import std.array: array;
    import std.algorithm: sorted = sort;

    const testData = moduleUnitTests!(unit_threaded.ut.modules.issue242);
    const tests = createTestCases(testData);
    // only one composite test case should be created
    assertEqual(tests.length, 1);

    auto composite = cast(const CompositeTestCase) tests[0];
    assert(composite !is null);
}
