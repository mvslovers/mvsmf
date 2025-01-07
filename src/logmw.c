#include "logmw.h"
#include "httpd.h"
#include "router.h"

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

			wtof("MVSMF42T env[%u] \"%s\"=\"%s\"", n, env->name, env->value);
		}
	}

    return 0;
}

