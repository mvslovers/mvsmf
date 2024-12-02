#include <stdio.h>
#include "clibwto.h"
#include "httpd.h"
#include "httpr.h"
#include "mvsmf.h"

int main(int argc, char **argv)
{
    int         rc          = 0;

    CLIBPPA     *ppa        = __ppaget();
    CLIBGRT     *grt        = __grtget();
    CLIBCRT     *crt        = __crtget();

    void        *crtapp1    = NULL;
    void        *crtapp2    = NULL;

    HTTPR       httpr       = {.routes= 0};    
    HTTPD       *httpd      = grt->grtapp1;
    HTTPC       *httpc      = grt->grtapp2;

    if (!httpd) {
        wtof("This program %s must be called by the HTTPD web server%s", argv[0], "");

        /* TSO callers might not see a WTO message, so we send a STDOUT message too */
        printf("This program %s must be called by the HTTPD web server%s", argv[0], "\n");

        return 12;
    }

    /* save for our exit/external programs */
    if (crt) {
        crtapp1         = crt->crtapp1;
        crtapp2         = crt->crtapp2;
        crt->crtapp1    = httpd;
        crt->crtapp2    = httpc;
    }

    init_router(&httpr, httpd, httpc);

    /* add the URL mappings */
    add_route(&httpr, GET, "/zosmf/info", infoHandler);
    
    add_route(&httpr, GET, "/zosmf/restjobs/jobs", jobListHandler);
    add_route(&httpr, GET, "/zosmf/restjobs/jobs/{job-name}/{jobid}/files", jobFilesHandler);
    add_route(&httpr, GET, "/zosmf/restjobs/jobs/{job-name}/{jobid}/files/{ddid}/records", jobRecordsHandler);
    add_route(&httpr, PUT, "/zosmf/restjobs/jobs", jobSubmitHandler);
    add_route(&httpr, GET, "/zosmf/restjobs/jobs/{job-name}/{jobid}", jobStatusHandler);
        
    add_route(&httpr, GET, "/zosmf/restfiles/ds", datasetListHandler);
    add_route(&httpr, GET, "/zosmf/restfiles/ds/{dataset-name}", datasetGetHandler);
    add_route(&httpr, GET, "/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}", datasetGetHandler);
    add_route(&httpr, PUT, "/zosmf/restfiles/ds/{dataset-name}", datasetPutHandler);
    add_route(&httpr, PUT, "/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}", datasetPutHandler);
    add_route(&httpr, GET, "/zosmf/restfiles/ds/{dataset-name}/member", memberListHandler);
    add_route(&httpr, GET, "/zosmf/restfiles/ds/{dataset-name}({member-name})", memberGetHandler);
    add_route(&httpr, PUT, "/zosmf/restfiles/ds/{dataset-name}({member-name})", memberPutHandler);
    
    /* dispatch the request */

    rc = handle_request(&httpr);
     		
/* TODO: error for dispatchRequest when no match is found
{
"rc": 4,
"reason": 7,
"category": 6,
"message": "No match for method GET and pathInfo='/files'"
}
*/

    if (rc != 0) {
        wtof("%s: handle_request failed with rc = %d", argv[0], rc);
    }

    /* we do not wan't to let this CGI module abend */
    rc = 0;

    /* restore crt values */
    if (crt) {
        /* restore crt values */
        crt->crtapp1    = crtapp1;
        crt->crtapp2    = crtapp2;
    }

    return rc;
}
