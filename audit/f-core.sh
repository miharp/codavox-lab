#!/bin/bash
# Batch F: the original suite, re-run against 0.6.1, plus the two fixed bugs.
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

hdr "F1. version actually under test"
for h in puppet compiler01 compiler02; do
  v=$(vm "$h" 'codavox version')
  if [ "$v" = "0.6.1" ]; then ok "$h: $v"; else bad "$h: $v, want 0.6.1"; fi
done

hdr "F2. both compilers converged, and agree with their own code-id"
fleet=$(vm puppet 'sudo codavox compilers')
printf '%s\n' "$fleet" | sed 's/^/     /'
for c in compiler01 compiler02; do
  own=$(vm "$c" 'codavox code-id production')
  if printf '%s' "$fleet" | grep -q "${own:0:12}"; then
    ok "$c reports ${own:0:12}, matching the fleet view"
  else
    bad "$c serves ${own:0:12}, not in the fleet view"
  fi
done

hdr "F3. no phantom peers from a diagnostic poll (#47 regression)"
vm puppet 'sudo curl -s -o /dev/null --cert /etc/puppetlabs/puppet/ssl/certs/puppet.example.com.pem --key /etc/puppetlabs/puppet/ssl/private_keys/puppet.example.com.pem --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem https://puppet.example.com:8150/v1/environments'
if vm puppet 'sudo codavox compilers' | grep -q 'puppet.example.com'; then
  bad "a manual poll added the publisher to its own fleet view"
else
  ok "a manual poll created no peer"
fi

hdr "F4. static catalog carries the served code_id"
vm agent01 'sudo /opt/puppetlabs/bin/puppet agent -t >/dev/null 2>&1'
cat=$(vm agent01 'sudo grep -o "\"code_id\":\"[^\"]*\"" /opt/puppetlabs/puppet/cache/client_data/catalog/agent01.example.com.json | head -1 | sed "s/.*:\"//;s/\"//"')
srv=$(vm compiler01 'codavox code-id production')
if [ -n "$cat" ] && [ "$cat" = "$srv" ]; then ok "catalog and compiler agree on ${cat:0:12}"; else bad "catalog=${cat:0:12} compiler=${srv:0:12}"; fi

hdr "F5. no fallback"
vm compiler01 'codavox code-id nosuchenv >/dev/null 2>&1; echo "  unknown env exit=$?"' | sed 's/^/   /'
vm compiler01 'codavox code-content production 0000000000000000000000000000000000000000000000000000000000000000 manifests/site.pp >/dev/null 2>&1; echo "  undeployed code_id exit=$?"' | sed 's/^/   /'
vm compiler01 'codavox code-content production "$(codavox code-id production)" ../../../../etc/shadow >/dev/null 2>&1; echo "  traversal exit=$?"' | sed 's/^/   /'
n=$(vm compiler01 'e=0; codavox code-id nosuchenv >/dev/null 2>&1 || e=$((e+1)); codavox code-content production 000 x >/dev/null 2>&1 || e=$((e+1)); codavox code-content production "$(codavox code-id production)" /etc/shadow >/dev/null 2>&1 || e=$((e+1)); echo $e')
if [ "$n" = "3" ]; then ok "all three refused"; else bad "only $n of 3 refused"; fi

hdr "F6. code-id is silent and fast"
errbytes=$(vm compiler01 'codavox code-id production 2>&1 >/dev/null | wc -c | tr -d " "')
if [ "$errbytes" = "0" ]; then ok "0 bytes on stderr"; else bad "$errbytes bytes on stderr"; fi
vm compiler01 'start=$(date +%s%N); for _ in $(seq 1 200); do codavox code-id production >/dev/null; done; end=$(date +%s%N); echo "     $(( (end-start)/200/1000 )) us/call"'

hdr "F7. publisher outage: serving continues, logging backs off (#48 regression)"
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

hdr "F8. reboot survival"
before=$(vm compiler02 'codavox code-id production')
vm compiler02 'sudo systemctl reboot' >/dev/null 2>&1
for _ in $(seq 1 40); do sleep 8; after=$(vm compiler02 'codavox code-id production'); [ -n "$after" ] && break; done
if [ "$after" = "$before" ]; then ok "came back on ${after:0:12}"; else bad "before=${before:0:12} after=${after:0:12}"; fi

hdr "F9. #56 regression: a failed publish must not destroy the running claim"
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

hdr "F10. #55 regression: an empty allowlist entry is refused"
out=$(vm puppet 'sudo codavox publish --basedir /etc/puppetlabs/code/environments --allow-role "" 2>&1 | tail -1')
printf '     %s\n' "$out"
if printf '%s' "$out" | grep -qi "allow-role"; then ok "refused, naming the flag"; else bad "not refused"; fi

hdr "F11. revocation still takes effect on the next poll"
vm puppet 'sudo /opt/puppetlabs/bin/puppetserver ca revoke --certname compiler02.example.com >/dev/null 2>&1'
sed -i '' "s/^profile::base::marker_content: .*/profile::base::marker_content: 'post-audit'/" data/common.yaml
git commit -aqm "regression: post-audit deploy" >/dev/null 2>&1 || true
vm puppet 'sudo /opt/puppetlabs/puppet/bin/r10k deploy environment production -p >/dev/null 2>&1; sudo systemctl reload codavox-publish'
sleep 35
c1=$(vm compiler01 'codavox code-id production'); c2=$(vm compiler02 'codavox code-id production')
if [ "$c1" != "$c2" ]; then ok "compiler01 moved to ${c1:0:12}, revoked compiler02 held at ${c2:0:12}"; else bad "a revoked compiler still received code"; fi
if vm puppet 'sudo journalctl -u codavox-publish --since "2 min ago" --no-pager' | grep -qi revoked; then
  ok "publisher logged the refusal"
else
  bad "no revocation in the publisher log"
fi

echo
vm puppet 'sudo codavox compilers' | sed 's/^/     /'
echo
if [ "$FAILED" -eq 0 ]; then printf '\033[1;32mBATCH F PASSED\033[0m\n'; else printf '\033[1;31mBATCH F HAD FAILURES\033[0m\n'; fi
exit "$FAILED"
