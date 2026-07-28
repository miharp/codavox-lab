#!/bin/bash
# Batch E: concurrency and interruption, driven from the host across all nodes.
#
# The specific claim under test is in docs/publishing.md: a superseded artifact is
# reaped on the next reseal, "safely, since an in-flight download holds an open
# descriptor and finishes even after the file is unlinked". That is an assertion
# about POSIX semantics under a real deploy, and nothing had verified it.
set -uo pipefail
cd /Users/michaelharp/projects/codavox-lab || exit 1

FAILED=0

# This batch commits to the control repo to trigger deploys, so it refuses to
# start with other work in the tree: `git commit` here would sweep it up, and an
# audit run has no business authoring someone else's change. Not hypothetical —
# an uncommitted Vagrantfile edit was once committed under this suite's message,
# and was the only reason a check went green.
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  printf '\033[1;31mrefusing to run:\033[0m the working tree has uncommitted changes.\n'
  git status --short | sed 's/^/     /'
  printf 'Commit or stash them first; this batch commits to the control repo.\n'
  exit 1
fi
ok()  { printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
hdr() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
vm()  { vagrant ssh "$1" -c "$2" 2>/dev/null | tr -d '\r'; }

bump() {
  sed -i '' "s/^profile::base::marker_content: .*/profile::base::marker_content: '$1'/" data/common.yaml
  # Only this file, and an empty commit is a failure rather than something to
  # swallow: a bump that changed nothing deploys nothing, and every check below
  # would then be comparing a node against itself and passing.
  if ! git commit -qm "audit: $1" -- data/common.yaml; then
    bad "bump $1 produced no commit, so nothing was deployed"
  fi
  vm puppet 'sudo /opt/puppetlabs/puppet/bin/r10k deploy environment production -p >/dev/null 2>&1; sudo systemctl reload codavox-publish'
}

advertised() {
  vm puppet 'sudo curl -s --cert /etc/puppetlabs/puppet/ssl/certs/puppet.example.com.pem --key /etc/puppetlabs/puppet/ssl/private_keys/puppet.example.com.pem --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem https://puppet.example.com:8150/v1/environments' \
    | sed 's/.*"production":"\([^"]*\)".*/\1/'
}

hdr "E1. three rapid reseals: agents must land on the final id, not an intermediate"
bump rapid-one; bump rapid-two; bump rapid-three
sleep 30
final=$(advertised)
c1=$(vm compiler01 'codavox code-id production')
c2=$(vm compiler02 'codavox code-id production')
if [ -n "$final" ] && [ "$c1" = "$final" ] && [ "$c2" = "$final" ]; then
  ok "both converged on ${final:0:12} after three reseals in quick succession"
else
  bad "publisher=${final:0:12} c1=${c1:0:12} c2=${c2:0:12}"
fi

hdr "E2. SIGKILLing the agent mid-sync must leave the environment intact"
before=$(vm compiler01 'codavox code-id production')
bump killed-midway
# shellcheck disable=SC2016  # the subshell runs on the remote, not here
vm compiler01 'sudo pkill -9 -f "codavox agent" 2>/dev/null; sleep 1; echo "service now: $(systemctl is-active codavox-agent)"' | sed 's/^/     /'
during=$(vm compiler01 'codavox code-id production')
if [ -n "$during" ]; then
  ok "still serving ${during:0:12} — a killed agent leaves no broken environment"
else
  bad "code-id answers nothing after the agent was killed"
fi
vm compiler01 'sudo systemctl start codavox-agent >/dev/null 2>&1'
sleep 30
after=$(vm compiler01 'codavox code-id production')
if [ -n "$after" ] && [ "$after" != "$before" ]; then
  ok "recovered and converged to ${after:0:12}"
else
  bad "did not converge after restart (before=${before:0:12} after=${after:0:12})"
fi

hdr "E3. an in-flight download survives its artifact being reaped"
id=$(vm compiler01 'codavox code-id production')
vm compiler01 "sudo sh -c 'nohup curl -s --limit-rate 25k --cert /etc/puppetlabs/puppet/ssl/certs/compiler01.example.com.pem --key /etc/puppetlabs/puppet/ssl/private_keys/compiler01.example.com.pem --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem -o /tmp/slow.tar.gz -w \"%{http_code}\" https://puppet.example.com:8150/v1/artifact/production/$id > /tmp/slow.out 2>&1 &' ; echo started" | sed 's/^/     /'
sleep 3
bump reaped-under-reader
bump reaped-under-reader-twice
sleep 20
res=$(vm compiler01 'echo "http=$(cat /tmp/slow.out 2>/dev/null) bytes=$(stat -c%s /tmp/slow.tar.gz 2>/dev/null)"')
printf '     %s\n' "$res"
if printf '%s' "$res" | grep -q "http=200"; then
  ok "completed after its artifact was unlinked — the open-descriptor claim holds"
else
  bad "in-flight download did not complete: $res"
fi

hdr "E4. both compilers fetching the same new artifact simultaneously"
bump simultaneous
sleep 35
c1=$(vm compiler01 'codavox code-id production'); c2=$(vm compiler02 'codavox code-id production')
if [ -n "$c1" ] && [ "$c1" = "$c2" ]; then ok "both on ${c1:0:12}"; else bad "c1=${c1:0:12} c2=${c2:0:12}"; fi
for c in compiler01 compiler02; do
  errs=$(vm "$c" 'sudo journalctl -u codavox-agent --since "3 min ago" --no-pager | grep -c "level=ERROR"')
  if [ "${errs:-0}" -eq 0 ]; then ok "$c: no errors through the concurrent fetch"; else bad "$c: $errs ERROR lines"; fi
done

hdr "E5. the fleet view after all of it"
vm puppet 'sudo codavox compilers' | sed 's/^/     /'

echo
if [ "$FAILED" -eq 0 ]; then printf '\033[1;32mBATCH E PASSED\033[0m\n'; else printf '\033[1;31mBATCH E HAD FAILURES\033[0m\n'; fi
exit "$FAILED"
