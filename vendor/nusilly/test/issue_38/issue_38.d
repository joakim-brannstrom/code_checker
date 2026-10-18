module issue_38;

import std.meta;

struct Foo
{

}

struct Bar
{

}

alias Types = AliasSeq!(Foo, Bar);

class Baz
{
    Types types;
}

@("ordinary case") unittest
{
    
}