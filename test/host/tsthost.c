/*
 * tsthost.c - #260 regression: splitting a Host header into host name and port.
 *
 * /zosmf/info echoes the host and port back so the client can build
 * self-referential URLs. The header is client-supplied and has now broken the
 * endpoint twice:
 *
 *   #175  an odd Host made the handler send nothing and drop the connection
 *   #260  a Host with no name in front of the colon (":8080", ":::garbage:::")
 *         parsed as SUCCESS with an empty string, so the caller's fallback to
 *         DEFAULT_HOST never ran and the client got "zosmf_hostname":""
 *
 * The contract the caller depends on, and the one this test pins down: a
 * non-zero return means the output is unusable. Returning 0 with an empty host
 * name is worse than failing, because it looks like it worked.
 *
 * ====================================================================
 * This test drives the REAL parser: src/hostparse.c is #included below.
 * infoapi.c itself cannot compile on the host (it pulls in the httpd
 * session headers), which is why the parsing lives in its own TU.
 * ====================================================================
 *
 * Runs on host via `make test-host`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/hostparse.c"

/* The buffer sizes infoapi.c uses, so the -2 cases are the real ones. */
#define HOSTBUF 256
#define PORTBUF 6      /* max port 65535 = 5 digits + nul */

static char msg[160];

/* Parse `value` and assert both the return code and, on success, the output.
   The buffer is poisoned first, so a parser that returns 0 without writing
   anything fails here rather than reading as success -- which is exactly the
   shape of #260. */
static void
check_host(const char *value, int want_rc, const char *want_host)
{
	char buf[HOSTBUF];
	int rc;

	memset(buf, '@', sizeof(buf));
	buf[sizeof(buf) - 1] = '\0';

	rc = parse_host_name(value, buf, sizeof(buf));
	sprintf(msg, "parse_host_name(\"%s\") returns %d", value, want_rc);
	CHECK_EQ(rc, want_rc, msg);

	if (want_rc == 0) {
		sprintf(msg, "parse_host_name(\"%s\") yields \"%s\"", value, want_host);
		CHECK(strcmp(buf, want_host) == 0, msg);
	}
}

static void
check_port(const char *value, int want_rc, const char *want_port)
{
	char buf[PORTBUF];
	int rc;

	memset(buf, '@', sizeof(buf));
	buf[sizeof(buf) - 1] = '\0';

	rc = parse_port_string(value, buf, sizeof(buf));
	sprintf(msg, "parse_port_string(\"%s\") returns %d", value, want_rc);
	CHECK_EQ(rc, want_rc, msg);

	if (want_rc == 0) {
		sprintf(msg, "parse_port_string(\"%s\") yields \"%s\"",
			value, want_port);
		CHECK(strcmp(buf, want_port) == 0, msg);
	}
}

int
main(void)
{
	char small[4];

	printf("\n--- #260: a Host with no name must FAIL, not succeed empty ---\n");

	/* Each of these carries no host name. Before the fix they returned 0
	   with an empty string, and the caller read that as success. */
	check_host(":8080",         -3, NULL);
	check_host(":",             -3, NULL);
	check_host(":::garbage:::", -3, NULL);

	printf("\n--- ordinary values ---\n");

	check_host("example.org:8080", 0, "example.org");
	check_host("example.org",      0, "example.org");
	check_host("mvsdev.lan:1080",  0, "mvsdev.lan");
	check_host("127.0.0.1:8080",   0, "127.0.0.1");

	printf("\n--- bad arguments and short buffers ---\n");

	CHECK_EQ(parse_host_name(NULL, small, sizeof(small)), -1,
		"parse_host_name with a null value");
	CHECK_EQ(parse_host_name("example.org", NULL, HOSTBUF), -1,
		"parse_host_name with a null buffer");
	CHECK_EQ(parse_host_name("example.org", small, 0), -1,
		"parse_host_name with outSize 0");
	CHECK_EQ(parse_host_name("example.org", small, sizeof(small)), -2,
		"parse_host_name into a buffer that is too small");
	CHECK_EQ(parse_host_name("abcd", small, sizeof(small)), -2,
		"parse_host_name with hostLen == outSize still fails");
	CHECK_EQ(parse_host_name("abc", small, sizeof(small)), 0,
		"parse_host_name with hostLen == outSize - 1 fits");

	printf("\n--- ports ---\n");

	check_port("example.org:8080", 0, "8080");
	check_port("example.org:80",   0, "80");
	check_port("example.org",      0, "");   /* no port: scheme implies it */
	check_port("example.org:",     0, "");   /* colon, nothing behind it   */
	check_port(":8080",            0, "8080");
	CHECK_EQ(parse_port_string(NULL, small, sizeof(small)), -1,
		"parse_port_string with a null value");
	/* 6 digits + nul does not fit PORTBUF; the caller then falls back */
	check_port("example.org:999999", -2, NULL);

	printf("\n--- port validation ---\n");

	CHECK_EQ(validate_port("8080"),   0, "8080 is a valid port");
	CHECK_EQ(validate_port("1"),      0, "1 is a valid port");
	CHECK_EQ(validate_port("65535"),  0, "65535 is a valid port");
	CHECK_EQ(validate_port("0"),     -1, "0 is not a valid port");
	CHECK_EQ(validate_port("65536"), -1, "65536 is out of range");
	CHECK_EQ(validate_port("99999"), -1, "99999 is out of range");
	CHECK_EQ(validate_port("80a"),   -1, "a non-digit is not a valid port");
	CHECK_EQ(validate_port("-80"),   -1, "a negative port is not valid");
	CHECK_EQ(validate_port(""),      -1, "an empty port is not valid");
	CHECK_EQ(validate_port(NULL),    -1, "a null port is not valid");

	printf("\n--- the /zosmf/info path, as infoapi.c runs it ---\n");

	/* A junk Host must leave BOTH outputs on their fallbacks. This is the
	   combination #260 got wrong: the port fell back correctly while the
	   host name came back empty. */
	{
		char host[HOSTBUF];
		char port[PORTBUF];
		int used_default_host = 0;

		strcpy(host, "127.0.0.1");      /* DEFAULT_HOST */
		if (parse_host_name(":::garbage:::", host, sizeof(host)) != 0) {
			strcpy(host, "127.0.0.1");
			used_default_host = 1;
		}
		if (parse_port_string(":::garbage:::", port, sizeof(port)) != 0) {
			port[0] = '\0';
		}

		CHECK(used_default_host,
			"a junk Host falls back to the default host name");
		CHECK(host[0] != '\0', "zosmf_hostname is never reported empty");
		CHECK(validate_port(port) != 0,
			"a junk Host leaves the port for the scheme default");
	}

	return mbt_test_summary("TSTHOST");
}
