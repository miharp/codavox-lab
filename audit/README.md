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
| `h-release-0.8.sh` | **host** | 0.8: module passthroughs, `--modules`, the r10k timeout, the extraction cap, and a webhook branch deletion purged end to end |

Use the runner, which knows which batch goes where and records what happened:

```console
bash audit/run.sh          # every batch, in order
bash audit/run.sh f        # one batch
bash audit/run.sh e f      # several
```

Or invoke a batch directly, if you would rather not record the run:

```console
# on the primary
vagrant ssh puppet -c 'sudo bash -s' < audit/c-integrity.sh

# from the host
bash audit/f-core.sh
```

## The record

`audit/run.sh` appends one JSON line per check to `audit/results.jsonl` and
commits it, carrying the codavox version and the repo commit the run happened
against. It stores the **evidence** each check printed, not just the verdict,
because the verdict is the part that lies.

That is what makes the failure mode below detectable across runs rather than
only by reading the script. After each run it reports any check whose evidence
is byte-identical to the previous run. For a static assertion that is expected —
`B3: refused` should never change. For a check that claims something *moved*, it
is the signature of one that has stopped testing anything:

```console
jq -r 'select(.check=="F12") | "\(.run) \(.detail)"' audit/results.jsonl
```

The batches refuse to start when the working tree is dirty. They commit to this
repo to trigger deploys, and `git commit` takes what it is given — an unrelated
edit was once committed under a batch's message, and was also the only reason a
check went green.

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

The inverse happens too. A check can go red for a state the suite created on a
previous run rather than a defect — `f-core.sh` revokes compiler02 and cannot
un-revoke it, so on a second run that node is legitimately absent from the fleet
view. F2 now recognizes that case and says so instead of failing. A stale red
teaches you to ignore reds, which is worse than the failure it reports.

`c-integrity.sh` also moves the CRL while the real publisher is running, which
makes it refuse requests for a few seconds — correct fail-closed behavior, but it
will make an unrelated check in another batch fail if they overlap. Run batches
one at a time.
