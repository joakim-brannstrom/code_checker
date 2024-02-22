#!/usr/bin/env bash

COMPILER_VERSION=$(command -v dmd >/dev/null 2>&1 && dmd --version | head -n1 || ldc2 --version | head -n1)

. $(dirname "${BASH_SOURCE[0]}")/common.sh

log "Compiler: $COMPILER_VERSION"
log "Dub     : $(dub --version | head -n1)"
log "System  : $(uname -a)"
echo

TESTSUITE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

SOMETHING_FAILED=0

rm -rf $TESTSUITE/.coverage
mkdir -p $TESTSUITE/.coverage

for test in $(ls -vd $TESTSUITE/*/); do
	log Performing test $(basename $test)...

	if TESTSUITE=$TESTSUITE ${test}test.sh; then
		true
	else
		SOMETHING_FAILED=1
		logError "Command failed"
	fi
done

exit ${SOMETHING_FAILED:-0}
