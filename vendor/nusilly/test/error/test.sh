. $TESTSUITE/common.sh

OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours --threads=1 2>&1 || true)

echo "$OUTPUT" | grep -c  "✓ error 1" > /dev/null
echo "$OUTPUT" | grep -c  "✗ error 2" > /dev/null
echo "$OUTPUT" | grep -c  "core\.exception\.AssertError" > /dev/null
echo "$OUTPUT" | grep -cv "✗ error 3" > /dev/null
echo "$OUTPUT" | grep -c  "core\.exception\.RangeError"  > /dev/null
echo "$OUTPUT" | grep -cv "✓ error 4" > /dev/null
echo "$OUTPUT" | grep -cv "Summary"   > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/error-test-unittest