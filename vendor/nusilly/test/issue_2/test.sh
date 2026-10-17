. $TESTSUITE/common.sh

OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours 2>&1 || true)

echo "$OUTPUT" | grep -c "✗ issue_2 Throwing an exception with multi-line message" > /dev/null
echo "$OUTPUT" | grep -c "Summary: 0 passed, 1 failed" > /dev/null
echo "$OUTPUT" | grep -cE "\s+Hello," > /dev/null
echo "$OUTPUT" | grep -cE "^\s+World!" > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/issue_2-test-unittest