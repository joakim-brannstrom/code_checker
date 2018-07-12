/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

For the design see $(LINK2 doc/design/analyze_engine.md, Analyze Engine).
*/
module code_checker.engine;

public import code_checker.engine.types : Environment, Status, Severity;
public import code_checker.engine.registry;
public import code_checker.engine.builtin.clang_tidy;
