. $TESTSUITE/common.sh

# with --fail-fast, must stop at the first error
OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours --threads=1 --fail-fast 2>&1 || true)

echo "$OUTPUT" | grep -c  "✓ error test ok" > /dev/null
echo "$OUTPUT" | grep -c  "✗ error assert failing" > /dev/null
echo "$OUTPUT" | grep -c  "core\.exception\.AssertError" > /dev/null
echo "$OUTPUT" | grep -cv "✗ error throw Exception" > /dev/null
echo "$OUTPUT" | grep -c  "object\.Exception thrown"  > /dev/null
echo "$OUTPUT" | grep -cv "✗ error throw Error" > /dev/null
echo "$OUTPUT" | grep -c  "core\.exception\.RangeError"  > /dev/null
echo "$OUTPUT" | grep -cv "Summary: 1 passed, 3 failed"   > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/error-test-unittest


# without --fail-fast, executes all tests
OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours --threads=1 2>&1 || true)

echo "$OUTPUT" | grep -c  "✓ error test ok" > /dev/null
echo "$OUTPUT" | grep -c  "✗ error assert failing" > /dev/null
echo "$OUTPUT" | grep -c  "core\.exception\.AssertError" > /dev/null
echo "$OUTPUT" | grep -cv "✗ error throw Exception" > /dev/null
echo "$OUTPUT" | grep -c  "object\.Exception thrown"  > /dev/null
echo "$OUTPUT" | grep -cv "✗ error throw Error" > /dev/null
echo "$OUTPUT" | grep -c  "core\.exception\.RangeError"  > /dev/null
echo "$OUTPUT" | grep -cv "✗ error throw OutOfMemoryError" > /dev/null
echo "$OUTPUT" | grep -c  "core\.exception\.OutOfMemoryError"  > /dev/null
echo "$OUTPUT" | grep -c  "✓ error test that not should be executed" > /dev/null
echo "$OUTPUT" | grep -cv "Summary: 2 passed, 4 failed"   > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/error-test-unittest
