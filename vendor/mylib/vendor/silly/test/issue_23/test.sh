. $TESTSUITE/common.sh

OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours 2>&1)

echo "$OUTPUT" | grep -c  "✓ issue_23 test name"        > /dev/null
echo "$OUTPUT" | grep -cv "this is ignored"             > /dev/null
echo "$OUTPUT" | grep -cv "customUDA"                   > /dev/null
echo "$OUTPUT" | grep -cv "custom uda"                  > /dev/null
echo "$OUTPUT" | grep -cv "customStructUDA"             > /dev/null
echo "$OUTPUT" | grep -c  "Summary: 1 passed, 0 failed" > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/issue_23-test-unittest