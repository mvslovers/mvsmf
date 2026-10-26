#ifndef REQPATH_H
#define REQPATH_H

#include <stddef.h>

/**
 * @file reqpath.h
 * @brief The request path the router matches routes against.
 *
 * httpd percent-decodes the path once, when it parses the request line
 * (`httppars.c`, `http_decode()`), and hands the result over as the
 * `REQUEST_PATH` variable. That value is already the name the client meant:
 * `%2541` arrives as `%41`, and `a%25b` as `a%b`. It must reach route matching
 * and the path variables as it is. Decoding it a second time reads a literal
 * `%` in a name as the start of an escape, so a name can turn into another one
 * after the handler's checks have already looked at the first.
 *
 * Pure string function -- no session, no httpd, no MVS -- so that
 * test/host/tstrqpth.c exercises the real code.
 */

/**
 * @brief Copy `REQUEST_PATH` into `out`, unchanged.
 *
 * @param raw     the value of `REQUEST_PATH`, already decoded by httpd
 * @param out     destination
 * @param outSize size of `out`, including the terminating NUL
 * @return 0 on success; -1 if an argument is unusable (`raw` NULL, `out` NULL,
 *         `outSize` 0). A path that does not fit is cut at `outSize - 1`.
 */
int request_path_copy(const char *raw, char *out, size_t outSize)
											asm("MFREQPTH");

#endif
