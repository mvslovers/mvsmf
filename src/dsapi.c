#include <stdio.h>
#include <string.h>
#include <clibwto.h>
#include <cliblist.h>
#include <clibdscb.h>
#include <osdcb.h>
#include <errno.h>

#include "dsapi.h"
#include "dsapi_err.h"
#include "common.h"
#include "httpd.h"
#include "xlate.h"

// Record format flags
#define FIXED     0x0001
#define VARIABLE  0x0002
#define UNDEFINED 0x0004

// Constants for better readability and maintainability
#define MAX_BUFFER_SIZE 1024
#define MAX_DATASET_NAME 44
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
    
    // Check for integer overflow
    if (fp->lrecl > (SIZE_MAX - 2)) {
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
		/* Text mode: fgets + EBCDIC->ASCII + strlen for length */
		while (fgets(buffer, lrecl + 2, fp) > 0) {
			size_t len = strlen(buffer);
			mvsmf_etoa((unsigned char *)buffer, len);
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
	int rc = http_resp_internal_error(session->httpc);
    if (rc < 0) return rc;
    
    return http_printf(session->httpc, 
                      "{\n  \"error\": \"%s\",\n  \"code\": %d\n}\n", 
                      message, error_code);
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

// Helper function to parse X-IBM-Data-Type header
static int parse_data_type(const char *data_type) {
    if (!data_type) return DATA_TYPE_TEXT;  // Default is text
    
    if (strncmp(data_type, "text", 4) == 0) return DATA_TYPE_TEXT;
    if (strcmp(data_type, "binary") == 0) return DATA_TYPE_BINARY;
    if (strcmp(data_type, "record") == 0) return DATA_TYPE_RECORD;
    
    return DATA_TYPE_TEXT;  // Default to text for unknown values
}

// Helper function to write a complete record
static int write_record(Session *session, FILE *fp, char *record_buffer, size_t record_length, size_t *total_written, int *line_count, int data_type) 
{   
    char ebcdic_buffer[MAX_BUFFER_SIZE];
    int recfm = fp->recfm;  // Get record format from file handle
    int lrecl = fp->lrecl;  // Get logical record length from file handle

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
            
            // Ensure we don't exceed LRECL
            if (record_length > fp->lrecl) {
                wtof("MVSMF30W Truncating record to fit LRECL (%d)", fp->lrecl);
                record_length = fp->lrecl;
            }
            
            // Copy to temporary buffer and convert to EBCDIC
            memcpy(ebcdic_buffer, record_buffer, record_length);
            mvsmf_atoe((unsigned char *)ebcdic_buffer, record_length);
  
            // Write the converted record
            if (fwrite(ebcdic_buffer, 1, record_length, fp) != record_length) return -1;
            fflush(fp);

            *total_written += record_length;
            break;
    }
    
    (*line_count)++;
    return 0;
}

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

		if ((rc = http_printf(session->httpc, "      \"dsname\": \"%.44s\",\n", ds->dsn)) < 0) goto quit;
		
		// TODO: the following fields should only be generated if X-IBM-Attributes == base
		// TODO: add vol field only if X-IBM-Attributes has 'vol'
		if (strcmp(ds->dsorg, "PO") == 0) {
			if ((rc = http_printf(session->httpc, "      \"dsntp\": \"%s\",\n", "PDS")) < 0) goto quit;
		} else if (strcmp(ds->dsorg, "PS") == 0) {
			if ((rc = http_printf(session->httpc, "      \"dsntp\": \"%s\",\n", "BASIC")) < 0) goto quit;
		} else {
			if ((rc = http_printf(session->httpc, "      \"dsntp\": \"%s\",\n", "UNKNOWN")) < 0) goto quit;
		}

		if ((rc = http_printf(session->httpc, "      \"recfm\": \"%.4s\",\n", ds->recfm)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"lrecl\": %d,\n", ds->lrecl)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"blksize\": %d,\n", ds->blksize)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"vol\": \"%.6s\",\n", ds->volser)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"vols\": \"%.6s\",\n", ds->volser)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"dsorg\": \"%.2s\",\n", ds->dsorg)) < 0) goto quit;
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
        return handle_error(session, ERR_IO, "Cannot open dataset");
    }

    rc = read_and_send_dataset(session, fp, data_type, max_records);

    fclose(fp);
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
    char record_buffer[MAX_BUFFER_SIZE] = {0};
    size_t record_pos = 0;
    size_t bytes_received = 0;
    int data_type;

    // Validate parameters
    dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
    
    if (!dsname) {
        wtof("MVSMF31E Missing required parameter: dsname=NULL");
        return handle_error(session, ERR_INVALID_PARAM, "Dataset name is required");
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

    fp = fopen(dsname, mode_str);
    if (!fp) {
        wtof("MVSMF34E Failed to open dataset for writing: %s (errno=%d)", dsname, errno);
        return handle_error(session, ERR_IO, "Cannot open dataset for writing");
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
                    fclose(fp);
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
            mvsmf_atoe((unsigned char *)chunk_size_str, strlen(chunk_size_str));

            // Convert chunk size from string to integer
            chunk_size = strtoul(chunk_size_str, NULL, 16);

            if (chunk_size == 0) {
                // Write last incomplete record if any
                if (record_pos > 0) {
                    if (data_type == DATA_TYPE_BINARY) {
                        // Pad to full LRECL for fixed-length binary records
                        memset(record_buffer + record_pos, 0x00, fp->lrecl - record_pos);
                        record_pos = fp->lrecl;
                    }
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                        wtof("MVSMF39E Error writing final record");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Error writing final record");
                    }
                }

                // Read final CRLF
                char crlf[2] = {0};
                if (recv(session->httpc->socket, crlf, 2, 0) != 2) {
                    wtof("MVSMF40E Error reading final line ending");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Error reading final line ending");
                }

                if (crlf[0] != 0x0d || crlf[1] != 0x0a) {
                    wtof("MVSMF41E Final line ending not CRLF");
                    fclose(fp);
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
                    size_t space = fp->lrecl - record_pos;
                    int n;
                    if (to_read > space) to_read = space;

                    n = recv(session->httpc->socket, record_buffer + record_pos, to_read, 0);
                    if (n <= 0) {
                        wtof("MVSMF38E Error reading chunk data");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Error reading chunk data");
                    }
                    bytes_read += n;
                    record_pos += n;

                    if (record_pos >= fp->lrecl) {
                        if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                            wtof("MVSMF42E Error writing record");
                            fclose(fp);
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
                        wtof("MVSMF38E Error reading chunk data");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Error reading chunk data");
                    }
                    bytes_read++;

                    if (record_pos >= sizeof(record_buffer) - 1) {
                        wtof("MVSMF43E Record too long");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Record too long");
                    }
                    record_buffer[record_pos++] = c;

                    if (c == 0x0A) {
                        if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                            wtof("MVSMF42E Error writing record");
                            fclose(fp);
                            return handle_error(session, ERR_IO, "Error writing record");
                        }
                        record_pos = 0;
                    }
                }

                // Write any remaining text data at end of chunk
                if (record_pos > 0) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                        wtof("MVSMF39E Error writing final record");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Error writing final record");
                    }
                    record_pos = 0;
                }
            }
            
            // Read chunk trailer (CRLF)
            char crlf[2];
            if (recv(session->httpc->socket, crlf, 2, 0) != 2) {
                wtof("MVSMF43E Error reading chunk trailer");
                fclose(fp);
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
                size_t space = fp->lrecl - record_pos;
                int n;
                if (to_read > space) to_read = space;

                n = recv(session->httpc->socket, record_buffer + record_pos, to_read, 0);
                if (n <= 0) {
                    wtof("MVSMF45E Error reading data in Content-Length mode");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Error reading data");
                }
                bytes_remaining -= n;
                record_pos += n;

                if (record_pos >= fp->lrecl) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                        wtof("MVSMF46E Error writing record");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Error writing record");
                    }
                    record_pos = 0;
                }
            }

            // Pad and write final incomplete binary record
            if (record_pos > 0) {
                memset(record_buffer + record_pos, 0x00, fp->lrecl - record_pos);
                record_pos = fp->lrecl;
                if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                    wtof("MVSMF39E Error writing final record");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Error writing final record");
                }
            }
        } else {
            // Text mode: split records at newline boundaries
            char c;
            while (bytes_remaining > 0) {
                if (recv(session->httpc->socket, &c, 1, 0) != 1) {
                    wtof("MVSMF45E Error reading data in Content-Length mode");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Error reading data");
                }
                bytes_remaining--;

                if (record_pos >= sizeof(record_buffer) - 1) {
                    wtof("MVSMF43E Record too long");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Record too long");
                }
                record_buffer[record_pos++] = c;

                if (c == 0x0A || c == 0x0D) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                        wtof("MVSMF46E Error writing record");
                        fclose(fp);
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

            // Write any remaining text data as the last record
            if (record_pos > 0) {
                if (record_pos > fp->lrecl) {
                    record_pos = fp->lrecl;
                }
                if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                    wtof("MVSMF39E Error writing final record");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Error writing final record");
                }
            }
        }
    }

    fclose(fp);
    fp = NULL;

    // Send response
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
    if (fp) {
        fclose(fp);
    }
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
		if ((rc = http_printf(session->httpc, "      \"member\": \"%.8s\"\n", pds->name)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "    }\n")) < 0) goto quit;
	}

end:
	if ((rc = http_printf(session->httpc, "  ],\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"returnedRows\": %d,\n", count)) < 0) goto quit;
	// TODO: add totalRows if X-IBM-Attributes has ',total'
	if ((rc = http_printf(session->httpc, "  \"JSONversion\": 1\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "} \n")) < 0) goto quit;

quit:
	if (pdslist) {
		__freepd(&pdslist);
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
    char dataset[MAX_DATASET_NAME] = {0};
    FILE *fp = NULL;

    // Validate parameters
    dsname = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_dataset-name");
    member = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_member-name");

    if (!dsname || !member) {
        return handle_error(session, ERR_INVALID_PARAM, "Dataset and member names are required");
    }

    // Check path length
    if (strlen(dsname) + strlen(member) + 3 > MAX_DATASET_NAME) {
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
        return handle_error(session, ERR_IO, "Cannot open dataset member");
    }

    // PDS member: record count unknown, pass -1 (no limit)
    rc = read_and_send_dataset(session, fp, data_type, -1);

    fclose(fp);
    return rc;
}

int memberPutHandler(Session *session)
{
    int rc = 0;
    char *dsname = NULL;
    char *member = NULL;
    char dataset[MAX_DATASET_NAME] = {0};
    FILE *fp = NULL;
    char buffer[MAX_BUFFER_SIZE];
    const char *content_length_str = NULL;
    const char *transfer_encoding = NULL;
    const char *data_type_str = NULL;
    int is_chunked = 0;
    int has_content_length = 0;
    size_t content_length = 0;
    size_t total_written = 0;
    int line_count = 0;
    char record_buffer[MAX_BUFFER_SIZE] = {0};
    size_t record_pos = 0;
    size_t bytes_received = 0;
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
    fp = fopen(dataset, member_mode);
    if (!fp) {
        wtof("MVSMF06E Failed to open dataset member for writing: %s (errno=%d)", dataset, errno);
        return handle_error(session, ERR_IO, "Cannot open dataset member for writing");
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
                    fclose(fp);
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
            mvsmf_atoe((unsigned char *)chunk_size_str, strlen(chunk_size_str));

            // Convert chunk size from string to integer
            chunk_size = strtoul(chunk_size_str, NULL, 16);

            if (chunk_size == 0) {
                // Write last incomplete record if any
                if (record_pos > 0) {
                    if (data_type == DATA_TYPE_BINARY) {
                        // Pad to full LRECL for fixed-length binary records
                        memset(record_buffer + record_pos, 0x00, fp->lrecl - record_pos);
                        record_pos = fp->lrecl;
                    }
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                        wtof("MVSMF11E Error writing final record");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Error writing final record");
                    }
                }

                // Read final CRLF
                char crlf[2] = {0};
                if (recv(session->httpc->socket, crlf, 2, 0) != 2) {
                    wtof("MVSMF40E Error reading final line ending");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Error reading final line ending");
                }

                if (crlf[0] != 0x0d || crlf[1] != 0x0a) {
                    wtof("MVSMF41E Final line ending not CRLF");
                    fclose(fp);
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
                    size_t space = fp->lrecl - record_pos;
                    int n;
                    if (to_read > space) to_read = space;

                    n = recv(session->httpc->socket, record_buffer + record_pos, to_read, 0);
                    if (n <= 0) {
                        wtof("MVSMF13E Error reading chunk data");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Error reading chunk data");
                    }
                    bytes_read += n;
                    record_pos += n;

                    if (record_pos >= fp->lrecl) {
                        if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                            wtof("MVSMF14E Error writing record");
                            fclose(fp);
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
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Error reading chunk data");
                    }
                    bytes_read++;

                    if (record_pos >= sizeof(record_buffer) - 1) {
                        wtof("MVSMF43E Record too long");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Record too long");
                    }
                    record_buffer[record_pos++] = c;

                    if (c == 0x0A) {
                        if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                            wtof("MVSMF14E Error writing record");
                            fclose(fp);
                            return handle_error(session, ERR_IO, "Error writing record");
                        }
                        record_pos = 0;
                    }
                }

                // Write any remaining text data at end of chunk
                if (record_pos > 0) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                        wtof("MVSMF39E Error writing final record");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Error writing final record");
                    }
                    record_pos = 0;
                }
            }
            
            // Read chunk trailer (CRLF)
            char crlf[2];
            if (recv(session->httpc->socket, crlf, 2, 0) != 2) {
                wtof("MVSMF15E Error reading chunk trailer");
                fclose(fp);
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
                size_t space = fp->lrecl - record_pos;
                int n;
                if (to_read > space) to_read = space;

                n = recv(session->httpc->socket, record_buffer + record_pos, to_read, 0);
                if (n <= 0) {
                    wtof("MVSMF17E Error reading data in Content-Length mode");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Error reading data");
                }
                bytes_remaining -= n;
                record_pos += n;

                if (record_pos >= fp->lrecl) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                        wtof("MVSMF18E Error writing record");
                        fclose(fp);
                        return handle_error(session, ERR_IO, "Error writing record");
                    }
                    record_pos = 0;
                }
            }

            // Pad and write final incomplete binary record
            if (record_pos > 0) {
                memset(record_buffer + record_pos, 0x00, fp->lrecl - record_pos);
                record_pos = fp->lrecl;
                if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                    wtof("MVSMF19E Error writing final record");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Error writing final record");
                }
            }
        } else {
            // Text mode: split records at newline boundaries
            char c;
            while (bytes_remaining > 0) {
                if (recv(session->httpc->socket, &c, 1, 0) != 1) {
                    wtof("MVSMF17E Error reading data in Content-Length mode");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Error reading data");
                }
                bytes_remaining--;

                if (record_pos >= sizeof(record_buffer) - 1) {
                    wtof("MVSMF43E Record too long");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Record too long");
                }
                record_buffer[record_pos++] = c;

                if (c == 0x0A || c == 0x0D) {
                    if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                        wtof("MVSMF18E Error writing record");
                        fclose(fp);
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
                if (record_pos > fp->lrecl) {
                    record_pos = fp->lrecl;
                }
                if (write_record(session, fp, record_buffer, record_pos, &total_written, &line_count, data_type) < 0) {
                    wtof("MVSMF19E Error writing final record");
                    fclose(fp);
                    return handle_error(session, ERR_IO, "Error writing final record");
                }
            }
        }
    }

    fclose(fp);
    fp = NULL;

    // Send response
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
        fclose(fp);
    }
    return rc;
}
