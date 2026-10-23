#ifndef JWN_H
#define JWN_H
/*
** JES spool authorization (#440)
**
** Who may see, read and purge which job on the JES2 spool.  The job list,
** the job status, the spool file list, the spool file content and the purge
** ask jwn_check() once per job; the owner filter of the job list asks
** jwn_narrows() and jwn_probe().
**
** The model is the one FTPD 1.3.0 applies to its JES mode, in the order
** jwn_check() applies it:
**   1. no ACEE or no userid            -> hidden, even the user's own jobs
**   2. the job's owner is the user     -> allowed, no RACF call, no entity
**   3. entity <owner>.<jobname>.<jobid> -> a component outside [A-Z0-9$#@]
**                                          or longer than 8 is an error
**   4. RACF class JESSPOOL, READ (and, for a purge only, UPDATE)
**        no profile, no READ, error  -> hidden
**        READ                        -> list and read, purge refused
**        UPDATE or better            -> everything
**
** This file and jwn.c are free of project and MVS headers so a host unit
** test can link them (test/host/tstjwn.c).  Nothing here keeps state:
** counters and buffers belong to the caller (mvsMF is RENT).
*/

/* Characters a job name, job id or owner may consist of.  Written as a
** string, never as a range: EBCDIC letters are not contiguous. */
#define JWN_CHARS "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$#@"

#define JWN_COMPMAX     8       /* longest component                    */
#define JWN_ENTMAX      26      /* 8 + '.' + 8 + '.' + 8               */
#define JWN_ENTSZ       (JWN_ENTMAX + 1)
/* The cache key is the first 8 characters of the entity, which is right only
** because RAKF cuts an entity at 8 characters before it matches a profile.
** Should RAKF ever compare more, this must grow with it. */
#define JWN_KEYLEN      8
#define JWN_PRTSZ       (JWN_COMPMAX + 1)
#define JWN_CACHEMAX    16      /* cache keys per request               */

/* What the caller is doing.  Only a purge asks for UPDATE. */
#define JWN_OP_LIST     0       /* an entry of the job list             */
#define JWN_OP_READ     1       /* status, spool file list, content     */
#define JWN_OP_PURGE    2

/* Access level of a foreign job, lowest first. */
#define JWN_LV_ERR       0      /* unusable answer or entity            */
#define JWN_LV_NOPROFILE 1      /* the class has no profile for it      */
#define JWN_LV_NONE      2      /* a profile matches, no READ           */
#define JWN_LV_READ      3
#define JWN_LV_UPDATE    4      /* UPDATE, CONTROL or ALTER             */

/* Decision.  HIDE is 0 so that a cleared result is a closed one. */
#define JWN_HIDE        0
#define JWN_ALLOW       1
#define JWN_NOPURGE     2       /* visible, but not purgeable           */

/* Why. */
#define JWN_R_ERR_RC        0   /* bad or missing RACF answer           */
#define JWN_R_OWN           1
#define JWN_R_NOACEE        2
#define JWN_R_ERR_COMPONENT 3
#define JWN_R_NOPROFILE     4
#define JWN_R_NONE          5
#define JWN_R_READ          6
#define JWN_R_UPDATE        7

/* Answer of the owner filter classification. */
#define JWN_NR_BAD      0       /* nothing can match: empty list        */
#define JWN_NR_RESET    1       /* empty: the own userid                */
#define JWN_NR_OWN      2       /* the own userid                       */
#define JWN_NR_ALL      3       /* "*": needs READ on the probe ..      */
#define JWN_NR_OTHER    4       /* one foreign userid: probe X..        */

/* The one question to RACF: may the user have READ (want_update 0) or
** UPDATE (want_update 1) on JESSPOOL entity?  Answer is racf_auth()'s
** return code.  arg is the caller's (the request's ACEE). */
typedef int (*jwn_auth_fn)(void *arg, const char *entity, int want_update);

/* Levels found during one request, by the first JWN_KEYLEN characters of the
** entity (what RAKF compares).  A stack variable of the caller; it lives one
** request.  The 17th key is not stored and not evicted for: it is asked
** every time, which is always right and only costs more. */
typedef struct jwn_cache {
    int             n;
    struct {
        char        key[JWN_KEYLEN + 1];
        char        update;     /* asked for UPDATE as well             */
        char        level;      /* one of the JWN_LV values             */
        char        rc;         /* RACF return code the level came from */
    } e[JWN_CACHEMAX];
} JWN_CACHE;

typedef struct jwn_ctx {
    int                 acee_present;   /* the request has an ACEE      */
    const char         *user;           /* the caller, upper case       */
    jwn_auth_fn         auth_fn;        /* NULL: foreign jobs are hidden */
    void               *auth_arg;
    JWN_CACHE          *cache;          /* NULL: ask RACF every time    */
} JWN_CTX;

typedef struct jwn_res {
    int decision;       /* HIDE, ALLOW or NOPURGE, see above            */
    int reason;         /* one of the JWN_R reasons                     */
    int level;          /* a JWN_LV value, foreign jobs only            */
    int rc;             /* last RACF return code, -1 = none called      */
    int elen;           /* length of the entity, 0 = none built         */
    int racf_calls;     /* 0, 1 or 2                                    */
} JWN_RES;

void jwn_cache_init(JWN_CACHE *c)                           asm("JWNCACHI");

/* 1 if s is 1..8 characters of JWN_CHARS, else 0. */
int jwn_component_ok(const char *s)                         asm("JWNCOMPO");

/* Builds "<owner>.<jobname>.<jobid>" into out.  Every component is checked
** first; the owner alone may be empty.  Returns the length, -1 for a bad
** component or a buffer smaller than the entity needs. */
int jwn_entity(char *out, int sz, const char *owner, const char *jobname,
               const char *jobid)                           asm("JWNENTIT");

/* The owner filter probe: "X.." for a userid, ".." for "" (any owner).
** Returns the length, -1 for a bad userid or a small buffer. */
int jwn_probe(char *out, int sz, const char *userid)        asm("JWNPROBE");

/* RACF return codes to level (0/4/8 only, anything else is LV_ERR).  Asks
** READ, and UPDATE when want_update and READ gave 0.  Sets rc and
** racf_calls of res. */
int jwn_level(const JWN_CTX *ctx, const char *entity, int want_update,
              JWN_RES *res)                                 asm("JWNLEVEL");

/* 1 if owner and user are the same non-empty userid, whole length, no
** blank or control character in either.  MIKE1 is not MIKE10. */
int jwn_mine(const char *owner, const char *user)           asm("JWNMINE");

/* The decision for a foreign job at a level. */
int jwn_decide(int op, int level)                           asm("JWNDECID");

/* The whole decision; see the top of this file.  res is set closed first.
** Returns res->decision. */
int jwn_check(const JWN_CTX *ctx, int op, const char *owner,
              const char *jobname, const char *jobid, JWN_RES *res)
                                                            asm("JWNCHECK");

/* Does the owner filter value show this owner?  An exact owner or "*";
** no prefix. */
int jwn_match(const char *pattern, const char *owner)       asm("JWNMATCH");

/* Classifies an owner filter value, whole value, any case.  canon (at least
** JWN_PRTSZ bytes) receives the upper-cased value for RESET, OWN, ALL and
** OTHER, "" otherwise.  Returns JWN_NR_*. */
int jwn_narrows(const char *user, const char *value, char *canon, int sz)
                                                            asm("JWNNARRO");

/* Copies value for output: only JWN_CHARS stay, anything else becomes '?',
** at most 8 characters, always NUL terminated (nothing written for
** sz < 1). */
void jwn_printable(char *out, int sz, const char *value)    asm("JWNPRINT");

#endif /* JWN_H */
