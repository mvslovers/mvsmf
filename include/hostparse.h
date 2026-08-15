#ifndef HOSTPARSE_H
#define HOSTPARSE_H

#include <stddef.h>

/**
 * @file hostparse.h
 * @brief Splitting a `Host` header into a host name and a port.
 *
 * `/zosmf/info` echoes the host and port back to the client so it can build
 * self-referential URLs, and it derives both from the `Host` header -- never
 * from `SERVER_PORT`, which is httpd's listen port and not the one the client
 * dialled.
 *
 * That header is client-supplied and arrives malformed often enough that the
 * endpoint has now been broken twice by it: issue #175 (an odd Host dropped
 * the connection) and issue #260 (a Host starting with a colon parsed
 * "successfully" as an empty name, so the caller's fallback never ran). The
 * parsing lives here so there is one copy of it and so test/host/tsthost.c can
 * exercise the real code on the host.
 *
 * All three are pure string functions -- no session, no httpd, no MVS. The
 * scheme-dependent default (`default_port()`) stays in infoapi.c, because it
 * needs the request.
 *
 * The contract every caller depends on: **a non-zero return means the output
 * is unusable and the caller must fall back.** Returning 0 with an empty host
 * name would be worse than failing, because it looks like success.
 *
 * One input still breaks that contract: an IPv6 literal. `[::1]:8080` has its
 * first colon at offset 1, so the name comes back as "[" and the return is 0.
 * MVS 3.8j has no IPv6 stack, so nothing on the target can dial one -- but a
 * reverse proxy could forward such a header, and this code already
 * accommodates proxies through X-Forwarded-*. Splitting on the last colon
 * outside brackets would fix it; nobody has needed it yet.
 */

/**
 * Extract the host name from a `Host` header value ("name" or "name:port").
 *
 * @param value   header value; may be NULL
 * @param outHost buffer for the name, always nul-terminated on success
 * @param outSize size of outHost
 * @return 0 on success, -1 on a bad argument, -2 if outHost is too small,
 *         -3 if the value carries no host name at all (":8080", ":::x:::").
 *         Anything non-zero leaves outHost untouched.
 */
int parse_host_name(const char *value, char *outHost, size_t outSize)
															asm("MFHSTNAM");

/**
 * Extract the port from a `Host` header value.
 *
 * A value with no port, or with a colon and nothing after it, is not an error:
 * RFC 7230 5.4 lets the header omit the port, and then the scheme implies it.
 * outPort is set empty and 0 returned, and it is the caller's job to supply
 * the scheme default.
 *
 * @return 0 on success, -1 on a bad argument, -2 if outPort is too small
 */
int parse_port_string(const char *value, char *outPort, size_t outSize)
															asm("MFHSTPRT");

/**
 * @return 0 if `port` is all digits and in 1..65535, -1 otherwise.
 *         An empty or NULL port is invalid -- see parse_port_string().
 */
int validate_port(const char *port)							asm("MFHSTVPT");

#endif /* HOSTPARSE_H */
