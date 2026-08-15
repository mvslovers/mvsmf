#include <clibary.h>
#include <clibwto.h>
#include "logmw.h"
#include "httpcgi.h"
#include "router.h"
#include "mvsmfmsg.h"

int logging_middleware(Session *session) 
{
	if (session->httpc->env) {
		unsigned count = array_count(&session->httpc->env);
		unsigned n;
		for(n=0;n<count;n++) {
			HTTPV *env = session->httpc->env[n];

			if (!env) {
				continue;
			}

			wtof(MSG_ENV_DUMP, n, env->name, env->value);
		}
	}

    return 0;
}

