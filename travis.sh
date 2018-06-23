#!/bin/bash

set -e

dub test
dub build

pushd test
dub test
popd
