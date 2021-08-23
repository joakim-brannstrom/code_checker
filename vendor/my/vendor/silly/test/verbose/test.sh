. $TESTSUITE/common.sh

OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours --verbose 2>&1 || true)

echo "$OUTPUT" | grep -cE "✓ verbose 1 \(100[0-9]\.[0-9]{3} ms\)"   > /dev/null
echo "$OUTPUT" | grep -cE "✓ verbose 2 \(50[0-9]\.[0-9]{3} ms\)"    > /dev/null
echo "$OUTPUT" | grep -cE "✓ verbose 3 \(25[0-9]\.[0-9]{3} ms\)"    > /dev/null
echo "$OUTPUT" | grep -c  "✗ verbose 4"                             > /dev/null
echo "$OUTPUT" | grep -c "Summary: 3 passed, 1 failed"              > /dev/null
echo "$OUTPUT" | grep -cv "this UDA should be ignored"              > /dev/null

echo "$OUTPUT" | grep -c  "core\.exception\.AssertError thrown from .*verbose\.d on line 23:"> /dev/null
echo "$OUTPUT" | grep -cE "\s+(unittest failure|Assertion failure)" > /dev/null
echo "$OUTPUT" | grep -cE "silly.d" > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/verbose-test-unittest