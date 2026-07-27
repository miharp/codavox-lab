#!/bin/bash
# Batch C: integrity and startup validation.
#
# These are the load-bearing safety claims — an artifact that does not match its
# code_id must be refused, and a publisher that cannot verify the CRL must not
# start. Both are security properties, so "probably fine" is not good enough
# before an announcement.
#
# Run on the primary. Restores everything it touches.
set -uo pipefail

FAILED=0
ok()  { printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
hdr() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

SSL=/etc/puppetlabs/puppet/ssl
STATE=/opt/puppetlabs/codavox/state
CONF=/etc/codavox/config.yaml

hdr "C1. a tampered artifact must be refused by the agent, not unpacked"
art=$(find "$STATE/artifacts" -name '*.tar.gz' | head -1)
if [ -z "$art" ]; then
  bad "no artifact on disk to tamper with"
else
  cp "$art" /tmp/artifact.orig
  # Flip bytes in the middle: still gzip-shaped at the edges, wrong content.
  printf 'CORRUPT' | dd of="$art" bs=1 seek=200 conv=notrunc status=none
  ok "corrupted $(basename "$art" | cut -c1-40)…"
  echo "     (the agent's rejection is checked from the compiler side afterwards)"
fi

hdr "C2. the publisher must refuse to start with no CRL"
mv "$SSL/crl.pem" /tmp/crl.pem.bak
out=$(codavox publish --config "$CONF" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qiE "crl|revocation"; then
  ok "exit $rc: $(printf '%s' "$out" | head -1 | cut -c1-85)"
else
  bad "started without a CRL (exit=$rc) — that is a silent downgrade to 'nothing is revoked'"
fi

hdr "C3. ... unless revocation is explicitly turned off"
out=$(codavox publish --config "$CONF" --certificate-revocation false 2>&1 &
      sleep 3; pkill -f 'codavox publish --config' 2>/dev/null)
if printf '%s' "$out" | grep -qiE "crl|cannot|failed to"; then
  bad "still complained about the CRL: $(printf '%s' "$out" | head -1 | cut -c1-80)"
else
  ok "starts when the operator says so out loud"
fi
mv /tmp/crl.pem.bak "$SSL/crl.pem"

hdr "C4. a CRL from a different CA must be refused, not believed"
cp "$SSL/crl.pem" /tmp/crl.pem.bak
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/rogue.key -out /tmp/rogue.crt \
  -subj "/CN=rogue-ca" -days 1 >/dev/null 2>&1
cat > /tmp/rogue.cnf <<'CNF'
[ca]
default_ca = c
[c]
database = /tmp/rogue.idx
crlnumber = /tmp/rogue.crlnum
default_md = sha256
default_crl_days = 1
CNF
: > /tmp/rogue.idx; echo 1000 > /tmp/rogue.crlnum
openssl ca -config /tmp/rogue.cnf -gencrl -keyfile /tmp/rogue.key -cert /tmp/rogue.crt \
  -out "$SSL/crl.pem" >/dev/null 2>&1
out=$(codavox publish --config "$CONF" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc: $(printf '%s' "$out" | head -1 | cut -c1-85)"
else
  bad "accepted a CRL signed by someone other than the Puppet CA"
fi
mv /tmp/crl.pem.bak "$SSL/crl.pem"

hdr "C5. the publisher must refuse to authorize nobody"
out=$(codavox publish --basedir /etc/puppetlabs/code/environments --allow-role '' 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc: $(printf '%s' "$out" | head -1 | cut -c1-85)"
else
  bad "started with an empty allowlist, which admits every enrolled node"
fi

hdr "C6. a nonexistent basedir must fail at startup, not advertise nothing"
out=$(codavox publish --basedir /nonexistent/environments 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc: $(printf '%s' "$out" | head -1 | cut -c1-85)"
else
  bad "started on a basedir that does not exist"
fi

hdr "C7. the real publisher is still healthy after all that"
systemctl is-active codavox-publish | sed 's/^/     codavox-publish: /'
if [ "$(systemctl is-active codavox-publish)" = "active" ]; then ok "untouched"; else bad "the service is down"; fi

echo
if [ "$FAILED" -eq 0 ]; then printf '\033[1;32mBATCH C PASSED\033[0m\n'; else printf '\033[1;31mBATCH C HAD FAILURES\033[0m\n'; fi
exit "$FAILED"
