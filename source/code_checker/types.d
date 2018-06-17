/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module code_checker.types;

@safe:

/// No guarantee regarding the path. May be absolute, relative, contain a '~'.
/// The user of this type must do all the safety checks to ensure that the
/// datacontained in valid.
struct Path {
    string payload;
    alias payload this;
}

/// ditto
struct DirName {
    Path payload;
    alias payload this;

    pure nothrow @nogc this(string p) {
        payload = Path(p);
    }
}

/// ditto
struct FileName {
pure @nogc nothrow:

    Path payload;
    alias payload this;

    this(Path p) {
        payload = p;
    }

    pure nothrow @nogc this(string p) {
        payload = Path(p);
    }
}

/** The path is guaranteed to be the absolute path.
 *
 * The user of the type has to make an explicit judgment when using the
 * assignment operator. Either a `Path` and then pay the cost of the path
 * expansion or an absolute which is already assured to be _ok_.
 * This divides the domain in two, one unchecked and one checked.
 */
struct AbsolutePath {
    import std.path : expandTilde, buildNormalizedPath;

    Path payload;
    alias payload this;

    invariant {
        import std.path : isAbsolute;

        assert(payload.length == 0 || payload.isAbsolute);
    }

    this(AbsolutePath p) {
        this.payload = p.payload;
    }

    this(Path p) {
        auto p_expand = () @trusted{ return p.expandTilde; }();
        // the second buildNormalizedPath is needed to correctly resolve "."
        // otherwise it is resolved to /foo/bar/.
        payload = buildNormalizedPath(p_expand).asAbsNormPath.Path;
    }

    /// Build the normalised path from workdir.
    this(FileName p, DirName workdir) {
        auto p_expand = () @trusted{ return p.expandTilde; }();
        auto workdir_expand = () @trusted{ return workdir.expandTilde; }();
        // the second buildNormalizedPath is needed to correctly resolve "."
        // otherwise it is resolved to /foo/bar/.
        payload = buildNormalizedPath(workdir_expand, p_expand).asAbsNormPath.Path;
    }

    void opAssign(Path p) {
        payload = p;
    }

    void opAssign(AbsolutePath p) pure nothrow @nogc {
        payload = p.payload;
    }

    FileName opCast(T : FileName)() pure nothrow @nogc {
        return FileName(payload);
    }

    Path opCast(T : Path)() @safe pure nothrow const @nogc scope {
        return payload;
    }

    string opCast(T : string)() pure nothrow @nogc {
        return payload;
    }
}

struct AbsoluteFileName {
    AbsolutePath payload;
    alias payload this;

    pure nothrow @nogc this(AbsolutePath p) {
        payload = p;
    }
}

struct AbsoluteDirectory {
    AbsolutePath payload;
    alias payload this;

    pure nothrow @nogc this(AbsolutePath p) {
        payload = p;
    }
}

/** During construction checks that the file exists on the filesystem.
 *
 * If it doesn't exist it will throw an Exception.
 */
struct Exists(T) {
    AbsolutePath payload;
    alias payload this;

    this(AbsolutePath p) {
        import std.file : exists, FileException;

        if (!exists(p)) {
            throw new FileException("File do not exist: " ~ cast(string) p);
        }

        payload = p;
    }

    this(Exists!T p) {
        payload = p.payload;
    }

    void opAssign(Exists!T p) pure nothrow @nogc {
        payload = p;
    }
}

auto makeExists(T)(T p) {
    return Exists!T(p);
}

@("shall always be the absolute path")
unittest {
    import std.algorithm : canFind;
    import std.path;
    import unit_threaded;

    AbsolutePath(FileName("~/foo")).canFind('~').shouldEqual(false);
    AbsolutePath(FileName("foo")).isAbsolute.shouldEqual(true);
}

@("shall expand . without any trailing /.")
unittest {
    import std.algorithm : canFind;
    import unit_threaded;

    AbsolutePath(FileName(".")).canFind('.').shouldBeFalse;
    AbsolutePath(FileName("."), DirName(".")).canFind('.').shouldBeFalse;
}

@("shall be an instantiation of Exists")
nothrow unittest {
    // the file is not expected to exist.

    try {
        auto p = makeExists(AbsolutePath(FileName("foo")));
    } catch (Exception e) {
    }
}

private:

string asAbsNormPath(string path) @trusted {
    import std.path;
    import std.conv : to;

    return to!string(path.asAbsolutePath.asNormalizedPath);
}
