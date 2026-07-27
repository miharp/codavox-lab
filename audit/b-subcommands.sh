#!/bin/bash
# Batch B: the subcommands nothing has exercised yet.
#
# publish, agent, code-id and code-content are covered. deploy, deploy-server,
# webhook, provenance and seal are shipped in the same binary and had never been
# run on a real node — which for an announcement is the gap that matters, because
# they are what a reader of the README will try first.
#
# Run on the primary.
set -uo pipefail

FAILED=0
ok()  { printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
hdr() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

BASEDIR=/etc/puppetlabs/code/environments
STATE=/opt/puppetlabs/codavox/state

hdr "B1. codavox seal: a deterministic id for a tree, standalone"
a=$(codavox seal "$BASEDIR/production" 2>/dev/null)
b=$(codavox seal "$BASEDIR/production" 2>/dev/null)
if [ -n "$a" ] && [ "$a" = "$b" ]; then
  ok "reproducible: ${a:0:12}"
else
  bad "seal gave '$a' then '$b'"
fi
served=$(curl -s --cert /etc/puppetlabs/puppet/ssl/certs/puppet.example.com.pem \
  --key /etc/puppetlabs/puppet/ssl/private_keys/puppet.example.com.pem \
  --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem \
  https://puppet.example.com:8150/v1/environments 2>/dev/null \
  | sed 's/.*"production":"\([^"]*\)".*/\1/')
if [ "$a" = "$served" ]; then
  ok "matches what the publisher advertises, so seal and publish agree"
else
  bad "seal says ${a:0:12} but the publisher advertises ${served:0:12}"
fi

hdr "B2. codavox seal --manifest: the canonical manifest behind the id"
lines=$(codavox seal "$BASEDIR/production" --manifest 2>/dev/null | wc -l | tr -d ' ')
if [ "${lines:-0}" -gt 10 ]; then ok "$lines manifest lines"; else bad "manifest was $lines lines"; fi

hdr "B3. codavox seal on a nonexistent tree must fail"
if codavox seal /nonexistent/tree >/dev/null 2>&1; then
  bad "sealed a tree that does not exist"
else
  ok "refused"
fi

hdr "B4. codavox provenance: code_id -> control-repo commit"
out=$(codavox provenance production "$served" --state "$STATE" 2>&1)
if printf '%s' "$out" | grep -qE '^[0-9a-f]{7,}'; then
  ok "$(printf '%s' "$out" | head -1 | cut -c1-70)"
else
  bad "no provenance for the served id: $(printf '%s' "$out" | head -1)"
fi

hdr "B5. codavox provenance --json"
if codavox provenance production "$served" --state "$STATE" --json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,list) and d and d[0]["commit"]; print("     commit:", d[0]["commit"][:12])' 2>/dev/null; then
  ok "valid JSON with a commit"
else
  bad "--json did not produce a usable record"
fi

hdr "B6. codavox provenance for an unrecorded id: honest absence, exit 0"
out=$(codavox provenance production 0000000000000000000000000000000000000000000000000000000000000000 --state "$STATE" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "no provenance"; then
  ok "exit 0 and says so — provenance is best effort, not load-bearing"
else
  bad "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

hdr "B7. codavox provenance rejects a malformed code_id"
if codavox provenance production 'not/a/valid/id' --state "$STATE" >/dev/null 2>&1; then
  bad "accepted an invalid code_id"
else
  ok "refused"
fi

hdr "B8. codavox compilers --json is machine-readable"
if codavox compilers --json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert isinstance(d,list), "not a list"
print("     peers:", len(d), "| keys:", sorted(d[0].keys()) if d else "none")' 2>/dev/null; then
  ok "parses"
else
  bad "--json is not valid JSON"
fi

hdr "B9. unknown subcommand and unknown flag must fail, not guess"
codavox nosuchcommand >/dev/null 2>&1; rc1=$?
codavox compilers --nosuchflag >/dev/null 2>&1; rc2=$?
if [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ]; then ok "both refused"; else bad "rc=$rc1/$rc2"; fi

hdr "B10. codavox version and --help are usable"
v=$(codavox version 2>&1)
h=$(codavox --help 2>&1 | wc -l | tr -d ' ')
if [ -n "$v" ] && [ "${h:-0}" -gt 20 ]; then ok "version $v, $h lines of help"; else bad "version='$v' help=$h lines"; fi

echo
if [ "$FAILED" -eq 0 ]; then printf '\033[1;32mBATCH B PASSED\033[0m\n'; else printf '\033[1;31mBATCH B HAD FAILURES\033[0m\n'; fi
exit "$FAILED"
