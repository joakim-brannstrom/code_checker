. $TESTSUITE/common.sh

OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours 2>&1)

echo "$OUTPUT" | grep -c "✓ include_exclude aabbaa" > /dev/null
echo "$OUTPUT" | grep -c "✓ include_exclude aabbbb" > /dev/null
echo "$OUTPUT" | grep -c "✓ include_exclude bbaabb" > /dev/null
echo "$OUTPUT" | grep -c "✓ include_exclude aaaaaa" > /dev/null
echo "$OUTPUT" | grep -c "✓ include_exclude AAAAAA" > /dev/null
echo "$OUTPUT" | grep -c "✓ include_exclude BBBBBB" > /dev/null
echo "$OUTPUT" | grep -c "✓ include_exclude FOO"    > /dev/null
echo "$OUTPUT" | grep -c "✓ include_exclude BAR"    > /dev/null
echo "$OUTPUT" | grep -c "✓ include_exclude FOOBAR" > /dev/null
echo "$OUTPUT" | grep -c "✓ include_exclude BARFOO" > /dev/null
echo "$OUTPUT" | grep -c "Summary: 10 passed, 0 failed" > /dev/null

EXEC=$(dirname "${BASH_SOURCE[0]}")/include_exclude-test-unittest

$EXEC --no-colours --include "^include_exclude" | grep -c "Summary: 10 passed, 0 failed" > /dev/null
$EXEC --no-colours --exclude "^include_exclude" | grep -c "Summary: 0 passed, 0 failed" > /dev/null

$EXEC --no-colours --include "[Aa]{6}" | grep -c "✓ include_exclude aaaaaa"    > /dev/null
$EXEC --no-colours --include "[Aa]{6}" | grep -c "✓ include_exclude AAAAAA"    > /dev/null
$EXEC --no-colours --include "[Aa]{6}" | grep -c "Summary: 2 passed, 0 failed" > /dev/null

$EXEC --no-colours --include "aa$"     | grep -c "✓ include_exclude aabbaa"    > /dev/null
$EXEC --no-colours --include "aa$"     | grep -c "✓ include_exclude aaaaaa"    > /dev/null
$EXEC --no-colours --include "aa$"     | grep -c "Summary: 2 passed, 0 failed" > /dev/null

$EXEC --no-colours --exclude "BAR"     | grep -c "Summary: 7 passed, 0 failed" > /dev/null
$EXEC --no-colours --exclude "BAR$"    | grep -c "Summary: 8 passed, 0 failed" > /dev/null
$EXEC --no-colours --exclude ".* BAR"  | grep -c "Summary: 8 passed, 0 failed" > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/include_exclude-test-unittest