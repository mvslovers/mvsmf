#ifndef JOBCARD_H
#define JOBCARD_H

#include <stddef.h>

/**
 * @file jobcard.h
 * @brief Clearing a submitted JOB card of credentials mvsMF will supply itself.
 *
 * mvsMF puts `USER=`/`PASSWORD=` on every INTRDR submit because MVS 3.8j does
 * no userid propagation: without a validated pair the job runs as the PROD
 * default rather than as the caller (see get_caller_credentials() in
 * jobsapi.c, and #164). Real z/OSMF injects nothing at all -- measured on the
 * reference 2026-09-14, a card carrying `USER=` came back out of JESJCL byte
 * for byte and the job ran under that userid, because there the submitter's
 * identity is propagated and SAF checks the card against it. That mechanism
 * does not exist here, which is why this code does.
 *
 * The injection used to run unconditionally, so a caller who wrote `USER=`
 * themselves got two of them and the job failed conversion with `IEF652I
 * MUTUALLY EXCLUSIVE KEYWORDS` (#365). The rule now is that **the
 * authenticated identity always wins**: any `USER=` or `PASSWORD=` already on
 * the card is removed before mvsMF adds its own.
 *
 * That is a deliberate deviation from the reference, and the reason is that
 * the alternative is worse here rather than merely different. Honouring a
 * card-supplied `USER=` would mean honouring it *without* propagation: the job
 * would not run as that user, it would lose the identity altogether. A rule
 * that silently downgrades who the job runs as is a poorer answer than one
 * that consistently runs it as whoever authenticated the request.
 *
 * What a caller loses is the ability to submit work under a second identity by
 * putting its credentials on the card. On this platform that was never
 * reliable anyway, and the request's own authentication is the identity mvsMF
 * can actually vouch for -- which is what the submit response reports as the
 * owner (#210) and what any future authorization on the jobs service (#345)
 * would have to key on.
 *
 * Kept free of MVS services so test/host/tstjcard.c drives the real code.
 *
 * The asm() names are not decoration: cc370 truncates external symbols to
 * eight characters, so every jobcard_* name here maps to `JOBCARD@` without
 * them and the four functions collide into one. cc370 warns about that, but a
 * duplicate external otherwise links clean and calls the wrong code.
 */

/**
 * Locate a JOB card operand, or NULL when the line does not carry it.
 *
 * A bare strstr() will not do: the keyword also occurs inside the quoted
 * programmer-name field -- `//J JOB (ACCT),'NOTIFY ME'` -- and the `=` a
 * caller then looks for belongs to some later operand, so the card reads as
 * carrying an operand it does not have. That misreading is silent in both
 * directions: it suppresses a removal that is needed, or cuts text out of the
 * programmer name.
 *
 * So the keyword must start at an operand boundary (the blank after the JOB
 * verb, a comma, or the blanks of a continuation card), sit outside quotes,
 * and be followed by `=`. Apostrophe doubling needs no special case: `''`
 * toggles the quote state twice and leaves it where it was.
 *
 * @param line     one JOB card line, NUL terminated; may be NULL.
 * @param keyword  operand name without the `=`, e.g. "USER".
 * @return pointer to the keyword within @p line, or NULL.
 */
char *jobcard_find_operand(char *line, const char *keyword)
	asm("JCRD0001");

/**
 * Remove every occurrence of one operand from a single line, in place.
 *
 * The operand goes together with one adjacent comma: the following one when
 * there is a further operand behind it, otherwise the preceding one. That is
 * what keeps the continuation structure intact -- a line that ended with a
 * comma still does, so the card still continues, and a line that did not still
 * does not.
 *
 * @return how many occurrences were removed.
 */
int jobcard_strip_operand(char *line, const char *keyword)
	asm("JCRD0002");

/**
 * True when a line carries no operands any more -- only `//` and blanks.
 *
 * Such a line is a JCL error if it is submitted, so the caller blanks it. Only
 * a continuation line can reach this state; the JOB statement itself always
 * keeps its name and verb.
 */
int jobcard_operands_empty(const char *line)
	asm("JCRD0003");

/**
 * Strip `USER=` and `PASSWORD=` from a whole JOB card.
 *
 * Continuation lines that are left carrying nothing are blanked (`""`), which
 * both submit loops already skip. The JOB statement line is never blanked.
 *
 * @param lines      the JCL lines.
 * @param start_idx  index of the JOB statement.
 * @param end_idx    index of its last continuation line.
 * @return how many operands were removed, or -1 on a bad argument.
 */
int jobcard_strip_credentials(char **lines, int start_idx, int end_idx)
	asm("JCRD0004");

#endif /* JOBCARD_H */
