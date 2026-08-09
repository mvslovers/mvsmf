#ifndef JCLINES_H
#define JCLINES_H

/**
 * @file jclines.h
 * @brief Growth of the JCL line table used by the job-submission paths.
 *
 * The submit paths in jobsapi.c hold a JCL deck as two allocations:
 *
 *   - `lines_buf` — one contiguous block of `capacity` fixed 81-byte slots
 *     (an 80-byte card image plus its NUL terminator), and
 *   - `lines` — an array of `capacity` pointers, where `lines[i]` always
 *     addresses `lines_buf + i * 81`.
 *
 * The pair is a single logical object: the pointer array is only meaningful
 * while every entry addresses the live buffer at the recorded capacity.
 * grow_lines_arrays() is the only place that resizes it, and it is therefore
 * the only place that can tear it apart.
 *
 * See issue #220.
 */

/**
 * Grow the line table so it holds at least `required` lines.
 *
 * On success returns 0 with all three out-params updated in step.
 *
 * On failure returns -1 leaving the caller's view of the table exactly as it
 * was: `*capacity_p` and `*lines_buf_p` are untouched, and entries
 * [0, *capacity_p) of `*lines_p` still address that same live buffer. The
 * caller may keep using the table at its old capacity, and frees `*lines_p`
 * and `*lines_buf_p` as usual. (`*lines_p` may have been replaced by a larger
 * -- harmlessly over-allocated -- array; see the ordering note in jclines.c.)
 *
 * A no-op returning 0 when `required` already fits.
 */
int grow_lines_arrays(char ***lines_p, char **lines_buf_p,
                      int *capacity_p, int required)          asm("MFJCLGRW");

#endif /* JCLINES_H */
