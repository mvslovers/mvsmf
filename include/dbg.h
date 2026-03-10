#ifndef DBG_H
#define DBG_H

extern int dbgw(const char *buf, int len);
extern int dbgs(const char *str);
extern int dbgf(const char *fmt, ...);
extern int dbgdump(void *buf, int len, const char *fmt, ...);
extern int dbgenter(const char *fmt, ...);
extern int dbgexit(const char *fmt, ...);
extern int dbgtime(const char *sep);

#endif
