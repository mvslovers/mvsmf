# Job spool authorization: who may see, read and purge which job

mvsMF 1.4.0 decides for every job whether the caller may list it, read its
output and purge it. The jobs endpoints (`/zosmf/restjobs/jobs/...`) apply this,
and so does the job lookup of the `/zosmf/test` endpoint. The RAKF class
`JESSPOOL` holds the rules. They are the rules FTPD 1.3.0 applies to its JES
mode, so one set of profiles governs both servers.

> **mvsMF always shows, reads and purges your own jobs; a profile of the class
> JESSPOOL regulates what you may see, read and purge of the jobs of others.**
> A JESSPOOL profile never restricts a user's own jobs; it only decides what a
> user may see, read and purge of other users' jobs.

The profiles regulate the REST channel only. They say nothing about who can
read the spool through TSO, SDSF, FTP or another interface.

Without any JESSPOOL profile nothing else is visible: every user lists, reads
and purges only their own jobs, and `owner=*` or another user's id in the owner
filter lists nothing of others. **That includes administrators**: a user in a
RAKF administrator group sees the jobs of others only if a profile says so.
That is the state of mvsMF 1.4.0 without any action.

The authorization needs **RAKF 2.0.0 or later**, the release whose class table
contains `JESSPOOL`.

## Change from mvsMF 1.3.0

> **Change from mvsMF 1.3.0:** any authenticated user could list, read and purge
> the jobs of everyone, and an administrator was no different from anyone else.
> If you relied on seeing or purging other users' jobs, define the profiles
> below **before** you upgrade. For example the started task `HTTPD` is a job
> of another owner: `owner=*` finds it only for a caller with READ on it.

What a caller sees after the upgrade, when no JESSPOOL profile exists:

| Request | mvsMF 1.3.0 | mvsMF 1.4.0 |
|---------|-------------|-------------|
| list with `owner=*` | the jobs of every owner | the caller's own jobs |
| list with `owner=X` (another user id) | the jobs of `X` | an empty list, HTTP 200 `[]` |
| list with `owner=ABC`, while the owner `ABCD` has jobs | the jobs of `ABCD` as well: the value was compared as a prefix | exactly `ABC` (`ABC` does not match `ABCD`) |
| list with a pattern (`owner=ABC*`) | not a pattern: the `*` was compared like any other character | an empty list |
| status, spool files, records of another user's job | shown | HTTP 404, the answer for a job that does not exist |
| purge of another user's job | purged | HTTP 404 |
| any of these requests from an administrator | no difference to any other user | no difference to any other user: own jobs only |

With a profile that gives the caller READ on a foreign job, the job is listed
and read as before. **A purge of a foreign job needs UPDATE.** With READ only,
the purge answers HTTP 500, category 4 (see below); in 1.3.0 it was carried
out.

The owner filter is upper-cased, so `owner=abc` is the user id `ABC`. An empty
`owner=` means your own jobs. A job id is compared as written, so the id in the
path must be upper case.

## What mvsMF asks RACF

For a job of another owner mvsMF builds the entity

```
<owner>.<jobname>.<jobid>          for example   ABC.PAYROLL.JOB00042
```

and asks RACF for READ on it in the class `JESSPOOL` (and, for a purge, for
UPDATE). The owner comes first because RAKF compares only the first **8**
characters of an entity: with the owner first, a profile `OWNER.*` is a rule
about a user. A job without an owner has the entity `.<jobname>.<jobid>`.

| Access to the entity | list, status, spool files, records | purge |
|----------------------|------------------------------------|-------|
| no profile covers it, or `NONE` | the job is hidden | hidden |
| `READ` | listed and read | refused: HTTP 500, category 4, "Authorization failed - You may not purge this job." |
| `UPDATE`, `CONTROL`, `ALTER` | listed and read | the job is purged |

The refusal of a purge with READ has the shape of every refusal of this API,
the one of the data set services (HTTP 500, not 403, which is not a z/OSMF
status):

```
{"rc":8,"category":4,"reason":0,"message":"LMOPEN error",
 "details":["Authorization failed - You may not purge this job."]}
```

A hidden job is answered with the same 404 as a job that does not exist (the
text names the job name and job id of the request), so the reply does not tell
whether the job exists.

Further rules:

- **A job whose owner is not known is never "own".** It falls under the
  profile `.<jobname>.<jobid>`, which only a `*` profile covers.
- **A job name, job id or owner with a character outside `A-Z 0-9 $ # @`, or
  longer than 8 characters, is hidden** for everyone but its owner.
- **A job id is compared whole.** `JOB0012*` is not a wildcard, it matches
  nothing.
- **Any other answer of RACF, and a request without an identity, hides the
  job.** A failure never opens a job.
- Job names, ids, owners and step names in a response, an error text or an
  operator message are sanitized: a character outside the set above becomes
  `?`.

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
cut to eight characters.

Each job of the list is then checked on its own, so `owner=*` with READ on `..`
still hides the jobs a more specific profile closes.

## Rules for profiles

1. **Write an owner profile only where an owner gives something to others or
   takes it away, and always with the star: `OWNER.*`** (for example `ABC.*`).
   Your own jobs need no profile. Always write the owner profile with the
   star, `OWNER.*`. Do not rely on a profile without a star in the class
   JESSPOOL: prefix matching is designed for DATASET only.
2. **At most one `*` profile**, if you mean all owners. No `OWN*` next to
   `OWN.*`, no profile that names job name characters (`ABC.PROD*`).
3. **Why:** among several matching profiles the **last** one in EBCDIC order
   wins, not the longest. `OWN*` beats `OWN.*` (`.` sorts before `*`), and a
   `*` profile loses against every more specific profile, except for owners
   that sort before `*`: the empty owner (`.`) and a user id that starts with
   `$`. For a user id that starts with `$` there is no effective owner profile
   against a `*` profile: the profile for `$ABC` sorts before `*` and loses
   against it. (Derived from the EBCDIC collating order, not measured.)
4. **Look first** whether a generic JESSPOOL profile exists. A second line with
   the same key, or a duplicate line, aborts the reload (`U0300`, below).
5. Job name and job ID make no difference (only eight characters count). There
   is no profile per job.
6. **Required line: `SYSTEM.*` with `NONE` next to every universal reader
   line.** All started tasks run under the owner `SYSTEM`; as soon as a
   universal line grants READ, the logs of all started tasks, including that
   of HTTPD, are open to every reader. Nothing enforces this line. Check under
   which owner your own started-task logs are listed before you rely on it, and
   do not create a user `SYSTEM` (it would then count as the owner of those
   jobs and see them whatever the profiles say).
7. **Every entity that has a line with an id needs a line without an id (the
   universal access) for the same entity: `OWNER.*`, `SYSTEM.*` and `*`
   itself.** See the warning below for what happens otherwise.
8. **Put the administrators' line into every owner block.** As soon as an owner
   profile exists, a role that should see that owner's jobs needs a line in it:
   a block without it falls back to its own universal access (`NONE`) and, as
   the last matching profile, wins against `*`.
9. **One connected group is enough.** The right comes from any group the user
   is connected to in `USERS` (the default group included), not from
   OPERATIONS. In the class JESSPOOL the OPERATIONS attribute grants no access;
   it does so only in the classes DATASET, TAPEVOL and DASDVOL (as in IBM RACF).
10. **The prefix trap:** `MIKE1.*` does not match `MIKE10.JOBE.JOB00016` (the
    prefix of the profile is `MIKE1.`); that job falls to `*`. Likewise
    `MIKE1` is not the owner of the jobs of `MIKE10` and vice versa.
11. **The owner needs no line.** Their own jobs are decided before RACF.
12. **Jobs without an owner** fall under `*`. A reader of `*` (READ) sees them,
    and no profile can exclude them (`.` sorts before `*`); `SYSTEM.*` with
    `NONE` does not cover them.
13. **Every user id that occurs as the owner of jobs and may log in to mvsMF
    lists, reads and purges its own jobs, whatever the JESSPOOL profiles say.**
    When you create a user id, check that it is not already the owner of jobs.
14. **The owner of a job is chosen by the submitting client; the JESSPOOL view
    of a job is not audit evidence.**

Do not raise the JESSPOOL entity maximum above 8 without adjusting the mvsMF key
(`JWN_KEYLEN` in the source).

## Create the profiles with the RAKF commands

Create the profiles with the RAKF commands `RDEFINE` and `PERMIT` and reload the
in-core tables with `S RAKFPROF`, rather than editing
`SYS1.SECURE.CNTL(PROFILES)` by hand. The commands come with RAKF 2.0.0.

```
RDEFINE 'resource' CLASS(class) UACC(NONE|READ|UPDATE|CONTROL|ALTER)      (alias RDEF)
PERMIT  'resource' CLASS(class) ID(group) ACCESS(NONE|READ|UPDATE|CONTROL|ALTER)   (alias PE)
```

- **Who may run them:** the user must be connected to the group `RAKFADM` and
  should have the SPECIAL authority (RAKF 2.0.0 `HELP` for `RDEFINE` and
  `PERMIT`: "You must be connected to the RAKFADM group." and "The issuing user
  should have the SPECIAL authority. Update access to the SYS1.SECURE.* dataset
  is necessary or the issuing user should have the OPERATIONS authority along
  with the SPECIAL authority."). SPECIAL is column 30 of `USERS`.
- `RDEFINE` creates the universal line of a profile, `PERMIT` adds a line for
  a group. `PERMIT` is refused for a profile without a universal line
  (`PERMIT: No universal access record found`), so the trap of rule 7 does not
  exist when you use the commands. For each
  profile `RDEFINE` comes before `PERMIT`.
- **Start every command in column 1.** In a TSO batch step a command with a
  leading blank is not run as written: ` RDEF * CL(JESSPOOL) ...` answers
  `ADDSD  : Profile already defined`, ` PE ...` answers
  `PERMIT: No universal access record found`, the job ends with return code 8
  and `JESSPOOL` stays unchanged.
- **A reload is part of every sequence.** Without `S RAKFPROF` the profile is
  not in effect. A successful reload is acknowledged on the console with
  `RAKFPROF7  RAKF PROFILES UPDATED`. A changed group membership applies after a
  new login.
- The commands sort the records and remove comment lines from `PROFILES`;
  comments in the file are lost with the first command. They accept up to
  1495 (`RDEFINE`) or 1500 (`PERMIT`) records (from the RAKF source, not
  measured), fewer than the loader (2000).
- `RDEFINE` refuses an existing profile ("Profile already defined"); `PERMIT`
  replaces the access of an existing combination of class, profile and id
  instead of writing a second line (from the RAKF source, not measured).
- The class must be known to the running RAKF; an unknown class is refused with
  RC 8 (`Class … unknown to RAKF`).

Keep a copy of `PROFILES` before the first change.

### Examples

Each example is a sequence of commands; the lines below it show what `PROFILES`
contains afterwards. The commands and the lines are the same for FTPD and mvsMF:
the profiles belong to RAKF, not to the server.

**A. Auditors read all jobs except the started tasks; everyone else only their
own.**

```
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(AUDIT) ACCESS(READ)
RDEF SYSTEM.* CL(JESSPOOL) UACC(NONE)
S RAKFPROF
```

```
         1         2         3         4         5         6
123456789012345678901234567890123456789012345678901234567890123456
JESSPOOL*                                                   NONE
JESSPOOL*                                           AUDIT   READ
JESSPOOLSYSTEM.*                                            NONE
```

`*` `NONE` closes foreign jobs for everyone, AUDIT reads foreign jobs (READ, no
purge) except the started-task logs (`SYSTEM.*` `NONE`). Everyone keeps their
own jobs. Jobs without an owner fall under `*`: an auditor can read them and
they cannot be excluded. An auditor lists all of them with `owner=*` (READ on
`..` comes from the `*` profile).

**B. Everyone reads everything, only OPS purges.**

```
RDEF * CL(JESSPOOL) UACC(READ)
PE * CL(JESSPOOL) ID(OPS) ACCESS(UPDATE)
RDEF SYSTEM.* CL(JESSPOOL) UACC(NONE)
S RAKFPROF
```

```
JESSPOOL*                                                   READ
JESSPOOL*                                           OPS     UPDATE
JESSPOOLSYSTEM.*                                            NONE
```

Everyone also purges their own jobs. **The line `SYSTEM.*` `NONE` is
required** (rule 6): without it all started-task logs are open to every reader.
It closes them for OPS as well; to open them for OPS add `SYSTEM.*` with the id
`OPS` and `READ` right behind it. Jobs without an owner are readable for
everyone and cannot be excluded. `owner=*` works for everyone.

**C. Nothing.** Create no profile: everyone sees, reads and purges only their
own jobs.

**D. Everyone sees and purges their own jobs; the group ADMIN sees and purges
all.**

```
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
S RAKFPROF
```

```
JESSPOOL*                                                   NONE
JESSPOOL*                                           ADMIN   UPDATE
```

Members of ADMIN (one connected group is enough, rule 9) see, read and purge all
foreign jobs, the started-task logs and jobs without an owner included. If
ADMIN should not get the started-task logs, add `SYSTEM.*` `NONE`; without an
ADMIN line in that block ADMIN is shut out as well (rule 8).

**E. Everyone reads everything except the started-task logs; ADMIN purges;
everyone purges their own.**

```
RDEF * CL(JESSPOOL) UACC(READ)
PE * CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
RDEF SYSTEM.* CL(JESSPOOL) UACC(NONE)
S RAKFPROF
```

```
JESSPOOL*                                                   READ
JESSPOOL*                                           ADMIN   UPDATE
JESSPOOLSYSTEM.*                                            NONE
```

`SYSTEM.*` `NONE` is required (rule 6) and closes the started-task logs for
ADMIN as well; if the administrators should read them, add `SYSTEM.*` with the
id `ADMIN` and `UPDATE`. Jobs without an owner are readable for everyone.

**F. A pair, MIKE1 and MIKE2, may read and purge each other's jobs; ADMIN all;
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

```
JESSPOOL*                                                   NONE
JESSPOOL*                                           ADMIN   UPDATE
JESSPOOLMIKE1.*                                             NONE
JESSPOOLMIKE1.*                                     ADMIN   UPDATE
JESSPOOLMIKE1.*                                     MIKE2   UPDATE
JESSPOOLMIKE2.*                                             NONE
JESSPOOLMIKE2.*                                     ADMIN   UPDATE
JESSPOOLMIKE2.*                                     MIKE1   UPDATE
```

`ID()` takes a user id here, although the `HELP` text speaks of a group (not
verified beyond the test images); the commands accepted it there and wrote the
lines shown. The ADMIN line in both blocks is
required (rule 8); `MIKE1.*` does not cover the jobs of `MIKE10` (rule 10).
MIKE2 lists MIKE1's jobs with `owner=MIKE1` (READ on `MIKE1..`, granted by the
profile `MIKE1.*`); `owner=*` needs READ on `..`, which only the `*` profile
covers, so MIKE2 gets their own jobs with it.

### The order of the lines and the placement in `profiles.txt`

The loader sorts the lines itself, so their order does not matter. Keeping them
in ascending order makes the file easier to read and duplicate lines easier to
see. In the `profiles.txt` that ships with RAKF the classes are in the order
`DASDVOL`, `DATASET`, `FACILITY`, `TAPEVOL`, `TERMINAL`; `JESSPOOL` sorts between
`FACILITY` and `TAPEVOL`.

### Writing `PROFILES` by hand

If you edit the member instead of using the commands, the rules of the RAKF
`PROFILES` table apply, and one more: **a line with an id needs a line without
an id for the same entity, also for `*` itself.** If it is missing, for example
`JESSPOOL*  ADMIN UPDATE` without `JESSPOOL*  NONE`, `S RAKFPROF` reports

```
RAKFPROF4  PERMIT RECORD WITHOUT UNIVERSAL ACCESS RECORD
RAKFPROF4  **  PROGRAM TERMINATED  **
IEF450I RAKFPROF RAKFPROF - ABEND S000 U0400
```

and `RAKFPROF8` before it names the offending record. A duplicate line aborts
the reload with `U0300` (`RAKFPROF3`), and a line without an access with `U0500`.

An aborted reload leaves the old chain in effect; the broken file stays where it
is, and **on RAKF 2.0.0 it prevents JES2 from starting at the next IPL.** Fix it
before the next IPL: write the correct file and run `S RAKFPROF`;
`RAKFPROF7  RAKF PROFILES UPDATED` confirms it. Always look at the console
after `S RAKFPROF`.

## What else to know

- **Empty class:** no JESSPOOL line means RACF answers "no profile" (RC 4):
  everyone sees only their own jobs.
- **Class not defined:** if the class is missing from the class table of the
  running RAKF, RAKF writes `RAKF0012` to the console for every check (a client
  can flood the console with it) and foreign jobs are hidden for everybody; own
  jobs stay visible.
- **Missing or invalid RAKF tables.** On RAKF 2.0.0 JES2 does not start without
  valid tables (measured with a broken `PROFILES` and a broken `USERS` at a cold
  start); have valid tables **before** the IPL. The older RAKF of the MVS/CE
  container images allows everything in that case.
- **Withdrawing by group membership** takes effect only after the person has
  logged in again. For an immediate withdrawal change the profile (a user
  permit with `NONE`).
- The loader holds 2000 records without a range check; every owner profile costs
  several lines (example F: three per block).
- **Jobs of the same owner share a profile.** There is no profile per job.
- **Submit** answers with the submitting user as the owner of the new job.
  That holds for the answer to the submit request only. JES2 writes the owner
  during conversion, and until then the job has none: a status, file list,
  spool read or purge of it, sent by the same caller, is answered 404 like a
  hidden job (rule 12: a job without an owner is nobody's). A caller who polls
  right after a submit may therefore see 404 for a while. This is intended: the
  services do not guess an owner they were not told.
- **Console output:** the operator messages of mvsMF name a job only after the
  caller has been cleared for it, or when the caller submitted it, and job
  names and ids in them are sanitized. The console service reads the Master
  Trace Table and is a separate surface, see the next section.

## What the policy does not cover

JESSPOOL decides the job services only: list, status, files, records and purge
under `/zosmf/restjobs/jobs`, and the job probes (`fn=job`, `fn=spool`,
`fn=syslog`) of `/zosmf/test`. Two other surfaces reach jobs without it.

- **Console services** (`/zosmf/restconsoles`). Any authenticated user can issue
  an operator command, including `$P` or `$C` for the job of somebody else,
  and read the Master Trace Table, whose message texts name jobs (for example
  `$HASP395 jobname ENDED`) and carry job numbers, whatever their owner.
  `consapi.c` makes no authorization call. See [Issue Command](endpoints/console/issue-command.md) and
  [#347](https://github.com/mvslovers/mvsmf/issues/347).
- **`fn=cmd` of `/zosmf/test`.** It issues operator commands the same way. The
  endpoint is registered in the default build. A build with
  `-DMVSMF_NO_TEST_ENDPOINT` leaves `/zosmf/test` unregistered, and it answers
  404.

A JESSPOOL profile does not keep a user from reaching a job through these two.
To remove `/zosmf/test`, build with `-DMVSMF_NO_TEST_ENDPOINT`. For the console
services, a `RES=FACILITY:MVSMF.ACCESS` check on the catch-all route decides who
may use mvsMF at all, not who may use the console services alone; see
[Register the routes](installation.md#4-register-the-routes).

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

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| `S RAKFPROF` ends with `ABEND S000 U0400` | A profile line with an id has no line without an id for the same entity. The old tables stay in effect |
| `PERMIT: No universal access record found` | The profile has no `RDEFINE` yet: define it first |
| HTTP 404 right after a submit, later 200 | JES2 has not written the owner yet: a job without an owner is nobody's. Poll again |
| HTTP 404 for a job that exists | The job is hidden: it belongs to another owner and no JESSPOOL profile gives you READ. Or the job id is not written in upper case |
| `owner=*` lists only your own jobs | No READ on the entity `..` (only a `*` profile covers it) |
| `owner=X` gives `[]` | No READ on the entity `X..`, or `X` is a pattern, longer than 8 characters or has a character outside `A-Z 0-9 $ # @` |
| a purge answers HTTP 500, category 4 | READ without UPDATE on the job |
| an administrator sees only their own jobs | Administrators have no special right in the class JESSPOOL: add a line for their group (examples D and E) |
| the started task `HTTPD` is not in the list | It is a job of another owner: it needs a profile like any other |
