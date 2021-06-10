module unit_threaded.ut.integration;

import unit_threaded.integration;

@safe unittest {
    auto sb = Sandbox();
    assert(sb.testPath != "");
}

@safe unittest {
    import std.file: exists, rmdirRecurse;
    import std.path: buildPath;
    import unit_threaded.should;

    Sandbox.sandboxesPath.shouldEqual(Sandbox.defaultSandboxesPath);

    immutable newPath = buildPath("foo", "bar", "baz");
    assert(!newPath.exists);
    Sandbox.setPath(newPath);
    assert(newPath.exists);
    scope(exit) () @trusted { rmdirRecurse("foo"); }();
    Sandbox.sandboxesPath.shouldEqual(newPath);

    with(immutable Sandbox()) {
        writeFile("newPath.txt");
        assert(buildPath(newPath, testPath, "newPath.txt").exists);
    }

    Sandbox.resetPath;
    Sandbox.sandboxesPath.shouldEqual(Sandbox.defaultSandboxesPath);
}


@safe unittest {
    import std.file: exists;
    import std.path: buildPath;

    with(immutable Sandbox()) {
        assert(!buildPath(testPath, "foo.txt").exists);
        writeFile("foo.txt");
        assert(buildPath(testPath, "foo.txt").exists);
    }
}

@safe unittest {
    import std.file: exists;
    import std.path: buildPath;

    with(immutable Sandbox()) {
        writeFile("foo/bar.txt");
        assert(buildPath(testPath, "foo", "bar.txt").exists);
    }
}

@safe unittest {
    with(immutable Sandbox()) {
        import unit_threaded.should;

        shouldExist("bar.txt").shouldThrow;
        writeFile("bar.txt");
        shouldExist("bar.txt");
    }
}

@safe unittest {
    with(immutable Sandbox()) {
        import unit_threaded.should;

        shouldNotExist("baz.txt");
        writeFile("baz.txt");
        shouldNotExist("baz.txt").shouldThrow;
    }
}


@safe unittest {
    with(immutable Sandbox()) {
        import unit_threaded.should;

        writeFile("lines.txt", ["foo", "toto"]);
        shouldEqualLines("lines.txt", ["foo", "bar"]).shouldThrow;
        shouldEqualLines("lines.txt", ["foo", "toto"]);
    }
}

version(Windows) {
    @safe unittest {
        with(immutable Sandbox()) {
            writeFile("newline.txt", "\r\n");
            shouldEqualContent("newline.txt", "\r\n\n");
        }
    }
}

@safe unittest {
    with(immutable Sandbox()) {
        import unit_threaded.should;

        shouldSucceed("definitely_not_an_existing_command_or_executable").shouldThrow;
        shouldFail("definitely_not_an_existing_command_or_executable");

        writeFile("hello.d", q{import std; void main() {writeln("hello");}});
        shouldExecuteOk(["dmd", inSandboxPath("hello.d")]);
        version (Windows)
            immutable exe = "hello.exe";
        else
            immutable exe = "hello";
        shouldSucceed(inSandboxPath(exe));
        shouldFail(inSandboxPath(exe)).shouldThrow;
    }
}
