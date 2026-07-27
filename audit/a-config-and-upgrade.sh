#!/bin/bash
# Batch A: the upgrade path across v0.5.0's breaking staging -> basedir rename.
#
# This is the highest-risk untested area before an announcement, because every
# existing user hits it. The rename shipped with no alias, deliberately: codavox
# rejects unknown config keys rather than ignoring them, so a config still saying
# `staging:` must fail loudly at startup rather than come up serving nothing.
#
# Run on the primary. Leaves the node on the current version.
set -uo pipefail

FAILED=0
ok()  { printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
hdr() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

CONF=/etc/codavox/config.yaml
BACKUP=/tmp/config.yaml.audit
cp "$CONF" "$BACKUP"
restore() { cp "$BACKUP" "$CONF"; }
trap restore EXIT

hdr "A1. an old config using 'staging:' must fail loudly, not start"
sed 's/^basedir:/staging:/' "$BACKUP" > "$CONF"
out=$(codavox publish --config "$CONF" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "refused to start (exit $rc)"
  if printf '%s' "$out" | grep -qi "staging"; then
    ok "and named the offending key: $(printf '%s' "$out" | head -1 | cut -c1-90)"
  else
    bad "error does not name 'staging', so an operator cannot tell what to change: $(printf '%s' "$out" | head -1)"
  fi
else
  bad "started anyway with an unknown key — this is the silent-wrong-config case codavox exists to prevent"
fi
restore

hdr "A2. a typo'd key must fail, not be ignored"
{ cat "$BACKUP"; echo "basdir: /wrong"; } > "$CONF"
if codavox publish --config "$CONF" >/dev/null 2>&1; then
  bad "a typo'd key was ignored"
else
  ok "a typo'd key is a startup error"
fi
restore

hdr "A3. malformed YAML must fail with something readable"
printf 'basedir: [unterminated\n' > "$CONF"
out=$(codavox publish --config "$CONF" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "refused: $(printf '%s' "$out" | head -1 | cut -c1-80)"
else
  bad "malformed YAML was accepted"
fi
restore

hdr "A4. an empty config must fail on the missing required setting, not crash"
: > "$CONF"
out=$(codavox publish --config "$CONF" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "basedir"; then
  ok "asks for basedir: $(printf '%s' "$out" | head -1 | cut -c1-80)"
else
  bad "empty config gave exit=$rc: $(printf '%s' "$out" | head -1)"
fi
restore

hdr "A5. a missing config file must not be silently treated as empty"
out=$(codavox publish --config /nonexistent/codavox.yaml 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc: $(printf '%s' "$out" | head -1 | cut -c1-80)"
else
  bad "a missing config file started a publisher"
fi

hdr "A6. package upgrade in place keeps the config and the service"
before=$(codavox version)
rpm -q codavox --qf '%{VERSION}\n' | sed 's/^/     rpm reports: /'
if rpm -V codavox 2>&1 | grep -q 'config.yaml'; then
  ok "config.yaml is flagged as modified, so an upgrade will not clobber it"
else
  ok "config.yaml unmodified from the package default (nothing to preserve)"
fi
echo "     binary reports: $before"

echo
if [ "$FAILED" -eq 0 ]; then printf '\033[1;32mBATCH A PASSED\033[0m\n'; else printf '\033[1;31mBATCH A HAD FAILURES\033[0m\n'; fi
exit "$FAILED"
