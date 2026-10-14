#ifndef ABENDMSG_H
#define ABENDMSG_H

#include <stddef.h>

/**
 * @file abendmsg.h
 * @brief The client-visible message for a handler abend.
 *
 * When a handler abends, the router's ESTAE recovery closes what the handler
 * left open and answers 500. The abend code itself used to stay behind on the
 * console, so the client read only "Internal server error (abend recovery)" --
 * a data set that ran out of space and a protection exception were the same
 * sentence, and telling them apart cost a console round trip every time
 * (issue #256).
 *
 * The message carries the code, and the x37 family is named outright because
 * that is what a write into a full data set produces and what the caller can
 * actually act on:
 *
 *   SB37  out of space on the volume
 *   SD37  primary extent full, no secondary allocation
 *   SE37  extent limit reached
 *
 * The status stays 500 (in the z/OSMF list for the files API) and the error
 * report keeps its shape -- only the `message` field changes.
 *
 * This lives in its own translation unit so test/host/tstabnd.c can drive the
 * real function: router.c cannot compile on the host (clibwto, clibtry, the
 * httpd callback table).
 */

/** Buffer size for abend_message(); holds the longest text (SD37) plus NUL. */
#define ABEND_MSG_SIZE	96

/**
 * Format the message for a handler abend into `buf`.
 *
 * @param buf   destination, at least ABEND_MSG_SIZE bytes. Must be writable
 *              storage -- MVSMF is link-edited RENT, and this runs in the
 *              recovery path, where a second abend would be unrecoverable.
 * @param size  size of `buf`; the text is truncated to fit.
 * @param sys   system completion code, 0 for a user abend.
 * @param usr   user completion code, used only when `sys` is 0.
 */
void abend_message(char *buf, size_t size, unsigned sys, unsigned usr);

/**
 * The `details[]` sentence for an abend that is an authorization denial, or
 * NULL when this abend is something else (issue #315).
 *
 * S913 means insufficient authority to open, and that is the whole test. Do
 * NOT widen it to the rest of the IEC1xx family: `SYS1.STGINDEX` produces
 * `IEC143I 213-04` / S213, which is "cannot be opened sequentially" -- a
 * different condition that must keep the generic abend body.
 *
 * The text ends with the abend, unlike the sentence a pre-check produces
 * (`ERR_MSG_DENIED_DETAIL` in common.h). That difference is deliberate and is
 * the only one: here OPEN refused and the task really did abend, so saying so
 * matches both the truth and the reference, whose own text reads
 * "... Open 913 abend."  A pre-check refuses before any open and must not
 * claim it.
 *
 * Returns a string literal -- no buffer, nothing writable. MVSMF is RENT and
 * this runs in the recovery path.
 *
 * @param sys   system completion code, 0 for a user abend.
 */
const char *abend_denial_detail(unsigned sys);

/**
 * Where the failing instruction starts, from the PSW a caught abend left
 * behind (libc370 tryinfo(), issue #425).
 *
 * For a program check the PSW address is normally the instruction *after*
 * the one that failed; the ILC (bits 32-33 of a BC-mode PSW, in halfwords)
 * says how far back that one starts. For an SVC 13 abend it is the SVC itself.
 * Two interruption codes are the exception: segment translation (0010) and
 * page translation (0011) *nullify* the instruction, so the PSW still points
 * AT it and nothing is subtracted -- the S0C4-10/-11 of a reference to storage
 * that is not allocated. That rule is the architecture's, from the
 * Principles of Operation, and has not been measured here. An ILC of 0 leaves
 * the address as it is.
 *
 * @param psw   the BC-mode PSW, two words as tryinfo() returns them.
 * @return      the 24-bit address of the failing instruction.
 */
unsigned abend_instr_addr(const unsigned psw[2]);

/**
 * The signed distance of a 24-bit address from the module's entry point.
 *
 * What MVSMF901E's companion message reports, because the entry point is the
 * one address both the running module and its link map know: `file370 -v`
 * prints it as `entry=`, so a listed offset is entry + this value.
 *
 * @param addr  any address; the high byte is ignored.
 * @param ep    the entry point; the high byte is ignored.
 */
long abend_ep_offset(unsigned addr, unsigned ep);

#endif /* ABENDMSG_H */
