#import "../bookmaster/bookmaster.typ": *

= Setting Up Security <ug-security>

#idx("security")#idx("RAKF")
mvsMF has no user database and no access rules of its own. HTTPD (httpd)
checks the user ID and the password with RAKF. From then on mvsMF works under
the identity of the caller, and RAKF decides what that identity may do. This
chapter says what mvsMF asks RAKF, what a client sees when RAKF says no, and
what the administrator defines so that the answers are the ones wanted.

Four decisions are involved:

#tab(caption: [The four security decisions of mvsMF])[
  #table(columns: (1.9in, 1.5in, 1fr),
    [Decision], [Made by], [Described in],
    [Who may use mvsMF at all], [HTTPD, with a FACILITY profile],
      [@ug-security-access],
    [Which data sets a user may read, write and delete],
      [mvsMF, with DATASET profiles], [@ug-security-dsn],
    [Which jobs a user sees, reads and purges],
      [mvsMF, with JESSPOOL profiles], [@ug-security-jesspool],
    [Who may use the console services],
      [HTTPD, with a FACILITY profile], [@ug-security-console],
  )
]

The profiles are RAKF profiles on MVS 3.8j. This chapter describes RAKF 2.0.0,
the release whose commands #cmd("RDEFINE"), #cmd("PERMIT") and #cmd("ADDUSER")
the tasks below use. @ug-security-notcovered lists what the profiles do not
govern.

#note[*Read the console after every reload.* A profile is in effect only after
the reload, and a broken table aborts the reload. @ug-security-jp-byhand says
what happens then.]

== Letting Users Use mvsMF: MVSMF.ACCESS <ug-security-access>

#idx("MVSMF.ACCESS")#idx("FACILITY class")#idx("route", "RES=")#idx("HTTPD", "route policy")
The route lines of HTTPD decide who may reach mvsMF at all. The installation
(@ug-install-routes) registers four routes of mvsMF. On the last of them, the
catch-all, the option #cmd("RES=FACILITY:MVSMF.ACCESS") adds a check: every
request to mvsMF other than the two #cmd("AUTH=NONE") routes and the console
services then needs a user who has READ access to the resource
#cmd("MVSMF.ACCESS") in the class #cmd("FACILITY"). The console services have a
route of their own (@ug-security-console). With the check, the four lines are:

#screen(```
MOD=MVSMF /zosmf/info                    AUTH=NONE
MOD=MVSMF /zosmf/services/authenticate   AUTH=NONE
MOD=MVSMF /zosmf/restconsoles/*          AUTH=TOKEN RES=FACILITY:MVSMF.CONSOLE
MOD=MVSMF /zosmf/*                       AUTH=TOKEN RES=FACILITY:MVSMF.ACCESS
```)

HTTPD works in two stages. Stage 1 authenticates the caller. #cmd("AUTH=TOKEN")
accepts a token or a user ID and a password in a Basic header, and answers a
bare #cmd("401 Unauthorized") without a challenge when neither is there.
Stage 2 runs only for an authenticated caller. It asks RAKF, under the identity
of the caller, for READ access to the resource of #cmd("RES="). The first
route line that matches the URL applies, so the lines for the narrower paths
come before the catch-all.

=== Limit mvsMF to a Group of Users <ug-security-access-task>

#idx("MVSMF.ACCESS", "defining")
To allow only the members of one group to use mvsMF:

+ Create the group by connecting the users to it (@ug-security-users). The
  group name below is #cmd("MVSMFUSR").
+ Define the resource, give the group READ, and reload the profiles. Run the
  commands in a TSO batch job. The user of the job needs the group
  #cmd("RAKFADM") (@ug-security-rakfadm).

#screen(```
//MVSMFACC JOB (ACCT),'MVSMF ACCESS',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDEF MVSMF.ACCESS CL(FACILITY) UACC(NONE)
PE MVSMF.ACCESS CL(FACILITY) ID(MVSMFUSR) ACCESS(READ)
/*
//RAKFPROF EXEC RAKFPROF
```)

The output of the commands in the step #cmd("TSO"), as the job wrote it to its
spool file #cmd("SYSTSPRT"). Both commands tell you to run #cmd("RAKFPROF"):

#screen(raw(read("../ex/ug-security/r-access-out.txt"), block: true))

The job log shows that the step #cmd("RAKFPROF") rebuilt the table:

#screen(raw(read("../ex/ug-security/r-access-log.txt"), block: true))

The member #cmd("PROFILES") now holds the two lines of the resource. The
universal access #cmd("NONE") is the line without an ID. The class fills the
columns 1 to 8, so the resource follows it without a blank. The name
#cmd("MVSMFUSR") has eight characters and fills the field of the ID (columns 53
to 60), so the access follows it without a blank. #cmd("PERMIT") wrote the line
in this form:

#screen(raw(read("../ex/ug-security/r-access-prof.txt"), block: true))

3. Put the option #cmd("RES=FACILITY:MVSMF.ACCESS") on the last route line in
   the #cmd("HTTPPRM") of HTTPD, then stop and start HTTPD (#cmd("P HTTPD"),
   #cmd("S HTTPD")). HTTPD reads its route policy only at start.

Submit the job through mvsMF (@ug-jobs), so that it runs as your own user ID.
A job that arrives without #cmd("USER=") and #cmd("PASSWORD=") runs under the
default user of the system, not under the person who submitted it.

Define the profile first. When the resource has no profile at the start of
HTTPD, HTTPD writes #cmd("HTTPD425W") and does not gate the route, so everyone
who can log in gets through. A line with a malformed #cmd("RES=") gives
#cmd("HTTPD412W"). On an #cmd("AUTH=NONE") route #cmd("RES=") is ignored
(#cmd("HTTPD414W")).

#note[*No profile means access.* At the time of a request, a resource without
a profile counts as permitted: RAKF answers "undefined resource" and HTTPD
reads that as yes. Keep the profile, and keep #cmd("UACC(NONE)") in it.]

=== What a User without Access Sees <ug-security-access-refused>

#idx("403")#idx("MVSMF.ACCESS", "refusal")
A user who has a valid password but no READ access to #cmd("MVSMF.ACCESS") gets
HTTP 403 from HTTPD on every route that the catch-all covers. The body is the
plain text #cmd("403 Forbidden"), and the content type is #cmd("text/plain").
It is not the JSON error report of the other services, because mvsMF does not
run for this request:

#screen(raw(read("../ex/ug-security/s-refused-facility.txt"), block: true))

The two #cmd("AUTH=NONE") routes are not covered by the catch-all. A user
without #cmd("MVSMF.ACCESS") therefore still gets the answer of
#cmd("/zosmf/info") and can log in for a token at
#cmd("/zosmf/services/authenticate"). Both routes check the password and
answer 401 for a wrong one. The token gives no more than the password does:
every other route answers 403.

#screen(raw(read("../ex/ug-security/s-info-open.txt"), block: true))

The sessions in this chapter send the password in a Basic header. Where that
matters, use a token instead.

== Users and Groups in RAKF <ug-security-users>

#idx("RAKF", "users")#idx("USERS member")#idx("group")#idx("ADDUSER")#idx("CONNECT")
mvsMF asks RAKF about the user ID of the caller and about the groups to which
the user is connected. Two members of #cmd("SYS1.SECURE.CNTL") hold them.
#cmd("USERS") has one line per user and group. Passwords are not in
#cmd("USERS"): RAKF 2.0.0 keeps a salted hash in #cmd("SYS1.SECURE.SHADOW").

#tab(caption: [The columns of a line of #cmd("SYS1.SECURE.CNTL(USERS)")])[
  #table(columns: (1.1in, 1fr),
    [Columns], [Content],
    [1 to 8], [User ID],
    [10 to 17], [Group],
    [18], [#cmd("*") marks the default group of a user that has several
      groups],
    [19 to 26], [Blank in RAKF 2.0.0],
    [28], [OPERATIONS: #cmd("Y") or #cmd("N")],
    [30], [SPECIAL: #cmd("Y") or #cmd("N")],
    [31 to 50], [Comment],
  )
]

A line with a star in column 1 is a comment. The lines are in ascending order
of the user ID.

=== Who May Change the Tables <ug-security-rakfadm>

#idx("RAKFADM")
The commands #cmd("ADDUSER"), #cmd("CONNECT"), #cmd("ADDSD"), #cmd("RDEFINE")
and #cmd("PERMIT") write the members #cmd("USERS") and #cmd("PROFILES") of
#cmd("SYS1.SECURE.CNTL"). The user who runs them

- is connected to the group #cmd("RAKFADM"),
- has the SPECIAL attribute (column 30 of #cmd("USERS")), and
- has update access to #cmd("SYS1.SECURE.*"), or has the OPERATIONS attribute
  along with SPECIAL. The profile #cmd("SYS1.SECURE.*") that ships with RAKF
  gives #cmd("RAKFADM") ALTER.

The commands sort the member they write and remove its comment lines. Keep a
copy of the members before the first change. The profile commands stop with a
message when the table holds about 1495 records.

The procedures that reload the tables, #cmd("RAKFPROF") and #cmd("RAKFUSER"),
need READ access to the resource #cmd("RAKFADM") in the class #cmd("FACILITY").
Without it the reload ends with the abend #cmd("U0600").

=== Add a User <ug-security-adduser>

#idx("user", "adding")
Run #cmd("ADDUSER") in a TSO batch job, and reload the users with the procedure
#cmd("RAKFUSER"). The DD statements #cmd("SYSPRINT"), #cmd("SYSTERM"),
#cmd("SYSIN") and #cmd("SYSTSPRT") are all needed. #cmd("ADDUSER") opens them
before it reads the command, and without one of them the step ends with return
code 12 and no message. Write the operands as they stand, without quotes: a
quoted operand list ends with the message #cmd("ADDUSER: Parse error"). The
first operand is the user ID. The job below defines the user #cmd("ADAMS") with
the default group #cmd("USER"), connects the user to #cmd("MVSMFUSR"), and
reloads the users:

#screen(```
//ADDUSER  JOB (ACCT),'ADDUSER',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTERM  DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 ADDUSER ADAMS PASSWORD(START123) DFLTGRP(USER) GROUP(MVSMFUSR)
/*
//RAKFUSER EXEC RAKFUSER
```)

The blank before #cmd("ADDUSER") does no harm: #cmd("ADDUSER") does not look at
the name under which it was called. The output of the step #cmd("TSO"):

#screen(raw(read("../ex/ug-security/r-adduser-out.txt"), block: true))

The job log shows that #cmd("RAKFUSER") rebuilt the user table:

#screen(raw(read("../ex/ug-security/r-adduser-log.txt"), block: true))

The member #cmd("USERS") now has two lines for the user, one for each group. The
star in column 18 marks the default group:

#screen(raw(read("../ex/ug-security/r-adduser-users.txt"), block: true))

#cmd("ADDUSER") writes one line of #cmd("USERS") for each group, with the star
on the default group, and a record in #cmd("SYS1.SECURE.SHADOW"). It folds its
input to upper case. The password has one to eight characters.
#cmd("OPERATIONS") and #cmd("SPECIAL") mark every line of the user; the
defaults are #cmd("NOOPERATIONS") and #cmd("NOSPECIAL"). The command refuses a
user that exists.

=== Connect a User to a Group <ug-security-connect>

#idx("group", "connecting a user")
A group exists as soon as a line of #cmd("USERS") names it. To connect an
existing user to one more group, run #cmd("CONNECT") in a TSO batch job with
the same DD statements as for #cmd("ADDUSER"), and reload with
#cmd("RAKFUSER") or with #cmd("S RAKFUSER") at the console. The job connects the
user #cmd("JONES") to the group #cmd("AUDIT"):

#screen(```
//CONNECT  JOB (ACCT),'CONNECT',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTERM  DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
CONNECT JONES GROUP(AUDIT)
/*
//RAKFUSER EXEC RAKFUSER
```)

The output of the step #cmd("TSO"):

#screen(raw(read("../ex/ug-security/r-connect-out.txt"), block: true))

The job log:

#screen(raw(read("../ex/ug-security/r-connect-log.txt"), block: true))

The command adds a line with the new group to #cmd("USERS"). The user
#cmd("JONES") now has three lines. The star is on the default group
#cmd("USER"):

#screen(raw(read("../ex/ug-security/r-connect-users.txt"), block: true))

HTTPD keeps the credential of a user, with the groups of the logon. A
#cmd("CONNECT") does not reach a user whose credential HTTPD already holds: the
user stays without the new group. A restart of HTTPD clears the credentials.
How long HTTPD keeps a credential is not stated here. A change to a profile
applies from the next check after the reload. This holds for every group of this
chapter, #cmd("MVSMFUSR"), #cmd("CONSOPS") and #cmd("AUDIT") included.

=== Which Identity Does Work Run Under <ug-security-identity>

#idx("identity")
Every request runs under the user ID of the caller. A job that a client
submits runs as that user too: mvsMF replaces any #cmd("USER=") on the JOB
statement with the user ID of the caller and adds the password of the caller.
The owner of the new job is the caller.

== Controlling Access to Data Sets <ug-security-dsn>

#idx("data set", "access")#idx("DATASET class")
Before mvsMF touches a data set for a caller, it asks RAKF, in the class
#cmd("DATASET"), whether the caller may do it. mvsMF folds the name to upper
case first and asks before it looks into the catalog or the VTOC. The check
for a member is the check for the library.

#tab(caption: [The access that each data set operation needs])[
  #table(columns: (3.2in, 1fr),
    [Operation], [Access],
    [Read a data set; list the members of a library; read a member], [READ],
    [Write a data set; write, rename or delete a member], [UPDATE],
    [Rename a data set (the old name and the new name are checked); delete a
      data set], [ALTER],
  )
]

@ug-data has the requests. This section is about the profiles behind them.

=== What a Refused User Sees <ug-security-dsn-refused>

#idx("data set", "refusal")
A refused operation answers HTTP 500 with an error report:

#screen(raw(read("../ex/ug-security/d-refused-read.txt"), block: true))

The report has the return code 8, the category 4, the reason 0, the message
#cmd("LMOPEN error") and the detail "Authorization failed - You may not use
this protected data set." The check runs before the data set is looked up, so
the answer does not tell whether the data set exists. mvsMF writes nothing to
the console for a refusal.

=== What Decides Create <ug-security-dsn-create>

#idx("data set", "creating")
The create request has no check of its own in mvsMF. The operating system
allocates the data set under the identity of the caller, and RAKF can refuse
it there. A failed allocation, whatever the reason, answers HTTP 500 with the
category 8, the return code 900, the reason 7 and the message "Dynamic
allocation Error". The answer does not say why. A success answers 201.

#screen(raw(read("../ex/ug-security/d-refused-create.txt"), block: true))

RAKF logs a refusal on the console. A client that reads the console services
(@ug-console) can see it there.

=== Create Needs the Catalog Too <ug-security-dsn-catalog>

#idx("data set", "creating")#idx("SYS1.VSAM.MASTER.CAT")#idx("master catalog")
A create request passes two RAKF checks, in this order:

+ *The name of the new data set.* A data set whose first qualifier is the user
  ID of the caller is always allowed. Under any other first qualifier the
  caller needs ALTER through a profile; READ is not enough. The session in
  @ug-security-dsn-create is a refusal at this step: the new name has no profile
  that gives the user access. RAKF writes #cmd("RAKF0005") and #cmd("RAKF000A")
  to the console, and #cmd("RAKF000A") names the new data set.
+ *The catalog.* When the high-level qualifier of the name has no alias in the
  catalog, the data set goes to the master catalog, and the caller needs UPDATE
  to the resource #cmd("SYS1.VSAM.MASTER.CAT") in the class #cmd("DATASET").
  Without it the allocation fails, and #cmd("RAKF000A") on the console names
  #cmd("SYS1.VSAM.MASTER.CAT") instead of the new data set.

The two refusals look the same to the client: both answer HTTP 500 with the
body of @ug-security-dsn-create (return code 900, category 8, reason 7). Tell
them apart in the log of the console, where the second message names the
resource that was refused.

To let the members of a group create data sets that the master catalog holds,
give the group UPDATE to the catalog. The job below defines the profile, adds
the group #cmd("CATUPD") with UPDATE, connects the user #cmd("SMITH") to the
group, and reloads both tables:

#screen(```
//CATALOG  JOB (ACCT),'CATALOG',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTERM  DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
ADDSD SYS1.VSAM.MASTER.CAT UACC(READ)
PE SYS1.VSAM.MASTER.CAT CLASS(DATASET) ID(CATUPD) ACCESS(UPDATE)
CONNECT SMITH GROUP(CATUPD)
/*
//RAKFPROF EXEC RAKFPROF
//RAKFUSER EXEC RAKFUSER
```)

The output of the step #cmd("TSO"):

#screen(raw(read("../ex/ug-security/r-catalog-out.txt"), block: true))

The job log shows that both tables were rebuilt:

#screen(raw(read("../ex/ug-security/r-catalog-log.txt"), block: true))

The lines in #cmd("PROFILES"):

#screen(raw(read("../ex/ug-security/r-catalog-prof.txt"), block: true))

The new group reaches #cmd("SMITH") at the next logon with a credential that
HTTPD does not hold yet (@ug-security-connect).

=== How RAKF Chooses the Profile <ug-security-dsn-match>

#idx("DATASET class", "profile matching")
RAKF holds the profiles in the order of their names. A profile matches a data
set when the data set name begins with the profile name, cut at the first star
or blank. The profile #cmd("*") matches every name. Of all profiles that match,
the *last one in the sort order decides alone.* There is no fall-through to an
earlier profile, and the longest profile does not win by being long.

Inside that profile RAKF looks first for a line with the user ID of the
caller, which decides alone. Then it looks at the lines of the groups to which
the caller is connected. If a group line matched but none gave enough access,
the answer is no, and the universal access is not consulted. The universal
access of the profile decides when no line matched.

Four more rules apply to data sets:

- *The sort order is EBCDIC.* A blank sorts before a period, a period before
  a dollar sign, a dollar sign before a star, a star before the characters
  #cmd("\#") and #cmd("@"), these before letters, and letters before digits.
- *Own data sets are granted.* A data set whose first qualifier is the user ID
  of the caller needs no profile.
- *The OPERATIONS attribute counts* in the classes DATASET, DASDVOL and
  TAPEVOL, and in no other class.
- *No profile means access.* A data set that no profile covers is permitted.
  A system without DATASET profiles lets every user do everything.

#note[*The list of names is not protected.* The listing of data sets
(#cmd("dslevel")) shows names from the catalog and makes no RAKF check. A user
sees the names of data sets that the user may not read. The profile protects
the contents.]

=== Protect a Data Set Group <ug-security-dsn-task>

#idx("ADDSD")#idx("PERMIT")
To let only the group #cmd("PAYGRP") change the data sets with the prefix
#cmd("PAYROLL."), and everyone else read them:

#screen(```
//PROTECT  JOB (ACCT),'PROTECT',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
ADDSD PAYROLL.* UACC(READ)
PE PAYROLL.* CLASS(DATASET) ID(PAYGRP) ACCESS(UPDATE)
/*
//RAKFPROF EXEC RAKFPROF
```)

The output of the step #cmd("TSO"):

#screen(raw(read("../ex/ug-security/r-protect-out.txt"), block: true))

The job log shows the reload:

#screen(raw(read("../ex/ug-security/r-protect-log.txt"), block: true))

#cmd("ADDSD") defines the profile and its universal access, always in the class
DATASET. #cmd("PERMIT") adds the line for the group, and is refused without the
universal line. In #cmd("PROFILES") the columns are the class in 1 to 8, the
profile in 9 to 52, the group or user ID in 53 to 60, and the access from 61.
The first line is the universal access and has no ID:

#screen(raw(read("../ex/ug-security/r-protect-prof.txt"), block: true))

== Protecting the Console Services <ug-security-console>

#idx("console", "protection")#idx("MVSMF.CONSOLE")#idx("FACILITY class")#idx("route", "RES=")
The console services issue operator commands. mvsMF makes no authorization
check of its own for them, and the command runs under the identity of the
caller. Any user who gets in can issue any command. HTTPD closes the gap: a
route of its own for #cmd("/zosmf/restconsoles/*") asks RAKF for READ access to
the resource #cmd("MVSMF.CONSOLE") in the class #cmd("FACILITY"). The route
lines are:

#screen(```
MOD=MVSMF /zosmf/info                    AUTH=NONE
MOD=MVSMF /zosmf/services/authenticate   AUTH=NONE
MOD=MVSMF /zosmf/restconsoles/*          AUTH=TOKEN RES=FACILITY:MVSMF.CONSOLE
MOD=MVSMF /zosmf/*                       AUTH=TOKEN
```)

The route for the console services stands above the catch-all.
HTTPD uses the first line that matches, so the catch-all would otherwise take
every console request. The sample member #cmd("MVSMFPRM") of
#cmd("MVSMF.SAMPLIB") has all four lines. If you also gate the catch-all with
#cmd("MVSMF.ACCESS"), the last line carries #cmd("RES=FACILITY:MVSMF.ACCESS")
(@ug-security-access).

=== Allow a Group to Use the Console Services <ug-security-console-task>

#idx("MVSMF.CONSOLE", "defining")
This task defines the resource, gives one group READ, and connects the users
of the group. The group #cmd("CONSOPS") and the users #cmd("SMITH") and
#cmd("IBMUSER") are examples. Run the commands in a TSO batch job as in
@ug-security-access-task. The user of the job needs the group
#cmd("RAKFADM"):

#screen(```
//CONSOLE  JOB (ACCT),'CONSOLE',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTERM  DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDEF MVSMF.CONSOLE CL(FACILITY) UACC(NONE)
PE MVSMF.CONSOLE CL(FACILITY) ID(CONSOPS) ACCESS(READ)
CONNECT SMITH GROUP(CONSOPS)
CONNECT IBMUSER GROUP(CONSOPS)
/*
//RAKFPROF EXEC RAKFPROF
//RAKFUSER EXEC RAKFUSER
```)

The output of the commands in the step #cmd("TSO"), as the job wrote it to its
spool file #cmd("SYSTSPRT"). The users #cmd("SMITH") and #cmd("IBMUSER") were
connected to the group before, so #cmd("CONNECT") says so and changes nothing:

#screen(raw(read("../ex/ug-security/r-console-out.txt"), block: true))

The job log shows that both tables were rebuilt:

#screen(raw(read("../ex/ug-security/r-console-log.txt"), block: true))

After the reload the file #cmd("PROFILES") holds the lines for the resource. The
universal access #cmd("NONE") is the line without an ID:

#screen(raw(read("../ex/ug-security/r-console-prof.txt"), block: true))

The profile takes effect at once. HTTPD asks RAKF on every request, so neither
HTTPD nor mvsMF needs a restart after you define the profile or change a
permission. Only a change of the route lines needs a restart of HTTPD. A change
of the group of a user is different: a user whose credential HTTPD already holds
keeps the groups of the logon, so the connection to #cmd("CONSOPS") does not
reach that user until HTTPD has dropped the credential
(@ug-security-connect).

=== What a User without Access Sees <ug-security-console-refused>

#idx("403")#idx("MVSMF.CONSOLE", "refusal")
A user who has a valid password but no READ access to #cmd("MVSMF.CONSOLE")
gets HTTP 403 from HTTPD on every request below
#cmd("/zosmf/restconsoles/"). The body is the plain text #cmd("403 Forbidden"),
as for #cmd("MVSMF.ACCESS") (@ug-security-access-refused). mvsMF does not
run, and the command is not issued. The user #cmd("JONES") is not in the group
#cmd("CONSOPS"):

#screen(raw(read("../ex/ug-security/g-refused.txt"), block: true))

The same user is refused the log of the console, and still reaches the
other services of mvsMF:

#screen(raw(read("../ex/ug-security/g-log.txt"), block: true))

#screen(raw(read("../ex/ug-security/g-rest.txt"), block: true))

A member of the group issues the same command:

#screen(raw(read("../ex/ug-security/g-allowed.txt"), block: true))

Tools that issue operator commands through the console service need the
permission too. MBT uses it to issue commands, for example for the restart of
a started task. The user of such a tool is a member of the group.

=== Check the Start Messages <ug-security-console-start>

#idx("HTTPD425W")
The route is gated only when the profile exists. Without a profile, HTTPD
cannot tell a protected resource from an unprotected one, and it lets everyone
through. It writes the message #cmd("HTTPD425W") when it registers the route.
The following session reads the line from the log of the console service:

#screen(raw(read("../ex/ug-security/g-warn.txt"), block: true))

With that message in the log the console services are open to every user who
can log on:

#screen(raw(read("../ex/ug-security/g-noprofile.txt"), block: true))

The messages #cmd("HTTPD036I") list the routes in the order in which HTTPD
registered them. After the start, check that the console route is above the
catch-all:

#screen(raw(read("../ex/ug-security/g-routes-gated.txt"), block: true))

If the console route is below the catch-all, HTTPD starts without a message,
the profile exists, and the route is never reached. The console services are
open to every user of mvsMF. The session below runs on a configuration with
the lines in the wrong order. The user #cmd("JONES"), who has no permission for
the console, issues a command:

#screen(raw(read("../ex/ug-security/g-routes-order.txt"), block: true))

#screen(raw(read("../ex/ug-security/g-order.txt"), block: true))

=== Users with the Console Permission Only <ug-security-console-only>

The route #cmd("/zosmf/restconsoles/*") checks #cmd("MVSMF.CONSOLE") and
nothing else. A route has one #cmd("RES="), and the first line that matches
decides, so the check of #cmd("MVSMF.ACCESS") on the catch-all does not run
for the console services. A user with READ on #cmd("MVSMF.CONSOLE") and none on
#cmd("MVSMF.ACCESS") can issue commands, and is refused by every other service.
The user #cmd("BROWN") has only the console permission:

#screen(raw(read("../ex/ug-security/g-consonly.txt"), block: true))

#screen(raw(read("../ex/ug-security/g-consonly-jobs.txt"), block: true))

Give an operator who is to use mvsMF both permissions.

#note[*A defect* (mvsmf\#460): The diagnostic endpoint #cmd("/zosmf/test") lies
under the catch-all route, so the check of #cmd("MVSMF.CONSOLE") does not apply
to it. Its functions #cmd("fn=cmd") and #cmd("fn=mtt") issue a command and
read the Master Trace Table for any user that #cmd("MVSMF.ACCESS") lets in.
Until the issue is fixed, the console gate is complete only for the routes
below #cmd("/zosmf/restconsoles/").]

The user #cmd("JONES") has no permission for the console and issues
#cmd("D T") through the diagnostic endpoint:

#screen(raw(read("../ex/ug-security/g-test.txt"), block: true))


== Letting Users See the Jobs of Others: JESSPOOL <ug-security-jesspool>

#idx("JESSPOOL")#idx("job", "security")#idx("RAKF", "JESSPOOL")
This section needs RAKF 2.0.0 or later, the release whose class table
contains #cmd("JESSPOOL"). mvsMF 1.4.0 decides for every job whether the caller
may list it, read its output and purge it. These are the decisions that FTPD
1.3.0 makes in its JES view, so one set of profiles governs both servers.

*mvsMF always shows, reads and purges the own jobs of a caller. A profile of
the class JESSPOOL regulates what the caller may see, read and purge of the
jobs of others.* A profile never restricts the own jobs of a user.

Without any JESSPOOL profile every user sees, reads and purges only the own
jobs. #cmd("owner=*") and the user ID of someone else in the owner filter list
nothing of others. *This holds for administrators too*: a user in an
administrator group sees the jobs of others only if a profile says so.

The tables of the decisions are in the chapter "Job Services", section "Job
Authorization", of the _mvsMF Reference_. This section says what the
administrator does.

=== Change from mvsMF 1.3.0 <ug-security-jp-change>

#idx("JESSPOOL", "change from 1.3.0")
#note[*Change from mvsMF 1.3.0.* In 1.3.0 every authenticated user could list,
read and purge the jobs of everyone. If your users rely on that, define the
profiles below before you upgrade. The started task #cmd("HTTPD"), for
example, is a job of another owner: #cmd("owner=*") finds it only for a
caller with READ access to it.]

What a caller gets after the upgrade, as long as no JESSPOOL profile exists:

#tab(caption: [Jobs requests in 1.3.0 and in 1.4.0 without JESSPOOL profiles])[
  #table(columns: (1.9in, 1fr, 1fr),
    [Request], [mvsMF 1.3.0], [mvsMF 1.4.0],
    [List with #cmd("owner=*")], [The jobs of every owner],
      [The own jobs of the caller],
    [List with #cmd("owner=X"), another user ID],
      [The jobs of X], [HTTP 200 and an empty list],
    [List with #cmd("owner=ABC"), while #cmd("ABCD") has jobs],
      [The jobs of ABCD too: the value was a prefix],
      [Exactly #cmd("ABC")],
    [List with a pattern, #cmd("owner=ABC*")],
      [Not a pattern: the star was an ordinary character],
      [An empty list],
    [Status, files or records of a job of another user], [Shown],
      [HTTP 404, the answer for a job that does not exist],
    [Purge of the job of another user], [Purged], [HTTP 404],
    [Any of these from an administrator],
      [No difference to any other user],
      [No difference to any other user],
  )
]

With a profile that gives the caller READ on a foreign job, the job is listed
and read as before. *A purge of a foreign job needs UPDATE.* With READ only,
the purge answers HTTP 500 with the category 4 (@ug-security-jp-ops). In 1.3.0
it was carried out.

=== What mvsMF Asks RAKF <ug-security-jp-entity>

#idx("JESSPOOL", "entity")
For a job of another owner mvsMF builds the entity

```
<owner>.<jobname>.<jobid>          for example   ABC.PAYROLL.JOB00042
```

and asks RAKF, in the class #cmd("JESSPOOL"), for READ access to it. For a
purge it asks for UPDATE as well. The owner comes first because RAKF compares
only the first eight characters of a JESSPOOL entity. With the owner first, a
profile #cmd("ABC.*") is a rule about a user. The job name and the job ID make
no difference to the profile, and there is no profile for one job. A job
without an owner has the entity #cmd(".PAYROLL.JOB00042").

The steps of the decision are:

+ A request without a user ID hides every job.
+ If the owner of the job is the caller, compared whole, the job is allowed
  and RAKF is not asked.
+ Each of the owner, the job name and the job ID has one to eight characters
  from #cmd("A") to #cmd("Z"), #cmd("0") to #cmd("9"), #cmd("$"), #cmd("#") and
  #cmd("@"). The owner may be empty. Any other job is hidden.
+ Otherwise RAKF decides: no profile, #cmd("NONE") or an error hides the job,
  #cmd("READ") lists and reads it, and #cmd("UPDATE") or better lets the
  caller purge it too.

#tab(caption: [What the access to the entity gives])[
  #table(columns: (1.6in, 1fr, 1fr),
    [Access], [List, status, files, records], [Purge],
    [No profile, or NONE], [The job is hidden], [The job is hidden],
    [READ], [Listed and read],
      [Refused with HTTP 500, category 4],
    [UPDATE, CONTROL, ALTER], [Listed and read], [The job is purged],
  )
]

A hidden job answers HTTP 404, the answer for a job that does not exist. The
reply does not tell whether the job exists. A job ID is compared whole and
must be in upper case: #cmd("JOB0012*") is not a wildcard and matches nothing.
Names in responses and messages are cleaned: a character outside the set above
becomes #cmd("?").

=== The Owner Filter of the Job List <ug-security-jp-filter>

#idx("owner filter")
The owner filter of the list only narrows the view and never widens it. The
value is folded to upper case and compared whole.

#tab(caption: [The query parameter #cmd("owner") of the job list])[
  #table(columns: (1.6in, 1fr),
    [#cmd("owner")], [What the caller gets],
    [Omitted or empty], [The own jobs],
    [The own user ID], [The own jobs],
    [#cmd("*")],
      [All jobs that the caller may read. This needs READ access to the entity
        #cmd(".."), which only a #cmd("*") profile covers. Without it the answer
        is the own jobs.],
    [Another user ID #cmd("X")],
      [The jobs of #cmd("X") that the caller may read. This needs READ access
        to the entity #cmd("X.."). Without it the answer is an empty list.],
    [A pattern such as #cmd("ABC*"), a value of more than eight characters, or
      a character outside the set],
      [An empty list (HTTP 200 and #cmd("[]")).],
  )
]

Each job of the list is checked on its own after that, so #cmd("owner=*") with
READ access to #cmd("..") still hides the jobs that a more specific profile
closes.

=== Rules for the Profiles <ug-security-jp-rules>

#idx("JESSPOOL", "rules")
These rules decide most cases. They follow from the way RAKF chooses a profile
(@ug-security-dsn-match).

+ *Write an owner profile with the star* (#cmd("OWNER.*")) only where an owner
  gives something to others or takes it away. The own jobs need no profile.
  Do not rely on a profile without a star in this class.
+ *Write at most one #cmd("*") profile,* if you mean all owners. Do not write
  #cmd("OWN*") next to #cmd("OWN.*"), and no profile that names job name
  characters (#cmd("ABC.PROD*")): only eight characters count.
+ *The last matching profile wins, not the longest.* #cmd("OWN*") beats
  #cmd("OWN.*"), because the period sorts before the star. A #cmd("*") profile
  loses against every more specific profile, except for the owners that sort
  before the star: the empty owner and a user ID that starts with #cmd("$").
  For such a user ID there is no effective owner profile against a #cmd("*")
  profile. This follows from the EBCDIC order.
+ *Look first* whether a JESSPOOL profile exists. A second line with the same
  key, or a duplicate line, aborts the reload (@ug-security-jp-byhand).
+ *Write #cmd("SYSTEM.*") with #cmd("NONE") next to every universal line that
  gives READ.* If the logs of your started tasks are listed with the owner
  #cmd("SYSTEM"), they are open to every reader as soon as a universal line
  gives READ, and that includes the log of HTTPD. Nothing enforces this line.
  Check under which owner your own started-task logs are listed. Do not create
  a user #cmd("SYSTEM"): that user would be the owner of those jobs and would
  see them whatever the profiles say.
+ *Every entity with a line for a group or a user needs a line without an ID*
  (the universal access) for the same entity: #cmd("*"), #cmd("SYSTEM.*") and
  each #cmd("OWNER.*"). #cmd("PERMIT") refuses to write it otherwise.
+ *Put the line of the administrators into every owner block.* A block
  without it falls back to its own universal access, usually #cmd("NONE"), and
  as the last matching profile it wins against #cmd("*").
+ *One connected group is enough.* The right comes from any group to which the
  user is connected in #cmd("USERS"), the default group included. The
  OPERATIONS attribute grants nothing in the class JESSPOOL.
+ *The prefix trap:* #cmd("MIKE1.*") does not match the jobs of #cmd("MIKE10").
  The entity of such a job is #cmd("MIKE10.JOBE.JOB00016"), and it falls to the
  #cmd("*") profile.
+ *The owner needs no line.* The own jobs are decided before RAKF is asked.
+ *A job without an owner falls under #cmd("*").* A reader of #cmd("*") sees
  it, and no profile can exclude it, because the period sorts before the star.
  #cmd("SYSTEM.*") with #cmd("NONE") does not cover it.
+ *Every user ID that is the owner of jobs and may use mvsMF lists, reads and
  purges those jobs,* whatever the profiles say. When you create a user ID,
  check that it is not already the owner of jobs.
+ *The JESSPOOL view of the jobs is not audit evidence.* The owner of a job is
  what JES2 recorded.

Only the first eight characters of a JESSPOOL entity count, and mvsMF keeps the
same eight characters as the key of its cache. Do not raise the entity maximum
of the JESSPOOL class in the class table of RAKF without changing the source of
mvsMF.

=== Create the Profiles <ug-security-jp-create>

#idx("RDEFINE")#idx("PERMIT")
Create the profiles with the commands #cmd("RDEFINE") (#cmd("RDEF")) and
#cmd("PERMIT") (#cmd("PE")). Do not edit #cmd("PROFILES") by hand. The commands
need the user and the job of @ug-security-rakfadm. The syntax is

```
RDEFINE 'resource' CLASS(class) UACC(NONE|READ|UPDATE|CONTROL|ALTER)
PERMIT  'resource' CLASS(class) ID(id) ACCESS(NONE|READ|UPDATE|CONTROL|ALTER)
```

- #cmd("RDEFINE") writes the universal line of a profile. It refuses a profile
  that exists, and a class that RAKF does not know.
- #cmd("PERMIT") adds a line for an ID, which is a group or a user ID. RAKF
  does not check the ID: a line matches a user whose ID is that name, and every
  user connected to a group of that name. #cmd("PERMIT") refuses a profile
  that has no universal line. It replaces the access of an identical line of
  class, profile and ID instead of writing a second one. The default access is
  #cmd("NONE"), the default class #cmd("DATASET").
- *Write #cmd("RDEFINE") and #cmd("RDEF") from column 1.* The program that
  serves #cmd("RDEFINE") and #cmd("ADDSD") decides from the first four
  characters of the command text whether it was called as #cmd("RDEF"). With a
  leading blank it does not take that branch: it works as #cmd("ADDSD"), takes
  no notice of #cmd("CLASS"), and defines a profile of the class DATASET. The
  sessions of this chapter write every #cmd("RDEF"), #cmd("PE") and
  #cmd("ADDSD") from column 1.
- Define the profile with #cmd("RDEFINE") before you use #cmd("PERMIT") on it.
- The reload is part of every sequence. Run the procedure #cmd("RAKFPROF") as
  the last step of the job, or enter #cmd("S RAKFPROF") at the console. The
  console shows #cmd("RAKFPROF7  RAKF PROFILES UPDATED") when it worked.

To withdraw a profile, run #cmd("RDELETE 'resource' CLASS(class)"). It removes
all lines of the resource, the universal line too. With #cmd("ID(id)") it
removes the line of that ID only. Then reload.

=== Let Users See Only Their Own Jobs <ug-security-jp-own>

#idx("JESSPOOL", "own jobs only")
Do nothing. Without a JESSPOOL profile every user lists, reads and purges only
the own jobs. If JESSPOOL profiles exist and you want this state back, remove
the profiles with #cmd("RDELETE") and reload (@ug-security-jp-create).

=== Let Auditors Read All Jobs <ug-security-jp-audit>

#idx("JESSPOOL", "auditors")
The auditors are the members of the group #cmd("AUDIT"). They read all jobs
except the logs of the started tasks, and they purge none. Everyone else keeps
the own jobs. Run the commands in a TSO batch job like the one in
@ug-security-access-task:

#screen(```
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(AUDIT) ACCESS(READ)
RDEF SYSTEM.* CL(JESSPOOL) UACC(NONE)
```)

The output of the step #cmd("TSO"):

#screen(raw(read("../ex/ug-security/r-audit-out.txt"), block: true))

The job log shows the reload:

#screen(raw(read("../ex/ug-security/r-audit-log.txt"), block: true))

After the reload #cmd("PROFILES") has these lines. The columns are as in
@ug-security-dsn-task. The class #cmd("JESSPOOL") has eight characters and
fills its field, so the profile follows it without a blank:

#screen(raw(read("../ex/ug-security/r-audit-prof.txt"), block: true))

The universal #cmd("NONE") closes the jobs of others to everyone. #cmd("AUDIT")
reads them, because the group line of the same profile gives READ. An auditor
lists them with #cmd("owner=*"): READ access to the entity #cmd("..") comes
from the #cmd("*") profile. Jobs without an owner fall under #cmd("*"), so an
auditor reads them, and nothing can exclude them.

The session below lists as a second user who is connected to #cmd("AUDIT"). The
first user, who owns the job, submitted it as in @ug-security-jp-check:

#screen(raw(read("../ex/ug-security/j-list-audit.txt"), block: true))

READ does not purge. The same auditor gets this answer for a purge of that job.
The body has the shape of every refusal of the data set services (category 4,
message #cmd("LMOPEN error")):

#screen(raw(read("../ex/ug-security/j-purge-read.txt"), block: true))

=== Let Operators Purge <ug-security-jp-ops>

#idx("JESSPOOL", "purge")#idx("purge")
A purge needs UPDATE. The group #cmd("OPS") reads all jobs and purges them, and
everyone purges the own jobs:

#screen(```
//JPOPS    JOB (ACCT),'OPS',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDEF * CL(JESSPOOL) UACC(READ)
PE * CL(JESSPOOL) ID(OPS) ACCESS(UPDATE)
RDEF SYSTEM.* CL(JESSPOOL) UACC(NONE)
/*
//RAKFPROF EXEC RAKFPROF
```)

The output of the step #cmd("TSO"):

#screen(raw(read("../ex/ug-security/r-ops-out.txt"), block: true))

The job log is the one of @ug-security-jp-audit: #cmd("RAKFPROF7  RAKF PROFILES
UPDATED"). The lines in #cmd("PROFILES"):

#screen(raw(read("../ex/ug-security/r-ops-prof.txt"), block: true))

The line #cmd("SYSTEM.*") with #cmd("NONE") closes the logs of the started
tasks for #cmd("OPS") too. To open them for #cmd("OPS"), add a line with the
ID #cmd("OPS") and the access READ or UPDATE to that profile. Jobs without an
owner are readable for everyone.

A caller who has READ only is refused the purge (@ug-security-jp-audit).

=== Let a Group Administer All Jobs <ug-security-jp-admin>

#idx("JESSPOOL", "administrators")
The members of #cmd("ADMIN") see, read and purge all foreign jobs, the logs of
the started tasks and the jobs without an owner included. Everyone else sees
the own jobs:

#screen(```
//JPADMIN  JOB (ACCT),'ADMIN',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
/*
//RAKFPROF EXEC RAKFPROF
```)

The output of the step #cmd("TSO"):

#screen(raw(read("../ex/ug-security/r-admin-out.txt"), block: true))

The lines in #cmd("PROFILES"):

#screen(raw(read("../ex/ug-security/r-admin-prof.txt"), block: true))

To keep the logs of the started tasks from #cmd("ADMIN"), add #cmd("SYSTEM.*")
with #cmd("NONE"). Without an #cmd("ADMIN") line in that block the group is
shut out as well (rule 7 in @ug-security-jp-rules).

To let everyone read everything except the started-task logs, and only
#cmd("ADMIN") purge, use the commands of @ug-security-jp-ops with the group
#cmd("ADMIN") in place of #cmd("OPS"). The group #cmd("ADMIN") then has no
access to the started tasks unless you add a line with the ID #cmd("ADMIN") and
the access UPDATE to the profile #cmd("SYSTEM.*").

=== Let Two Users See Each Other's Jobs <ug-security-jp-pair>

#idx("JESSPOOL", "pair of users")
The users #cmd("MIKE1") and #cmd("MIKE2") read and purge each other's jobs,
the group #cmd("ADMIN") everything, and everyone else sees the own jobs. Each
of the two gets an owner block, and #cmd("ADMIN") appears in both:

#screen(```
//JPPAIR   JOB (ACCT),'PAIR',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
RDEF MIKE1.* CL(JESSPOOL) UACC(NONE)
PE MIKE1.* CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
PE MIKE1.* CL(JESSPOOL) ID(MIKE2) ACCESS(UPDATE)
RDEF MIKE2.* CL(JESSPOOL) UACC(NONE)
PE MIKE2.* CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
PE MIKE2.* CL(JESSPOOL) ID(MIKE1) ACCESS(UPDATE)
/*
//RAKFPROF EXEC RAKFPROF
```)

The lines in #cmd("PROFILES"), in the order in which RAKF keeps them:

#screen(raw(read("../ex/ug-security/r-pair-prof.txt"), block: true))

#cmd("MIKE2") lists the jobs of #cmd("MIKE1") with #cmd("owner=MIKE1"): READ
access to #cmd("MIKE1..") comes from the profile #cmd("MIKE1.*").
#cmd("owner=*") needs READ access to #cmd(".."), and only the #cmd("*") profile
covers it, so #cmd("MIKE2") gets the own jobs with it. The profile
#cmd("MIKE1.*") does not cover #cmd("MIKE10") (rule 9).

=== Writing PROFILES by Hand and Recovering <ug-security-jp-byhand>

#idx("PROFILES member")#idx("RAKFPROF")#idx("U0400")#idx("U0300")
The loader reads #cmd("SYS1.SECURE.CNTL(PROFILES)") when the procedure
#cmd("RAKFPROF") runs. It holds 2000 records. The layout is the one of the
lines above: the class in columns 1 to 8, the entity from column 9, the ID in
columns 53 to 60 and the access from column 61. A star in column 1 makes a
comment. The lines must be in strictly ascending order of class, entity and
ID; the commands keep them so.

If you edit the member by hand, these abends reject it:

#tab(caption: [Abends of the reload of PROFILES])[
  #table(columns: (0.9in, 1fr),
    [Abend], [Cause],
    [#cmd("U0300")], [A line is out of order, or a line is a duplicate.],
    [#cmd("U0400")], [A line with an ID has no line without an ID for the same
      entity, also for #cmd("*") itself. The message is
      #cmd("RAKFPROF4  PERMIT RECORD WITHOUT UNIVERSAL ACCESS RECORD").],
    [#cmd("U0500")], [A line with an ID that is blank where one is needed, or
      an entity line without an access.],
    [#cmd("U0600")], [The user has no READ access to #cmd("RAKFADM") in the
      class FACILITY. The message is #cmd("RAKF008W").],
    [#cmd("U0200")], [The member has no records.],
  )
]

An abend leaves the old tables active. The broken member stays as it is.
Correct it and run #cmd("S RAKFPROF") again. The console shows
#cmd("RAKFPROF7  RAKF PROFILES UPDATED") when the reload worked.

=== Check It <ug-security-jp-check>

#idx("JESSPOOL", "checking")
Check the result with two users. The first command submits a job as the first
user, who owns it. The job stays in the output queue:

#screen(raw(read("../ex/ug-security/j-submit.txt"), block: true))

The owner sees the job. List with #cmd("owner=*") and a prefix:

#screen(raw(read("../ex/ug-security/j-list-own.txt"), block: true))

A second user, for whom no profile names the first user, gets an empty list,
and a 404 for the job:

#screen(raw(read("../ex/ug-security/j-list-user2.txt"), block: true))

#screen(raw(read("../ex/ug-security/j-status-user2.txt"), block: true))

When the profiles change, repeat the check with a member of each group that a
profile names, and read the console after every reload.

#note[*A new job has no owner for a while.* The answer to the submit
request names the submitting user as the owner. JES2 writes the owner during
conversion. Until then the job has none, and the decision for it is the one for a
job without an owner (rule 11 in @ug-security-jp-rules): the entity falls under
the profile #cmd("*"). Where no profile gives the caller READ there, a status,
a file list or a purge is answered 404, like a hidden job. A caller who polls
right after the submit may see 404 for a short time.]

=== When It Does Not Work <ug-security-jp-trouble>

#idx("JESSPOOL", "troubleshooting")
#tab(caption: [Symptoms of the JESSPOOL profiles])[
  #table(columns: (2.1in, 1fr),
    [Symptom], [Cause],
    [#cmd("S RAKFPROF") ends with #cmd("U0400")],
      [A line with an ID has no line without an ID for the same entity. The old
        tables stay in effect.],
    [#cmd("PERMIT: No universal access record found")],
      [The profile has no #cmd("RDEFINE") yet. Define it first.],
    [HTTP 404 right after a submit, later 200],
      [JES2 has not written the owner yet, and no #cmd("*") profile gives the
        caller READ.],
    [HTTP 404 for a job that exists],
      [The job belongs to another owner and no profile gives READ. Or the job
        ID is not in upper case.],
    [#cmd("owner=*") lists only the own jobs],
      [No READ access to the entity #cmd(".."). Only a #cmd("*") profile covers
        it.],
    [#cmd("owner=X") answers #cmd("[]")],
      [No READ access to #cmd("X.."), or X is a pattern, is longer than eight
        characters or has a character outside the set.],
    [A purge answers HTTP 500, category 4], [READ without UPDATE.],
    [An administrator sees only the own jobs],
      [Administrators have no special right in this class. Add a line for the
        group (@ug-security-jp-admin).],
    [The started task #cmd("HTTPD") is not in the list],
      [It is a job of another owner and needs a profile like any other.],
    [Foreign jobs are hidden for everyone, and the console shows
      #cmd("RAKF0012")],
      [The class is missing from the class table of the running RAKF. RAKF
        writes the message for every check. The own jobs stay visible.],
  )
]

== What the Profiles Do Not Cover <ug-security-notcovered>

#idx("security", "limits")#idx("/zosmf/test")
The profiles above decide the data set and job services of mvsMF. These
surfaces reach the system without them:

- *The test endpoint.* #cmd("/zosmf/test") is registered in the default
  build. #cmd("fn=cmd") issues an operator command and #cmd("fn=mtt") reads the
  Master Trace Table. The check of #cmd("MVSMF.ACCESS") is the only one that
  applies (@ug-security-console-only).
  #cmd("fn=listds"), #cmd("fn=locate") and #cmd("fn=dscb") read the catalog
  and the VTOC with no data set check. #cmd("fn=password") prints the password
  of the caller, masked, and unmasked with #cmd("reveal=1"). The job probes
  #cmd("fn=job"), #cmd("fn=spool") and #cmd("fn=syslog") do follow the
  JESSPOOL rules. A build with #cmd("-DMVSMF_NO_TEST_ENDPOINT") leaves the
  endpoint out and answers 404. In the default build every user who passes the
  #cmd("MVSMF.ACCESS") check reaches it.
- *USS files.* RAKF profiles do not protect the files of the UFS. mvsMF hands
  the user ID and the group of the caller to UFSD, and UFSD decides by the
  permission bits of the file (@ug-uss).
- *The list of data set names.* The listing is not checked
  (@ug-security-dsn-match).
- *TSO, SDSF and FTP.* They are separate interfaces. The profiles of this
  chapter say nothing about who can read the spool or a data set through them.
  FTPD asks RAKF the same way for its own users (see "Setting Up Security" in
  the _FTPD User's Guide_).

#note[*Check the build you run.* Whether #cmd("/zosmf/test") answers 404
depends on how mvsMF was built, not on a setting. Ask for
#cmd("/zosmf/test?fn=version") with a user who has access, and look at the
status.]
