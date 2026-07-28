# codavox-lab

A control repo and Vagrant topology whose only job is to validate
[codavox](https://github.com/miharp/codavox) against real OpenVox Server nodes.

It follows the
[OpenVox getting-started workflow](https://docs.openvoxproject.org/openvox/latest/getting_started.html)
and slots codavox into the gap that guide leaves open: the guide gets resolved code
onto **the primary**, and says nothing about getting it onto a compiler, because
OpenVox Server ships without Code Manager or file sync.

## Why this exists separately

codavox was first wired into a general-purpose dev control repo, and it did not
fit. That repo serves `production` from a synced working tree so an edit appears on
the next agent run with no deploy step. codavox distributes sealed, immutable,
content-addressed versions. Those requirements are opposed, and every attempt to
reconcile them cost something:

- the working tree could not be sealed at all — `.onceover/` holds rspec-puppet
  fixture symlinks pointing at absolute host paths, which codavox refuses to unpack
- the compiler could never serve `production`, because codavox repoints
  `environmentpath` rather than adding to it
- static catalogs had to be turned **off** on the primary, losing a real capability
  purely to the conflict

Following the getting-started guide removes all of it. r10k deploys a clean
resolved tree into `/etc/puppetlabs/code/environments`, and that directory is
exactly what codavox is designed to seal.

## Topology

All four nodes are **EL9** (`bento/rockylinux-9`), matching what codavox's own
integration harness and ovadm validate on (`rockylinux/rockylinux:9-ubi-init`).

Deliberately not EL10. This lab exists to find codavox bugs, and EL10 is far enough
ahead of the Puppet module ecosystem that its gaps surface as failures that look
like codavox problems — the dev control repo needed seven lines of postgresql and
dnf overrides for it, and `puppetlabs/firewall` cannot persist rules there at all.

| node | IP | serves | gets code from |
|---|---|---|---|
| `puppet` | 192.168.57.10 | **no agents** | r10k, from `file:///vagrant-src/.git` |
| `compiler01` | 192.168.57.11 | `agent01` | codavox agent |
| `compiler02` | 192.168.57.12 | nothing yet | codavox agent |
| `agent01` | 192.168.57.13 | — | `compiler01` |

The primary serves no agents on purpose. That is how a real multi-compiler estate
is laid out, and it keeps static catalogs purely a codavox property — no node here
can produce a `code_id` by any other means, so there is nowhere for a wrong one to
come from.

**Two compilers**, because one can only ever demonstrate convergence. Two can
demonstrate divergence — see [Things worth trying](#things-worth-trying).

`192.168.57.x` so this lab and a `192.168.56.x` dev repo can both be up at once.

### Memory

About **7.4 GB** across the four VMs: 2560 for the primary, 2048 per compiler, 768
for the agent. puppetserver's default heap is `-Xms2g -Xmx2g`, which would fill a
2 GB VM and get the JVM OOM-killed, so provisioning caps it at 1 GB. That is a lab
setting, not advice — a real compiler wants the default.

Bring-up is sequential, so peak usage is roughly the total. If the host is tight,
`vagrant up puppet compiler01 agent01` gives a working chain minus the divergence
demo.

## Getting started

```console
vagrant up
```

Bring-up is sequential: the compilers enrol against the primary's CA and poll its
publisher, so the primary has to finish first.

Then:

```console
vagrant ssh puppet -c 'sudo codavox compilers'
```

```text
COMPILER                ENVIRONMENT  CODE_ID       COMMIT        LAST POLL
compiler01.example.com  production   3224ddbe7e3d  a3f1c9e4b2d8  4s ago
compiler02.example.com  production   3224ddbe7e3d  a3f1c9e4b2d8  7s ago
```

Both on one `code_id`, each reporting it from its own environment symlink — the
same one its `code-id` reads.

## How this maps to the guide

| guide step | here |
|---|---|
| Install OpenVox Server | `dnf install openvox-server` on the primary and both compilers |
| Enrol agents: `puppet agent --test`, `puppetserver ca list`, `ca sign` | same, but the three certnames are in `autosign.conf` so provisioning is non-interactive. `pp_role` is written to `csr_attributes.yaml` **before** first check-in |
| Control repo, default branch `production` | this repo |
| `gem install r10k` | same |
| `/etc/puppetlabs/r10k/r10k.yaml`, `cachedir: /var/cache/r10k` | same |
| `basedir: /etc/puppetlabs/code/environments` | same — **and this is `codavox::basedir`** |
| `r10k deploy environment -v` | same, then `systemctl reload codavox-publish` |

### The two deviations, and why

**The r10k remote is `file:///vagrant-src/.git`**, not an https URL. The repo is
synced into the primary read-only and r10k clones from its `.git`, so the loop is
*commit → deploy* rather than *push → deploy* and the control repo needs no remote
host. Module fetches still reach the network — the Puppetfile pulls from the Forge
and from GitHub — so this is not an air-gapped lab, just one that does not require
pushing to iterate.

Nothing downstream changes: r10k still produces a real resolved tree from a
committed branch, so an uncommitted edit is invisible to the fleet. That is the
point, not a limitation.

**`pp_role` is set before enrolment.** The guide does not mention it, because
nothing in base OpenVox needs it. codavox's publisher does: a certificate signed by
the CA only proves the peer is *some* enrolled node, and every agent in the estate
clears that bar. `pp_role` is an X.509 extension, so it is fixed when the
certificate is issued — it cannot be added later without revoking and re-enrolling,
which is why it has to be in `csr_attributes.yaml` from the first boot.

## The iteration loop

```console
# edit something, then:
git commit -am 'change the marker'
./scripts/deploy --watch
```

`scripts/deploy` runs `r10k deploy environment production`, sends the publisher a
`SIGHUP` to reseal, and with `--watch` waits until both compilers report the same
new `code_id`.

**Uncommitted changes are not deployed**, and the script says so. r10k deploys
committed branches.

## Things worth trying

### Divergence, and catch-up

The property codavox exists for, and the one a single compiler cannot show:

```console
vagrant ssh compiler02 -c 'sudo systemctl stop codavox-agent'
git commit -am 'a deploy compiler02 will miss'
./scripts/deploy
vagrant ssh puppet -c 'sudo codavox compilers'
```

compiler01 moves, compiler02 does not, and the fleet view reports two different
`code_id`s. Nothing is broken — compiler02 is honestly serving the older version,
and says so. Then:

```console
vagrant ssh compiler02 -c 'sudo systemctl start codavox-agent'
```

It catches up on its next poll, with no event replayed to it. A webhook would have
lost that deploy permanently.

### A static catalog carrying the served code_id

```console
vagrant ssh agent01 -c 'sudo /opt/puppetlabs/bin/puppet agent -t'
vagrant ssh agent01 -c 'grep -o "\"code_id\":\"[^\"]*\"" \
  /opt/puppetlabs/puppet/cache/client_data/catalog/agent01.example.com.json'
vagrant ssh compiler01 -c 'sudo codavox code-id production'
```

The two must match. `agent01` has no codavox on it at all — it just asked a
compiler for a catalog, so a match means the `code_id`, the artifact, the symlink
swap, and `code-content` all held together.

### Revocation taking effect without a restart

```console
vagrant ssh puppet -c 'sudo puppetserver ca revoke --certname compiler02.example.com'
./scripts/deploy
vagrant ssh puppet -c 'sudo journalctl -u codavox-publish --no-pager -n 20 | grep -i revoked'
```

compiler02 stops receiving code on its next poll. The publisher checks the CRL on
**every request**, not just at handshake — which matters because the agent polls
over one keep-alive connection and never handshakes again.

### No fallback

```console
vagrant ssh compiler01 -c 'sudo codavox code-id nonexistent; echo "exit=$?"'
```

Exits non-zero. codavox never invents a `code_id`, and OpenVox Server treats a
non-zero exit as a hard error rather than compiling something plausible.

## Testing without VMs

```console
bundle install
bundle exec onceover run spec
```

Onceover compiles every role against a node factset. It proves a role is *valid* —
**not** that any node is classified into it. `manifests/site.pp` owns that, and the
two have to be kept in agreement by hand. A role listed in `spec/onceover.yaml`
with no matching node definition compiles clean forever while never running on
anything, which is a mistake that has already been made once.

## Layout

| path | what |
|---|---|
| `Vagrantfile` | the four nodes and their provisioning |
| `Puppetfile` | four modules, including `codavox` pinned by tag |
| `manifests/site.pp` | node definitions; keep in step with onceover |
| `data/` | Hiera; all `codavox::*` settings live here |
| `site-modules/profile/` | `base`, `openvox_server`, `codavox::primary`, `codavox::compiler` |
| `site-modules/role/` | `primary`, `compiler`, `agent` |
| `scripts/deploy` | deploy, reseal, and optionally wait for the fleet |
