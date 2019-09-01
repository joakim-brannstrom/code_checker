# Testing

A developer of `code_checker` that wants to run the tests.
```sh
dub test && dub run -c integration_test
```

Extra arguments can be passed to the integration test runner:
```sh
dub run -c integration_test -- -h
```

# Style

Use dfmt to format the file. The configuration is in `.editorconfig`.
