/*
** The decision behind the console and test endpoint gate
**
** See include/authdec.h.  Free of project and MVS headers on purpose.
*/
#include <stddef.h>

#include "authdec.h"

int
authdec_decide(int acee_present, int rc)
{
    if (!acee_present)
        return AUTHDEC_NOACEE;
    if (rc == 0)
        return AUTHDEC_ALLOW;
    return AUTHDEC_DENY;
}

int
authdec_gate(int acee_present, authdec_fn fn, void *arg)
{
    if (!acee_present)
        return AUTHDEC_NOACEE;
    if (!fn)
        return AUTHDEC_DENY;
    return authdec_decide(1, fn(arg));
}
