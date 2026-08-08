#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <clibary.h>
#include <clibwto.h>
#include <cliblist.h>
#include <clibdscb.h>
#include <clibio.h>
#include <osdcb.h>
#include <errno.h>

#include "dsapi.h"
#include "dsapi_err.h"
#include "common.h"
#include "httpcgi.h"

// Record format flags
#define FIXED     0x0001
#define VARIABLE  0x0002
#define UNDEFINED 0x0004

// Constants for better readability and maintainability
#define MAX_DATASET_NAME 44
#define MAX_MEMBER_NAME 8
// Qualified form DSN(MEMBER): 44 + '(' + 8 + ')' + NUL
#define MAX_QUALIFIED_DSN (MAX_DATASET_NAME + 1 + MAX_MEMBER_NAME + 1 + 1)
#define HTTP_OK 200
#define DEFAULT_JOB_CLASS 'A'

// Data type constants
#define DATA_TYPE_TEXT     1
#define DATA_TYPE_BINARY   2
#define DATA_TYPE_RECORD   3

// Error codes
#define ERR_INVALID_PARAM -1
#define ERR_MEMORY -2
#define ERR_IO -3

// Forward declarations
static int handle_error(Session *session, int error_code, const char* message);
static int send_standard_headers(Session *session, const char* content_type);
static int process_rename(Session *session, const char *target_dsn,
                          const char *target_member);

// Helper functions for memory management
static void cleanup_resources(char* buffer, FILE* fp) {
    if (buffer) {
        free(buffer);
        buffer = NULL;
    }
    if (fp) {
        fclose(fp);
        fp = NULL;
    }
}

static char* allocate_buffer(FILE* fp, int* rc) {
    if (!fp || fp->lrecl <= 0) {
        *rc = ERR_INVALID_PARAM;
        return NULL;
    }

    char* buffer = calloc(1, fp->lrecl + 2);
    if (!buffer) {
        *rc = ERR_MEMORY;
    }
    return buffer;
}

// Helper function for HTTP headers
static int send_standard_headers(Session *session, const char* content_type) {
    int rc = 0;

    session->headers_sent = 1;
    if ((rc = http_resp(session->httpc, HTTP_OK)) < 0) return rc;
    if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) return rc;
    if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", content_type)) < 0) return rc;
    if ((rc = http_printf(session->httpc, "Pragma: no-cache\r\n")) < 0) return rc;
    if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) return rc;
    if ((rc = http_printf(session->httpc, "\r\n")) < 0) return rc;
    
    return rc;
}

// Calculate total record count for an FB dataset from VTOC info.
// Returns total number of records, or -1 on error / non-FB dataset.
__asm__("\n&FUNC    SETC 'get_fb_reccnt'");
static long
get_fb_record_count(const char *dsname)
{
	LOCWORK locwork;
	DSCB dscb1, dscb4;
	char dsn44[44];
	unsigned short blksz, lrecl, devtk, devov, devk;
	unsigned overhead, bpt, recs_per_block;
	unsigned tt, r;
	long total_blocks;
	int rc;

	memset(dsn44, ' ', sizeof(dsn44));
	memcpy(dsn44, dsname, strlen(dsname));

	/* Locate dataset to get volser */
	memset(&locwork, 0, sizeof(locwork));
	rc = __locate(dsn44, &locwork);
	if (rc != 0) return -1;

	/* Read DSCB1 for dataset attributes */
	memset(&dscb1, 0, sizeof(dscb1));
	rc = __dscbdv(dsn44, locwork.volser, &dscb1);
	if (rc != 0) return -1;

	/* Must be FB (fixed, non-keyed) */
	if ((dscb1.dscb1.recfm & RECFF) == 0) return -1;
	if (dscb1.dscb1.keyl != 0) return -1;

	blksz = dscb1.dscb1.blksz;
	lrecl = dscb1.dscb1.lrecl;
	if (blksz == 0 || lrecl == 0) return -1;

	/* Read DSCB4 for device geometry */
	memset(&dscb4, 0, sizeof(dscb4));
	rc = __dscbv(locwork.volser, &dscb4);
	if (rc != 0) return -1;

	devtk = dscb4.dscb4.devtk;
	devov = dscb4.dscb4.devov;
	devk  = dscb4.dscb4.devk;

	/* blocks_per_track = floor((devtk - overhead) / (overhead + blksz))
	   where overhead = devov - devk for non-keyed records */
	overhead = devov - devk;
	if (overhead + blksz == 0) return -1;
	bpt = (devtk - overhead) / (overhead + blksz);
	if (bpt == 0) return -1;

	/* DS1LSTAR: TT = relative track (0-based), R = block on track (1-based) */
	tt = ((unsigned)dscb1.dscb1.lstar[0] << 8) | dscb1.dscb1.lstar[1];
	r  = dscb1.dscb1.lstar[2];

	total_blocks = (long)tt * bpt + r;
	recs_per_block = blksz / lrecl;

	return total_blocks * recs_per_block;
}

// Read and send dataset content respecting data type.
//
// TEXT mode: uses fgets (fp must be opened "r") for correct record
// boundaries and EOF. BINARY/RECORD mode: uses fread (fp must be
// opened "rb") with max_records limit to avoid reading past logical
// EOF. If max_records is -1, reads until fread returns 0.
__asm__("\n&FUNC    SETC 'read_and_send_ds'");
static int
read_and_send_dataset(Session *session, FILE *fp, int data_type,
	long max_records)
{
	int rc = 0;
	char *buffer = NULL;
	const char *content_type;
	int lrecl = fp->lrecl;
	long count = 0;

	buffer = calloc(1, lrecl + 2);
	if (!buffer) {
		return handle_error(session, ERR_MEMORY, "Memory allocation failed");
	}

	if (data_type == DATA_TYPE_TEXT) {
		content_type = "text/plain";
	} else {
		content_type = "application/octet-stream";
	}

	rc = send_standard_headers(session, content_type);
	if (rc < 0) {
		free(buffer);
		return rc;
	}

	if (data_type == DATA_TYPE_TEXT) {
		/* Text mode: fgets + EBCDIC->ASCII + strlen for length.
		   F/FB records are padded with EBCDIC blanks to LRECL; strip them
		   so the download matches VB-style output (newline right after the
		   text). The stripping must happen while the buffer is still EBCDIC,
		   i.e. before the EBCDIC->ASCII translation: there the fgets line
		   terminator ('\n') and the pad character (' ' = X'40') are the
		   native character literals. Doing it after translation would compare
		   the ASCII bytes against the compiler's EBCDIC '\n' and inject a
		   stray control byte into the output. */
		int is_undefined = ((fp->recfm & _FILE_RECFM_TYPE) == _FILE_RECFM_U);
		int is_fixed = !is_undefined && !(fp->recfm & VARIABLE);
		while (fgets(buffer, lrecl + 2, fp) > 0) {
			size_t len = strlen(buffer);
			if (is_fixed && len > 0) {
				size_t end = len;
				if (end > 0 && buffer[end - 1] == '\n') end--;
				while (end > 0 && buffer[end - 1] == ' ') end--;
				buffer[end] = '\n';
				len = end + 1;
			}
			http_xlate((unsigned char *)buffer, len, httpx->xlate_cp037->etoa);
			if ((rc = http_send(session->httpc,
					(const UCHAR *)buffer, len)) < 0) {
				break;
			}
		}
	} else if (data_type == DATA_TYPE_BINARY) {
		/* Binary: fread raw bytes, no conversion */
		size_t n;
		while ((n = fread(buffer, 1, lrecl, fp)) > 0) {
			if (max_records >= 0 && count >= max_records) break;
			if ((rc = http_send(session->httpc,
					(const UCHAR *)buffer, n)) < 0) {
				break;
			}
			count++;
		}
	} else if (data_type == DATA_TYPE_RECORD) {
		/* Record: like binary but prefix each record with 4-byte
		   big-endian length */
		size_t n;
		while ((n = fread(buffer, 1, lrecl, fp)) > 0) {
			unsigned char len_prefix[4];
			if (max_records >= 0 && count >= max_records) break;
			len_prefix[0] = (n >> 24) & 0xFF;
			len_prefix[1] = (n >> 16) & 0xFF;
			len_prefix[2] = (n >> 8) & 0xFF;
			len_prefix[3] = n & 0xFF;
			if ((rc = http_send(session->httpc,
					(const UCHAR *)len_prefix, 4)) < 0) {
				break;
			}
			if ((rc = http_send(session->httpc,
					(const UCHAR *)buffer, n)) < 0) {
				break;
			}
			count++;
		}
	}

	free(buffer);
	return rc;
}

// Helper function for error handling
static int handle_error(Session *session, int error_code, const char* message) {
    int status;

    switch (error_code) {
        case ERR_INVALID_PARAM:
            status = HTTP_STATUS_BAD_REQUEST;
            break;
        default:
            status = HTTP_STATUS_INTERNAL_SERVER_ERROR;
            break;
    }

    return sendErrorResponse(session, status,
        CATEGORY_SERVICE, RC_ERROR, -error_code, message, NULL, 0);
}

// Helper function to check if a dataset is a PDS via VTOC DSCB lookup
__asm__("\n&FUNC    SETC 'is_pds'");
static int
is_pds(const char *dsname)
{
	LOCWORK locwork;
	DSCB dscb;
	char dsn44[44];
	int rc;

	// Pad dataset name to 44 bytes (required by __locate/__dscbdv)
	memset(dsn44, ' ', sizeof(dsn44));
	memcpy(dsn44, dsname, strlen(dsname));

	// Locate dataset in catalog to get volume serial
	memset(&locwork, 0, sizeof(locwork));
	rc = __locate(dsn44, &locwork);
	if (rc != 0) {
		return 0;
	}

	// Read DSCB from VTOC to get real dsorg
	memset(&dscb, 0, sizeof(dscb));
	rc = __dscbdv(dsn44, locwork.volser, &dscb);
	if (rc != 0) {
		return 0;
	}

	return (dscb.dscb1.dsorg1 & DSGPO) != 0;
}

/*
 * Why an fopen() of a data set or member failed (issue #191).
 *
 * fopen() only ever reports NULL, so the handlers had nothing to go on and
 * reported every failure as an I/O error: a member that is simply not there
 * came back as 500, indistinguishable from a broken server, and a client had
 * no reason not to retry something that can never succeed.
 *
 * Two cheap primitives settle it. __locate() is a catalog lookup, and
 * __listpd() applies its filter with __patmat() before it allocates, so
 * passing the exact member name walks the directory but builds at most one
 * entry - no full member list for a one-name question. Member names cannot
 * contain pattern characters, so the match is exact.
 *
 * Pass member = NULL for a sequential data set, and also for a write to a
 * member: a member that does not exist yet is what a create looks like, only
 * a missing data set is an error there.
 */
#define OPEN_FAIL_IO      0     /* the object is there - a real I/O error */
#define OPEN_FAIL_NODSN   1     /* the data set is not cataloged          */
#define OPEN_FAIL_NOMEM   2     /* the data set has no such member        */
#define OPEN_FAIL_NOTPDS  3     /* a member was asked of a non-PDS        */

/* Is the data set in the catalog? __locate() wants a blank-padded 44-byte
   name, which is the only reason this is a function and not a call. */
__asm__("\n&FUNC    SETC 'dataset_cataloged'");
static int
dataset_cataloged(const char *dsname)
{
    LOCWORK locwork;
    char    dsn44[44];
    size_t  len;

    if (!dsname) {
        return 0;
    }

    len = strlen(dsname);
    if (len > sizeof(dsn44)) {
        len = sizeof(dsn44);
    }
    memset(dsn44, ' ', sizeof(dsn44));
    memcpy(dsn44, dsname, len);

    memset(&locwork, 0, sizeof(locwork));

    return __locate(dsn44, &locwork) == 0;
}

__asm__("\n&FUNC    SETC 'diagnose_open_failure'");
static int
diagnose_open_failure(const char *dsname, const char *member)
{
    PDSLIST  **pdslist;

    if (!dsname) {
        return OPEN_FAIL_IO;
    }

    if (!dataset_cataloged(dsname)) {
        return OPEN_FAIL_NODSN;
    }

    if (!member) {
        return OPEN_FAIL_IO;
    }

    /* __listpd() reads the directory with BPAM and abends S001 if the data
       set is not partitioned, so the DSCB has to be checked first - a member
       request against a sequential data set is a client error, not a dump. */
    if (!is_pds(dsname)) {
        return OPEN_FAIL_NOTPDS;
    }

    pdslist = __listpd(dsname, member);
    if (!pdslist) {
        return OPEN_FAIL_NOMEM;
    }
    __freepd(&pdslist);

    return OPEN_FAIL_IO;
}

/* Answer a failed open with the status it deserves: 404 when the data set or
   the member is not there, 500 only for a genuine I/O error. */
__asm__("\n&FUNC    SETC 'send_open_failure'");
static int
send_open_failure(Session *session, const char *dsname, const char *member,
                  const char *io_message)
{
    switch (diagnose_open_failure(dsname, member)) {
    case OPEN_FAIL_NODSN:
        return sendErrorResponse(session, HTTP_STATUS_NOT_FOUND,
            CATEGORY_SERVICE, RC_ERROR, REASON_DATASET_NOT_FOUND,
            ERR_MSG_DATASET_NOT_FOUND, NULL, 0);
    case OPEN_FAIL_NOMEM:
        return sendErrorResponse(session, HTTP_STATUS_NOT_FOUND,
            CATEGORY_SERVICE, RC_ERROR, REASON_MEMBER_NOT_FOUND,
            ERR_MSG_MEMBER_NOT_FOUND, NULL, 0);
    case OPEN_FAIL_NOTPDS:
        /* mirror of the "dataset is a PDS, use the member endpoint" 400 */
        return handle_error(session, ERR_INVALID_PARAM,
            "Dataset is not partitioned (use the dataset endpoint instead)");
    }

    return handle_error(session, ERR_IO, io_message);
}

/*
 * Pre-flight for a directory read (issue #193).
 *
 * __listpd() opens the data set and reads its directory with BPAM. Against a
 * data set that is not partitioned that is an S001 abend, not a NULL return -
 * so the DSCB has to be checked before the call, not the result after it.
 * Without this, GET .../{sequential-dataset}/member abends the handler and the
 * client is answered by the router's ESTAE recovery.
 *
 * Returns 0 when the caller may go ahead; otherwise the response has already
 * been sent.
 */
__asm__("\n&FUNC    SETC 'require_pds'");
static int
require_pds(Session *session, const char *dsname)
{
    if (!dataset_cataloged(dsname)) {
        sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
            RC_ERROR, REASON_DATASET_NOT_FOUND, ERR_MSG_DATASET_NOT_FOUND,
            NULL, 0);
        return -1;
    }

    if (!is_pds(dsname)) {
        /* mirror of the "dataset is a PDS, use the member endpoint" 400 */
        handle_error(session, ERR_INVALID_PARAM,
            "Dataset is not partitioned (use the dataset endpoint instead)");
        return -1;
    }

    return 0;
}

// Helper function to parse X-IBM-Data-Type header
static int parse_data_type(const char *data_type) {
    if (!data_type) return DATA_TYPE_TEXT;  // Default is text
    
    if (strncmp(data_type, "text", 4) == 0) return DATA_TYPE_TEXT;
    if (strcmp(data_type, "binary") == 0) return DATA_TYPE_BINARY;
    if (strcmp(data_type, "record") == 0) return DATA_TYPE_RECORD;
    
    return DATA_TYPE_TEXT;  // Default to text for unknown values
}

/* Helper function to write a complete record.
 *
 * TEXT records are translated to EBCDIC in place, inside the caller's buffer.
 * There used to be a fixed 1024-byte conversion buffer here, while the length
 * was clamped against the data set's LRECL -- so a record from a data set with
 * LRECL > 1024 overran it and smashed the stack (issue #198). The caller's
 * buffer is already sized to the data set and its contents are dead once this
 * returns, so no second buffer is needed at all.
 *
 * eff_lrecl: the caller's allocation size and record limit in one value -- the
 * data set's LRECL, or its BLKSIZE for RECFM=U where LRECL is 0. Clamping
 * against fp->lrecl instead cut every record of a RECFM=U data set to zero
 * length, because a text-mode write is selected by the X-IBM-Data-Type header
 * and does not care what RECFM the data set has.
 */
static int write_record(Session *session, FILE *fp, char *record_buffer, size_t record_length, size_t *total_written, int *line_count, int data_type, size_t eff_lrecl)
{
    int recfm = fp->recfm;  // Get record format from file handle

    int is_variable = (recfm & VARIABLE) == VARIABLE;
    
    // Handle different data types
    switch (data_type) {
        case DATA_TYPE_BINARY:
            // Binary mode - write raw data without conversion
            if (is_variable) {
                // Add RDW for variable records
                unsigned short record_descriptor = record_length + 4;
                char rdw[4];
                rdw[0] = (record_descriptor >> 8) & 0xFF;
                rdw[1] = record_descriptor & 0xFF;
                rdw[2] = 0;
                rdw[3] = 0;
                if (fwrite(rdw, 1, 4, fp) != 4) return -1;
                *total_written += 4;
            }
            
            // Write the raw data
            if (fwrite(record_buffer, 1, record_length, fp) != record_length) return -1;
            fflush(fp);
            *total_written += record_length;
            break;
            
        case DATA_TYPE_RECORD:
            // Record mode - each record is preceded by 4-byte length
            if (record_length < 4) return -1;  // Need at least 4 bytes for length
            
            // First 4 bytes contain the record length
            unsigned int rec_len = (record_buffer[0] << 24) | 
                                 (record_buffer[1] << 16) |
                                 (record_buffer[2] << 8) |
                                 record_buffer[3];
                                 
            // Skip the length bytes
            record_buffer += 4;
            record_length -= 4;
            
            if (rec_len > record_length) return -1;  // Invalid record length
            
            if (is_variable) {
                // Add RDW for variable records
                unsigned short record_descriptor = rec_len + 4;
                char rdw[4];
                rdw[0] = (record_descriptor >> 8) & 0xFF;
                rdw[1] = record_descriptor & 0xFF;
                rdw[2] = 0;
                rdw[3] = 0;
                if (fwrite(rdw, 1, 4, fp) != 4) return -1;
                *total_written += 4;
            }
            
            // Write the record data
            if (fwrite(record_buffer, 1, rec_len, fp) != rec_len) return -1;
            fflush(fp);
            *total_written += rec_len;
            break;
            
        case DATA_TYPE_TEXT:
        default:
            // Text mode - convert from ASCII to EBCDIC
            
            // Remove newline if present (ASCII LF = 0x0A, ASCII CR = 0x0D)
            if (record_length > 0 && (record_buffer[record_length-1] == 0x0A || record_buffer[record_length-1] == 0x0D)) {
                record_length--;
            }

            // Also remove CR if we had CRLF
            if (record_length > 0 && record_buffer[record_length-1] == 0x0D) {
                record_length--;
            }
            
            /* Backstop only: every text caller already rejects a line at
               eff_lrecl - 1 with "Record too long", so this cannot normally
               fire. It stays as the last line of defence against a caller
               and this function disagreeing about the limit -- which is
               precisely how issue #198 happened. */
            if (eff_lrecl && record_length > eff_lrecl) {
                record_length = eff_lrecl;
            }

            // Convert to EBCDIC in place -- the caller's buffer is sized to the
            // data set and it does not read the ASCII back after this call.
            http_xlate((unsigned char *)record_buffer, record_length, httpx->xlate_cp037->atoe);

            // Write the converted record
            if (fwrite(record_buffer, 1, record_length, fp) != record_length) return -1;
            fflush(fp);

            *total_written += record_length;
            break;
    }
    
    (*line_count)++;
    return 0;
}

/*
** extract_level_prefix - split a dslevel pattern into a catalog LEVEL
** prefix and an optional wildcard filter for __listds().
**
** level_out must be at least 45 bytes. *filter_out is set to the
** original dslevel when post-filtering is needed, NULL otherwise.
*/
static void
extract_level_prefix(const char *dslevel, char *level_out, char **filter_out)
{
	const char	*p;
	const char	*last_dot = NULL;
	int		has_wildcard = 0;
	int		dots = 0;

	*filter_out = NULL;
	level_out[0] = '\0';

	if (!dslevel || !*dslevel) return;

	/* scan for wildcards and count qualifiers */
	for (p = dslevel; *p; p++) {
		if (*p == '*' || *p == '?') has_wildcard = 1;
		if (*p == '.') {
			dots++;
			last_dot = p;
		}
	}

	if (!has_wildcard) {
		/* No wildcards: pass through as catalog LEVEL, no filter.
		** Caller handles z/OSMF prefix semantics (the exact name
		** plus anything below it) separately. */
		strcpy(level_out, dslevel);
		return;
	}

	/* has wildcards — find longest prefix before first wild qualifier */
	{
		const char	*src = dslevel;
		const char	*seg_start = dslevel;
		const char	*prefix_end = NULL;
		int		seg_has_wild;

		while (*src) {
			seg_start = src;
			seg_has_wild = 0;

			/* scan one qualifier */
			while (*src && *src != '.') {
				if (*src == '*' || *src == '?') seg_has_wild = 1;
				src++;
			}

			if (seg_has_wild) break;

			prefix_end = src;  /* end of this clean segment */

			if (*src == '.') src++;  /* skip dot */
		}

		if (prefix_end && prefix_end > dslevel) {
			memcpy(level_out, dslevel, prefix_end - dslevel);
			level_out[prefix_end - dslevel] = '\0';
		} else {
			/* wildcard in first qualifier — use full dslevel */
			strcpy(level_out, dslevel);
		}

		/* HLQ.** is equivalent to bare HLQ, no filter needed */
		if (seg_start && strcmp(seg_start, "**") == 0 &&
			prefix_end == seg_start - 1) {
			*filter_out = NULL;
		} else {
			*filter_out = (char *) dslevel;
		}
	}
}

/* convert year + julian day (1-366) to month (1-12) + day (1-31) */
static void
jday_to_md(unsigned short year, unsigned short jday,
	unsigned char *mon_out, unsigned char *day_out)
{
	static const unsigned short mdays[] =
		{31,28,31,30,31,30,31,31,30,31,30,31};
	int leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
	int m, d;
	d = jday;
	for (m = 0; m < 12; m++) {
		int dim = mdays[m] + (m == 1 && leap ? 1 : 0);
		if (d <= dim) break;
		d -= dim;
	}
	*mon_out = (unsigned char)(m + 1);
	*day_out = (unsigned char)d;
}

int datasetListHandler(Session *session)
{
	unsigned	rc		= 0;
	unsigned	count		= 0;
	unsigned	first		= 1;
	unsigned	i		= 0;
	unsigned	maxitems	= 0;
	unsigned	emitted		= 0;

	char		*method		= NULL;
	char		*path		= NULL;
	char		*verb		= NULL;
	char		*maxitems_str	= NULL;

	DSLIST		**dslist	= NULL;

	char		*dslevel	= NULL;
	char		*volser		= NULL;
	char		*start		= NULL;
	char		*filter		= NULL;
	char		level_buf[45]	= {0};

	method	= (char *) http_get_env(session->httpc, (const UCHAR *) "REQUEST_METHOD");
	path	= (char *) http_get_env(session->httpc, (const UCHAR *) "REQUEST_PATH");

	verb	= strrchr(path, '/');

	dslevel = (char *) http_get_env(session->httpc, (const UCHAR *) "QUERY_DSLEVEL");
	volser	= (char *) http_get_env(session->httpc, (const UCHAR *) "QUERY_VOLSER");
	start 	= (char *) http_get_env(session->httpc, (const UCHAR *) "QUERY_START");

	extract_level_prefix(dslevel, level_buf, &filter);
	dslist = __listds(level_buf, "NONVSAM VOLUME", filter);

	/* z/OSMF prefix semantics: a bare multi-qualifier dslevel like
	** "A.B" must return the exact dataset AND anything below it.
	** LISTC LEVEL('A.B') returns entries cataloged *under* A.B
	** (e.g. A.B.C) but not A.B itself.  Look up the exact name
	** via __locate()+__dscbdv() and append it if it exists. */
	if (!filter && dslevel && strchr(dslevel, '.') &&
		!strchr(dslevel, '*') && !strchr(dslevel, '?')) {
		LOCWORK locwork = {0};
		if (__locate(dslevel, &locwork) == 0) {
			DSCB dscb = {0};
			DSCB1 *dscb1 = &dscb.dscb1;
			char vol[7] = {0};
			memcpy(vol, locwork.volser, 6);
			if (__dscbdv(dslevel, vol, &dscb) == 0) {
				DSLIST *ds = calloc(1, sizeof(DSLIST));
				if (ds) {
					char *p2;
					strcpy(ds->dsn, dslevel);
					strcpy(ds->volser, vol);
					p2 = NULL;
					switch(dscb1->dsorg1 & 0x7F) {
					case DSGPS: p2 = "PS"; break;
					case DSGPO: p2 = "PO"; break;
					case DSGDA: p2 = "DA"; break;
					case DSGIS: p2 = "IS"; break;
					}
					if (dscb1->dsorg2 == ORGAM) p2 = "VS";
					if (p2) strcpy(ds->dsorg, p2);
					p2 = NULL;
					switch(dscb1->recfm & 0xC0) {
					case RECFF: p2 = "F"; break;
					case RECFV: p2 = "V"; break;
					case RECFU: p2 = "U"; break;
					}
					if (p2) strcat(ds->recfm, p2);
					if (dscb1->recfm & RECFB) strcat(ds->recfm,"B");
					if (dscb1->recfm & RECFS) strcat(ds->recfm,"S");
					if (dscb1->recfm & RECFA) strcat(ds->recfm,"A");
					if (dscb1->recfm & RECMC) strcat(ds->recfm,"M");
					ds->extents = dscb1->noepv;
					ds->lrecl   = dscb1->lrecl;
					ds->blksize = dscb1->blksz;
					ds->scal1   = dscb1->scal1;
					if ((dscb1->scal1 & 0xC0) == CYL)
						ds->spacu = 'C';
					else
						ds->spacu = 'T';
					ds->secondary = ((unsigned)dscb1->scal3[0] << 16)
					              | ((unsigned)dscb1->scal3[1] << 8)
					              |  (unsigned)dscb1->scal3[2];
					ds->used_trks = (((unsigned)dscb1->lstar[0] << 8)
					              |  (unsigned)dscb1->lstar[1]) + 1;
					{
						int e, dscbrc;
						unsigned short trks = 0;
						DSCB dscb4buf = {0};
						unsigned short tpc = 0;
						dscbrc = __dscbv(vol, &dscb4buf);
						/* workaround: struct dscb4 includes key[44]
						** but __dscbv() returns data-only (96 bytes).
						** dstrk is at data offset 20, not struct
						** offset 64. Read directly from work area. */
						if (dscbrc == 0)
							tpc = ((unsigned char)dscb4buf.work[20] << 8)
							    |  (unsigned char)dscb4buf.work[21];
						if (tpc == 0) tpc = 30;
						switch (tpc) {
						case 30: strcpy(ds->dev, "3350"); break;
						case 12: strcpy(ds->dev, "3375"); break;
						case 19: strcpy(ds->dev, "3380"); break;
						case 15: strcpy(ds->dev, "3390"); break;
						default: strcpy(ds->dev, "3390"); break;
						}
						for (e = 0; e < 3 && e < dscb1->noepv; e++) {
							unsigned short lc, lh, hc, hh;
							lc = ((unsigned)dscb1->extent[e].lower[0] << 8)
							   |  (unsigned)dscb1->extent[e].lower[1];
							lh = ((unsigned)dscb1->extent[e].lower[2] << 8)
							   |  (unsigned)dscb1->extent[e].lower[3];
							hc = ((unsigned)dscb1->extent[e].upper[0] << 8)
							   |  (unsigned)dscb1->extent[e].upper[1];
							hh = ((unsigned)dscb1->extent[e].upper[2] << 8)
							   |  (unsigned)dscb1->extent[e].upper[3];
							trks += (hc - lc) * tpc + (hh - lh) + 1;
						}
						ds->alloc_trks = trks;
					}
					ds->cryear  = 1900 + dscb1->credt[0];
					if (ds->cryear < 1980) ds->cryear += 100;
					ds->crjday  = *(unsigned short*)&dscb1->credt[1];
					jday_to_md(ds->cryear, ds->crjday,
						&ds->crmon, &ds->crday);
					ds->rfyear  = 1900 + dscb1->refd[0];
					if (ds->rfyear < 1980) ds->rfyear += 100;
					ds->rfjday  = *(unsigned short*)&dscb1->refd[1];
					jday_to_md(ds->rfyear, ds->rfjday,
						&ds->rfmon, &ds->rfday);
					arrayadd(&dslist, ds);
				}
			}
		}
	}

	maxitems_str = getHeaderParam(session, "X-IBM-Max-Items");
	if (maxitems_str) maxitems = (unsigned) atoi(maxitems_str);

	session->headers_sent = 1;
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

		if (maxitems > 0 && emitted >= maxitems) break;

		if (first) {
			/* first time we're printing this '{' so no ',' needed */
			if ((rc = http_printf(session->httpc, "    {\n")) < 0) goto quit;
			first = 0;
		} else {
			/* all other times we need a ',' before the '{' */
			if ((rc = http_printf(session->httpc, "   ,{\n")) < 0) goto quit;
		}

		{
		const char *dsntp;
		unsigned pct;

		if ((rc = http_printf(session->httpc, "      \"dsname\": \"%.44s\",\n", ds->dsn)) < 0) goto quit;

		if (strcmp(ds->dsorg, "PO") == 0) dsntp = "PDS";
		else if (strcmp(ds->dsorg, "PS") == 0) dsntp = "BASIC";
		else dsntp = "UNKNOWN";

		if ((rc = http_printf(session->httpc, "      \"blksz\": \"%u\",\n", ds->blksize)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"catnm\": \"\",\n")) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"cdate\": \"%u/%02u/%02u\",\n", ds->cryear, ds->crmon, ds->crday)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"dev\": \"%.4s\",\n", ds->dev[0] ? ds->dev : "3390")) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"dsntp\": \"%s\",\n", dsntp)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"dsorg\": \"%.4s\",\n", ds->dsorg)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"edate\": \"***None***\",\n")) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"extx\": \"%u\",\n", ds->extents)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"lrecl\": \"%u\",\n", ds->lrecl)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"migr\": \"NO\",\n")) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"mvol\": \"N\",\n")) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"ovf\": \"NO\",\n")) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"rdate\": \"%u/%02u/%02u\",\n", ds->rfyear, ds->rfmon, ds->rfday)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"recfm\": \"%.4s\",\n", ds->recfm)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"sizex\": \"%u\",\n", ds->alloc_trks)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"spacu\": \"%s\",\n",
			ds->spacu == 'C' ? "CYLINDERS" : "TRACKS")) < 0) goto quit;
		pct = ds->alloc_trks ? (ds->used_trks * 100 / ds->alloc_trks) : 0;
		if ((rc = http_printf(session->httpc, "      \"used\": \"%u\",\n", pct)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"vol\": \"%.6s\",\n", ds->volser)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"vols\": \"%.6s\"\n", ds->volser)) < 0) goto quit;
		}

		if ((rc = http_printf(session->httpc, "    }\n")) < 0) goto quit;

		emitted++;
	}

end:
	if ((rc = http_printf(session->httpc, "  ],\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"returnedRows\": %d,\n", emitted)) < 0) goto quit;
	// TODO: add totalRows if X-IBM-Attributes has ',total'
	if ((rc = http_printf(session->httpc, "  \"moreRows\": %s,\n",
		(maxitems > 0 && emitted < count) ? "true" : "false")) < 0) goto quit;

	if ((rc = http_printf(session->httpc, "  \"JSONversion\": 1\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "} \n")) < 0) goto quit;

quit:
	if (dslist) {
		__freeds(&dslist);
	}

	return rc;
}

int datasetGetHandler(Session *session)
{
    int rc = 0;
    char *dsname = NULL;
    const char *data_type_str = NULL;
    int data_type;
    long max_records = -1;
    FILE *fp = NULL;

    // Validate parameters
    dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
    if (!dsname) {
        return handle_error(session, ERR_INVALID_PARAM, "Dataset name is required");
    }

    // Reject PDS - this endpoint is for sequential datasets only
    if (is_pds(dsname)) {
        return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
            CATEGORY_SERVICE, RC_ERROR, REASON_PDS_NOT_SEQUENTIAL,
            ERR_MSG_PDS_NOT_SEQUENTIAL, NULL, 0);
    }

    // Parse X-IBM-Data-Type header
    data_type_str = (char *) http_get_env(session->httpc,
        (const UCHAR *) "HTTP_X-IBM-Data-Type");
    data_type = parse_data_type(data_type_str);

    if (data_type == DATA_TYPE_TEXT) {
        fp = fopen(dsname, "r");
    } else {
        max_records = get_fb_record_count(dsname);
        fp = fopen(dsname, "rb");
    }
    if (!fp) {
        return send_open_failure(session, dsname, NULL, "Cannot open dataset");
    }
    session_register_file(session, fp);

    rc = read_and_send_dataset(session, fp, data_type, max_records);

    session_fclose(session, fp);
    return rc;
}

int datasetPutHandler(Session *session)
{
    int rc = 0;
    char *dsname = NULL;
    FILE *fp = NULL;
    const char *content_length_str = NULL;
    const char *transfer_encoding = NULL;
    const char *data_type_str = NULL;
    int is_chunked = 0;
    int has_content_length = 0;
    size_t content_length = 0;
    size_t total_written = 0;
    int line_count = 0;
    char *record_buffer = NULL;
    size_t eff_lrecl = 0;
    int is_undefined = 0;
    size_t record_pos = 0;
    int data_type;

    // Validate parameters
    dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
    
    if (!dsname) {
        wtof("MVSMF31E Missing required parameter: dsname=NULL");
        return handle_error(session, ERR_INVALID_PARAM, "Dataset name is required");
    }

    // z/OSMF control request (rename): Content-Type: application/json.
    // Must be handled before the existence/PDS checks because the target
    // data set (the URL name) does not exist yet.
    {
        const char *ct = getHeaderParam(session, "Content-Type");
        if (ct && strstr(ct, "application/json") != NULL) {
            return process_rename(session, dsname, NULL);
        }
    }

    // Reject PDS - this endpoint is for sequential datasets only
    if (is_pds(dsname)) {
        return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
            CATEGORY_SERVICE, RC_ERROR, REASON_PDS_NOT_SEQUENTIAL,
            ERR_MSG_PDS_NOT_SEQUENTIAL, NULL, 0);
    }

    // Get headers
    data_type_str = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_X-IBM-Data-Type");
    transfer_encoding = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_TRANSFER-ENCODING");
    content_length_str = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_CONTENT-LENGTH");

    // Parse data type
    data_type = parse_data_type(data_type_str);

    // Check transfer encoding
    is_chunked = (transfer_encoding && strstr(transfer_encoding, "chunked") != NULL);
    
    if (content_length_str) {
        has_content_length = 1;
        content_length = strtoul(content_length_str, NULL, 10);
    }

    // Require either Content-Length or chunked transfer
    if (!is_chunked && !has_content_length) {
        wtof("MVSMF33E Missing Content-Length or Transfer-Encoding header");
        return handle_error(session, ERR_INVALID_PARAM, "Missing Content-Length or Transfer-Encoding header");
    }

    char mode_str[2+1];
    if (data_type == DATA_TYPE_TEXT) {
        snprintf(mode_str, sizeof(mode_str), "%s", "w"); 
    } else if (data_type == DATA_TYPE_BINARY) {
        snprintf(mode_str, sizeof(mode_str), "%s", "wb");
    } else if (data_type == DATA_TYPE_RECORD) {
        snprintf(mode_str, sizeof(mode_str), "%s", "wb");
    }

    /* Verify dataset exists - do not auto-create with wrong DCB (issue #65) */
    {
        FILE *chk = fopen(dsname, "r");
        if (!chk) {
            return sendErrorResponse(session, HTTP_STATUS_NOT_FOUND,
                CATEGORY_SERVICE, RC_ERROR, REASON_DATASET_NOT_FOUND,
                ERR_MSG_DATASET_NOT_FOUND, NULL, 0);
        }
        fclose(chk);
    }

    fp = fopen(dsname, mode_str);
    if (!fp) {
        wtof("MVSMF34E Failed to open dataset for writing: %s (errno=%d)", dsname, errno);
        return handle_error(session, ERR_IO, "Cannot open dataset for writing");
    }
    session_register_file(session, fp);

    /* For RECFM=U (undefined record format), lrecl is 0. Use blksize instead. */
    is_undefined = ((fp->recfm & _FILE_RECFM_TYPE) == _FILE_RECFM_U);
    eff_lrecl = is_undefined ? (size_t)fp->blksize : (size_t)fp->lrecl;
    if (eff_lrecl == 0) {
        wtof("MVSMF34E Dataset has zero record length: %s", dsname);
        session_fclose(session, fp);
        return handle_error(session, ERR_IO, "Dataset has zero record length");
    }
    // NOTE: record_buffer is not tracked by session for ESTAE recovery.
    // On abend, this allocation leaks. Acceptable since abends are rare
    // and the leak is bounded by eff_lrecl bytes per occurrence.
    record_buffer = calloc(1, eff_lrecl);
    if (!record_buffer) {
        session_fclose(session, fp);
        return handle_error(session, ERR_MEMORY, "Memory allocation failed");
    }

    if (is_chunked) {
        // Handle chunked transfer encoding
        while (1) {
            char chunk_size_str[10] = {0};
            size_t chunk_size;
            int i = 0;
            char c;
            
            // Read chunk size as ASCII hex string
            while (i < sizeof(chunk_size_str)-1) {
                if (recv(session->httpc->socket, &c, 1, 0) != 1) {
                    wtof("MVSMF36E Error reading chunk size");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error reading chunk size");
                }
                if (c == 0x0D) { // ASCII CR \r
                    chunk_size_str[i] = '\0';
                    recv(session->httpc->socket, &c, 1, 0);  // Read ASCII LF \n
                    break;
                }
                chunk_size_str[i++] = c;
            }
            
            // Convert chunk size from ASCII hex to EBCDIC hex
            http_xlate((unsigned char *)chunk_size_str, strlen(chunk_size_str), httpx->xlate_cp037->atoe);

            // Convert chunk size from string to integer
            chunk_size = strtoul(chunk_size_str, NULL, 16);

            if (chunk_size == 0) {
                // Write last incomplete record if any
                if (record_pos > 0) {
                    if (data_type == DATA_TYPE_BINARY && !is_undefined) {
                        /* Pad to full LRECL for fixed-length binary records */
                        memset(record_buffer + record_pos, 0x00, eff_lrecl - record_pos);
                        record_pos = eff_lrecl;
                    }
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                        wtof("MVSMF39E Error writing final record");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error writing final record");
                    }
                }

                // Read final CRLF
                char crlf[2] = {0};
                if (recv(session->httpc->socket, crlf, 2, 0) != 2) {
                    wtof("MVSMF40E Error reading final line ending");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error reading final line ending");
                }

                if (crlf[0] != 0x0d || crlf[1] != 0x0a) {
                    wtof("MVSMF41E Final line ending not CRLF");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Final line ending not CRLF");
                }

                break;
            }

            // Process chunk data
            size_t bytes_read = 0;
            if (data_type == DATA_TYPE_BINARY) {
                /* Binary mode: read in bulk, split at eff_lrecl boundaries */
                while (bytes_read < chunk_size) {
                    size_t to_read = chunk_size - bytes_read;
                    size_t space = eff_lrecl - record_pos;
                    int n;
                    if (to_read > space) to_read = space;

                    n = recv(session->httpc->socket, record_buffer + record_pos, to_read, 0);
                    if (n <= 0) {
                        wtof("MVSMF38E Error reading chunk data");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error reading chunk data");
                    }
                    bytes_read += n;
                    record_pos += n;

                    if (record_pos >= eff_lrecl) {
                        if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                            wtof("MVSMF42E Error writing record");
                            free(record_buffer);
                            session_fclose(session, fp);
                            return handle_error(session, ERR_IO, "Error writing record");
                        }
                        record_pos = 0;
                    }
                }
                /* Do NOT flush buffer at end of chunk for binary */
            } else {
                /* Text mode: split records at newline boundaries */
                while (bytes_read < chunk_size) {
                    if (recv(session->httpc->socket, &c, 1, 0) != 1) {
                        wtof("MVSMF38E Error reading chunk data");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error reading chunk data");
                    }
                    bytes_read++;

                    if (record_pos >= eff_lrecl - 1) {
                        wtof("MVSMF43E Record too long");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Record too long");
                    }
                    record_buffer[record_pos++] = c;

                    if (c == 0x0A) {
                        if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                            wtof("MVSMF42E Error writing record");
                            free(record_buffer);
                            session_fclose(session, fp);
                            return handle_error(session, ERR_IO, "Error writing record");
                        }
                        record_pos = 0;
                    }
                }

                /* Write any remaining text data at end of chunk */
                if (record_pos > 0) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                        wtof("MVSMF39E Error writing final record");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error writing final record");
                    }
                    record_pos = 0;
                }
            }

            /* Read chunk trailer (CRLF) */
            char crlf[2];
            if (recv(session->httpc->socket, crlf, 2, 0) != 2) {
                wtof("MVSMF43E Error reading chunk trailer");
                free(record_buffer);
                session_fclose(session, fp);
                return handle_error(session, ERR_IO, "Error reading chunk trailer");
            }
        }
    } else {
        /* Handle Content-Length transfer */
        size_t bytes_remaining = content_length;

        if (data_type == DATA_TYPE_BINARY) {
            /* Binary mode: read in bulk, split at eff_lrecl boundaries */
            while (bytes_remaining > 0) {
                size_t to_read = bytes_remaining;
                size_t space = eff_lrecl - record_pos;
                int n;
                if (to_read > space) to_read = space;

                n = recv(session->httpc->socket, record_buffer + record_pos, to_read, 0);
                if (n <= 0) {
                    wtof("MVSMF45E Error reading data in Content-Length mode");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error reading data");
                }
                bytes_remaining -= n;
                record_pos += n;

                if (record_pos >= eff_lrecl) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                        wtof("MVSMF46E Error writing record");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error writing record");
                    }
                    record_pos = 0;
                }
            }

            /* Pad and write final incomplete binary record (skip for RECFM=U) */
            if (record_pos > 0) {
                if (!is_undefined) {
                    memset(record_buffer + record_pos, 0x00, eff_lrecl - record_pos);
                    record_pos = eff_lrecl;
                }
                if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                    wtof("MVSMF39E Error writing final record");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error writing final record");
                }
            }
        } else {
            /* Text mode: split records at newline boundaries */
            char c;
            while (bytes_remaining > 0) {
                if (recv(session->httpc->socket, &c, 1, 0) != 1) {
                    wtof("MVSMF45E Error reading data in Content-Length mode");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error reading data");
                }
                bytes_remaining--;

                if (record_pos >= eff_lrecl - 1) {
                    wtof("MVSMF43E Record too long");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Record too long");
                }
                record_buffer[record_pos++] = c;

                if (c == 0x0A || c == 0x0D) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                        wtof("MVSMF46E Error writing record");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error writing record");
                    }
                    record_pos = 0;
                    if (c == 0x0D) {
                        char next;
                        if (recv(session->httpc->socket, &next, 1, 0) == 1 && next == 0x0A) {
                            bytes_remaining--;
                        } else {
                            record_buffer[record_pos++] = next;
                        }
                    }
                }
            }

            /* Write any remaining text data as the last record */
            if (record_pos > 0) {
                if (record_pos > eff_lrecl) {
                    record_pos = eff_lrecl;
                }
                if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                    wtof("MVSMF39E Error writing final record");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error writing final record");
                }
            }
        }
    }

    free(record_buffer);
    record_buffer = NULL;
    session_fclose(session, fp);
    fp = NULL;

    /* Send response */
    session->headers_sent = 1;
    if ((rc = http_resp(session->httpc, 204)) < 0) {
        wtof("MVSMF48E Error sending response status: rc=%d", rc);
        return rc;
    }

    if ((rc = http_printf(session->httpc, "Content-Type: application/json\r\n")) < 0) goto error;
    if ((rc = http_printf(session->httpc, "Cache-Control: no-cache\r\n")) < 0) goto error;
    if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto error;

    return rc;

error:
    wtof("MVSMF50E Error sending response: rc=%d", rc);
    free(record_buffer);
    if (fp) {
        session_fclose(session, fp);
    }
    return rc;
}

/* PDS directory block, as delivered by fopen(dataset, "r,record") -- one block
   per record, 256 bytes:

       0..1    halfword: bytes used in this block, including these two
       2..     packed entries, each
                 0..7   member name, blank padded
                 8..10  TTR
                 11     0x80 alias, 0x60 TTR count, 0x1F user data halfwords
                 12..   user data
       a name of eight 0xFF bytes marks the logical end of the directory

   This mirrors the walk in libc370's __listpd() (libc370/src/clib/@@listpd.c).
   There are now two parsers for this format -- keep them in step. */
#define PDS_DIR_BLKSIZE		256
#define PDS_DIR_ENT_FIXED	12	/* name + TTR + indicator */
#define PDS_DIR_UDATA_MASK	0x1F	/* user data size, in halfwords */

/* 8 name bytes, each worst case "\uXXXX", plus the terminator */
#define MEMBER_ESC_SIZE		(8 * 6 + 1)

/* Render a directory member name as the body of a JSON string.

   Member names are normally A-Z 0-9 @ # $, but nothing enforces that: a PDS
   directory can hold arbitrary bytes, and the SMP/E keys in SYS1.SMPCDS are
   binary. Emitting those raw produces a response that is not JSON -- jq and
   every other parser reject the unescaped control characters.

   The printability test has to be applied to the ASCII byte, not the EBCDIC
   one, because http_printf() translates everything we emit on the way out.
   So each name byte is run through the same table httpd will use, and the
   result decides: pass the EBCDIC byte through and let the translation do its
   work, or emit a \uXXXX escape naming the ASCII value.

   This is the one place where comparing against numeric ASCII values is
   correct rather than the mistake the root CLAUDE.md warns about: `a` is
   already post-translation, so 0x22 and 0x5C really are the quote and the
   backslash the parser will see. */
__asm__("\n&FUNC    SETC 'json_escape_member'");
static void
json_escape_member(const unsigned char *raw, unsigned rawlen,
                   const unsigned char *etoa, char *out, size_t outlen)
{
	size_t		o = 0;
	unsigned	i;

	for (i = 0; i < rawlen; i++) {
		unsigned char a = etoa[raw[i]];

		/* room for the longest escape plus the terminator */
		if (o + 6 >= outlen) break;

		if (a < 0x20 || a > 0x7E || a == 0x22 /* " */ || a == 0x5C /* \ */) {
			o += (size_t) snprintf(&out[o], outlen - o, "\\u%04X", a);
		} else {
			out[o++] = (char) raw[i];
		}
	}

	out[o] = '\0';
}

int memberListHandler(Session *session)
{
	unsigned	rc		= 0;
	unsigned	emitted		= 0;
	unsigned	first		= 1;
	unsigned	maxitems	= 0;
	int		more		= 0;
	int		at_end		= 0;

	char		*method		= NULL;
	char		*path		= NULL;
	char		*verb		= NULL;

	FILE		*fp		= NULL;
	char		blk[PDS_DIR_BLKSIZE];

	char 		*dsname		= NULL;

	char		*start		= NULL;
	char		*pattern	= NULL;
	char		*maxitems_str	= NULL;


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

	maxitems_str = getHeaderParam(session, "X-IBM-Max-Items");
	if (maxitems_str) maxitems = (unsigned) atoi(maxitems_str);

	/* opening a non-partitioned data set this way abends S001 (#193) */
	if (require_pds(session, dsname) != 0) {
		goto quit;
	}

	/* Walk the directory and emit as we go.  This used to call __listpd(),
	   which builds the complete member array in storage first: on a data set
	   like SYS1.SMPCDS (~23000 members) that exhausts the region, abends S878,
	   and -- because the abend unwinds before the handler's __freepd() -- leaves
	   the storage lost, after which httpd can no longer LINK MVSMF at all and
	   every endpoint answers S80A until the server is restarted (#212).
	   Streaming keeps the footprint at one 256-byte block. */
	fp = fopen(dsname, "r,record");
	if (!fp) {
		rc = sendErrorResponse(session, HTTP_STATUS_NOT_FOUND,
				CATEGORY_UNEXPECTED, RC_ERROR, REASON_DATASET_NOT_FOUND,
				ERR_MSG_DATASET_NOT_FOUND, NULL, 0);
		goto quit;
	}

	/* The handle is held across the whole streaming loop, which on a large
	   directory runs for seconds. If this handler abends in that window the
	   quit: path below never runs, and an unregistered handle is one that
	   session_cleanup() cannot find -- the data set then stays allocated to
	   the address space for good, and the next DELETE of it waits on the
	   SCRATCH enqueue forever, costing a worker permanently (#217). */
	session_register_file(session, fp);

	session->headers_sent = 1;
	if ((rc = http_resp(session->httpc,200)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", "application/json")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Pragma: no-cache\r\n")) < 0) goto quit;	
	if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

	if ((rc = http_printf(session->httpc, "{\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"items\": [\n")) < 0) goto quit;

	while (!at_end) {
		int	len;
		int	used;
		int	pos;

		len = fread(blk, 1, sizeof(blk), fp);
		if (len <= 0) break;

		used = (int) *(unsigned short *) blk;

		/* the block says how much of it is in use -- never take that at face
		   value.  A short read or a damaged block would otherwise walk us off
		   the end of blk[], the same class of defect as the MTT length in
		   #176.  Clamp to what we actually read. */
		if (used > len) used = len;

		/* PDS_DIR_ENT_FIXED bytes must be present before the indicator byte
		   at +11 can be read */
		for (pos = 2; pos + PDS_DIR_ENT_FIXED <= used; ) {
			int	size;
			char	member[MEMBER_ESC_SIZE];

			if (memcmp(&blk[pos],
			           "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF", 8) == 0) {
				at_end = 1;
				break;
			}

			size = PDS_DIR_ENT_FIXED
			     + ((blk[pos + 11] & PDS_DIR_UDATA_MASK) * 2);

			if (maxitems > 0 && emitted >= maxitems) {
				more = 1;
				at_end = 1;
				break;
			}

			json_escape_member((const unsigned char *) &blk[pos], 8,
				httpx->xlate_cp037->etoa, member, sizeof(member));

			if (first) {
				/* first time we're printing this '{' so no ',' needed */
				if ((rc = http_printf(session->httpc, "    {\n")) < 0) goto quit;
				first = 0;
			} else {
				/* all other times we need a ',' before the '{' */
				if ((rc = http_printf(session->httpc, "   ,{\n")) < 0) goto quit;
			}

			// TODO: extract user data from the entry, if X-IBM-Attributes == base
			if ((rc = http_printf(session->httpc, "      \"member\": \"%s\"\n", member)) < 0) goto quit;
			if ((rc = http_printf(session->httpc, "    }\n")) < 0) goto quit;

			emitted++;
			pos += size;
		}
	}

	if ((rc = http_printf(session->httpc, "  ],\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"returnedRows\": %d,\n", emitted)) < 0) goto quit;
	// TODO: add totalRows if X-IBM-Attributes has ',total'
	if ((rc = http_printf(session->httpc, "  \"moreRows\": %s,\n",
		more ? "true" : "false")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"JSONversion\": 1\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "} \n")) < 0) goto quit;

quit:
	if (fp) {
		session_fclose(session, fp);
	}

	return rc;
}

int memberGetHandler(Session *session)
{
    int rc = 0;
    char *dsname = NULL;
    char *member = NULL;
    const char *data_type_str = NULL;
    int data_type;
    char dataset[MAX_QUALIFIED_DSN] = {0};
    FILE *fp = NULL;

    // Validate parameters
    dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
    member = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_member-name");

    if (!dsname || !member) {
        return handle_error(session, ERR_INVALID_PARAM, "Dataset and member names are required");
    }

    // Validate dsname and member individually (not combined — qualified form fits MAX_QUALIFIED_DSN)
    if (strlen(dsname) > MAX_DATASET_NAME || strlen(member) > MAX_MEMBER_NAME) {
        return handle_error(session, ERR_INVALID_PARAM, "Dataset or member name too long");
    }

    // Create dataset path
    snprintf(dataset, sizeof(dataset), "%s(%s)", dsname, member);

    // Parse X-IBM-Data-Type header
    data_type_str = (char *) http_get_env(session->httpc,
        (const UCHAR *) "HTTP_X-IBM-Data-Type");
    data_type = parse_data_type(data_type_str);

    if (data_type == DATA_TYPE_TEXT) {
        fp = fopen(dataset, "r");
    } else {
        fp = fopen(dataset, "rb");
    }
    if (!fp) {
        return send_open_failure(session, dsname, member, "Cannot open dataset member");
    }
    session_register_file(session, fp);

    // PDS member: record count unknown, pass -1 (no limit)
    rc = read_and_send_dataset(session, fp, data_type, -1);

    session_fclose(session, fp);
    return rc;
}

int memberPutHandler(Session *session)
{
    int rc = 0;
    char *dsname = NULL;
    char *member = NULL;
    char dataset[MAX_QUALIFIED_DSN] = {0};
    FILE *fp = NULL;
    const char *content_length_str = NULL;
    const char *transfer_encoding = NULL;
    const char *data_type_str = NULL;
    int is_chunked = 0;
    int has_content_length = 0;
    size_t content_length = 0;
    size_t total_written = 0;
    int line_count = 0;
    char *record_buffer = NULL;
    size_t eff_lrecl = 0;
    int is_undefined = 0;
    size_t record_pos = 0;
    int data_type;

    // Validate parameters
    dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
    member = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_member-name");

    if (!dsname || !member) {
        wtof("MVSMF02E Missing required parameters: dsname=%s, member=%s, Data-Type=%s",
             dsname ? dsname : "NULL",
             member ? member : "NULL",
             data_type_str ? data_type_str : "NULL");

        return handle_error(session, ERR_INVALID_PARAM, "Dataset and member names are required");
    }

    // z/OSMF control request (rename): Content-Type: application/json.
    // Must be handled before opening the (new) member for writing.
    {
        const char *ct = getHeaderParam(session, "Content-Type");
        if (ct && strstr(ct, "application/json") != NULL) {
            return process_rename(session, dsname, member);
        }
    }

    // Validate dsname and member individually (not combined — qualified form fits MAX_QUALIFIED_DSN)
    if (strlen(dsname) > MAX_DATASET_NAME || strlen(member) > MAX_MEMBER_NAME) {
        return handle_error(session, ERR_INVALID_PARAM, "Dataset or member name too long");
    }

    // Get headers
    content_length_str = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_CONTENT-LENGTH");
    transfer_encoding = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_TRANSFER-ENCODING");
    data_type_str = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_X-IBM-Data-Type");

    // Create dataset path
    snprintf(dataset, sizeof(dataset), "%s(%s)", dsname, member);

    // Check transfer encoding
    is_chunked = (transfer_encoding && strstr(transfer_encoding, "chunked") != NULL);
    
    if (content_length_str) {
        has_content_length = 1;
        content_length = strtoul(content_length_str, NULL, 10);
    }

    // Require either Content-Length or chunked transfer
    if (!is_chunked && !has_content_length) {
        wtof("MVSMF04E Missing Content-Length or Transfer-Encoding header");
        return handle_error(session, ERR_INVALID_PARAM, "Missing Content-Length or Transfer-Encoding header");
    }

    // Parse data type
    data_type = parse_data_type(data_type_str);

    // Open file for writing
    char member_mode[3];
    if (data_type == DATA_TYPE_BINARY || data_type == DATA_TYPE_RECORD) {
        snprintf(member_mode, sizeof(member_mode), "%s", "wb");
    } else {
        snprintf(member_mode, sizeof(member_mode), "%s", "w");
    }
    /* Verify the data set exists before opening the member for output. Same
       reason as the sequential path (issue #65): fopen("w") on a name that is
       not cataloged auto-allocates it, and it does so with the wrong DCB - a
       PUT to a member of a missing PDS used to leave a RECFM=V sequential data
       set behind and then answer 500. Checking afterwards cannot help; by then
       the data set exists. A member that does not exist yet is fine - that is
       what a create looks like. */
    if (!dataset_cataloged(dsname)) {
        return sendErrorResponse(session, HTTP_STATUS_NOT_FOUND,
            CATEGORY_SERVICE, RC_ERROR, REASON_DATASET_NOT_FOUND,
            ERR_MSG_DATASET_NOT_FOUND, NULL, 0);
    }

    fp = fopen(dataset, member_mode);
    if (!fp) {
        wtof("MVSMF06E Failed to open dataset member for writing: %s (errno=%d)", dataset, errno);
        /* member = NULL: a member that does not exist yet is a create, not an
           error - only a missing data set is */
        return send_open_failure(session, dsname, NULL,
            "Cannot open dataset member for writing");
    }
    session_register_file(session, fp);

    /* Size the record buffer from the member's DCB, exactly as the sequential
       handler does. It used to be a fixed 1024-byte array on the stack while
       the binary path bounded its reads by fp->lrecl -- a PDS with LRECL > 1024
       therefore overran it (issue #198). For RECFM=U, lrecl is 0; use blksize. */
    is_undefined = ((fp->recfm & _FILE_RECFM_TYPE) == _FILE_RECFM_U);
    eff_lrecl = is_undefined ? (size_t)fp->blksize : (size_t)fp->lrecl;
    if (eff_lrecl == 0) {
        wtof("MVSMF06E Dataset has zero record length: %s", dataset);
        session_fclose(session, fp);
        return handle_error(session, ERR_IO, "Dataset has zero record length");
    }
    /* NOTE: same as the sequential handler -- record_buffer is not tracked by
       the session for ESTAE recovery, so an abend leaks it. Bounded by
       eff_lrecl per occurrence, and abends are rare. */
    record_buffer = calloc(1, eff_lrecl);
    if (!record_buffer) {
        session_fclose(session, fp);
        return handle_error(session, ERR_MEMORY, "Memory allocation failed");
    }

    if (is_chunked) {
        // Handle chunked transfer encoding
        while (1) {
            char chunk_size_str[10] = {0};
            size_t chunk_size;
            int i = 0;
            char c;
            
            // Read chunk size as ASCII hex string
            while (i < sizeof(chunk_size_str)-1) {
                if (recv(session->httpc->socket, &c, 1, 0) != 1) {
                    wtof("MVSMF08E Error reading chunk size");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error reading chunk size");
                }
                if (c == '\r') {
                    chunk_size_str[i] = '\0';
                    recv(session->httpc->socket, &c, 1, 0);  // Read \n
                    break;
                }
                chunk_size_str[i++] = c;
            }
            
            // Convert chunk size from ASCII hex to EBCDIC hex
            http_xlate((unsigned char *)chunk_size_str, strlen(chunk_size_str), httpx->xlate_cp037->atoe);

            // Convert chunk size from string to integer
            chunk_size = strtoul(chunk_size_str, NULL, 16);

            if (chunk_size == 0) {
                // Write last incomplete record if any
                if (record_pos > 0) {
                    if (data_type == DATA_TYPE_BINARY) {
                        // Pad to full LRECL for fixed-length binary records
                        memset(record_buffer + record_pos, 0x00, eff_lrecl - record_pos);
                        record_pos = eff_lrecl;
                    }
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                        wtof("MVSMF11E Error writing final record");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error writing final record");
                    }
                }

                // Read final CRLF
                char crlf[2] = {0};
                if (recv(session->httpc->socket, crlf, 2, 0) != 2) {
                    wtof("MVSMF40E Error reading final line ending");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error reading final line ending");
                }

                if (crlf[0] != 0x0d || crlf[1] != 0x0a) {
                    wtof("MVSMF41E Final line ending not CRLF");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Final line ending not CRLF");
                }

                break;
            }

            // Process chunk data
            size_t bytes_read = 0;
            if (data_type == DATA_TYPE_BINARY) {
                // Binary mode: read in bulk, split at LRECL boundaries
                while (bytes_read < chunk_size) {
                    size_t to_read = chunk_size - bytes_read;
                    size_t space = eff_lrecl - record_pos;
                    int n;
                    if (to_read > space) to_read = space;

                    n = recv(session->httpc->socket, record_buffer + record_pos, to_read, 0);
                    if (n <= 0) {
                        wtof("MVSMF13E Error reading chunk data");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error reading chunk data");
                    }
                    bytes_read += n;
                    record_pos += n;

                    if (record_pos >= eff_lrecl) {
                        if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                            wtof("MVSMF14E Error writing record");
                            free(record_buffer);
                            session_fclose(session, fp);
                            return handle_error(session, ERR_IO, "Error writing record");
                        }
                        record_pos = 0;
                    }
                }
                // Do NOT flush buffer at end of chunk for binary
            } else {
                // Text mode: split records at newline boundaries
                while (bytes_read < chunk_size) {
                    if (recv(session->httpc->socket, &c, 1, 0) != 1) {
                        wtof("MVSMF13E Error reading chunk data");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error reading chunk data");
                    }
                    bytes_read++;

                    if (record_pos >= eff_lrecl - 1) {
                        wtof("MVSMF43E Record too long");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Record too long");
                    }
                    record_buffer[record_pos++] = c;

                    if (c == 0x0A) {
                        if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                            wtof("MVSMF14E Error writing record");
                            free(record_buffer);
                            session_fclose(session, fp);
                            return handle_error(session, ERR_IO, "Error writing record");
                        }
                        record_pos = 0;
                    }
                }

                // Write any remaining text data at end of chunk
                if (record_pos > 0) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                        wtof("MVSMF39E Error writing final record");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error writing final record");
                    }
                    record_pos = 0;
                }
            }
            
            // Read chunk trailer (CRLF)
            char crlf[2];
            if (recv(session->httpc->socket, crlf, 2, 0) != 2) {
                wtof("MVSMF15E Error reading chunk trailer");
                free(record_buffer);
                session_fclose(session, fp);
                return handle_error(session, ERR_IO, "Error reading chunk trailer");
            }
        }
    } else {
        // Handle Content-Length transfer
        size_t bytes_remaining = content_length;

        if (data_type == DATA_TYPE_BINARY) {
            // Binary mode: read in bulk, split at LRECL boundaries
            while (bytes_remaining > 0) {
                size_t to_read = bytes_remaining;
                size_t space = eff_lrecl - record_pos;
                int n;
                if (to_read > space) to_read = space;

                n = recv(session->httpc->socket, record_buffer + record_pos, to_read, 0);
                if (n <= 0) {
                    wtof("MVSMF17E Error reading data in Content-Length mode");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error reading data");
                }
                bytes_remaining -= n;
                record_pos += n;

                if (record_pos >= eff_lrecl) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                        wtof("MVSMF18E Error writing record");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error writing record");
                    }
                    record_pos = 0;
                }
            }

            // Pad and write final incomplete binary record
            if (record_pos > 0) {
                memset(record_buffer + record_pos, 0x00, eff_lrecl - record_pos);
                record_pos = eff_lrecl;
                if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                    wtof("MVSMF19E Error writing final record");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error writing final record");
                }
            }
        } else {
            // Text mode: split records at newline boundaries
            char c;
            while (bytes_remaining > 0) {
                if (recv(session->httpc->socket, &c, 1, 0) != 1) {
                    wtof("MVSMF17E Error reading data in Content-Length mode");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error reading data");
                }
                bytes_remaining--;

                if (record_pos >= eff_lrecl - 1) {
                    wtof("MVSMF43E Record too long");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Record too long");
                }
                record_buffer[record_pos++] = c;

                if (c == 0x0A || c == 0x0D) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                        wtof("MVSMF18E Error writing record");
                        free(record_buffer);
                        session_fclose(session, fp);
                        return handle_error(session, ERR_IO, "Error writing record");
                    }
                    record_pos = 0;
                    if (c == 0x0D) {
                        char next;
                        if (recv(session->httpc->socket, &next, 1, 0) == 1 && next == 0x0A) {
                            bytes_remaining--;
                        } else {
                            record_buffer[record_pos++] = next;
                        }
                    }
                }
            }

            // Write any remaining text data
            if (record_pos > 0) {
                if (record_pos > eff_lrecl) {
                    record_pos = eff_lrecl;
                }
                if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type, eff_lrecl) < 0) {
                    wtof("MVSMF19E Error writing final record");
                    free(record_buffer);
                    session_fclose(session, fp);
                    return handle_error(session, ERR_IO, "Error writing final record");
                }
            }
        }
    }

    free(record_buffer);
    record_buffer = NULL;
    session_fclose(session, fp);
    fp = NULL;

    // Send response
    session->headers_sent = 1;
    if ((rc = http_resp(session->httpc, 204)) < 0) {
        wtof("MVSMF20E Error sending response status: rc=%d", rc);
        return rc;
    }

    if ((rc = http_printf(session->httpc, "Content-Type: application/json\r\n")) < 0) goto error;
    if ((rc = http_printf(session->httpc, "Cache-Control: no-cache\r\n")) < 0) goto error;
    if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto error;

    return rc;

error:
    wtof("MVSMF22E Error sending response: rc=%d", rc);
    if (fp) {
        session_fclose(session, fp);
    }
    return rc;
}

// JSON parsing helpers for dataset create
__asm__("\n&FUNC    SETC 'ext_json_str'");
static int
extract_json_string(const char *json, const char *key, char *out, size_t outlen)
{
	char search[64];
	char *pos, *val_start, *val_end;
	size_t len;

	snprintf(search, sizeof(search), "\"%s\"", key);
	pos = strstr(json, search);
	if (!pos) return -1;

	pos += strlen(search);
	while (*pos == ' ' || *pos == '\t') pos++;
	if (*pos != ':') return -1;
	pos++;
	while (*pos == ' ' || *pos == '\t') pos++;
	if (*pos != '"') return -1;
	pos++;
	val_start = pos;

	val_end = strchr(val_start, '"');
	if (!val_end) return -1;

	len = val_end - val_start;
	if (len >= outlen) len = outlen - 1;
	memcpy(out, val_start, len);
	out[len] = '\0';
	return 0;
}

__asm__("\n&FUNC    SETC 'ext_json_int'");
static int
extract_json_int(const char *json, const char *key, int *out)
{
	char search[64];
	char *pos;

	snprintf(search, sizeof(search), "\"%s\"", key);
	pos = strstr(json, search);
	if (!pos) return -1;

	pos += strlen(search);
	while (*pos == ' ' || *pos == '\t') pos++;
	if (*pos != ':') return -1;
	pos++;
	while (*pos == ' ' || *pos == '\t') pos++;

	if (*pos < '0' || *pos > '9') return -1;
	*out = atoi(pos);
	return 0;
}

// Handle a z/OSMF rename control request (Content-Type: application/json).
//
//   Member rename:  PUT /ds/{dsn}({newmember})
//                   body {"request":"rename","from-dataset":{"dsn":"{dsn}","member":"{oldmember}"}}
//                   -> target_member = newmember (URL), oldmember from body
//   Dataset rename: PUT /ds/{newdsn}
//                   body {"request":"rename","from-dataset":{"dsn":"{olddsn}"}}
//                   -> target_member = NULL, target_dsn = newdsn (URL), olddsn from body
//
// PDS members are renamed with __renmem() (STOW change); cataloged data sets
// with rename() (IDCAMS ALTER). Returns 204 on success.
__asm__("\n&FUNC    SETC 'ds_rename'");
static int
process_rename(Session *session, const char *target_dsn,
               const char *target_member)
{
	char	*body		= NULL;
	size_t	body_len	= 0;
	char	request[16]	= {0};
	char	from_dsn[MAX_DATASET_NAME] = {0};
	char	from_member[12]	= {0};
	int	rc;

	// Read and EBCDIC-translate the JSON control body
	if (read_request_content(session, &body, &body_len) < 0) {
		return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
			CATEGORY_SERVICE, RC_ERROR, REASON_INVALID_RENAME_REQUEST,
			ERR_MSG_INVALID_RENAME_REQUEST, NULL, 0);
	}
	http_xlate((unsigned char *)body, body_len, httpx->xlate_cp037->atoe);

	// Only "rename" is supported
	if (extract_json_string(body, "request", request, sizeof(request)) < 0 ||
	    strcmp(request, "rename") != 0) {
		free(body);
		return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
			CATEGORY_SERVICE, RC_ERROR, REASON_INVALID_RENAME_REQUEST,
			ERR_MSG_INVALID_RENAME_REQUEST, NULL, 0);
	}

	if (target_member) {
		// Member rename: from-dataset.member is the OLD member name,
		// the URL member is the NEW name, within the same PDS (target_dsn).
		if (extract_json_string(body, "member", from_member,
				sizeof(from_member)) < 0) {
			free(body);
			return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
				CATEGORY_SERVICE, RC_ERROR, REASON_INVALID_RENAME_REQUEST,
				ERR_MSG_INVALID_RENAME_REQUEST, NULL, 0);
		}
		free(body);

		rc = __renmem(target_dsn, from_member, target_member);
		if (rc == 0) {
			return sendDefaultHeaders(session, 204, "application/json", 0);
		}
		if (rc == 8 || rc == -2) {	// old member / data set not found
			return sendErrorResponse(session, HTTP_STATUS_NOT_FOUND,
				CATEGORY_SERVICE, RC_ERROR, REASON_MEMBER_NOT_FOUND,
				ERR_MSG_MEMBER_NOT_FOUND, NULL, 0);
		}
		if (rc == 4) {			// new member already exists
			return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
				CATEGORY_SERVICE, RC_ERROR, REASON_RENAME_TARGET_EXISTS,
				ERR_MSG_RENAME_TARGET_EXISTS, NULL, 0);
		}
		wtof("MVSMF80E Member rename failed: %s(%s) -> (%s) rc=%d",
			target_dsn, from_member, target_member, rc);
		return sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
			CATEGORY_SERVICE, RC_ERROR, REASON_RENAME_FAILED,
			ERR_MSG_RENAME_FAILED, NULL, 0);
	} else {
		// Data set rename: from-dataset.dsn is the OLD name, the URL
		// data set (target_dsn) is the NEW name.
		LOCWORK	locwork;
		char	dsn44[44];

		if (extract_json_string(body, "dsn", from_dsn,
				sizeof(from_dsn)) < 0) {
			free(body);
			return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
				CATEGORY_SERVICE, RC_ERROR, REASON_INVALID_RENAME_REQUEST,
				ERR_MSG_INVALID_RENAME_REQUEST, NULL, 0);
		}
		free(body);

		// Verify the source data set exists
		memset(dsn44, ' ', sizeof(dsn44));
		memcpy(dsn44, from_dsn, strlen(from_dsn));
		memset(&locwork, 0, sizeof(locwork));
		if (__locate(dsn44, &locwork) != 0) {
			return sendErrorResponse(session, HTTP_STATUS_NOT_FOUND,
				CATEGORY_SERVICE, RC_ERROR, REASON_DATASET_NOT_FOUND,
				ERR_MSG_DATASET_NOT_FOUND, NULL, 0);
		}

		rc = rename(from_dsn, target_dsn);	// IDCAMS ALTER NEWNAME
		if (rc == 0) {
			return sendDefaultHeaders(session, 204, "application/json", 0);
		}
		wtof("MVSMF81E Dataset rename failed: %s -> %s rc=%d",
			from_dsn, target_dsn, rc);
		return sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
			CATEGORY_SERVICE, RC_ERROR, REASON_RENAME_FAILED,
			ERR_MSG_RENAME_FAILED, NULL, 0);
	}
}

__asm__("\n&FUNC    SETC 'DAPI0004'");
int datasetCreateHandler(Session *session)
{
	int rc = 0;
	char *dsname = NULL;
	char *body = NULL;
	char local_body[4096];
	int free_body = 0;
	size_t body_size = 0;

	char dsorg[8] = {0};
	char alcunit[8] = {0};
	char recfm[8] = {0};
	int primary = 0;
	int secondary = 0;
	int dirblk = 0;
	int lrecl = 0;
	int blksize = 0;

	char ddname[9] = {0};
	char opts[512];

	dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
	if (!dsname) {
		wtof("MVSMF60E Dataset create: missing dataset name");
		return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
			CATEGORY_SERVICE, RC_ERROR, REASON_INVALID_ALLOC_PARAMS,
			ERR_MSG_INVALID_ALLOC_PARAMS, NULL, 0);
	}

	/*
	 * Try POST_STRING first — HTTPD sets this when the request
	 * includes a Content-Type header (already in EBCDIC).
	 *
	 * If POST_STRING is empty (e.g. Zowe CLI sends no Content-Type),
	 * read the body directly from the socket.
	 */
	body = (char *) http_get_env(session->httpc,
		(const UCHAR *) "POST_STRING");

	if (!body || !*body) {
		const char *te = (const char *) http_get_env(session->httpc,
			(const UCHAR *) "HTTP_TRANSFER-ENCODING");
		const char *cl = (const char *) http_get_env(session->httpc,
			(const UCHAR *) "HTTP_CONTENT-LENGTH");
		int is_chunked = (te && strstr(te, "chunked") != NULL);

		memset(local_body, 0, sizeof(local_body));
		body_size = 0;

		if (is_chunked) {
			/* Read chunked transfer encoding */
			while (1) {
				char chunk_hdr[10] = {0};
				size_t chunk_size;
				int i = 0;
				char c;
				size_t n;

				/* Read chunk size line (ASCII hex + CRLF) */
				while (i < (int)sizeof(chunk_hdr) - 1) {
					if (recv(session->httpc->socket, &c, 1, 0) != 1) break;
					if (c == 0x0D) {	/* ASCII CR */
						recv(session->httpc->socket, &c, 1, 0); /* LF */
						break;
					}
					chunk_hdr[i++] = c;
				}
				chunk_hdr[i] = '\0';

				/* Convert ASCII hex to EBCDIC for strtoul */
				http_xlate((unsigned char *)chunk_hdr, strlen(chunk_hdr), httpx->xlate_cp037->atoe);
				chunk_size = strtoul(chunk_hdr, NULL, 16);

				if (chunk_size == 0) {
					/* Read trailing CRLF */
					char crlf[2];
					recv(session->httpc->socket, crlf, 2, 0);
					break;
				}

				/* Read chunk data */
				n = 0;
				while (n < chunk_size) {
					int r = recv(session->httpc->socket, local_body + body_size + n, 1, 0);
					if (r != 1) break;
					n++;
					if (body_size + n >= sizeof(local_body) - 1) break;
				}
				body_size += n;

				/* Read chunk trailing CRLF */
				{
					char crlf[2];
					recv(session->httpc->socket, crlf, 2, 0);
				}
			}
		} else if (cl) {
			/* Read Content-Length bytes */
			size_t content_length = strtoul(cl, NULL, 10);
			if (content_length >= sizeof(local_body))
				content_length = sizeof(local_body) - 1;

			while (body_size < content_length) {
				int r = recv(session->httpc->socket,
					local_body + body_size, 1, 0);
				if (r != 1) break;
				body_size++;
			}
		}

		if (body_size == 0) {
			wtof("MVSMF61E Dataset create: no body");
			return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
				CATEGORY_SERVICE, RC_ERROR, REASON_INVALID_ALLOC_PARAMS,
				ERR_MSG_INVALID_ALLOC_PARAMS, NULL, 0);
		}

		local_body[body_size] = '\0';

		/* Convert from ASCII to EBCDIC (CP037 for dataset API) */
		http_xlate((unsigned char *)local_body, body_size, httpx->xlate_cp037->atoe);
		body = local_body;
	} else {
		body_size = strlen(body);
	}

	/* Parse JSON fields */
	if (extract_json_string(body, "dsorg", dsorg, sizeof(dsorg)) < 0 ||
	    extract_json_string(body, "recfm", recfm, sizeof(recfm)) < 0 ||
	    extract_json_int(body, "lrecl", &lrecl) < 0 ||
	    extract_json_int(body, "blksize", &blksize) < 0 ||
	    extract_json_int(body, "primary", &primary) < 0) {
		wtof("MVSMF62E Dataset create: missing required JSON fields");
		return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
			CATEGORY_SERVICE, RC_ERROR, REASON_INVALID_ALLOC_PARAMS,
			ERR_MSG_INVALID_ALLOC_PARAMS, NULL, 0);
	}

	/* Optional fields */
	extract_json_int(body, "secondary", &secondary);
	extract_json_int(body, "dirblk", &dirblk);
	if (extract_json_string(body, "alcunit", alcunit, sizeof(alcunit)) < 0) {
		strcpy(alcunit, "TRK");
	}

	/* Build allocation options string */
	snprintf(opts, sizeof(opts),
		"DSN=%s;DISP=(NEW,CATLG,DELETE);DSORG=%s;RECFM=%s;"
		"LRECL=%d;BLKSIZE=%d;SPACE=%s(%d,%d,%d)",
		dsname, dsorg, recfm, lrecl, blksize,
		alcunit, primary, secondary, dirblk);

	/* Allocate the dataset */
	rc = __dsalcf(ddname, "%s", opts);
	if (rc != 0) {
		wtof("MVSMF64E Dataset create failed: rc=%d dsn=%s", rc, dsname);
		return sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
			CATEGORY_SERVICE, RC_ERROR, REASON_DATASET_ALLOC_FAILED,
			ERR_MSG_DATASET_ALLOC_FAILED, NULL, 0);
	}

	/* Free the DD allocation */
	__dsfree(ddname);

	/* Send HTTP 201 Created */
	rc = sendDefaultHeaders(session, HTTP_STATUS_CREATED,
		"application/json", 0);

	return rc;
}

__asm__("\n&FUNC    SETC 'DAPI0005'");
int datasetDeleteHandler(Session *session)
{
	int rc = 0;
	char *dsname = NULL;
	LOCWORK locwork;
	char dsn44[44];

	dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
	if (!dsname) {
		wtof("MVSMF70E Dataset delete: missing dataset name");
		return sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST,
			CATEGORY_SERVICE, RC_ERROR, REASON_INVALID_ALLOC_PARAMS,
			ERR_MSG_INVALID_ALLOC_PARAMS, NULL, 0);
	}

	/* Check if dataset exists via catalog locate */
	memset(dsn44, ' ', sizeof(dsn44));
	memcpy(dsn44, dsname, strlen(dsname));
	memset(&locwork, 0, sizeof(locwork));

	rc = __locate(dsn44, &locwork);
	if (rc != 0) {
		wtof("MVSMF71E Dataset delete: dataset not found: %s", dsname);
		return sendErrorResponse(session, HTTP_STATUS_NOT_FOUND,
			CATEGORY_SERVICE, RC_ERROR, REASON_DATASET_NOT_FOUND,
			ERR_MSG_DATASET_NOT_FOUND, NULL, 0);
	}

	/* remove() uncatalogs and scratches the dataset */
	rc = remove(dsname);
	if (rc != 0) {
		wtof("MVSMF72E Dataset delete failed: rc=%d dsn=%s errno=%d",
			rc, dsname, errno);
		return sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
			CATEGORY_SERVICE, RC_ERROR, REASON_DATASET_ALLOC_FAILED,
			ERR_MSG_DATASET_ALLOC_FAILED, NULL, 0);
	}

	/* Send HTTP 204 No Content */
	rc = sendDefaultHeaders(session, 204, "application/json", 0);

	return rc;
}

__asm__("\n&FUNC    SETC 'DAPI0013'");
int memberDeleteHandler(Session *session)
{
	int rc = 0;
	char *dsname = NULL;
	char *member = NULL;
	char dataset[MAX_QUALIFIED_DSN] = {0};
	FILE *fp = NULL;

	dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
	member = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_member-name");

	if (!dsname || !member) {
		wtof("MVSMF74E Member delete: missing parameters");
		return handle_error(session, ERR_INVALID_PARAM,
			"Dataset and member names are required");
	}

	// Validate dsname and member individually (not combined — qualified form fits MAX_QUALIFIED_DSN)
	if (strlen(dsname) > MAX_DATASET_NAME || strlen(member) > MAX_MEMBER_NAME) {
		return handle_error(session, ERR_INVALID_PARAM,
			"Dataset or member name too long");
	}

	snprintf(dataset, sizeof(dataset), "%s(%s)", dsname, member);

	/* Verify member exists by attempting to open it */
	fp = fopen(dataset, "r");
	if (!fp) {
		wtof("MVSMF75E Member delete: member not found: %s", dataset);
		return sendErrorResponse(session, HTTP_STATUS_NOT_FOUND,
			CATEGORY_SERVICE, RC_ERROR, REASON_MEMBER_NOT_FOUND,
			ERR_MSG_MEMBER_NOT_FOUND, NULL, 0);
	}
	fclose(fp);

	/* remove() deletes the PDS directory entry */
	rc = remove(dataset);
	if (rc != 0) {
		wtof("MVSMF76E Member delete failed: rc=%d ds=%s errno=%d",
			rc, dataset, errno);
		return sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
			CATEGORY_SERVICE, RC_ERROR, REASON_DATASET_ALLOC_FAILED,
			ERR_MSG_DATASET_ALLOC_FAILED, NULL, 0);
	}

	/* Send HTTP 204 No Content */
	rc = sendDefaultHeaders(session, 204, "application/json", 0);

	return rc;
}
