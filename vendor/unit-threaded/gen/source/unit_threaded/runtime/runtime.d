/**
This module implements a $(LINK2 http://dlang.org/template-mixin.html,
template mixin) containing a program to search a list of directories
for all .d files therein, then writes a D program to run all unit
tests in those files using unit_threaded. The program
implemented by this mixin only writes out a D file that itself must be
compiled and run.

To use this as a runnable program, simply mix in and compile:
-----
#!/usr/bin/rdmd
import unit_threaded;
mixin genUtMain;
-----

Generally however, this code will be used by the gen_ut_main
dub configuration via `dub run`.

By default, genUtMain will look for unit tests in CWD
and write a program out to a temporary file. To change
the file to write to, use the $(D -f) option. To change what
directories to look in, simply pass them in as the remaining
command-line arguments.

The resulting file is also a program that must be compiled and, when
run, will run the unit tests found. By default, it will run all
tests. To run one test or all tests in a particular package, pass them
in as command-line arguments.  The $(D -h) option will list all
command-line options.

Examples (assuming the generated file is called $(D ut.d)):
-----
rdmd -unittest ut.d // run all tests
rdmd -unittest ut.d tests.foo tests.bar // run all tests from these packages
rdmd ut.d -h // list command-line options
-----
*/

module unit_threaded.runtime.runtime;

import unit_threaded.from;


mixin template genUtMain() {

    int main(string[] args) {
        try {
            writeUtMainFile(args);
            return 0;
        } catch(Exception ex) {
            import std.stdio: stderr;
            stderr.writeln(ex.msg);
            return 1;
        }
    }
}


struct Options {
    bool verbose;
    string fileName;
    string[] dirs;
    string dubBinary;
    bool help;
    bool showVersion;
    string[] includes;
    string[] files;

    bool earlyReturn() @safe pure nothrow const {
        return help || showVersion;
    }
}


Options getGenUtOptions(string[] args) {
    import std.getopt;
    import std.range: empty;
    import std.stdio: writeln;

    Options options;
    auto getOptRes = getopt(
        args,
        "verbose|v", "Verbose mode.", &options.verbose,
        "file|f", "The filename to write. Will use a temporary if not set.", &options.fileName,
        "dub|d", "The dub binary to use.", &options.dubBinary,
        "I", "Import paths as would be passed to the compiler", &options.includes,
        "version", "Show version.", &options.showVersion,
        );

    if (getOptRes.helpWanted) {
        defaultGetoptPrinter("Usage: gen_ut_main [options] [testDir1] [testDir2]...", getOptRes.options);
        options.help = true;
        return options;
    }

    if (options.showVersion) {
        writeln("unit_threaded.runtime version v0.6.1");
        return options;
    }

    options.dirs = args.length <= 1 ? ["."] : args[1 .. $];

    if (options.verbose) {
        writeln(__FILE__, ": finding all test cases in ", options.dirs);
    }

    if (options.dubBinary.empty) {
        options.dubBinary = "dub";
    }

    return options;
}


from!"std.file".DirEntry[] findModuleEntries(in Options options) {

    import std.algorithm: splitter, canFind, map, startsWith, filter;
    import std.array: array, empty;
    import std.file: DirEntry, isDir, dirEntries, SpanMode;
    import std.path: dirSeparator, buildNormalizedPath;
    import std.exception: enforce;

    // dub list of files, don't bother reading the filesystem since
    // dub has done it already
    if(!options.files.empty && options.dirs == ["."]) {
        return dubFilesToAbsPaths(options.fileName, options.files)
            .map!toDirEntry
            .array;
    }

    DirEntry[] modules;
    foreach (dir; options.dirs) {
        enforce(isDir(dir), dir ~ " is not a directory name");
        auto entries = dirEntries(dir, "*.d", SpanMode.depth);
        auto normalised = entries.map!(a => buildNormalizedPath(a.name));

        bool isHiddenDir(string p) { return p.startsWith("."); }
        bool anyHiddenDir(string p) { return p.splitter(dirSeparator).canFind!isHiddenDir; }

        modules ~= normalised.
            filter!(a => !anyHiddenDir(a)).
            map!toDirEntry.array;
    }

    return modules;
}

auto toDirEntry(string a) {
    import std.file: DirEntry;
    return DirEntry(removePackage(a));
}

// package.d files will show up as foo.bar.package
// remove .package from the end
string removePackage(string name) {
    import std.algorithm: endsWith;
    import std.array: replace;
    enum toRemove = "/package.d";
    return name.endsWith(toRemove)
        ? name.replace(toRemove, "")
        : name;
}


string[] dubFilesToAbsPaths(in string fileName, in string[] files) {
    import std.algorithm: filter, map;
    import std.array: array;
    import std.path: buildNormalizedPath;

    // dub list of files, don't bother reading the filesystem since
    // dub has done it already
    return files
        .filter!(a => a != fileName)
        .map!(a => removePackage(a))
        .map!(a => buildNormalizedPath(a))
        .array;
}



string[] findModuleNames(in Options options) {
    import std.path : dirSeparator, stripExtension, absolutePath, relativePath;
    import std.algorithm: endsWith, startsWith, filter, map;
    import std.array: replace, array;
    import std.path: baseName, absolutePath;

    // if a user passes -Isrc and a file is called src/foo/bar.d,
    // the module name should be foo.bar, not src.foo.bar,
    // so this function subtracts import path options
    string relativeToImportDirs(string path) {
        foreach(string importPath; options.includes) {
            importPath = relativePath(importPath);
            if(!importPath.endsWith(dirSeparator)) importPath ~= dirSeparator;
            if(path.startsWith(importPath)) {
                return path.replace(importPath, "");
            }
        }

        return path;
    }

    return findModuleEntries(options).
        filter!(a => a.baseName != "reggaefile.d").
        filter!(a => a.absolutePath != options.fileName.absolutePath).
        map!(a => relativeToImportDirs(a.name)).
        map!(a => replace(a.stripExtension, dirSeparator, ".")).
        array;
}

string writeUtMainFile(string[] args) {
    auto options = getGenUtOptions(args);
    return writeUtMainFile(options);
}

string writeUtMainFile(Options options) {
    if (options.earlyReturn) {
        return options.fileName;
    }

    return writeUtMainFile(options, findModuleNames(options));
}

private string writeUtMainFile(Options options, in string[] modules) {
    import std.path: buildPath, dName = dirName;
    import std.stdio: writeln, File;
    import std.file: tempDir, getcwd, mkdirRecurse, exists;
    import std.algorithm: map;
    import std.array: join;
    import std.format : format;

    if (!options.fileName) {
        options.fileName = buildPath(tempDir, getcwd[1..$], "ut.d");
    }

    if(!haveToUpdate(options, modules)) {
        if(options.verbose) writeln("Not writing to ", options.fileName, ": no changes detected");
        return options.fileName;
    } else {
        if(options.verbose) writeln("Writing to unit test main file ", options.fileName);
    }

    const dirName = options.fileName.dName;
    dirName.exists || mkdirRecurse(dirName);


    auto wfile = File(options.fileName, "w");
    wfile.write(modulesDbList(modules));
    wfile.writeln(format(q{
//Automatically generated by unit_threaded.gen_ut_main, do not edit by hand.
import unit_threaded.runner : runTestsMain;

mixin runTestsMain!(%(%s, %));
}, modules));
    wfile.close();

    return options.fileName;
}


private bool haveToUpdate(in Options options, in string[] modules) {
    import std.file: exists;
    import std.stdio: File;
    import std.array: join;
    import std.string: strip;

    if (!options.fileName.exists) {
        return true;
    }

    auto file = File(options.fileName);
    return file.readln.strip != modulesDbList(modules);
}


//used to not update the file if the file list hasn't changed
private string modulesDbList(in string[] modules) @safe pure nothrow {
    import std.array: join;
    return "//" ~ modules.join(",");
}
