#!/usr/bin/env bash
# The open-source share of the runtime, as the paper's Implementation section
# counts it: lines of TypeScript and of tests, and test cases, in the pinned
# enclawed-oss. Run after scripts/setup.sh.
set -euo pipefail
cd "$(dirname "$0")/../enclawed-oss/src/enclawed"
present() { for f in "$@"; do [ -f "$f" ] && echo "$f"; done; return 0; }
src=$(present hpc/*.ts swarm/*.ts hardware-root/broker.ts hardware-root/queue-journal.ts \
  hardware-root/latches.ts | grep -v -e '\.test\.ts$' -e test-utils)
tests=$(present hpc/*.test.ts swarm/*.test.ts hardware-root/broker.test.ts \
  hardware-root/queue-journal.test.ts hardware-root/latches.test.ts)
helpers=$(present swarm/swarm-test-utils.ts hardware-root/test-child.ts hardware-root/broker-exit-child.ts)
echo "source lines: $(cat $src | wc -l)"
echo "test lines:   $(cat $tests $helpers | wc -l)"
cd ../..
npx vitest run --config test/vitest/vitest.unit.config.ts $(for f in $tests; do echo "src/enclawed/$f"; done) \
  --reporter=json --outputFile=/tmp/enclawed-count.json >/dev/null 2>&1 || true
node -e 'const r=require("/tmp/enclawed-count.json").testResults;console.log("test cases:   "+r.reduce((n,f)=>n+f.assertionResults.length,0))'
