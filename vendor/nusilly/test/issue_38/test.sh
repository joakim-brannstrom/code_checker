. $TESTSUITE/common.sh

OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours 2>&1)

echo "$OUTPUT" | grep -c  "✓ issue_38 ordinary case"    > /dev/null
echo "$OUTPUT" | grep -c  "Summary: 1 passed, 0 failed" > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/issue_38-test-unittest
