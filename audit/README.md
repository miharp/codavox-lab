# Audit suite

The checks run against a release before announcing it. They exist because the
first time they were run — against v0.6.0, which had already been tagged — they
found a release blocker.

Run them against a lab that is already up and converged
(`vagrant up`, then confirm `codavox compilers` shows both compilers on one
`code_id`).

| batch | run from | covers |
|---|---|---|
| `a-config-and-upgrade.sh` | primary | an old config key, typos, malformed YAML, an empty file, a missing file, conffile survival |
| `b-subcommands.sh` | primary | `seal`, `seal --manifest`, `provenance` incl. honest absence, `compilers --json`, unknown flags |
| `c-integrity.sh` | primary | a tampered artifact, a missing CRL, a CRL from another CA, an empty allowlist, a nonexistent basedir |
| `d-scale.sh` | primary | a ~13 MB tree, 21 environments, reseal cost |
| `e-concurrency.sh` | **host** | rapid reseals, `SIGKILL` mid-sync, an in-flight download whose artifact is reaped, simultaneous fetches |
| `f-core.sh` | **host** | the core suite plus regressions for #47, #48, #49, #55, #56 |
| `g-deploy.sh` | primary | `codavox deploy`, and `deploy-server` token auth and history |

```console
# on the primary
vagrant ssh puppet -c 'sudo bash -s' < audit/c-integrity.sh

# from the host
bash audit/f-core.sh
```

## Two things to know before trusting a green run

**These are destructive.** `c-integrity.sh` moves the CRL aside and corrupts an
artifact; `f-core.sh` revokes compiler02's certificate and reboots it. Run them
against a lab you are willing to `vagrant destroy`, and expect the lab to need
rebuilding afterwards.

**A batch that passes has not necessarily tested what it claims.** Two checks
passed for the wrong reason during the first run: one exited non-zero on
`address already in use` rather than the empty allowlist it was checking, and
another reported a config unmodified while `rpm -V` plainly disagreed. Read the
evidence each check prints, not just the `ok`.

`c-integrity.sh` also moves the CRL while the real publisher is running, which
makes it refuse requests for a few seconds — correct fail-closed behavior, but it
will make an unrelated check in another batch fail if they overlap. Run batches
one at a time.
