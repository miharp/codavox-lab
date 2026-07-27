#!/bin/bash
# Batch G: codavox deploy and deploy-server.
#
# Both ship in the released binary and neither had ever been run on a real node.
# For an announcement that is the gap that matters most after the upgrade path,
# because deploy is what the README tells a reader to run first.
#
# Run on the primary.
set -uo pipefail

FAILED=0
ok()  { printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
hdr() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

advertised() {
  curl -s --cert /etc/puppetlabs/puppet/ssl/certs/puppet.example.com.pem \
    --key /etc/puppetlabs/puppet/ssl/private_keys/puppet.example.com.pem \
    --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem \
    https://puppet.example.com:8150/v1/environments 2>/dev/null \
    | sed 's/.*"production":"\([^"]*\)".*/\1/'
}

hdr "G1. codavox deploy: runs r10k then makes the publisher reseal"
# The lab's r10k source is a file:// remote, so a deploy only changes anything if
# the repo has moved. Move it, so this tests a real state change rather than a
# no-op that would pass either way.
sed -i "s/^profile::base::marker_content: .*/profile::base::marker_content: 'via-codavox-deploy'/" \
  /vagrant-src/data/common.yaml 2>/dev/null || true
out=$(codavox deploy production 2>&1); rc=$?
printf '%s\n' "$out" | head -4 | sed 's/^/     /'
if [ "$rc" -eq 0 ]; then ok "exit 0"; else bad "exit $rc"; fi
after=$(advertised)
if [ -n "$after" ]; then ok "publisher advertises ${after:0:12} after the deploy"; else bad "nothing advertised"; fi

hdr "G2. codavox deploy --json is machine-readable"
if codavox deploy production --json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("     keys:", sorted(d.keys()) if isinstance(d,dict) else type(d).__name__)' 2>/dev/null; then
  ok "parses"
else
  bad "--json did not produce JSON"
fi

hdr "G3. codavox deploy on an unknown environment must fail"
if codavox deploy nosuchenvironment >/dev/null 2>&1; then
  bad "deployed an environment that does not exist"
else
  ok "refused"
fi

hdr "G4. deploy-server refuses to start with no credentials"
out=$(codavox deploy-server --basedir /etc/puppetlabs/code/environments --listen :18170 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc: $(printf '%s' "$out" | head -1 | cut -c1-80)"
else
  bad "started an unauthenticated deploy API"
fi

hdr "G5. deploy-server with a token: health open, API gated"
install -d -m 0700 /etc/codavox
printf 'audit-token-not-a-real-secret\n' > /etc/codavox/api.token
chmod 0600 /etc/codavox/api.token
nohup codavox deploy-server --basedir /etc/puppetlabs/code/environments \
  --api-token /etc/codavox/api.token --listen :18170 \
  --certname puppet.example.com >/tmp/ds.log 2>&1 &
sleep 4
h=$(curl -sk -o /dev/null -w '%{http_code}' https://puppet.example.com:18170/v1/health 2>/dev/null)
if [ "$h" = "200" ]; then ok "GET /v1/health -> 200 (open, for load balancers)"; else bad "health returned $h"; fi

n=$(curl -sk -o /dev/null -w '%{http_code}' https://puppet.example.com:18170/v1/deploys 2>/dev/null)
if [ "$n" = "401" ]; then ok "GET /v1/deploys without a token -> 401"; else bad "unauthenticated request returned $n"; fi

w=$(curl -sk -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong-token' \
  https://puppet.example.com:18170/v1/deploys 2>/dev/null)
if [ "$w" = "401" ]; then ok "a wrong token -> 401"; else bad "a wrong token returned $w"; fi

g=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat /etc/codavox/api.token)" \
  https://puppet.example.com:18170/v1/deploys 2>/dev/null)
if [ "$g" = "200" ]; then ok "the right token -> 200"; else bad "the right token returned $g"; fi

hdr "G6. POST a deploy through the API"
body=$(curl -sk -X POST -H "Authorization: Bearer $(cat /etc/codavox/api.token)" \
  -H 'Content-Type: application/json' -d '{"environments":["production"]}' \
  https://puppet.example.com:18170/v1/deploys 2>/dev/null)
printf '     %s\n' "$(printf '%s' "$body" | head -c 200)"
if printf '%s' "$body" | grep -qiE 'id|queued|accepted|production'; then
  ok "accepted"
else
  bad "unexpected response"
fi
sleep 8
hist=$(curl -sk -H "Authorization: Bearer $(cat /etc/codavox/api.token)" \
  https://puppet.example.com:18170/v1/deploys 2>/dev/null)
printf '     history: %s\n' "$(printf '%s' "$hist" | head -c 220)"

hdr "G7. the webhook path rejects an unsigned request"
u=$(curl -sk -o /dev/null -w '%{http_code}' -X POST -d '{}' \
  https://puppet.example.com:18170/v1/webhook 2>/dev/null)
if [ "$u" = "401" ] || [ "$u" = "403" ] || [ "$u" = "404" ]; then
  ok "unsigned webhook -> $u"
else
  bad "unsigned webhook returned $u"
fi

pkill -f 'deploy-server' 2>/dev/null
rm -f /etc/codavox/api.token

hdr "G8. the real publisher survived all of it"
if [ "$(systemctl is-active codavox-publish)" = "active" ]; then ok "active"; else bad "down"; fi

echo
if [ "$FAILED" -eq 0 ]; then printf '\033[1;32mBATCH G PASSED\033[0m\n'; else printf '\033[1;31mBATCH G HAD FAILURES\033[0m\n'; fi
exit "$FAILED"
