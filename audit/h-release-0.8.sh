#!/bin/bash
# Batch H: what codavox 0.8 and puppet-codavox 0.5.0 added.
#
# Each of these shipped with a unit test and, for the deletion path, a pass
# through codavox's own harness — but none had run against a real r10k, a real
# publisher, and two real compilers, which is the only place the deletion path
# can be shown to purge an environment the whole way to a pruning compiler.
#
# Run from the host: H6 creates and deletes a branch in this repo, which is
# r10k's remote, and the synced mount is read-only from inside the VMs.
set -uo pipefail
cd /Users/michaelharp/projects/codavox-lab || exit 1

FAILED=0

if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  printf '\033[1;31mrefusing to run:\033[0m the working tree has uncommitted changes.\n'
  git status --short | sed 's/^/     /'
  printf 'Commit or stash them first; this batch creates and deletes a branch.\n'
  exit 1
fi
ok()  { printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
hdr() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
vm()  { vagrant ssh "$1" -c "$2" 2>/dev/null | tr -d '\r'; }

# The publisher's own view, from the primary, over its own certificate.
advertised() {
  vm puppet 'sudo curl -s --cert /etc/puppetlabs/puppet/ssl/certs/puppet.example.com.pem \
    --key /etc/puppetlabs/puppet/ssl/private_keys/puppet.example.com.pem \
    --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem \
    https://puppet.example.com:8150/v1/environments'
}

hdr "H1. the module passed r10k_timeout and agent.max_unpacked through"
cfg=$(vm puppet 'sudo cat /etc/codavox/config.yaml')
if printf '%s\n' "$cfg" | grep -q '^r10k_timeout: 5m$'; then
  ok "primary config carries r10k_timeout: 5m"
else
  bad "r10k_timeout missing from the primary's config: $(printf '%s' "$cfg" | grep -c . ) lines, no match"
fi
if printf '%s\n' "$cfg" | grep -q '^  max_unpacked: 1G$'; then
  ok "primary config carries agent.max_unpacked: 1G"
else
  bad "agent.max_unpacked missing from the primary's config"
fi
ccfg=$(vm compiler01 'sudo cat /etc/codavox/config.yaml')
if printf '%s\n' "$ccfg" | grep -q '^  max_unpacked: 1G$'; then
  ok "compiler01 config carries agent.max_unpacked: 1G"
else
  bad "agent.max_unpacked missing from compiler01's config"
fi

hdr "H2. deploy --modules re-resolves one named module and exits 0"
out=$(vm puppet 'sudo codavox deploy production --modules stdlib 2>&1; echo "rc=$?"')
rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p' | tail -1)
printf '%s\n' "$out" | grep -v '^rc=' | head -3 | sed 's/^/     /'
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q 'deployed'; then
  ok "exit 0, production reported deployed"
else
  bad "exit $rc"
fi

hdr "H3. a module not in the Puppetfile fails the deploy (r10k alone exits 0)"
out=$(vm puppet 'sudo codavox deploy production --modules nosuchmodule 2>&1; echo "rc=$?"')
rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p' | tail -1)
if [ "$rc" != "0" ] && printf '%s' "$out" | grep -q "not in production's Puppetfile: nosuchmodule"; then
  ok "exit $rc: $(printf '%s' "$out" | grep -o "not in production's Puppetfile: nosuchmodule")"
else
  bad "exit $rc, output: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi

hdr "H4. a long module name is refused before r10k runs"
out=$(vm puppet 'sudo codavox deploy production --modules puppetlabs/stdlib 2>&1; echo "rc=$?"')
rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p' | tail -1)
if [ "$rc" != "0" ] && printf '%s' "$out" | grep -qi 'short name'; then
  ok "exit $rc with the hint"
else
  bad "exit $rc, output: $(printf '%s' "$out" | head -1)"
fi

hdr "H5. a hung r10k is killed at --r10k-timeout, children included"
vm puppet 'sudo bash -c "cat > /tmp/audit-slow-r10k <<'"'"'S'"'"'
#!/bin/sh
sleep 300 &
echo \$! > /tmp/audit-slow-r10k.child
wait
S
chmod 0755 /tmp/audit-slow-r10k; rm -f /tmp/audit-slow-r10k.child"' >/dev/null
start=$(date +%s)
out=$(vm puppet 'sudo codavox deploy production --r10k /tmp/audit-slow-r10k --r10k-timeout 2s 2>&1; echo "rc=$?"')
elapsed=$(( $(date +%s) - start ))
rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p' | tail -1)
if [ "$rc" != "0" ] && printf '%s' "$out" | grep -q 'timed out after 2s'; then
  ok "exit $rc after ${elapsed}s: $(printf '%s' "$out" | grep -o 'r10k deploy timed out after 2s')"
else
  bad "exit $rc after ${elapsed}s, output: $(printf '%s' "$out" | head -1)"
fi
if [ "$elapsed" -lt 30 ]; then ok "gave up promptly (${elapsed}s)"; else bad "took ${elapsed}s to give up"; fi
sleep 2
child=$(vm puppet 'sudo cat /tmp/audit-slow-r10k.child 2>/dev/null')
alive=$(vm puppet "sudo kill -0 $child 2>/dev/null && echo alive || echo gone")
if [ "$alive" = "gone" ]; then
  ok "r10k's child $child is gone (process group signaled)"
else
  bad "r10k's child $child survived the timeout"
  vm puppet "sudo kill -9 $child" >/dev/null 2>&1
fi
vm puppet 'sudo rm -f /tmp/audit-slow-r10k /tmp/audit-slow-r10k.child' >/dev/null

hdr "H6. an artifact past --max-unpacked is refused before it lands"
out=$(vm puppet 'sudo rm -rf /tmp/audit-h6; sudo env CODAVOX_ROOT=/tmp/audit-h6 codavox agent --once \
  --publisher https://puppet.example.com:8150 --environmentpath /tmp/audit-h6/environments \
  --flush-environment-cache false --max-unpacked 4K 2>&1; echo "rc=$?"')
rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p' | tail -1)
if printf '%s' "$out" | grep -q 'expands past 4096 bytes'; then
  ok "refused: $(printf '%s' "$out" | grep -o 'refusing archive that expands past 4096 bytes at [^ "]*' | head -1)"
else
  bad "no refusal in output (exit $rc): $(printf '%s' "$out" | head -1 | cut -c1-120)"
fi
left=$(vm puppet 'sudo ls /tmp/audit-h6/versions 2>/dev/null | grep -vc "^\." ')
if [ "${left:-0}" = "0" ]; then
  ok "nothing installed under the scratch root"
else
  bad "$left version directories landed despite the refusal"
fi
vm puppet 'sudo rm -rf /tmp/audit-h6' >/dev/null

hdr "H7. a branch deleted at the webhook is purged from the primary and pruned on compiler01"
# A real branch, so r10k stages a real environment and both compilers pick it
# up before it goes. The name maps to audit_h7 the way r10k sanitizes it.
git branch -D audit-h7 >/dev/null 2>&1 || true
git branch audit-h7 >/dev/null
out=$(vm puppet 'sudo codavox deploy --all 2>&1; echo "rc=$?"')
if printf '%s' "$out" | grep -q '^audit_h7 .*deployed'; then
  ok "deploy --all staged audit_h7"
else
  bad "audit_h7 not deployed: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
fi
for _ in $(seq 1 12); do
  vm compiler01 'ls /opt/puppetlabs/codavox/environments' | grep -q '^audit_h7$' && \
  vm compiler02 'ls /opt/puppetlabs/codavox/environments' | grep -q '^audit_h7$' && break
  sleep 5
done
if vm compiler01 'ls /opt/puppetlabs/codavox/environments' | grep -q '^audit_h7$' && \
   vm compiler02 'ls /opt/puppetlabs/codavox/environments' | grep -q '^audit_h7$'; then
  ok "both compilers serve audit_h7"
else
  bad "compilers never picked audit_h7 up"
fi

# A deploy server with both front doors: the webhook takes the deletion, the
# API shows what it did.
vm puppet 'sudo bash -c "install -d -m 0700 /etc/codavox
printf audit-h7-token > /etc/codavox/audit-api.token; chmod 0600 /etc/codavox/audit-api.token
printf audit-h7-secret > /etc/codavox/audit-webhook.secret; chmod 0600 /etc/codavox/audit-webhook.secret
nohup setsid codavox deploy-server --basedir /etc/puppetlabs/code/environments \
  --api-token /etc/codavox/audit-api.token --secret /etc/codavox/audit-webhook.secret \
  --listen :18170 --certname puppet.example.com >/tmp/audit-h7-ds.log 2>&1 &
sleep 3"' >/dev/null

git branch -D audit-h7 >/dev/null
code=$(vm puppet 'curl -sk -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer audit-h7-secret" \
  -H "Content-Type: application/json" -d "{\"environment\":\"audit_h7\",\"deleted\":true}" \
  https://puppet.example.com:18170/v1/webhook')
if [ "$code" = "202" ]; then ok "webhook accepted the deletion (202)"; else bad "webhook returned $code"; fi

rec=""
for _ in $(seq 1 60); do
  rec=$(vm puppet 'curl -sk -H "Authorization: Bearer audit-h7-token" https://puppet.example.com:18170/v1/deploys' \
    | python3 -c '
import json,sys
for r in json.load(sys.stdin):
    if r.get("source")=="webhook" and r.get("all"):
        print(r.get("status"), "|", r.get("reason",""), "|", " ".join(r.get("environments") or []))
        break' 2>/dev/null)
  case "$rec" in complete*|failed*) break ;; esac
  sleep 5
done
printf '     record: %s\n' "${rec:-none}"
case "$rec" in
  "complete | branch for audit_h7 deleted |"*) ok "history shows a complete all-deploy with reason 'branch for audit_h7 deleted'" ;;
  *) bad "no complete webhook all-deploy in history" ;;
esac
if printf '%s' "$rec" | grep -q ' audit_h7'; then
  bad "the deploy still reports audit_h7 among what remains"
else
  ok "the deploy reports only what remains"
fi

adv=$(advertised)
if printf '%s' "$adv" | grep -q '"audit_h7"'; then
  bad "publisher still advertises audit_h7: $adv"
else
  ok "publisher no longer advertises audit_h7"
fi

for _ in $(seq 1 12); do
  vm compiler01 'ls /opt/puppetlabs/codavox/environments' | grep -q '^audit_h7$' || break
  sleep 5
done
if vm compiler01 'ls /opt/puppetlabs/codavox/environments' | grep -q '^audit_h7$'; then
  bad "compiler01 (prune on) still serves audit_h7"
else
  ok "compiler01 (prune on) removed audit_h7"
fi
if vm compiler02 'ls /opt/puppetlabs/codavox/environments' | grep -q '^audit_h7$'; then
  ok "compiler02 (prune off) still serves it, as documented"
else
  bad "compiler02 removed audit_h7 without being told to prune"
fi

vm puppet 'sudo pkill -f "codavox deploy-server" ; sudo rm -f /etc/codavox/audit-api.token /etc/codavox/audit-webhook.secret' >/dev/null 2>&1

exit "$FAILED"
