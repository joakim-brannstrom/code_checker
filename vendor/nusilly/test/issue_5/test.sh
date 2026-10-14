. $TESTSUITE/common.sh

OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours 2>&1)

echo "$OUTPUT" | grep -c "✓ issue_5 __unittest_L5_C1" > /dev/null
echo "$OUTPUT" | grep -c "Summary: 1 passed, 0 failed" > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/issue_5-test-unittest