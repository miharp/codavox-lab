#!/bin/bash
# Batch I: the catalog label (codavox#97, #101), provenance for a branch that
# has not diverged (codavox#102), the module commits a label leads to
# (codavox#106), and the toolchain the release is built with.
#
# codavox config-version shipped with a unit test and a harness feature, but the
# harness compiles at environment_timeout = 0 from a control repo that points
# config_version straight at the binary. Here the label comes the way a real
# estate gets it: from the OpenVox template's own script plus codavox's
# three-line branch, on servers that cache their environments forever, with a
# primary that compiled from r10k's basedir until codavox::primary cut it over.
#
# Run from the host: I5 commits a marker deploy to this repo, which is r10k's
# remote, and the synced mount is read-only from inside the VMs.
set -uo pipefail
cd /Users/michaelharp/projects/codavox-lab || exit 1

FAILED=0

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

# shellcheck source=audit/lib.sh
. audit/lib.sh

# label <node> — run the agent on <node> and print the configuration version
# it applied, read from the run itself rather than from any file it left.
label() {
  vm "$1" 'sudo /opt/puppetlabs/bin/puppet agent -t 2>&1' \
    | sed -n "s/.*Applying configuration version '\([^']*\)'.*/\1/p" | tail -1
}

CATALOG=/opt/puppetlabs/puppet/cache/client_data/catalog/agent01.example.com.json
REPORT=/opt/puppetlabs/puppet/cache/state/last_run_report.yaml

hdr "I1. every server has the codavox-config-version symlink"
for h in puppet compiler01 compiler02; do
  target=$(vm "$h" 'readlink /usr/bin/codavox-config-version')
  if [ "$target" = "/usr/bin/codavox" ]; then
    ok "$h: /usr/bin/codavox-config-version -> $target"
  else
    bad "$h: /usr/bin/codavox-config-version -> '${target:-missing}'"
  fi
done

# A snapshot built with whatever Go the host has would test a binary the release
# workflow never produces: it builds with the go directive in go.mod. Read that
# from the codavox commit the snapshot came from, not from a checkout that may
# have moved since.
hdr "I2. the binary was built with the Go release go.mod names"
src="${CODAVOX_SRC:-$HOME/projects/codavox}"
commit=""
case "$(lab_pin)" in
  /vagrant-src/dist/*) commit=$(awk '{print $2}' dist/VERSION 2>/dev/null) ;;
esac
want=""
[ -n "$commit" ] && want=$(git -C "$src" show "${commit}:go.mod" 2>/dev/null | sed -n 's/^go \([0-9.]*\)$/go\1/p')
built=$(vm puppet "grep -ao 'go1\.[0-9]\+\.[0-9]\+' /usr/bin/codavox | sort -u | tr '\n' ' '")
if [ -z "$commit" ]; then
  ok "a released package, built by the release workflow: ${built% }"
elif [ "${built% }" = "$want" ]; then
  ok "/usr/bin/codavox carries $want, matching go.mod at $commit"
else
  bad "/usr/bin/codavox carries '${built% }', go.mod at $commit says $want"
fi

hdr "I3. agent01's catalog is labeled with the code_id compiler01 serves"
served=$(vm compiler01 'codavox code-id production')
first=$(label agent01)
sleep 2
second=$(label agent01)
if [ -n "$served" ] && [ "$first" = "production-${served:0:12}" ] && [ "$second" = "$first" ]; then
  ok "two runs both applied '$first'; compiler01 serves ${served:0:12}"
else
  bad "runs applied '$first' then '$second'; compiler01 serves '${served:0:12}'"
fi
stamped=$(vm agent01 "sudo grep -o '\"version\":\"[^\"]*\"' $CATALOG | head -1 | cut -d'\"' -f4")
reported=$(vm agent01 "sudo sed -n \"s/^configuration_version: '*\\([^']*\\)'*\$/\\1/p\" $REPORT")
if [ "$stamped" = "$second" ] && [ "$reported" = "$second" ]; then
  ok "the catalog's version and the report's configuration_version are both '$second'"
else
  bad "catalog version '$stamped', report configuration_version '$reported', run applied '$second'"
fi

hdr "I4. the primary labels its own catalog with its own code_id"
envpath=$(vm puppet 'sudo /opt/puppetlabs/bin/puppet config print environmentpath --section server')
own=$(vm puppet 'codavox code-id production')
mine=$(label puppet)
if [ "$envpath" = "/opt/puppetlabs/codavox/environments" ] && [ "$mine" = "production-${own:0:12}" ]; then
  ok "cut over to $envpath, and its run applied '$mine'"
else
  bad "environmentpath '$envpath', run applied '$mine', primary serves '${own:0:12}'"
fi

# Every server here caches its environments forever, so OpenVox runs
# config_version once per environment instance. The label moves only because
# the agent expires the cache after the swap; without that, agent01 would keep
# getting the old label, and the old tree with it. F14 proves the content
# moves; this proves the label moves with it.
hdr "I5. a deploy moves the label, though the environment cache never times out"
timeout=$(vm compiler01 'sudo grep "^environment_timeout" /etc/puppetlabs/puppet/puppet.conf | sed "s/.*= *//"')
if [ "$timeout" = "unlimited" ]; then
  ok "compiler01 holds its environment cache (environment_timeout = unlimited)"
else
  bad "environment_timeout is '${timeout:-unset}' on compiler01, so the label would move without a flush"
fi
before=$(vm compiler01 'codavox code-id production')
marker="catalog-label-$(date +%s)"
sed -i '' "s/^profile::base::marker_content: .*/profile::base::marker_content: '${marker}'/" data/common.yaml
if ! git commit -qm "regression: ${marker} deploy" -- data/common.yaml; then
  bad "the marker commit was empty, so the deploy below proves nothing"
fi
vm puppet 'sudo /opt/puppetlabs/puppet/bin/r10k deploy environment production -p >/dev/null 2>&1; sudo systemctl reload codavox-publish'
after="$before"
for _ in $(seq 1 12); do
  sleep 5
  after=$(vm compiler01 'codavox code-id production')
  [ "$after" != "$before" ] && break
done
moved=$(label agent01)
if [ "$after" != "$before" ] && [ "$moved" = "production-${after:0:12}" ]; then
  ok "compiler01 moved ${before:0:12} -> ${after:0:12}, and agent01 applied '$moved'"
else
  bad "compiler01 ${before:0:12} -> ${after:0:12}, agent01 applied '$moved'"
fi

# The other half of the branch, for a server not yet cut over: the same script,
# given r10k's basedir, must fall through to the template's own answer. The
# deploy above is what r10k recorded, so the commit is this repo's HEAD.
hdr "I6. on r10k's basedir the same script still prints the commit"
head=$(git rev-parse HEAD)
fallthrough=$(vm puppet 'sudo -u puppet /etc/puppetlabs/code/environments/production/scripts/config_version.sh /etc/puppetlabs/code/environments production')
if [ "$fallthrough" = "puppet-production-${head:0:11}" ]; then
  ok "printed '$fallthrough'"
else
  bad "printed '$fallthrough', want 'puppet-production-${head:0:11}'"
fi

hdr "I7. config-version refuses a directory codavox does not serve"
out=$(vm puppet 'codavox-config-version /etc/puppetlabs/code/environments production 2>&1; echo "rc=$?"')
rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p' | tail -1)
stdout=$(vm puppet 'codavox-config-version /etc/puppetlabs/code/environments production 2>/dev/null')
if [ "$rc" = "1" ] && [ -z "$stdout" ]; then
  ok "exit 1, nothing on stdout: $(printf '%s\n' "$out" | grep -v '^rc=' | head -1)"
else
  bad "exit $rc, stdout '$stdout'"
fi

# A branch with no commits of its own has production's tree and HEAD, so the
# same code_id and the same commit. Before codavox#101 its catalogs carried
# production's label; before #102 the provenance log dropped its record as a
# duplicate of production's, so the fleet view showed no commit for it. The
# name maps to audit_i8 the way r10k sanitizes it, as H7's does.
hdr "I8. a branch that has not diverged gets its own label and its own commit"
git branch -D audit-i8 >/dev/null 2>&1 || true
git branch audit-i8 >/dev/null
head=$(git rev-parse HEAD)
vm puppet 'sudo codavox deploy --all >/dev/null 2>&1'
for _ in $(seq 1 12); do
  vm compiler01 'ls /opt/puppetlabs/codavox/environments' | grep -q '^audit_i8$' && break
  sleep 5
done
prod_id=$(vm compiler01 'codavox code-id production')
branch_id=$(vm compiler01 'codavox code-id audit_i8')
envpath=/opt/puppetlabs/codavox/environments
prod_label=$(vm compiler01 "codavox-config-version $envpath production")
branch_label=$(vm compiler01 "codavox-config-version $envpath audit_i8")
if [ -n "$branch_id" ] && [ "$branch_id" = "$prod_id" ] \
  && [ "$prod_label" = "production-${prod_id:0:12}" ] && [ "$branch_label" = "audit_i8-${prod_id:0:12}" ]; then
  ok "both serve ${prod_id:0:12}, labeled '$prod_label' and '$branch_label'"
else
  bad "production ${prod_id:0:12} '$prod_label', audit_i8 '${branch_id:0:12}' '$branch_label'"
fi
recorded=$(vm puppet "sudo codavox provenance audit_i8 $branch_id 2>/dev/null" | awk 'NR==1 {print $1}')
if [ -n "$branch_id" ] && [ "$recorded" = "$head" ]; then
  ok "provenance for audit_i8 names ${head:0:11}, the commit it was deployed from"
else
  bad "provenance for audit_i8 names '${recorded:-nothing}', want ${head:0:11}"
fi
# The fleet view joins what compiler01 reported to that record; the report
# follows the swap, so give it a poll to arrive.
fleet=""
for _ in $(seq 1 12); do
  fleet=$(vm puppet 'sudo codavox compilers --json' | python3 -c '
import json,sys
for p in json.load(sys.stdin):
    if p.get("certname")=="compiler01.example.com":
        print((p.get("commits") or {}).get("audit_i8",""))' 2>/dev/null)
  [ -n "$fleet" ] && break
  sleep 5
done
if [ "$fleet" = "$head" ]; then
  ok "the fleet view shows ${head:0:11} for compiler01's audit_i8"
else
  bad "the fleet view shows '${fleet:-nothing}' for compiler01's audit_i8, want ${head:0:11}"
fi
# Leave nothing behind: r10k purges the deleted branch, the publisher stops
# advertising it, and compiler01 prunes it. The primary's agent does not prune,
# so its link goes by hand, as in H7.
git branch -D audit-i8 >/dev/null
vm puppet 'sudo codavox deploy --all >/dev/null 2>&1; sudo rm -f /opt/puppetlabs/codavox/environments/audit_i8' >/dev/null

# A control-repo commit pins a module only when its Puppetfile entry is
# immutable, so provenance also records each git module's commit, read from the
# module's own checkout (codavox#106). Look it up the way someone holding a run
# report would, by the label agent01 applied. The commit to expect comes from
# the remote, not from anything on the primary, and the Forge modules beside it
# must not be listed as git modules.
hdr "I9. the label leads to the commit of each git module in the tree"
remote=https://github.com/miharp/puppet-codavox.git
tag=$(sed -n "s/^ *tag: *'\([^']*\)'.*/\1/p" Puppetfile | head -1)
refs=$(git ls-remote "$remote" "refs/tags/$tag*" 2>/dev/null)
peeled=$(printf '%s\n' "$refs" | awk -v r="refs/tags/$tag^{}" '$2 == r {print $1}')
want=${peeled:-$(printf '%s\n' "$refs" | awk -v r="refs/tags/$tag" '$2 == r {print $1}')}
current=$(label agent01)
out=$(vm puppet "sudo codavox provenance $current --modules 2>&1")
# Newest record only: a code_id deployed from several commits lists each.
newest=$(printf '%s\n' "$out" | awk 'NR > 1 && !/^  / {exit} {print}')
listed=$(printf '%s\n' "$newest" | grep -c '^  ')
if [ -n "$want" ] && [ "$listed" = "1" ] \
  && printf '%s\n' "$newest" | awk -v w="$want" -v r="$remote" \
    '$1 == "modules/codavox" && $2 == w && $3 == r {f = 1} END {exit !f}'; then
  ok "'$current' names modules/codavox at ${want:0:11}, $tag's commit on $remote"
else
  bad "'$current' should list only modules/codavox at '${want:-unresolved}' ($tag); got: $(printf '%s' "$out" | tr '\n' ' ')"
fi

echo
vm puppet 'sudo codavox compilers' | sed 's/^/     /'
exit "$FAILED"
