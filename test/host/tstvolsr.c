/*
 * tstvolsr.c - #336: the -({volume-serial}) routes must read the volume.
 *
 * The seven routes captured {volume-serial} and no handler read it, so a
 * request naming the wrong volume was answered as if it had named the right
 * one. The decision is a function now: served only when the catalog entry is on
 * exactly the named volume; a different volume and an uncataloged name are
 * refused, and a malformed volume serial is not guessed at.
 *
 * This test drives the REAL functions: src/volser.c is #included below.
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/volser.c"

static char msg[200];

static void
check_verdict(const char *requested, int located, const char *cat, int want)
{
	snprintf(msg, sizeof(msg), "verdict(\"%s\", located=%d, cat=\"%.6s\") is %d",
		requested ? requested : "NULL", located, cat ? cat : "-", want);
	CHECK_EQ(volser_verdict(requested, located, cat), want, msg);
}

static void
check_norm(const char *value, int want_rc, const char *want_out)
{
	char out[VOLSER_SIZE];

	memset(out, 'x', sizeof(out));
	snprintf(msg, sizeof(msg), "normalize(\"%s\") rc is %d",
		value ? value : "NULL", want_rc);
	CHECK_EQ(volser_normalize(value, out, sizeof(out)), want_rc, msg);
	if (want_rc == 0) {
		snprintf(msg, sizeof(msg), "normalize(\"%s\") gives \"%s\"", value, want_out);
		CHECK_EQ(strcmp(out, want_out), 0, msg);
	} else {
		snprintf(msg, sizeof(msg), "normalize(\"%s\") leaves out untouched",
			value ? value : "NULL");
		CHECK_EQ(out[0], 'x', msg);
	}
}

int
main(void)
{
	printf("--- the catalog entry is on exactly that volume ---\n");
	check_verdict("SYSRES", 1, "SYSRES", VOLSER_ON_VOLUME);
	check_verdict("MVSRES", 1, "MVSRES", VOLSER_ON_VOLUME);
	check_verdict("WORK1",  1, "WORK1 ", VOLSER_ON_VOLUME);
	check_verdict("A",      1, "A     ", VOLSER_ON_VOLUME);
	check_verdict("pub000", 1, "PUB000", VOLSER_ON_VOLUME);
	check_verdict("$#@123", 1, "$#@123", VOLSER_ON_VOLUME);

	printf("\n--- cataloged on another volume: never the cataloged data set ---\n");
	check_verdict("SYSRES", 1, "MVSRES", VOLSER_OTHER_VOLUME);
	check_verdict("WORK",   1, "WORK1 ", VOLSER_OTHER_VOLUME);
	check_verdict("WORK12", 1, "WORK1 ", VOLSER_OTHER_VOLUME);
	check_verdict("WORK1",  1, "WORK12", VOLSER_OTHER_VOLUME);
	check_verdict("A",      1, "B     ", VOLSER_OTHER_VOLUME);

	printf("\n--- not cataloged: refused, whatever the volume ---\n");
	check_verdict("SYSRES", 0, "SYSRES", VOLSER_NOT_CATALOGED);
	check_verdict("SYSRES", 0, "      ", VOLSER_NOT_CATALOGED);
	check_verdict("SYSRES", 0, NULL,     VOLSER_NOT_CATALOGED);

	printf("\n--- a malformed volume serial is not guessed at ---\n");
	check_verdict(NULL,       1, "SYSRES", VOLSER_BAD);
	check_verdict("",         1, "SYSRES", VOLSER_BAD);
	check_verdict("TOOLONG1", 1, "TOOLON", VOLSER_BAD);
	check_verdict("SYS RES",  1, "SYS RE", VOLSER_BAD);
	check_verdict("SYS-RE",   1, "SYS-RE", VOLSER_BAD);
	check_verdict("      ",   1, "      ", VOLSER_BAD);

	printf("\n--- normalize ---\n");
	check_norm("SYSRES", 0, "SYSRES");
	check_norm("sysres", 0, "SYSRES");
	check_norm("A",      0, "A");
	check_norm("a1b2c3", 0, "A1B2C3");
	check_norm("$#@",    0, "$#@");
	check_norm("SYSRES ", -1, NULL);
	check_norm(" SYSRES", -1, NULL);
	check_norm("SYSRES1", -1, NULL);
	check_norm("",        -1, NULL);
	check_norm(NULL,      -1, NULL);
	check_norm("SYS.RE",  -1, NULL);
	check_norm("SYS/RE",  -1, NULL);
	check_norm("SYS*",    -1, NULL);

	{
		char tiny[VOLSER_SIZE - 1];

		memset(tiny, 'x', sizeof(tiny));
		CHECK_EQ(volser_normalize("SYSRES", tiny, sizeof(tiny)), -1,
			"an out one byte too small is refused");
		CHECK_EQ(tiny[0], 'x', "an out that is too small is untouched");
		CHECK_EQ(volser_normalize("SYSRES", NULL, 0), -1,
			"a NULL out is refused");
	}

	return mbt_test_summary("TSTVOLSR");
}
