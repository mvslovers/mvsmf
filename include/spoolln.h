#ifndef SPOOLLN_H
#define SPOOLLN_H

/**
 * @file spoolln.h
 * @brief What becomes of one record of a JES2 spool data set (issue #314).
 *
 * Two rules decide, and their order is load-bearing:
 *
 *   1. the record-count cap of issue #158, and
 *   2. the JESJCLIN records that are not card images.
 *
 * JES2 writes a pointer record into the JCL data set behind every in-stream
 * `DD *` card -- 9 binary bytes carrying the DSID of the SYSIN data set the
 * card opened (measured: 0x65 = 101 behind the first, 0x66 = 102 behind the
 * second). The PDDB record count does NOT include those records: it equals
 * the number of JCL statements exactly, in every job measured, and equals the
 * JESJCL line count.
 *
 * So the cap of #158 -- which counts what went out -- spends one of its
 * budget on every pointer record, and the listing loses one real card off the
 * tail per in-stream DD. That is the actual damage behind #314: the binary
 * record on the wire is the visible half, the truncation the silent one.
 *
 * The fix is therefore not "hide the record" but "do not count it": a skipped
 * pointer must advance neither the cap counter nor the output counter, or the
 * cards it displaced stay lost.
 *
 * @see jobsapi.c do_print_sysout(), and /zosmf/test?fn=spool for the raw
 *      block dump the record format was read from.
 */

/** @brief Print this record. */
#define SPOOL_LINE_EMIT 0

/**
 * @brief Not a record of this data set's content -- drop it silently.
 *
 * The caller must not count it: not toward the cap, and not toward "output
 * has gone out" (which gates the dd separator and the no-output status).
 */
#define SPOOL_LINE_SKIP 1

/** @brief The logical end of the data set -- stop the walk. */
#define SPOOL_LINE_STOP 2

/**
 * Decide what to do with one record.
 *
 * @param jclin   non-zero when the data set is JESJCLIN (dsid PDBINJCL).
 *                Only there is a non-statement record known to be JES2's own;
 *                every other spool data set may hold arbitrary bytes.
 * @param limit   the #158 cap (the PDDB record count), 0 for no cap.
 * @param count   records already emitted from this data set.
 * @param line    the record, as jesprint() hands it out: blank-trimmed, and
 *                with unprintable bytes already folded to blanks.
 * @param linelen its length.
 *
 * @return SPOOL_LINE_EMIT, SPOOL_LINE_SKIP or SPOOL_LINE_STOP.
 *
 * The cap is tested first: once it is reached the walk ends whatever the
 * record looks like. A JESJCLIN record that does not begin with '/' is then
 * skipped -- every JCL statement does, continuations (`//`), comments (`//*`)
 * and JES2 control statements (`/*`) included, and in-stream data lives in its
 * own SYSIN data set, never here. The test is deliberately positive ("this is
 * what JCLIN holds") rather than a match on the pointer record's first byte:
 * it also covers the pre-formatted "JOB DELETED BY JES2 ..." line #158 was
 * written for, which starts with a letter.
 */
int spool_line_action(int jclin, unsigned limit, unsigned count,
                      const char *line, unsigned linelen)     asm("MFSPLACT");

#endif /* SPOOLLN_H */
