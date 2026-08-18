# Test JCL

Fixtures used by `tests/curl-jobs.sh` and by hand.

| file | job ends as | `JCTCNVRC` | `JCTJTFLG` | `retcode` |
|---|---|---|---|---|
| `iefbr14.jcl` | clean | `77000000` | `00` | `CC 0000` |
| `condfail.jcl` | `IEF451I ENDED BY CC 0012` | `7700000C` | `C0` | `CC 0012` |
| `abendjob.jcl` | `IEF450I ABEND S806` | `77806000` | `20` | `ABEND S806` |
| `jclerror.jcl` | `IEF452I JOB NOT RUN - JCL ERROR` | `00000004` | `00` | `JCL ERROR` |
| `allocpds.jcl` | allocates the test PDS — **no suite uses it any more** | — | — | — |

The four above are the regression set for the `retcode` decoding (#305) —
between them they cover every branch of it. Read the raw fields back with
`/zosmf/test?fn=job&jobname=NAME`.

A fifth case has no fixture because it is site-specific: a job whose step
fails **allocation** (`IEF245I INCONSISTENT UNIT NAME AND VOLUME SERIAL`,
`IEF453I JOB FAILED - JCL ERROR`) leaves `JCTCNVRC` at `77000000` — identical
to a clean run — and is distinguished only by `JCTJTFLG` = `80`. Provoke one
by requesting a UNIT/VOLUME pair the target system does not have.

**Every card in the regression set carries `NOTIFY`, and that is load-bearing.**
Without it JES2 writes none of these fields, because `HASPSSSM` gates them all
on `CLI JCTTSUAF,0` — see `docs/endpoints/jobs/status.md`.

`nonotify.jcl` is the one fixture that deliberately has no `NOTIFY`, and it is
not part of the matrix above — its raw fields have not been measured. Its point
is that a job submitted through `PUT /zosmf/restjobs/jobs` reports a `retcode`
at all, which it can only do if mvsMF injected a `NOTIFY` on submit (#307). It
runs IDCAMS on a bogus command, so the expected answer is `CC 0012`; submitted
by any other route it reports `null`.

Neither suite uses `allocpds.jcl` any more. It names a UNIT/VOLUME pair, so it
JCL-errors on any stand that does not have that pair — setup then failed,
`SETUP_DONE` stayed 0, and every dataset-submit test skipped while the suite
still reported green. Both suites now allocate the test PDS through the files
API instead (`curl-jobs.sh` with `POST /zosmf/restfiles/ds/<pds>`,
`zowe-jobs.sh` with `zowe files create data-set-partitioned`), which works on
any stand. The file is kept only for allocating the PDS by hand; prefer the
suites' `--setup`.

`largejcl.jcl` is a 130 KB body for the submit path, not part of the matrix.
