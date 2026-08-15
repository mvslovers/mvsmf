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

#endif /* ABENDMSG_H */
