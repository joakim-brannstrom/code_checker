#!/usr/bin/env rdmd
/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
import core.stdc.stdlib;
import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.file;
import std.process;
import std.path;
import std.range;
import std.stdio;
import std.string;
import std.typecons;
import logger = std.experimental.logger;

int main(string[] args) {
    const string root = getcwd();
    const work_dir = buildPath(root, "output_latex");

    fixLatexTempDir(work_dir);
    prepareImages(work_dir);
    preparePlantuml([getcwd, "design"], work_dir);

    // dfmt off
    auto chapters = [
        "preamble.md",
        "design/use_case.md",
        "design/purpose.md",
        "design/analyze_engine.md",
        "reading_instructions.md",
        "license.md"
    ];
    // dfmt on

    auto data = constructPandocCommand(work_dir, chapters.map!(a => a.absolutePath).array);
    data.outputFile = "code_checker";

    chdir(work_dir);
    scope (exit)
        chdir(work_dir);

    pandoc(data);

    return 0;
}

void fixLatexTempDir(const string dir) {
    if (!exists(dir))
        mkdir(dir);

    foreach (file; dirEntries(dir, SpanMode.shallow).filter!(a => a.extension != ".pdf"))
        remove(file);
}

void prepareImages(const string dest_dir) {
    foreach (f; dirEntries(getcwd, SpanMode.shallow).filter!(a => a.extension.among(".png",
            ".jpg"))) {
        copy(f.name, buildPath(dest_dir, f.name.baseName));
    }
}

void preparePlantuml(const string[] search_in, const string dest_dir) {
    import std.algorithm : map, joiner;

    foreach (f; search_in.map!(search_dir => dirEntries(search_dir,
            SpanMode.shallow).filter!(a => a.extension.among(".pu", ".uml"))).joiner) {
        const dst = buildPath(dest_dir, f.name.baseName);
        if (exists(dst))
            writefln("WARNING: Multiple '%s' exists", dst);
        copy(f.name, dst);
        try {
            spawnProcess(["plantuml", "-teps", dst], null, Config.none, dest_dir).wait;
        } catch (Exception e) {
            logger.warning(e.msg);
        }
    }
}

auto constructPandocCommand(const string work_dir, string[] files) {
    auto r = Pandoc(files);

    foreach (a; [tuple(Meta.metadata, "metadata.yaml"), tuple(Meta.latexTemplate,
            "template.latex"), tuple(Meta.biblio, "references.bib")].filter!(a => exists(a[1]))) {
        r.meta[a[0]] = a[1].absolutePath;
        writefln("Using '%s' as %s", a[1], a[0]);
    }

    foreach (a; [tuple(Post.definitions, "definitions.md"), tuple(Post.abbrevations,
            "abbrevations.md"), tuple(Post.appendix, "appendix.md"),
            tuple(Post.references, "references.bib")].filter!(a => exists(a[1]))) {
        r.postChapters[a[0]] = a[1].absolutePath;
        writefln("Chapters to add to the end '%s' as %s", a[1], a[0]);
    }

    r.outputFile = absolutePath("result.pdf");

    return r;
}

enum Meta {
    metadata,
    latexTemplate,
    biblio,
}

enum Post {
    definitions,
    abbrevations,
    appendix,
    references,
}

struct Pandoc {
    string[Meta] meta;
    string[Post] postChapters;
    string outputFile;
    string[] files;

    this(string[] files) {
        this.files = files;
    }
}

void pandoc(Pandoc dat) {
    const temp_out = dat.outputFile.baseName.stripExtension;
    const temp_latex = temp_out ~ ".latex";
    const temp_pdf = temp_out ~ ".pdf";

    // dfmt off
    string[] cmd = ["pandoc",
          "-f", "markdown_github+citations+yaml_metadata_block+tex_math_dollars+pandoc_title_block+raw_tex",
          "-S",
          "--self-contained",
          "--toc",
          "-o", temp_latex];
    // dfmt on
    if (auto v = Meta.metadata in dat.meta)
        cmd ~= *v;
    if (auto v = Meta.latexTemplate in dat.meta)
        cmd ~= ["--template", *v];
    if (auto v = Meta.biblio in dat.meta) {
        cmd ~= ["--bibliography", *v];
        cmd ~= ["--natbib", "-M", "biblio-style=unsrtnat", "-M", "biblio-title=heading=none"];
    }

    cmd ~= dat.files;

    if (auto v = Post.definitions in dat.postChapters)
        cmd ~= *v;
    if (auto v = Post.abbrevations in dat.postChapters)
        cmd ~= *v;
    if (auto v = Post.appendix in dat.postChapters)
        cmd ~= *v;
    if (auto v = Post.references in dat.postChapters)
        cmd ~= *v;

    run(cmd);

    // generates the aux
    runInteractive(["pdflatex", temp_latex]);

    // generate first pass of the resolution of references
    try {
        if (Meta.biblio in dat.meta)
            runInteractive(["bibtex", temp_out ~ ".aux"]);
    } catch (Exception e) {
    }
    // resolve pass 1
    runInteractive(["pdflatex", temp_latex]);
    // resolve pass 2
    runInteractive(["pdflatex", temp_latex]);

    copy(temp_pdf, dat.outputFile);
}

void run(string[] cmd) {
    writeln("run: ", cmd.joiner(" "));
    auto res = execute(cmd);

    if (res.status != 0) {
        writeln(res.output);
        throw new Exception("Command failed");
    }
}

void runInteractive(string[] cmd) {
    writeln("run: ", cmd.joiner(" "));
    auto status = spawnProcess(cmd).wait;

    if (status != 0) {
        throw new Exception("Command failed");
    }
}
