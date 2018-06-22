#!/bin/bash

set -e

dub build

pushd test
dub test
popd
