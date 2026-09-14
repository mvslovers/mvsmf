/*
 * jobcard.c - clearing a submitted JOB card of credentials mvsMF supplies (#365).
 *
 * See include/jobcard.h for why the injection exists and why the authenticated
 * identity always wins. Deliberately free of MVS services: jobsapi.c cannot
 * compile on the host, so this lives in its own TU and test/host/tstjcard.c
 * drives the real code.
 */

#include <stddef.h>
#include <string.h>

#include "jobcard.h"

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'jc_find_op'");
#endif
char *
jobcard_find_operand(char *line, const char *keyword)
{
	int	in_quotes	= 0;
	int	at_operand	= 1;
	char	*pp		= NULL;
	size_t	klen		= 0;

	if (!line || !keyword) {
		return NULL;
	}

	klen = strlen(keyword);
	if (klen == 0) {
		return NULL;
	}

	for (pp = line; *pp != '\0'; pp++) {
		if (*pp == '\'') {
			in_quotes = !in_quotes;
			at_operand = 0;
			continue;
		}

		if (in_quotes) {
			continue;
		}

		if (at_operand && strncmp(pp, keyword, klen) == 0) {
			const char *qq = pp + klen;

			while (*qq == ' ') {
				qq++;
			}

			if (*qq == '=') {
				return pp;
			}
		}

		at_operand = (*pp == ',' || *pp == ' ');
	}

	return NULL;
}

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'jc_strip_op'");
#endif
int
jobcard_strip_operand(char *line, const char *keyword)
{
	int	removed = 0;
	char	*op	= NULL;

	if (!line || !keyword) {
		return 0;
	}

	while ((op = jobcard_find_operand(line, keyword)) != NULL) {
		size_t	start	= (size_t)(op - line);
		size_t	end	= start;
		char	*eq	= strchr(op, '=');

		if (!eq) {
			break;      /* find_operand guarantees one; belt and braces */
		}

		/* The value runs to the first comma or blank: JCL has no quoting
		   inside these operands, and neither a userid nor a password can
		   contain either. */
		end = (size_t)(eq - line) + 1;
		while (line[end] != '\0' && line[end] != ',' && line[end] != ' ') {
			end++;
		}

		if (line[end] == ',') {
			/* another operand follows: take its separator with it, so the
			   one in front of this operand keeps separating */
			end++;
		} else if (start > 0 && line[start - 1] == ',') {
			/* last in the operand field: take the separator in front, so the
			   field does not end on a comma that now leads nowhere */
			start--;
		}

		memmove(line + start, line + end, strlen(line + end) + 1);
		removed++;
	}

	return removed;
}

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'jc_ops_empty'");
#endif
int
jobcard_operands_empty(const char *line)
{
	const char *pp = line;

	if (!line) {
		return 1;
	}

	if (pp[0] == '/' && pp[1] == '/') {
		pp += 2;
	}

	while (*pp == ' ') {
		pp++;
	}

	return (*pp == '\0');
}

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'jc_strip_cred'");
#endif
int
jobcard_strip_credentials(char **lines, int start_idx, int end_idx)
{
	int	ii	= 0;
	int	removed	= 0;

	if (!lines || start_idx < 0 || end_idx < start_idx) {
		return -1;
	}

	/* The operands may sit on any line of the card, including a continuation,
	   so the whole card is walked rather than only the JOB statement. */
	for (ii = start_idx; ii <= end_idx; ii++) {
		if (!lines[ii]) {
			continue;
		}

		removed += jobcard_strip_operand(lines[ii], "USER");
		removed += jobcard_strip_operand(lines[ii], "PASSWORD");

		/* A continuation left with nothing on it is a JCL error if it is
		   submitted. Blank it; both submit loops skip empty lines. The line
		   before it still ends with the comma that made this one a
		   continuation, so the card still continues -- onto the next line it
		   has, or onto the one mvsMF is about to add. */
		if (ii > start_idx && jobcard_operands_empty(lines[ii])) {
			lines[ii][0] = '\0';
		}
	}

	return removed;
}
