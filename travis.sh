#!/bin/bash

set -e

dub test
dub build

pushd test
# the tests do not support running in parallel
dub test -- -s
popd
