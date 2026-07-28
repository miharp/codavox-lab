#!/bin/bash
# Batch F: the original suite, re-run against the pinned release, plus the two
# fixed bugs.
#
# Everything here passed before the fixes except F9 and F10, which are the
# regressions for #56 and #55. Re-running the rest is the point: the pidfile change
# touches publisher startup, so convergence, revocation and the fleet view all have
# to be shown still working rather than assumed.
set -uo pipefail
cd /Users/michaelharp/projects/codavox-lab || exit 1

FAILED=0
ok()  { printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
hdr() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
vm()  { vagrant ssh "$1" -c "$2" 2>/dev/null | tr -d '\r'; }

# Taken from Hiera rather than written here twice. The literal drifted once
# already: the pin moved to 0.6.2 while this batch still asserted 0.6.1, so the
# suite was checking a version the lab had stopped installing.
WANT=$(sed -n 's|.*/download/v\([0-9.]*\)/.*|\1|p' data/common.yaml | head -1)

hdr "F1. version actually under test (Hiera pins $WANT)"
for h in puppet compiler01 compiler02; do
  v=$(vm "$h" 'codavox version')
  if [ "$v" = "$WANT" ]; then ok "$h: $v"; else bad "$h: $v, want $WANT"; fi
done

# The primary is in this list because it runs an agent against its own publisher:
# it compiles its own catalog, so it wants versioned code like any compiler. The
# fleet view is self-reported, so it has to agree with what each node's own
# code-id says — the primary included.
hdr "F2. every serving node converged, and agrees with its own code-id"
fleet=$(vm puppet 'sudo codavox compilers')
printf '%s\n' "$fleet" | sed 's/^/     /'
# The last check in this batch revokes compiler02, and revocation is not
# reversible. A second run of the suite would otherwise report a bare FAIL here
# forever, for a state the suite itself created deliberately — the same
# "red for a stale reason" hazard as a green that passed for the wrong one.
revoked=$(vm puppet 'sudo /opt/puppetlabs/bin/puppetserver ca list --all 2>/dev/null | sed -n "/^Revoked Certificates:/,\$p"')
for c in puppet compiler01 compiler02; do
  own=$(vm "$c" 'codavox code-id production')
  if printf '%s' "$fleet" | grep -q "${own:0:12}"; then
    ok "$c reports ${own:0:12}, matching the fleet view"
  elif printf '%s' "$revoked" | grep -q "${c}.example.com"; then
    ok "$c is revoked, absent from the view, still serving ${own:0:12} — what the last check leaves behind"
  else
    bad "$c serves ${own:0:12}, not in the fleet view"
  fi
done

# This check used to assert the primary never appears in its own fleet view. That
# stopped being the right test the moment the primary started running an agent —
# and #47 named a self-compiling primary as exactly the case a naive fix would
# have erased. Absence is no longer the property; *earning* the entry is.
#
# So: stop the primary's agent and restart the publisher to clear the in-memory
# view, let the compilers report themselves back in, then poll by hand with the
# primary's own certificate. A poll alone must not create an entry — only
# fetching an artifact or reporting what is served does.
hdr "F3. a poll alone earns no entry; a real agent does (#47 regression)"
vm puppet 'sudo systemctl stop codavox-agent; sudo systemctl restart codavox-publish'
sleep 20
vm puppet 'sudo curl -s -o /dev/null --cert /etc/puppetlabs/puppet/ssl/certs/puppet.example.com.pem --key /etc/puppetlabs/puppet/ssl/private_keys/puppet.example.com.pem --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem https://puppet.example.com:8150/v1/environments'
polled=$(vm puppet 'sudo codavox compilers')
printf '%s\n' "$polled" | sed 's/^/     /'
if printf '%s' "$polled" | grep -q 'puppet.example.com'; then
  bad "a hand-run poll created a peer entry with the agent stopped"
else
  ok "a hand-run poll created no peer"
fi
# The discriminator: a node that really is converged reports itself and appears,
# over the same interval in which the hand poll earned nothing.
if printf '%s' "$polled" | grep -q 'compiler01.example.com'; then
  ok "compiler01 reported itself back in, so the view is not simply empty"
else
  bad "compiler01 is missing too — the view is empty, and F3 proves nothing"
fi

vm puppet 'sudo systemctl start codavox-agent'
sleep 20
if vm puppet 'sudo codavox compilers' | grep -q 'puppet.example.com'; then
  ok "the primary reappears once its agent reports what it serves"
else
  bad "a self-compiling primary is missing from its own fleet view"
fi

hdr "F4. static catalog carries the served code_id"
vm agent01 'sudo /opt/puppetlabs/bin/puppet agent -t >/dev/null 2>&1'
cat=$(vm agent01 'sudo grep -o "\"code_id\":\"[^\"]*\"" /opt/puppetlabs/puppet/cache/client_data/catalog/agent01.example.com.json | head -1 | sed "s/.*:\"//;s/\"//"')
srv=$(vm compiler01 'codavox code-id production')
if [ -n "$cat" ] && [ "$cat" = "$srv" ]; then ok "catalog and compiler agree on ${cat:0:12}"; else bad "catalog=${cat:0:12} compiler=${srv:0:12}"; fi

# The primary compiles its own catalog, so it needs the same guarantee. Left
# publisher-only it was the one node in the estate whose catalog carried no
# code_id at all — a gap that looked like nothing, because an ordinary catalog is
# not an error.
hdr "F5. the primary's own catalog is static too"
vm puppet 'sudo /opt/puppetlabs/bin/puppet agent -t >/dev/null 2>&1'
pcat=$(vm puppet 'sudo grep -o "\"code_id\":\"[^\"]*\"" /opt/puppetlabs/puppet/cache/client_data/catalog/puppet.example.com.json | head -1 | sed "s/.*:\"//;s/\"//"')
psrv=$(vm puppet 'codavox code-id production')
if [ -z "$pcat" ]; then
  bad "the primary compiled an ordinary catalog — no code_id, so it is not wired"
elif [ "$pcat" = "$psrv" ]; then
  ok "the primary's catalog and its own code-id agree on ${pcat:0:12}"
else
  bad "primary catalog=${pcat:0:12} but it serves ${psrv:0:12}"
fi

# It compiles from the version directory, not from r10k's basedir. If
# environmentpath still pointed at the basedir the catalog above could carry a
# code_id while the content came from an unsealed tree.
env_path=$(vm puppet 'sudo grep "^environmentpath" /etc/puppetlabs/puppet/puppet.conf | sed "s/.*= *//"')
if [ "$env_path" = "/opt/puppetlabs/codavox/environments" ]; then
  ok "environmentpath is codavox's, so the content matches the code_id"
else
  bad "environmentpath is '$env_path', not codavox's version directories"
fi

hdr "F6. no fallback"
vm compiler01 'codavox code-id nosuchenv >/dev/null 2>&1; echo "  unknown env exit=$?"' | sed 's/^/   /'
vm compiler01 'codavox code-content production 0000000000000000000000000000000000000000000000000000000000000000 manifests/site.pp >/dev/null 2>&1; echo "  undeployed code_id exit=$?"' | sed 's/^/   /'
vm compiler01 'codavox code-content production "$(codavox code-id production)" ../../../../etc/shadow >/dev/null 2>&1; echo "  traversal exit=$?"' | sed 's/^/   /'
n=$(vm compiler01 'e=0; codavox code-id nosuchenv >/dev/null 2>&1 || e=$((e+1)); codavox code-content production 000 x >/dev/null 2>&1 || e=$((e+1)); codavox code-content production "$(codavox code-id production)" /etc/shadow >/dev/null 2>&1 || e=$((e+1)); echo $e')
if [ "$n" = "3" ]; then ok "all three refused"; else bad "only $n of 3 refused"; fi

hdr "F7. code-id is silent and fast"
errbytes=$(vm compiler01 'codavox code-id production 2>&1 >/dev/null | wc -c | tr -d " "')
if [ "$errbytes" = "0" ]; then ok "0 bytes on stderr"; else bad "$errbytes bytes on stderr"; fi
vm compiler01 'start=$(date +%s%N); for _ in $(seq 1 200); do codavox code-id production >/dev/null; done; end=$(date +%s%N); echo "     $(( (end-start)/200/1000 )) us/call"'

hdr "F8. publisher outage: serving continues, logging backs off (#48 regression)"
vm puppet 'sudo systemctl stop codavox-publish'
sleep 60
still=$(vm compiler01 'codavox code-id production')
if [ -n "$still" ]; then ok "still serving ${still:0:12} with the publisher down"; else bad "code-id stopped answering"; fi
lines=$(vm compiler01 'sudo journalctl -u codavox-agent --since "70 sec ago" --no-pager | grep -c "sync failed"')
if [ "${lines:-99}" -le 4 ]; then ok "$lines log lines for a ~6-poll outage (was one per poll)"; else bad "$lines lines — backoff not working"; fi
vm puppet 'sudo systemctl start codavox-publish'
sleep 25
if vm compiler01 'sudo journalctl -u codavox-agent --since "1 min ago" --no-pager' | grep -q "sync recovered"; then
  ok "recovery logged"
else
  bad "no recovery line"
fi

hdr "F9. reboot survival"
before=$(vm compiler02 'codavox code-id production')
vm compiler02 'sudo systemctl reboot' >/dev/null 2>&1
for _ in $(seq 1 40); do sleep 8; after=$(vm compiler02 'codavox code-id production'); [ -n "$after" ] && break; done
if [ "$after" = "$before" ]; then ok "came back on ${after:0:12}"; else bad "before=${before:0:12} after=${after:0:12}"; fi

hdr "F10. #56 regression: a failed publish must not destroy the running claim"
vm puppet 'sudo bash -c "
  systemctl restart codavox-publish; sleep 5
  held=\$(cat /opt/puppetlabs/codavox/state/publish.pid)
  out=\$(codavox publish --basedir /etc/puppetlabs/code/environments 2>&1 | tail -1)
  echo \"     second publisher: \$out\"
  if [ -f /opt/puppetlabs/codavox/state/publish.pid ] && [ \"\$(cat /opt/puppetlabs/codavox/state/publish.pid)\" = \"\$held\" ]; then
    echo PIDFILE_INTACT
  else
    echo PIDFILE_LOST
  fi
  codavox deploy production >/dev/null 2>&1 && echo DEPLOY_OK || echo DEPLOY_FAILED
"' > /tmp/f9.out 2>&1
sed -n 's/^     /     /p' /tmp/f9.out
if grep -q PIDFILE_INTACT /tmp/f9.out; then ok "the incumbent's pidfile survived"; else bad "the pidfile was destroyed"; fi
if grep -q DEPLOY_OK /tmp/f9.out; then ok "codavox deploy still signals the publisher"; else bad "deploy could not signal"; fi

hdr "F11. #55 regression: an empty allowlist entry is refused"
out=$(vm puppet 'sudo codavox publish --basedir /etc/puppetlabs/code/environments --allow-role "" 2>&1 | tail -1')
printf '     %s\n' "$out"
if printf '%s' "$out" | grep -qi "allow-role"; then ok "refused, naming the flag"; else bad "not refused"; fi

hdr "F12. revocation still takes effect on the next poll"
vm puppet 'sudo /opt/puppetlabs/bin/puppetserver ca revoke --certname compiler02.example.com >/dev/null 2>&1'
# A unique value, and only this file committed. The old version wrote a fixed
# string and used `git commit -a`, which failed twice over on a rerun: the marker
# was already that string so the commit was empty, and `-a` swept up whatever else
# happened to be modified in the working tree. On the run that caught this, an
# unrelated Vagrantfile edit was the only thing that changed the tree — so the
# deploy below produced a new code_id by accident, and this check passed without
# testing anything.
marker="post-audit-$(date +%s)"
sed -i '' "s/^profile::base::marker_content: .*/profile::base::marker_content: '${marker}'/" data/common.yaml
if ! git commit -qm "regression: ${marker} deploy" -- data/common.yaml; then
  bad "the marker commit was empty, so the deploy below proves nothing"
fi
vm puppet 'sudo /opt/puppetlabs/puppet/bin/r10k deploy environment production -p >/dev/null 2>&1; sudo systemctl reload codavox-publish'
sleep 35
c1=$(vm compiler01 'codavox code-id production'); c2=$(vm compiler02 'codavox code-id production')
if [ "$c1" != "$c2" ]; then ok "compiler01 moved to ${c1:0:12}, revoked compiler02 held at ${c2:0:12}"; else bad "a revoked compiler still received code"; fi
if vm puppet 'sudo journalctl -u codavox-publish --since "2 min ago" --no-pager' | grep -qi revoked; then
  ok "publisher logged the refusal"
else
  bad "no revocation in the publisher log"
fi

hdr "F13. #49 regression: a skipped directory is named, and dot-dirs are not"
vm puppet 'sudo bash -c "
  B=/etc/puppetlabs/code/environments
  mkdir -p \$B/feature-my-branch/manifests \$B/.hidden-audit
  systemctl reload codavox-publish; sleep 4
  journalctl -u codavox-publish --no-pager --since \"15 sec ago\" | sed \"s/.*codavox\[[0-9]*\]: //\" | grep -E \"^skipped\" || echo NO_SKIP_LINE
"' > /tmp/f12.out 2>&1
sed 's/^/     /' /tmp/f12.out
if grep -q "skipped feature-my-branch" /tmp/f12.out; then
  ok "the invalid name was reported"
else
  bad "an invalid directory was skipped silently"
fi
if grep -q "hidden-audit" /tmp/f12.out; then
  bad "a dot-prefixed directory was reported as a problem"
else
  ok "the dot-prefixed directory stayed silent"
fi

# Following the advice has to work, or the message is just noise.
vm puppet 'sudo bash -c "
  B=/etc/puppetlabs/code/environments
  mv \$B/feature-my-branch \$B/feature_my_branch
  systemctl reload codavox-publish; sleep 4
  journalctl -u codavox-publish --no-pager --since \"10 sec ago\" | sed \"s/.*codavox\[[0-9]*\]: //\" | grep -E \"^(re)?sealed feature_my_branch|^skipped\" || true
"' > /tmp/f12b.out 2>&1
sed 's/^/     /' /tmp/f12b.out
if grep -qE "sealed feature_my_branch" /tmp/f12b.out && ! grep -q "^ *skipped" /tmp/f12b.out; then
  ok "renaming it cleared the warning and the environment is served"
else
  bad "the fix the message recommends did not work"
fi
vm puppet 'sudo bash -c "rm -rf /etc/puppetlabs/code/environments/feature_my_branch /etc/puppetlabs/code/environments/.hidden-audit; systemctl reload codavox-publish"'

echo
vm puppet 'sudo codavox compilers' | sed 's/^/     /'
echo
if [ "$FAILED" -eq 0 ]; then printf '\033[1;32mBATCH F PASSED\033[0m\n'; else printf '\033[1;31mBATCH F HAD FAILURES\033[0m\n'; fi
exit "$FAILED"
