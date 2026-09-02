#!/bin/bash
# Runs audit batches and records what happened, so a green run is evidence
# rather than a claim someone remembers making.
#
# Until this existed, results lived in whatever terminal ran them. That is
# tolerable for a pass/fail, and not tolerable for the failure this suite
# actually produces: a check that goes green without testing anything. F12 wrote
# a fixed marker string, so on a rerun its commit was empty and the deploy it
# triggered carried no new content — it compared a node against itself and
# passed. Nothing in a transcript makes that visible. A record of the *evidence*
# each check printed, across runs, does: the same code_id twice in a row where
# the check claims to have moved one is the tell.
#
# So this writes one JSON line per check to audit/results.jsonl, carrying the
# codavox version and the repo commit the run happened against, and commits it.
#
#   bash audit/run.sh            # every batch, in order
#   bash audit/run.sh f          # one batch
#   bash audit/run.sh e f        # several
#
# It also knows where each batch runs, which the README otherwise asks you to
# remember: e and f drive the estate from the host, the rest run on the primary.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

RESULTS=audit/results.jsonl
RUN_ID=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Batches that drive the whole estate from the host. Everything else is piped to
# the primary, where it needs root and the local codavox binary.
HOST_BATCHES=" e f h "

# A case rather than an associative array: macOS ships bash 3.2, which has
# neither, and every other script here assumes the same /bin/bash.
batch_file() {
  case "$1" in
    a) echo audit/a-config-and-upgrade.sh ;;
    b) echo audit/b-subcommands.sh ;;
    c) echo audit/c-integrity.sh ;;
    d) echo audit/d-scale.sh ;;
    e) echo audit/e-concurrency.sh ;;
    f) echo audit/f-core.sh ;;
    g) echo audit/g-deploy.sh ;;
    h) echo audit/h-release-0.8.sh ;;
    *) return 1 ;;
  esac
}
ORDER="a b c d e f g h"

# The batches commit to this repo to trigger deploys, and `git commit` takes what
# it is given. Starting dirty once meant an unrelated edit was committed under a
# batch's message, and was also the only thing that made a check go green.
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  printf '\033[1;31mrefusing to run:\033[0m the working tree has uncommitted changes.\n'
  git status --short | sed 's/^/     /'
  printf 'Commit or stash them first; these batches commit to the control repo.\n'
  exit 1
fi

requested="$*"
[ -z "$requested" ] && requested="$ORDER"

for b in $requested; do
  if ! batch_file "$b" >/dev/null; then
    printf 'unknown batch %s (have: %s)\n' "$b" "$ORDER"
    exit 1
  fi
done

# Recorded per batch rather than once: the batches commit, so HEAD moves under us
# and a single run-level commit would misattribute later batches.
# shellcheck source=audit/lib.sh
. audit/lib.sh
version_pin() { lab_version_label; }

# Rows are buffered outside the tree until every batch has run. Appending to
# results.jsonl per batch dirtied the tree after the first one, and the host
# batches refuse a dirty tree — so e, f, and h never ran from the runner and
# were recorded as "no output", which read as a failure of theirs rather than
# of this script.
log=$(mktemp)
buffer=$(mktemp)
trap 'rm -f "$log" "$buffer"' EXIT

overall=0
for b in $requested; do
  file=$(batch_file "$b")
  commit=$(git rev-parse --short HEAD)
  pin=$(version_pin)

  printf '\n\033[1;35m######\033[0m batch %s (%s) — codavox %s, repo %s\n' \
    "$b" "$file" "$pin" "$commit"

  if [[ "$HOST_BATCHES" == *" $b "* ]]; then
    bash "$file" 2>&1 | tee "$log"
  else
    vagrant ssh puppet -c 'sudo bash -s' < "$file" 2>&1 | tee "$log"
  fi
  rc=${PIPESTATUS[0]}
  [ "$rc" -ne 0 ] && overall=1

  # Parsing the printed output rather than instrumenting seven scripts. The
  # format is theirs and stable: "  ok   msg", "  FAIL msg", "==> F3. title".
  RUN_ID="$RUN_ID" BATCH="$b" PIN="$pin" COMMIT="$commit" RC="$rc" \
  LOG="$log" RESULTS="$buffer" python3 - <<'PY'
import json, os, re

ansi = re.compile(r'\x1b\[[0-9;]*m')
check = None
rows = []

with open(os.environ['LOG'], errors='replace') as fh:
    for raw in fh:
        line = ansi.sub('', raw).rstrip()
        m = re.match(r'^==> (\S+?)\.\s*(.*)$', line)
        if m:
            check, title = m.group(1), m.group(2)
            continue
        m = re.match(r'^\s{2}(ok|FAIL)\s+(.*)$', line)
        if m:
            rows.append({
                'run': os.environ['RUN_ID'],
                'batch': os.environ['BATCH'],
                'check': check or '?',
                'status': 'pass' if m.group(1) == 'ok' else 'fail',
                # The evidence, not just the verdict. Comparing these across runs
                # is what exposes a check that passed without testing anything.
                'detail': m.group(2),
                'codavox': os.environ['PIN'],
                'commit': os.environ['COMMIT'],
            })

if not rows:
    # A batch that printed no verdicts did not run. Silence here would otherwise
    # read as "nothing failed".
    rows.append({
        'run': os.environ['RUN_ID'], 'batch': os.environ['BATCH'],
        'check': '-', 'status': 'no-output',
        'detail': f"batch produced no ok/FAIL lines (exit {os.environ['RC']})",
        'codavox': os.environ['PIN'], 'commit': os.environ['COMMIT'],
    })

with open(os.environ['RESULTS'], 'a') as out:
    for r in rows:
        out.write(json.dumps(r, sort_keys=True) + '\n')

p = sum(1 for r in rows if r['status'] == 'pass')
f = sum(1 for r in rows if r['status'] != 'pass')
print(f"\n  recorded {len(rows)} checks: {p} pass, {f} not")
PY
done

cat "$buffer" >> "$RESULTS"

printf '\n\033[1;35m######\033[0m run %s\n' "$RUN_ID"
RUN_ID="$RUN_ID" RESULTS="$RESULTS" python3 - <<'PY'
import json, os, collections

run = os.environ['RUN_ID']
rows = [json.loads(l) for l in open(os.environ['RESULTS'])]
mine = [r for r in rows if r['run'] == run]

by_batch = collections.OrderedDict()
for r in mine:
    by_batch.setdefault(r['batch'], []).append(r)
for b, rs in by_batch.items():
    bad = [r for r in rs if r['status'] != 'pass']
    print(f"  batch {b}: {len(rs) - len(bad)}/{len(rs)}" + (f"  FAILED: {len(bad)}" if bad else ""))
    for r in bad:
        print(f"      {r['check']}: {r['detail']}")

# The point of keeping history: a check whose evidence never changes between
# runs is the shape of one that is not testing anything.
prev = sorted({r['run'] for r in rows if r['run'] != run})
if prev:
    last = prev[-1]
    before = {(r['batch'], r['check'], r['detail']) for r in rows if r['run'] == last}
    same = [r for r in mine if (r['batch'], r['check'], r['detail']) in before]
    if same:
        print(f"\n  identical evidence to {last} for {len(same)} checks —")
        print("  expected for static assertions, suspicious for any check that")
        print("  claims something moved:")
        for r in same[:8]:
            print(f"      {r['batch']}/{r['check']}: {r['detail'][:90]}")
PY

# Stage first, then ask. `git diff` says nothing about an untracked file, so
# testing before adding silently skipped the very first run — the one that
# creates the record.
git add "$RESULTS"
if git diff --cached --quiet -- "$RESULTS"; then
  printf '\n  no new results to record\n'
else
  git commit -qm "audit: record run ${RUN_ID}" -- "$RESULTS" \
    && printf '\n  recorded in %s and committed\n' "$RESULTS"
fi

exit "$overall"
