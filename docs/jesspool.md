# Job spool authorization: who may see, read and purge which job

mvsMF decides for every job whether the caller may list it, read its output
and purge it. The jobs endpoints (`/zosmf/restjobs/jobs/...`) apply this, and
so does the job lookup of the `/zosmf/test` endpoint. The RAKF class `JESSPOOL`
holds the rules. They are the rules FTPD 1.3.0 applies to its JES mode, so one
set of profiles governs both servers.

> **mvsMF always shows, reads and purges the caller's own jobs. A profile of the
> class JESSPOOL regulates what the caller may see, read and purge of the jobs
> of others.** A JESSPOOL profile never restricts a user's own jobs.

The profiles regulate the REST channel only. They say nothing about who can
read the spool through TSO, SDSF, FTP or another interface.

Without any JESSPOOL profile nothing else is visible: every user lists, reads
and purges only their own jobs. **That includes administrators**: a user in a
RAKF administrator group sees the jobs of others only if a profile says so.
Define the profiles below **before** you rely on seeing other users' jobs (for
example the started task `HTTPD` through `owner=*`).

> **Change from mvsMF 1.3.0 and before:** any authenticated user could list,
> read and purge the jobs of everyone. If you relied on that, define the
> profiles below before you upgrade.

## What mvsMF asks RACF

For a job of another owner mvsMF builds the entity

```
<owner>.<jobname>.<jobid>          for example   ABC.PAYROLL.JOB00042
```

and asks RACF for READ on it in the class `JESSPOOL` (and, for a purge, for
UPDATE). The owner comes first because RAKF compares only the first **8**
characters of an entity: with the owner first, a profile `OWNER.*` is a rule
about a user.

| Access to the entity | list, status, spool files, records | purge |
|----------------------|------------------------------------|-------|
| no profile covers it, or `NONE` | hidden | hidden |
| `READ` | allowed | refused: HTTP 500, category 4, "Authorization failed - You may not purge this job." |
| `UPDATE`, `CONTROL`, `ALTER` | allowed | allowed |

Further rules:

- **Hidden is not found.** A hidden job answers with exactly the 404 a job that
  does not exist gets, so the reply does not tell whether the job exists.
- **A job whose owner is not known is never "own".** It falls under the
  profile `.<jobname>.<jobid>`, which only a `*` profile covers.
- **A job name, job id or owner with a character outside `A-Z 0-9 $ # @`, or
  longer than 8 characters, is hidden** for everyone but its owner.
- **A job id is compared whole.** `JOB0012*` is not a wildcard, it matches
  nothing.
- **Any other answer of RACF, and a request without an identity, hides the
  job.** A failure never opens a job.
- Job names, ids, owners and step names in a response, a log or an operator
  message are sanitized: a character outside the set above becomes `?`.

### The owner filter of the job list

`GET /zosmf/restjobs/jobs?owner=...` only narrows the view, never widens it.
The value is one user id (compared whole: `ABC` does not match `ABCD`, any
case) or `*` for all owners.

| `owner` | what you get |
|---------|--------------|
| omitted or empty | your own jobs |
| your own user id | your own jobs |
| `*` | all jobs you may read: needs READ on the entity `..`. Without it the answer is your own jobs |
| another user id `X` | the jobs of `X` you may read: needs READ on the entity `X..`. Without it the answer is an empty list |
| a pattern (`ABC*`), a value of more than eight characters, a character outside `A-Z 0-9 $ # @` | an empty list |

An empty list is HTTP 200 with `[]`, like every empty listing. A value is never
cut to eight characters. A prefix pattern such as `ABC*` was matched as a
prefix before; it is not supported any more.

Each job of the list is then checked on its own, so `owner=*` with READ on `..`
still hides the jobs a more specific profile closes.

## Rules for profiles

1. **Write an owner profile only where an owner gives something to others or
   takes it away, and always with the star: `OWNER.*`** (for example `ABC.*`).
   Your own jobs need no profile. Do not rely on a profile without a star in
   the class JESSPOOL: prefix matching is designed for DATASET only.
2. **At most one `*` profile**, if you mean all owners. No `OWN*` next to
   `OWN.*`, no profile that names job name characters (`ABC.PROD*`).
3. **Why:** among several matching profiles the **last** one in EBCDIC order
   wins, not the longest. `OWN*` beats `OWN.*` (`.` sorts before `*`), and a
   `*` profile loses against every more specific profile, except for owners
   that sort before `*`: the empty owner (`.`) and a user id that starts with
   `$`.
4. **Look first** whether a generic JESSPOOL profile exists. A second line with
   the same key, or a duplicate line, aborts the reload (`U0300`).
5. Job name and job id make no difference (only eight characters count). There
   is no profile per job.
6. **Required line: `SYSTEM.*` with `NONE` next to every universal reader
   line.** All started tasks run under the owner `SYSTEM`; as soon as a
   universal line grants READ, the logs of all started tasks are open to every
   reader. Nothing enforces this line. Do not create a user `SYSTEM`.
7. **Every entity that has a line with an id needs a line without an id (the
   universal access) for the same entity: `OWNER.*`, `SYSTEM.*` and `*`
   itself.** The RAKF commands below enforce this.
8. **Put the administrators' line into every owner block.** As soon as an owner
   profile exists, a role that should see that owner's jobs needs a line in
   it: a block without it falls back to its own universal access (`NONE`) and,
   as the last matching profile, wins against `*`.
9. **One connected group is enough.** The right comes from any group the user
   is connected to in `USERS`. In the class JESSPOOL the OPERATIONS attribute
   grants no access.
10. **The prefix trap:** `MIKE1.*` does not match `MIKE10.JOBE.JOB00016`; that
    job falls to `*`.
11. **The owner needs no line.** Their own jobs are decided before RACF.
12. **The owner of a job is chosen by the submitting client; the JESSPOOL view
    of a job is not audit evidence.**

## Create the profiles with the RAKF commands

Create the profiles with `RDEFINE` and `PERMIT` and reload the in-core tables
with `S RAKFPROF`, rather than editing `SYS1.SECURE.CNTL(PROFILES)` by hand.
The commands come with RAKF 2.0.0 and run under TSO as a user connected to the
group `RAKFADM`.

```
RDEFINE 'resource' CLASS(class) UACC(NONE|READ|UPDATE|CONTROL|ALTER)      (alias RDEF)
PERMIT  'resource' CLASS(class) ID(group) ACCESS(NONE|READ|UPDATE|CONTROL|ALTER)   (alias PE)
```

`RDEFINE` creates the universal line of a profile, `PERMIT` adds a line for a
group, `RDEFINE` comes first. **A reload is part of every sequence**: without
`S RAKFPROF` the profile is not in effect. A successful reload is acknowledged
on the console with `RAKFPROF7  RAKF PROFILES UPDATED`.

Keep a copy of `PROFILES` before the first change.

### Examples

**A. Administrators (group ADMIN) see, read and purge all jobs; everyone else
only their own.**

```
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
S RAKFPROF
```

Members of ADMIN also get the started-task logs and the jobs without an owner.
If ADMIN should not get the started-task logs, add `SYSTEM.*` with `NONE`;
without an ADMIN line in that block ADMIN is shut out as well (rule 8).
The test suite `tests/curl-jesspool.sh` runs this case.

**B. Auditors read all jobs except the started tasks; everyone else only their
own.**

```
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(AUDIT) ACCESS(READ)
RDEF SYSTEM.* CL(JESSPOOL) UACC(NONE)
S RAKFPROF
```

**C. Everyone reads everything, only OPS purges.**

```
RDEF * CL(JESSPOOL) UACC(READ)
PE * CL(JESSPOOL) ID(OPS) ACCESS(UPDATE)
RDEF SYSTEM.* CL(JESSPOOL) UACC(NONE)
S RAKFPROF
```

`SYSTEM.*` `NONE` is required (rule 6). `owner=*` works for everyone.

**D. Nothing.** Create no profile: everyone sees, reads and purges only their
own jobs.

**E. A pair, MIKE1 and MIKE2, may read and purge each other's jobs; ADMIN all;
otherwise everyone sees only their own.**

```
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
RDEF MIKE1.* CL(JESSPOOL) UACC(NONE)
PE MIKE1.* CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
PE MIKE1.* CL(JESSPOOL) ID(MIKE2) ACCESS(UPDATE)
RDEF MIKE2.* CL(JESSPOOL) UACC(NONE)
PE MIKE2.* CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
PE MIKE2.* CL(JESSPOOL) ID(MIKE1) ACCESS(UPDATE)
S RAKFPROF
```

MIKE2 lists MIKE1's jobs with `owner=MIKE1` (READ on `MIKE1..`, granted by the
profile `MIKE1.*`); `owner=*` needs READ on `..`, which only the `*` profile
covers, so MIKE2 gets their own jobs with it.

## What else to know

- **Empty class:** no JESSPOOL line means RACF answers "no profile": everyone
  sees only their own jobs.
- **Class not defined:** if the class is missing from the class table of the
  running RAKF, foreign jobs are hidden for everybody; own jobs stay visible.
- **Missing or invalid RAKF tables:** have valid tables before the IPL. On RAKF
  2.0.0 JES2 does not start without them.
- **Withdrawing by group membership** takes effect only after the person has
  logged in again. For an immediate withdrawal change the profile.
- **Jobs of the same owner share a profile.** There is no profile per job.
- **Submit** answers with the submitting user as the owner of the new job,
  and the new job is the caller's own: the caller can poll it right away.
- **Console output:** mvsMF's own operator messages carry no job data of
  others, and job names, ids and owners in them are sanitized. The console
  service reads the Master Trace Table and is a separate surface, see
  [console](endpoints/console/).

## Check it

1. Log in as an ordinary user: `GET /zosmf/restjobs/jobs?owner=*` lists only
   your own jobs, and the status of another user's job answers 404.
2. Log in as a member of the group that a profile permits: the listing shows
   the foreign jobs, the spool files can be read; a purge answers HTTP 500
   with READ and HTTP 200 with UPDATE.
3. After every `S RAKFPROF` read the console.

The automated check is `mbt run rest-tests -- curl-jesspool` (a throwaway
system with RAKF 2.0.0 and an administrator as the test user: it writes
`SYS1.SECURE.CNTL(PROFILES)` and puts it back).
