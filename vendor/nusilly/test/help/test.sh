. $TESTSUITE/common.sh

OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours --help 2>&1)

echo "$OUTPUT" | grep -ce "--no-colours" > /dev/null
echo "$OUTPUT" | grep -ce "--threads" > /dev/null
echo "$OUTPUT" | grep -ce "--include" > /dev/null
echo "$OUTPUT" | grep -ce "--exclude" > /dev/null
echo "$OUTPUT" | grep -ce "--verbose" > /dev/null
echo "$OUTPUT" | grep -ce "--help" > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/help-test-unittest