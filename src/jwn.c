/*
** JES spool authorization
**
** See include/jwn.h.  Free of project and MVS headers on purpose.
*/
#include <ctype.h>
#include <string.h>

#include "jwn.h"

/* --------------------------------------------------------------------
** Components and entities
** ----------------------------------------------------------------- */
int
jwn_component_ok(const char *s)
{
    size_t i;

    if (!s || !s[0])
        return 0;
    for (i = 0; s[i]; i++) {
        if (i >= JWN_COMPMAX)
            return 0;
        if (strchr(JWN_CHARS, s[i]) == NULL)
            return 0;
    }
    return 1;
}

int
jwn_entity(char *out, int sz, const char *owner, const char *jobname,
           const char *jobid)
{
    size_t lo, lj, li;
    int need;

    if (!out || sz < 1 || !owner || !jobname || !jobid)
        return -1;
    out[0] = '\0';

    if (owner[0] && !jwn_component_ok(owner))
        return -1;
    if (!jwn_component_ok(jobname) || !jwn_component_ok(jobid))
        return -1;

    lo = strlen(owner);
    lj = strlen(jobname);
    li = strlen(jobid);
    need = (int)(lo + 1 + lj + 1 + li);
    if (need + 1 > sz)
        return -1;

    memcpy(out, owner, lo);
    out[lo] = '.';
    memcpy(out + lo + 1, jobname, lj);
    out[lo + 1 + lj] = '.';
    memcpy(out + lo + 1 + lj + 1, jobid, li);
    out[need] = '\0';
    return need;
}

int
jwn_probe(char *out, int sz, const char *userid)
{
    size_t l = 0;

    if (!out || sz < 1)
        return -1;
    out[0] = '\0';

    if (userid && userid[0]) {
        if (!jwn_component_ok(userid))
            return -1;
        l = strlen(userid);
    }
    if ((int)(l + 2 + 1) > sz)
        return -1;

    if (l)
        memcpy(out, userid, l);
    out[l] = '.';
    out[l + 1] = '.';
    out[l + 2] = '\0';
    return (int)(l + 2);
}

/* --------------------------------------------------------------------
** Ownership
** ----------------------------------------------------------------- */
#ifdef __MVS__
__asm__("\n&FUNC\tSETC 'has_filler'");
#endif
static int
has_filler(const char *s)
{
    for (; *s; s++) {
        if ((unsigned char)*s <= (unsigned char)' ')
            return 1;
    }
    return 0;
}

int
jwn_mine(const char *owner, const char *user)
{
    if (!owner || !user || !owner[0] || !user[0])
        return 0;
    if (has_filler(owner) || has_filler(user))
        return 0;
    return strcmp(owner, user) == 0;
}

/* --------------------------------------------------------------------
** Level and decision
** ----------------------------------------------------------------- */
int
jwn_level(const JWN_CTX *ctx, const char *entity, int want_update,
          JWN_RES *res)
{
    int rc;

    res->rc = -1;
    res->racf_calls = 0;

    if (!ctx || !ctx->auth_fn || !entity)
        return JWN_LV_ERR;

    rc = ctx->auth_fn(ctx->auth_arg, entity, 0);
    res->rc = rc;
    res->racf_calls = 1;
    if (rc == 4)
        return JWN_LV_NOPROFILE;
    if (rc == 8)
        return JWN_LV_NONE;
    if (rc != 0)
        return JWN_LV_ERR;
    if (!want_update)
        return JWN_LV_READ;

    rc = ctx->auth_fn(ctx->auth_arg, entity, 1);
    res->rc = rc;
    res->racf_calls = 2;
    if (rc == 0)
        return JWN_LV_UPDATE;
    if (rc == 8)
        return JWN_LV_READ;
    return JWN_LV_ERR;
}

void
jwn_cache_init(JWN_CACHE *c)
{
    if (c)
        memset(c, 0, sizeof(*c));
}

/* The level of a foreign job: from the cache if its key was asked in this
** request, otherwise from RACF (and then remembered unless the answer is
** unusable or the cache is full).  RC values are 0, 4 and 8 whenever a
** level is stored, so they fit a char. */
#ifdef __MVS__
__asm__("\n&FUNC\tSETC 'level_cached'");
#endif
static int
level_cached(const JWN_CTX *ctx, const char *entity, int want_update,
             JWN_RES *res)
{
    JWN_CACHE *c = ctx->cache;
    char key[JWN_KEYLEN + 1];
    int i, level;

    if (!c)
        return jwn_level(ctx, entity, want_update, res);

    strncpy(key, entity, JWN_KEYLEN);
    key[JWN_KEYLEN] = '\0';

    for (i = 0; i < c->n; i++) {
        if (c->e[i].update == (char)(want_update != 0) &&
            strcmp(c->e[i].key, key) == 0) {
            res->rc = c->e[i].rc;
            res->racf_calls = 0;
            return c->e[i].level;
        }
    }

    level = jwn_level(ctx, entity, want_update, res);
    if (level != JWN_LV_ERR && c->n < JWN_CACHEMAX) {
        strcpy(c->e[c->n].key, key);
        c->e[c->n].update = (char)(want_update != 0);
        c->e[c->n].level = (char)level;
        c->e[c->n].rc = (char)res->rc;
        c->n++;
    }
    return level;
}

int
jwn_decide(int op, int level)
{
    switch (level) {
    case JWN_LV_READ:
        return op == JWN_OP_PURGE ? JWN_NOPURGE : JWN_ALLOW;
    case JWN_LV_UPDATE:
        return JWN_ALLOW;
    default:
        return JWN_HIDE;
    }
}

#ifdef __MVS__
__asm__("\n&FUNC\tSETC 'reason_of'");
#endif
static int
reason_of(int level)
{
    switch (level) {
    case JWN_LV_NOPROFILE: return JWN_R_NOPROFILE;
    case JWN_LV_NONE:      return JWN_R_NONE;
    case JWN_LV_READ:      return JWN_R_READ;
    case JWN_LV_UPDATE:    return JWN_R_UPDATE;
    default:               return JWN_R_ERR_RC;
    }
}

int
jwn_check(const JWN_CTX *ctx, int op, const char *owner, const char *jobname,
          const char *jobid, JWN_RES *res)
{
    char entity[JWN_ENTSZ];
    int n;

    if (!res)
        return JWN_HIDE;

    res->decision = JWN_HIDE;
    res->reason = JWN_R_ERR_RC;
    res->level = JWN_LV_ERR;
    res->rc = -1;
    res->elen = 0;
    res->racf_calls = 0;

    if (!ctx)
        return res->decision;

    if (!ctx->acee_present || !ctx->user || !ctx->user[0]) {
        res->reason = JWN_R_NOACEE;
        return res->decision;
    }

    if (jwn_mine(owner, ctx->user)) {
        res->decision = JWN_ALLOW;
        res->reason = JWN_R_OWN;
        return res->decision;
    }

    n = jwn_entity(entity, (int)sizeof(entity), owner ? owner : "",
                   jobname ? jobname : "", jobid ? jobid : "");
    if (n < 0) {
        res->reason = JWN_R_ERR_COMPONENT;
        return res->decision;
    }
    res->elen = n;

    res->level = level_cached(ctx, entity, op == JWN_OP_PURGE, res);
    res->reason = reason_of(res->level);
    res->decision = jwn_decide(op, res->level);
    return res->decision;
}

/* --------------------------------------------------------------------
** The owner filter
** ----------------------------------------------------------------- */
int
jwn_match(const char *pattern, const char *owner)
{
    if (!pattern || !pattern[0])
        return 0;
    if (pattern[0] == '*' && pattern[1] == '\0')
        return 1;
    if (!owner || !owner[0] || !jwn_component_ok(pattern))
        return 0;
    return strcmp(owner, pattern) == 0;
}

int
jwn_narrows(const char *user, const char *value, char *canon, int sz)
{
    char up[JWN_PRTSZ];
    size_t len, i;
    int kind;

    if (canon && sz > 0)
        canon[0] = '\0';
    if (!value || !canon || sz < JWN_PRTSZ)
        return JWN_NR_BAD;

    len = strlen(value);
    if (len > JWN_COMPMAX)
        return JWN_NR_BAD;
    for (i = 0; i < len; i++)
        up[i] = (char)toupper((unsigned char)value[i]);
    up[len] = '\0';

    if (len == 0)
        kind = JWN_NR_RESET;
    else if (jwn_mine(up, user))
        kind = JWN_NR_OWN;
    else if (up[0] == '*' && up[1] == '\0')
        kind = JWN_NR_ALL;
    else if (jwn_component_ok(up))
        kind = JWN_NR_OTHER;
    else
        return JWN_NR_BAD;

    memcpy(canon, up, len + 1);
    return kind;
}

/* --------------------------------------------------------------------
** Output
** ----------------------------------------------------------------- */
void
jwn_printable(char *out, int sz, const char *value)
{
    int i = 0;

    if (!out || sz < 1)
        return;
    if (value) {
        while (value[i] && i < JWN_COMPMAX && i < sz - 1) {
            out[i] = strchr(JWN_CHARS, value[i]) ? value[i] : '?';
            i++;
        }
    }
    out[i] = '\0';
}
