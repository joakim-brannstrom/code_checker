#!/usr/bin/env rdmd

import std.file;

void main(string[] args) {
    copy("orig.json", "compile_commands.json");
}
