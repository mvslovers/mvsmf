#ifndef NTSTORE_H
#define NTSTORE_H

/**
 * @file ntstore.h
 * @brief Persistent name-keyed key/value store for mvsMF.
 *
 * A "dumb" store: it only knows name -> opaque bytes. All cursor/value
 * semantics live in the caller's value blob; the store never interprets it.
 * One __getm block of fixed slots, linear search, per-op latch, TTL/LRU via a
 * store-internal last-access TOD. RENT-safe (no writable static; the block is
 * GETMAINed and anchored in MVSMF_CTX).
 *
 * See doc/endpoints/restconsoles-issue-command.md and issue #143.
 */

#define MVSMF_KVS_EYE     "MVSMFKVS"     /* 8 bytes                              */
#define MVSMF_KVS_SLOTS   32
#define MVSMF_KVS_NAMELEN 16
#define MVSMF_KVS_VALMAX  192            /* covers SOL_CURSOR (~140 B) + reserve */

typedef struct nt_slot {
    char                name[MVSMF_KVS_NAMELEN]; /* opaque key; all-zero = free  */
    unsigned long long  last_access;             /* STCK TOD; drives TTL + LRU   */
    unsigned short      val_len;                 /* bytes used in value          */
    unsigned char       value[MVSMF_KVS_VALMAX]; /* opaque (store never reads)   */
} NT_SLOT;

typedef struct nt_store {
    char                eye[8];          /* "MVSMFKVS"                           */
    unsigned short      len;             /* sizeof(NT_STORE)                     */
    unsigned short      ver;             /* layout version                       */
    unsigned            nslots;          /* MVSMF_KVS_SLOTS                      */
    NT_SLOT             slot[MVSMF_KVS_SLOTS];
} NT_STORE;                              /* ~7 KB; one __getm block              */

/** Stamp a freshly GETMAINed store block (eye/len/ver/nslots, slots zeroed). */
void nt_store_init(NT_STORE *s)                                         asm("MFNTINI");

/** Upsert name -> value (len clamped to MVSMF_KVS_VALMAX). Returns 0. */
int nt_set(NT_STORE *s, const char *name, const void *val, unsigned len) asm("MFNTSET");

/** Retrieve value for name. 0 + copies min(val_len,max) into buf (out_len set,
 *  last_access touched); 4 on miss (also for an expired entry). */
int nt_get(NT_STORE *s, const char *name, void *buf, unsigned max,
           unsigned *out_len)                                          asm("MFNTGET");

/** Delete name. 0 if deleted, 4 if not found. */
int nt_del(NT_STORE *s, const char *name)                              asm("MFNTDEL");

#endif /* NTSTORE_H */
