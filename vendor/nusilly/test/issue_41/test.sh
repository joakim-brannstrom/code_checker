. $TESTSUITE/common.sh

OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours 2>&1)

echo "$OUTPUT" | grep -c "✓ issue_41 normal unittest" > /dev/null
echo "$OUTPUT" | grep -c "✓ issue_41.Foo root class" > /dev/null
echo "$OUTPUT" | grep -c "✓ issue_41.Foo.Bar nested static class" > /dev/null
echo "$OUTPUT" | grep -c "✓ issue_41.Foo.Baz nested class" > /dev/null
echo "$OUTPUT" | grep -c "Summary: 4 passed, 0 failed" > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/issue_41-test-unittest
