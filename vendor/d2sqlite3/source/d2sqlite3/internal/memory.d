/+
This module is part of d2sqlite3.

Authors:
    Nicolas Sicard (biozic) and other contributors at $(LINK https://github.com/biozic/d2sqlite3)

Copyright:
    Copyright 2011-18 Nicolas Sicard.

License:
    $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module d2sqlite3.internal.memory;

import std.traits : isFunctionPointer, isDelegate, isCallable;
import core.memory : GC;
import core.stdc.stdlib : malloc, free;

package(d2sqlite3):

struct WrappedDelegate(T)
{
    T dlg;
    string name;
}

void* delegateWrap(T)(T dlg, string name = null) nothrow
    if (isFunctionPointer!T || isDelegate!T)
{
    import std.functional : toDelegate;

    if (dlg is null)
        return null;

    alias D = typeof(toDelegate(dlg));
    auto d = cast(WrappedDelegate!D*) malloc(WrappedDelegate!D.sizeof);
    d.dlg = toDelegate(dlg);
    d.name = name;
    return cast(void*) d;
}

WrappedDelegate!T* delegateUnwrap(T)(void* ptr) nothrow
    if (isCallable!T)
{
    return cast(WrappedDelegate!T*) ptr;
}

// Anchors and returns a pointer to D memory, so that it will not
// be moved or collected. For use with releaseMem.
inout(void)* anchorMem(inout(void)* ptr)
{
    GC.addRoot(ptr);
    // Cast to work around https://issues.dlang.org/show_bug.cgi?id=21484
    GC.setAttr(cast(void*) ptr, GC.BlkAttr.NO_MOVE);
    return ptr;
}

// Passed to sqlite3_xxx_blob64/sqlite3_xxx_text64 to unanchor memory.
extern(C) void releaseMem(const void* ptr)
{
    // Cast to work around https://issues.dlang.org/show_bug.cgi?id=21484
    GC.setAttr(cast(void*) ptr, GC.BlkAttr.NO_MOVE);
    GC.removeRoot(ptr);
}

// Adapted from https://p0nce.github.io/d-idioms/#GC-proof-resource-class
void ensureNotInGC(T)(string info = null) nothrow
{
    import core.memory : GC;
    import core.stdc.stdio : fprintf, stderr;
    import core.stdc.stdlib : exit;

    if (!GC.inFinalizer)
        return;

    fprintf(stderr,
            "Error: clean-up of %s incorrectly depends on destructors called by the GC.\n",
            T.stringof.ptr);
    if (info)
        fprintf(stderr, "Info: %s\n", info.ptr);
    assert(false);
}
