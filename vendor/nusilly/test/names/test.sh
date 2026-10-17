. $TESTSUITE/common.sh

OUTPUT=$(dub test -b unittest-cov --root=$(dirname "${BASH_SOURCE[0]}") --skip-registry=all --nodeps -q -- --no-colours 2>&1)

echo "$OUTPUT" | grep -c "✓ .six.seven.eight.nine.ten.m name"    > /dev/null
echo "$OUTPUT" | grep -c "✓ sgoingtousenameslikethisanyway test" > /dev/null
echo "$OUTPUT" | grep -c "Summary: 2 passed, 0 failed"           > /dev/null

EXEC=$(dirname "${BASH_SOURCE[0]}")/names-test-unittest

$EXEC --no-colours --verbose | grep -c "✓ names.one.two.three.four.five.six.seven.eight.nine.ten.m name" > /dev/null
$EXEC --no-colours --verbose | grep -c "✓ names.modulewithnamewhichistoolongandnobodysgoingtousenameslikethisanyway test" > /dev/null

rm -r $(dirname "${BASH_SOURCE[0]}")/.dub $(dirname "${BASH_SOURCE[0]}")/names-test-unittest