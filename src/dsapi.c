#include <stdio.h>
#include <string.h>
#include <clibwto.h>
#include <cliblist.h>

#include "dsapi.h"
#include "httpd.h"

int datasetListHandler(Session *session)
{
	unsigned	rc		= 0;
	unsigned	count		= 0;
	unsigned	first		= 1;
	unsigned	i		= 0;

	char		*method		= NULL;
	char		*path		= NULL;
	char		*verb		= NULL;

	DSLIST		**dslist	= NULL;

	char		*dslevel	= NULL;
	char		*volser		= NULL;
	char		*start		= NULL;

	method	= (char *) http_get_env(session->httpc, (const UCHAR *) "REQUEST_METHOD");
	path	= (char *) http_get_env(session->httpc, (const UCHAR *) "REQUEST_PATH");

	verb	= strrchr(path, '/');

	dslevel = (char *) http_get_env(session->httpc, (const UCHAR *) "QUERY_DSLEVEL"); 
	volser	= (char *) http_get_env(session->httpc, (const UCHAR *) "QUERY_VOLSER"); 
	start 	= (char *) http_get_env(session->httpc, (const UCHAR *) "QUERY_START"); 

	dslist = __listds(dslevel, "NONVSAM VOLUME", NULL);
	
	if ((rc = http_resp(session->httpc,200)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", "application/json")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Pragma: no-cache\r\n")) < 0) goto quit;	
	if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

	if ((rc = http_printf(session->httpc, "{\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"items\": [\n")) < 0) goto quit;

	if (!dslist) goto end;

	count = array_count(&dslist);

	for(i=0; i < count; i++) {
		DSLIST *ds = dslist[i];
		
		if (!ds) continue;
		
		if (first) {
			/* first time we're printing this '{' so no ',' needed */
			if ((rc = http_printf(session->httpc, "    {\n")) < 0) goto quit;
			first = 0;
		} else {
			/* all other times we need a ',' before the '{' */
			if ((rc = http_printf(session->httpc, "   ,{\n")) < 0) goto quit;
		}

		if ((rc = http_printf(session->httpc, "      \"dsname\": \"%s\",\n", ds->dsn)) < 0) goto quit;
		
		// TODO: the following fields should only be generated if X-IBM-Attributes == base
		// TODO: add vol field only if X-IBM-Attributes has 'vol'
		if (strcmp(ds->dsorg, "PO") == 0) {
			if ((rc = http_printf(session->httpc, "      \"dsntp\": \"%s\",\n", "PDS")) < 0) goto quit;
		} else if (strcmp(ds->dsorg, "PS") == 0) {
			if ((rc = http_printf(session->httpc, "      \"dsntp\": \"%s\",\n", "BASIC")) < 0) goto quit;
		} else {
			if ((rc = http_printf(session->httpc, "      \"dsntp\": \"%s\",\n", "UNKNOWN")) < 0) goto quit;
		}

		if ((rc = http_printf(session->httpc, "      \"recfm\": \"%s\",\n", ds->recfm)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"lrecl\": %d,\n", ds->lrecl)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"blksize\": %d,\n", ds->blksize)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"vol\": \"%s\",\n", ds->volser)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"vols\": \"%s\",\n", ds->volser)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"dsorg\": \"%s\",\n", ds->dsorg)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"cdate\": \"%u-%02u-%02u\",\n", ds->cryear, ds->crmon, ds->crday)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"rdate\": \"%u-%02u-%02u\"\n", ds->rfyear, ds->rfmon, ds->rfday)) < 0) goto quit;
		
		if ((rc = http_printf(session->httpc, "    }\n")) < 0) goto quit;
	}

end:
	if ((rc = http_printf(session->httpc, "  ],\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"returnedRows\": %d,\n", count)) < 0) goto quit;
	// TODO: add totalRows if X-IBM-Attributes has ',total'
	if ((rc = http_printf(session->httpc, "  \"moreRows\": false,\n")) < 0) goto quit;

	if ((rc = http_printf(session->httpc, "  \"JSONversion\": 1\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "} \n")) < 0) goto quit;

quit:
	return rc;
}

int datasetGetHandler(Session *session)
{
	unsigned	rc		= 0;

	unsigned	i		= 0;

	char 		*dsname		= NULL;
	char 		*volser		= NULL;

	char		*datatype	= NULL;
	
	FILE		*fp;
	char		*buffer;

	dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
	volser = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_volume-serial");

	if (!dsname) {
		rc = http_resp_internal_error(session->httpc);
		goto quit;
	}

	fp = fopen(dsname, "r");
	if (!fp) goto quit;

	buffer = calloc(1, fp->lrecl + 2);
	if (!buffer) {
		fclose(fp);
		goto quit;
	}

	if ((rc = http_resp(session->httpc,200)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", "application/json")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Pragma: no-cache\r\n")) < 0) goto quit;	
	if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

	while (fgets(buffer, sizeof(buffer), fp) > 0) {
		if ((rc = http_printf(session->httpc, "%s", buffer)) < 0) goto quit;
	}

	free(buffer);
	fclose(fp);
	
quit:
	return rc;
} 

int datasetPutHandler(Session *session)
{
	unsigned	rc		= 0;

	unsigned	i		= 0;

	char 		*dsname		= NULL;
	char		*volser		= NULL;

	char		*datatype	= NULL;
	char		*pattern	= NULL;

	FILE		*fp;
    char 		buffer[1024];
    int  		bytes_received;

	// path variables
	dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
	volser = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_volume-serial");

	// header variables
	datatype 	= (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_X-IBM-Data-Type"); 

	if (!dsname){
		rc = http_resp_internal_error(session->httpc);
		goto quit;
	}

	// read PUT request body
    memset(buffer, 0, sizeof(buffer));
    bytes_received = recv(session->httpc->socket, buffer, sizeof(buffer) - 1, 0);
    if (bytes_received < 0) {
		wtof("Fehler beim Lesen vom Socket");
    } else if (bytes_received == 0) {
		wtof("Verbindung geschlossen");
    } else {
		wtof("Empfangene Daten: %s", buffer);
    }

	wtof("DONE");
	
quit:
	return rc;
} 

int memberListHandler(Session *session)
{
	unsigned	rc		= 0;
	unsigned	count		= 0;
	unsigned	first		= 1;
	unsigned	i		= 0;

	char		*method		= NULL;
	char		*path		= NULL;
	char		*verb		= NULL;

	PDSLIST		**pdslist	= NULL;

	char 		*dsname		= NULL;

	char		*start		= NULL;
	char		*pattern	= NULL;


	dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
	if (!dsname){
		rc = http_resp_internal_error(session->httpc);
		goto quit;
	}

	method	= (char *) http_get_env(session->httpc, (const UCHAR *) "REQUEST_METHOD");
	path	= (char *) http_get_env(session->httpc, (const UCHAR *) "REQUEST_PATH");

	verb	= strrchr(path, '/');

	start 	= (char *) http_get_env(session->httpc, (const UCHAR *) "QUERY_START"); 
	pattern = (char *) http_get_env(session->httpc, (const UCHAR *) "QUERY_PATTERN"); 

	pdslist = __listpd(dsname, NULL);

	if ((rc = http_resp(session->httpc,200)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", "application/json")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Pragma: no-cache\r\n")) < 0) goto quit;	
	if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

	count = array_count(&pdslist);

	if ((rc = http_printf(session->httpc, "{\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"items\": [\n")) < 0) goto quit;

	if (!pdslist) {
		goto end;
	} 

	for(i=0; i < count; i++) {
		PDSLIST *pds = pdslist[i];
		
		if (!pds) continue;
		
		if (first) {
			/* first time we're printing this '{' so no ',' needed */
			if ((rc = http_printf(session->httpc, "    {\n")) < 0) goto quit;
			first = 0;
		} else {
			/* all other times we need a ',' before the '{' */
			if ((rc = http_printf(session->httpc, "   ,{\n")) < 0) goto quit;
		}

		// TODO: extract user data from pds->udata, if X-IBM-Attributes == base 
		if ((rc = http_printf(session->httpc, "      \"member\": \"%s\"\n", pds->name)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "    }\n")) < 0) goto quit;
	}

end:
	if ((rc = http_printf(session->httpc, "  ],\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"returnedRows\": %d,\n", count)) < 0) goto quit;
	// TODO: add totalRows if X-IBM-Attributes has ',total'
	if ((rc = http_printf(session->httpc, "  \"JSONversion\": 1\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "} \n")) < 0) goto quit;

quit:
	return rc;
}

int memberGetHandler(Session *session)
{
	unsigned	rc			= 0;
	unsigned	count		= 0;
	unsigned	first		= 1;
	unsigned	c,i			= 0;

	char 		*dsname		= NULL;
	char		*member		= NULL;
	
	char		*start		= NULL;
	char		*pattern	= NULL;

	char		dataset[44];
	FILE		*fp;
	char		*buffer;

	dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
	member = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_member-name");

	if (!dsname || !member){
		rc = http_resp_internal_error(session->httpc);
		goto quit;
	}
	
	/* TODO: get header and parms e.g.
	start 	= (char *) http_get_env(httpc, (const UCHAR *) "QUERY_START"); 
	pattern = (char *) http_get_env(httpc, (const UCHAR *) "QUERY_PATTERN"); 
	*/

	sprintf(dataset, "%s(%s)", dsname, member);

	fp = fopen(dataset, "r");
	if (!fp) goto quit;

	buffer = calloc(1, fp->lrecl + 2);
	if (!buffer) {
		fclose(fp);
		goto quit;
	}

	if ((rc = http_resp(session->httpc,200)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", "application/json")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Pragma: no-cache\r\n")) < 0) goto quit;	
	if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

	while (fgets(buffer, sizeof(buffer), fp) > 0) {
		if ((rc = http_printf(session->httpc, "%s", buffer)) < 0) goto quit;
	}

	free(buffer);
	fclose(fp);

quit:
	return rc;
}

int memberPutHandler(Session *session)
{
	unsigned	rc		= 0;

	unsigned	i		= 0;

	char 		*dsname		= NULL;
	char		*member		= NULL;

	char		*datatype		= NULL;
	char		*pattern	= NULL;

	FILE		*fp;
	char		*buffer;

	dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
	member = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_member-name");
	
	if (!dsname || !member){
		rc = http_resp_internal_error(session->httpc);
		goto quit;
	}

	/* TODO: get header and parms e.g.
	start 	= (char *) http_get_env(httpc, (const UCHAR *) "HTTP_START"); 
	pattern = (char *) http_get_env(httpc, (const UCHAR *) "HTTP_PATTERN"); 
	*/

	goto quit;
	
	fp = fopen(dsname, "w");
	if (!fp) goto quit;

	buffer = calloc(1, fp->lrecl + 2);
	if (!buffer) {
		fclose(fp);
		goto quit;
	}

	if ((rc = http_resp(session->httpc,200)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", "application/json")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Pragma: no-cache\r\n")) < 0) goto quit;	
	if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

	while (fgets(buffer, sizeof(buffer), fp) > 0) {
		if ((rc = http_printf(session->httpc, "%s", buffer)) < 0) goto quit;
	}

	free(buffer);
	fclose(fp);
	
quit:
	return rc;
} 
