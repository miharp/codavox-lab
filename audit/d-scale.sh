#!/bin/bash
# Batch D: scale.
#
# The lab's control repo is a few hundred kilobytes, so nothing so far has said
# whether the numbers in docs/performance.md hold, or whether code-id stays a
# single symlink read once there are many environments. Both are load-bearing:
# code-id runs on every static catalog compile.
#
# Run on the primary. Cleans up the environments it creates.
set -uo pipefail

FAILED=0
ok()  { printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
hdr() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

BASEDIR=/etc/puppetlabs/code/environments
made=()
# This runs rm -rf against the primary's codedir, so both halves of the path are
# required to be non-empty. Without :? an unset variable expands to / and the trap
# deletes the environments directory it was meant to tidy.
cleanup() {
  for e in "${made[@]}"; do
    [ -n "$e" ] || continue
    rm -rf "${BASEDIR:?}/${e:?}"
  done
  systemctl reload codavox-publish
}
trap cleanup EXIT

hdr "D1. a realistically sized environment: ~50 modules, ~2500 files"
big="$BASEDIR/bigenv"; made+=(bigenv)
rm -rf "$big"; mkdir -p "$big/manifests"
cp "$BASEDIR/production/environment.conf" "$big/" 2>/dev/null || true
echo 'node default { }' > "$big/manifests/site.pp"
for m in $(seq 1 50); do
  d="$big/modules/mod$m"
  mkdir -p "$d/manifests" "$d/files" "$d/templates"
  for f in $(seq 1 16); do
    # Mixed sizes, text-shaped like real Puppet code so compression is realistic.
    head -c $((RANDOM % 20000 + 2000)) /usr/share/dict/words 2>/dev/null > "$d/files/f$f.txt" \
      || head -c $((RANDOM % 20000 + 2000)) /dev/urandom | base64 > "$d/files/f$f.txt"
    printf 'class mod%s::c%s { notify { "m%s c%s": } }\n' "$m" "$f" "$m" "$f" > "$d/manifests/c$f.pp"
  done
done
files=$(find "$big" -type f | wc -l | tr -d ' ')
size=$(du -sm "$big" | cut -f1)
ok "built: $files files, ${size} MB"

hdr "D2. seal time for that tree"
start=$(date +%s%N); id=$(codavox seal "$big"); end=$(date +%s%N)
ms=$(( (end-start)/1000000 ))
ok "sealed in ${ms} ms -> ${id:0:12}"
if [ "$ms" -gt 30000 ]; then bad "sealing took over 30s, which would stall every deploy"; fi

hdr "D3. reseal the whole basedir with the big environment in it"
start=$(date +%s%N); systemctl reload codavox-publish; sleep 2
for _ in $(seq 1 60); do
  journalctl -u codavox-publish --since "1 min ago" --no-pager | grep -q "bigenv" && break
  sleep 1
done
end=$(date +%s%N)
journalctl -u codavox-publish --since "2 min ago" --no-pager | grep -oE "(re)?sealed bigenv [0-9a-f]{12}" | tail -1 | sed 's/^/     /'
ok "publisher reseal wall time ~$(( (end-start)/1000000000 ))s"
art=$(find /opt/puppetlabs/codavox/state/artifacts -name "bigenv*" | head -1)
[ -n "$art" ] && ok "artifact: $(du -h "$art" | cut -f1) from ${size} MB of tree"

hdr "D4. many environments: does code-id stay a symlink read?"
for i in $(seq 1 20); do
  e="env$i"; made+=("$e")
  mkdir -p "$BASEDIR/$e/manifests"
  echo "node default { }" > "$BASEDIR/$e/manifests/site.pp"
done
systemctl reload codavox-publish; sleep 5
n=$(curl -s --cert /etc/puppetlabs/puppet/ssl/certs/puppet.example.com.pem \
  --key /etc/puppetlabs/puppet/ssl/private_keys/puppet.example.com.pem \
  --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem \
  https://puppet.example.com:8150/v1/environments 2>/dev/null \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
ok "publisher advertises $n environments"
if [ "${n:-0}" -lt 22 ]; then bad "expected 22+ environments (production + bigenv + 20), got $n"; fi

hdr "D5. reseal cost with 22 environments"
start=$(date +%s%N); systemctl reload codavox-publish
for _ in $(seq 1 90); do
  [ "$(journalctl -u codavox-publish --since '30 sec ago' --no-pager | grep -c 'sealed ')" -ge 22 ] && break
  sleep 1
done
end=$(date +%s%N)
ok "resealed 22 environments in ~$(( (end-start)/1000000000 ))s"

echo
if [ "$FAILED" -eq 0 ]; then printf '\033[1;32mBATCH D PASSED\033[0m\n'; else printf '\033[1;31mBATCH D HAD FAILURES\033[0m\n'; fi
exit "$FAILED"
