# colorlog

**colorlog** is a logger implementation of the interface for
`std.experimental.logger` that supports coloring the messages.

# Usage

The simples way to use **colorlog** is to call the config function. It takes
care of creating a shared logger instance and registering it.

```d
import colorlog;
// set the loglevel to info and register a SimpleLogger.
confLogger(VerboseMode.info);
```

Messages from logger will now have there loglevel colored. If additional
coloring is desired the message can be manually colored.
```d
logger.info("foo", "my message".color(Color.green).bg(Background.cyan).mode(Mode.bold));
```

# Credit

Credit goes to the developers of dub. A significant part of the color handling
is copied from that project.

Credit also goes to the developer of colorize for the inspiration.
