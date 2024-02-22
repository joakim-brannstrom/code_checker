module issue_29;

@("ordinary case") unittest
{

}

mixin template Foo(string name)
{
    @(name) unittest
    {

    }
}

mixin Foo!("test name");
