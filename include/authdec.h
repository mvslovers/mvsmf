#ifndef AUTHDEC_H
#define AUTHDEC_H
/*
** The decision behind the console and test endpoint gate (#460)
**
** The console service and /zosmf/test need READ on the RAKF resource
** FACILITY MVSMF.CONSOLE.  This file and authdec.c decide; consauth.c asks
** RACF.  They are free of project and MVS headers so a host unit test can
** link them (test/host/tstauthd.c).
**
** Only SAF rc 0 permits.  rc 4 (no profile covers the resource) is refused on
** purpose: http_check_auth() folds it into "permitted", and for a path that
** issues operator commands "no profile" must not mean "everyone".
*/

#define AUTHDEC_ALLOW   0       /* rc 0: READ granted                     */
#define AUTHDEC_DENY    1       /* rc 4, 8, anything else                 */
#define AUTHDEC_NOACEE  2       /* the request has no identity            */

/* The question to RACF.  arg is the caller's (the request's ACEE). */
typedef int (*authdec_fn)(void *arg);

/* The decision for an answer already in hand. */
int authdec_decide(int acee_present, int rc)                asm("AUTHDDEC");

/* Asks fn only when there is an ACEE, then decides.  A NULL fn is a refusal. */
int authdec_gate(int acee_present, authdec_fn fn, void *arg) asm("AUTHDGAT");

#endif /* AUTHDEC_H */
