# mvsMF USS/UFS Feature Pack — Specification & Implementation Plan

**Version:** 1.1  
**Date:** 2026-03-16  
**Status:** REVIEWED — Technische Entscheidungen geklärt, implementierungsbereit  
**Scope:** Integration der UFSD/libufs-APIs in mvsMF als z/OSMF-kompatible REST Endpoints

---

## 1. Executive Summary

Mit dem funktionierenden UFSD PoC (Unix File System Daemon) steht erstmals eine USS-ähnliche
Filesystem-Schicht für MVS 3.8j zur Verfügung. Dieses Feature Pack integriert die libufs-API
über neue REST-Endpoints in mvsMF, die z/OSMF-kompatibel sind und damit direkt von Zowe CLI
und Zowe Explorer genutzt werden können.

**Ziel:** 11 neue z/OSMF REST Endpoints für Unix-File-Operationen, aufgeteilt in 4 Phasen.

---

## 2. Ist-Zustand

### 2.1 mvsMF — Aktuelle Endpoints (Stand: main branch)

| # | Method | Route | Handler | Modul |
|---|--------|-------|---------|-------|
| 1 | GET | `/zosmf/info` | infoHandler | infoapi.c |
| 2 | GET | `/zosmf/test` | testHandler | testapi.c |
| 3 | GET | `/zosmf/restjobs/jobs` | jobListHandler | jobsapi.c |
| 4 | GET | `/zosmf/restjobs/jobs/{job-name}/{jobid}/files` | jobFilesHandler | jobsapi.c |
| 5 | GET | `/zosmf/restjobs/jobs/{job-name}/{jobid}/files/{ddid}/records` | jobRecordsHandler | jobsapi.c |
| 6 | PUT | `/zosmf/restjobs/jobs` | jobSubmitHandler | jobsapi.c |
| 7 | GET | `/zosmf/restjobs/jobs/{job-name}/{jobid}` | jobStatusHandler | jobsapi.c |
| 8 | DELETE | `/zosmf/restjobs/jobs/{job-name}/{jobid}` | jobPurgeHandler | jobsapi.c |
| 9 | GET | `/zosmf/restfiles/ds` | datasetListHandler | dsapi.c |
| 10 | GET | `/zosmf/restfiles/ds/{dataset-name}` | datasetGetHandler | dsapi.c |
| 11 | GET | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}` | datasetGetHandler | dsapi.c |
| 12 | PUT | `/zosmf/restfiles/ds/{dataset-name}` | datasetPutHandler | dsapi.c |
| 13 | PUT | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}` | datasetPutHandler | dsapi.c |
| 14 | POST | `/zosmf/restfiles/ds/{dataset-name}` | datasetCreateHandler | dsapi.c |
| 15 | DELETE | `/zosmf/restfiles/ds/{dataset-name}` | datasetDeleteHandler | dsapi.c |
| 16 | DELETE | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}` | datasetDeleteHandler | dsapi.c |
| 17 | GET | `/zosmf/restfiles/ds/{dataset-name}/member` | memberListHandler | dsapi.c |
| 18 | GET | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}/member` | memberListHandler | dsapi.c |
| 19 | GET | `/zosmf/restfiles/ds/{dataset-name}({member-name})` | memberGetHandler | dsapi.c |
| 20 | GET | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}({member-name})` | memberGetHandler | dsapi.c |
| 21 | PUT | `/zosmf/restfiles/ds/{dataset-name}({member-name})` | memberPutHandler | dsapi.c |
| 22 | PUT | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}({member-name})` | memberPutHandler | dsapi.c |
| 23 | DELETE | `/zosmf/restfiles/ds/{dataset-name}({member-name})` | memberDeleteHandler | dsapi.c |
| 24 | DELETE | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}({member-name})` | memberDeleteHandler | dsapi.c |

**Gesamt:** 24 Routen (davon 2 Utility, 6 Jobs, 16 Datasets)

> Snapshot as of USS Phase 1 planning, kept as written. Rows 11, 13, 16,
> 18, 20, 22 and 24 — the seven `-({volume-serial})` routes — were
> withdrawn in #336 and are no longer registered.

### 2.2 libufs — Verfügbare API-Funktionen (aus libufs.h)

| Kategorie | Funktion | Beschreibung |
|-----------|----------|-------------|
| **Session** | `ufsnew()` / `ufsfree()` | Session anlegen/freigeben |
| **Auth** | `ufs_signon()` / `ufs_signoff()` | Phase-1 Stubs (kein RACF) |
| **Accessors** | `ufs_get/set_acee()`, `ufs_get/set_cwd()`, `ufs_get/set_create_perm()` | Handle-Konfiguration |
| **Directories** | `ufs_chgdir()`, `ufs_mkdir()`, `ufs_rmdir()`, `ufs_remove()` | Verzeichnis-Ops |
| **Dir Listing** | `ufs_diropen()`, `ufs_dirread()`, `ufs_dirclose()` | Verzeichnis auflisten |
| **File I/O** | `ufs_fopen()`, `ufs_fclose()`, `ufs_fsync()`, `ufs_sync()` | Datei öffnen/schließen |
| **Bulk I/O** | `ufs_fread()`, `ufs_fwrite()` | Block-I/O (chunked > 248 Bytes) |
| **Char I/O** | `ufs_fgets()`, `ufs_fputc()`, `ufs_fputs()`, `ufs_fgetc()` | Zeilen/Zeichen-I/O |
| **Seek/Status** | `ufs_fseek()`, `ufs_feof()`, `ufs_ferror()`, `ufs_clearerr()` | Positionierung |

**Nicht in libufs vorhanden (relevant für Gap-Analyse):**
- `chmod`, `chown`, `chtag` — keine API-Funktionen
- `stat()` / `lstat()` — kein separater stat-Aufruf (nur über `UFSDLIST` aus `ufs_dirread`)
- `ufs_rename()` / `ufs_move()` — kein Rename/Move
- Filesystem create/delete/mount/unmount — kein VSAM/Aggregate-Management
- Symlink-Operationen — keine Symlink-API
- ACL-Operationen (getfacl/setfacl) — keine ACL-API

---

## 3. z/OSMF USS API → libufs Gap-Analyse

### 3.1 Mapping-Matrix

| # | z/OSMF Endpoint | HTTP | libufs Coverage | Prio |
|---|----------------|------|-----------------|------|
| **A** | **List files/dirs** `GET /zosmf/restfiles/fs?path=` | GET | ✅ `ufs_diropen/dirread/dirclose` — `UFSDLIST` liefert name, attr, owner, group, size, mtime, inode, nlink | **P1** |
| **B** | **Read file** `GET /zosmf/restfiles/fs/<path>` | GET | ✅ `ufs_fopen("r")` + `ufs_fread` — text & binary möglich | **P1** |
| **C** | **Write file** `PUT /zosmf/restfiles/fs/<path>` | PUT | ✅ `ufs_fopen("w")` + `ufs_fwrite` — create-if-not-exists implizit | **P1** |
| **D** | **Create file/dir** `POST /zosmf/restfiles/fs/<path>` | POST | ⚠️ **Partiell** — `ufs_mkdir()` für dirs ✅, Files via `ufs_fopen("w")` + sofort close ✅, aber `ufs_set_create_perm()` nur globaler Default, kein per-file mode | **P1** |
| **E** | **Delete file/dir** `DELETE /zosmf/restfiles/fs/<path>` | DELETE | ⚠️ **Partiell** — `ufs_remove()` für files ✅, `ufs_rmdir()` für leere dirs ✅, **kein rekursives Löschen** (X-IBM-Option: recursive) | **P2** |
| **F** | **File utilities** `PUT /zosmf/restfiles/fs/<path>` (JSON body) | PUT | ❌ **chmod/chown/chtag/copy/move/rename** — keine libufs-Funktionen | **P3** |
| **G** | **List filesystems** `GET /zosmf/restfiles/mfs/` | GET | ❌ Kein Filesystem-Registry in UFSD | **P4** |
| **H** | **Create ZFS** `POST /zosmf/restfiles/mfs/zfs/<name>` | POST | ❌ VSAM/Aggregate-Management nicht in libufs | **P4** |
| **I** | **Delete ZFS** `DELETE /zosmf/restfiles/mfs/zfs/<name>` | DELETE | ❌ Siehe oben | **P4** |
| **J** | **Mount FS** `PUT /zosmf/restfiles/mfs/<name>` (action:mount) | PUT | ❌ Kein Mount-Interface in libufs | **P4** |
| **K** | **Unmount FS** `PUT /zosmf/restfiles/mfs/<name>` (action:unmount) | PUT | ❌ Kein Unmount-Interface in libufs | **P4** |

### 3.2 Gap-Zusammenfassung

**Sofort umsetzbar (libufs reicht):** Endpoints A, B, C, D (mit Einschränkungen)

**libufs-Erweiterung nötig:**
- Endpoint E: rekursives Löschen → `ufs_rmdir_r()` o.ä. oder Implementierung im Handler
- Endpoint F: chmod/chown/chtag/copy/move → neue libufs-Funktionen oder UFSD-SSI-Requests

**Nicht umsetzbar ohne UFSD-Kernänderungen:** Endpoints G–K (Filesystem-Management)

---

## 4. Architektur-Konzept

### 4.1 Neue Dateien

```
mvsmf/
├── include/
│   └── ussapi.h          ← NEU: Handler-Deklarationen + UFS-Session-Management
├── src/
│   └── ussapi.c          ← NEU: USS REST API Handler-Implementierung
├── doc/endpoints/
│   └── uss/              ← NEU: Endpoint-Dokumentation
│       ├── list.md
│       ├── read.md
│       ├── write.md
│       ├── create.md
│       └── delete.md
├── project.toml          ← EDIT: libufs als MBT-Dependency hinzufügen
└── tests/
    ├── curl-uss.sh       ← NEU: USS curl-Tests
    └── zowe-uss.sh       ← NEU: USS Zowe CLI-Tests
```

### 4.2 Dependency: libufs via MBT (MVS Build Tool)

Die libufs wird über MBT als Dependency gezogen — analog zu anderen Libraries im 
mvslovers-Ökosystem. MBT kümmert sich um Fetch, Build und Linkage.

**project.toml Erweiterung** (Beispiel — exaktes Format nach MBT-Konventionen):
```toml
[dependencies]
libufs = { repo = "mvslovers/ufsd", path = "lib" }
```

**Include-Path:** MBT stellt sicher, dass `#include "libufs.h"` auflöst.
**Link:** MBT linkt `libufs.a` automatisch in das mvsMF Load Module.

### 4.3 Kritisches Architektur-Thema: Router-Erweiterung für /fs/-Pfade

**Problem:** Der aktuelle Router-Pattern-Matcher (`is_pattern_match` in router.c) verwendet `{variable}` Platzhalter, die bei `/`, `(`, `)` stoppen. Ein USS-Pfad wie `/zosmf/restfiles/fs/u/user/dir/file.txt` enthält aber nach `/fs/` mehrere `/`-Segmente.

Ein Pattern wie `GET /zosmf/restfiles/fs/{filepath}` würde nur `/zosmf/restfiles/fs/u` matchen — der Rest geht verloren.

**Lösung — Drei Optionen:**

| Option | Beschreibung | Aufwand | Empfehlung |
|--------|-------------|---------|------------|
| **1. Wildcard-Pattern `{*filepath}`** | Neuer Pattern-Typ: `{*var}` konsumiert den gesamten Rest des Pfads inkl. `/` | Mittel | ✅ **Empfohlen** — sauberste Lösung |
| **2. Query-Parameter statt Pfad** | Nur für List: `GET /zosmf/restfiles/fs?path=/u/user/dir` (z/OSMF-konform für List) | Niedrig | ⚠️ Funktioniert nur für List, nicht für Read/Write/Delete |
| **3. Handler liest REQUEST_PATH direkt** | Handler parst den Pfad selbst, Route matcht nur Prefix `/zosmf/restfiles/fs` | Niedrig | ⚠️ Umgeht Router-Abstraktion |

**Empfohlene Kombination:**
- **List (Endpoint A)** nutzt den Query-Parameter `?path=` (z/OSMF-konform, kein Router-Umbau)
- **Read/Write/Create/Delete (Endpoints B–E)** brauchen `{*filepath}` im Router

**Router-Änderung für `{*filepath}`:**

```c
/* In is_pattern_match(): */
if (*pattern == '{') {
    int is_wildcard = (*(pattern + 1) == '*');  /* check for {*...} */
    if (is_wildcard) pattern++;  /* skip the '*' */
    
    while (*pattern && *pattern != '}') pattern++;
    if (*pattern == '}') pattern++;

    if (is_wildcard) {
        /* consume everything remaining in path */
        while (*path) path++;
    } else {
        /* existing behavior: stop at / ( ) */
        while (*path && *path != '/' && *path != '(' && *path != ')') path++;
    }
}

/* In extract_path_vars(): analog anpassen */
```

### 4.4 UFS-Session-Management

**Verhalten:** `ufsnew()` ruft intern IEFSSREQ (SVC 34) auf. Wenn UFSD STC nicht läuft → SVC 34 Fehler-RC → `ufsnew()` gibt `NULL` zurück. **Kein ABEND, kein Timeout.**

Jede CGI-Instanz bekommt ihr eigenes UFS-Handle. Kein globales Handle teilen — `ufs_chgdir()` und `ufs_set_create_perm()` sind per-Handle State.

**Pattern:**

```c
static int uss_with_session(Session *session, 
                            int (*action)(Session *, UFS *)) 
{
    UFS *ufs = ufsnew();
    if (!ufs) {
        return sendErrorResponse(session, 503, 1, 8, 1,
            "UFSD subsystem not available", NULL, 0);
    }
    
    /* Pass RACF ACEE for future auth support (Phase 1: ignored by UFSD) */
    if (session->acee) {
        ufs_set_acee(ufs, session->acee);
    }
    
    int rc = action(session, ufs);
    
    ufsfree(&ufs);  /* ALWAYS cleanup, even on error paths */
    return rc;
}
```

### 4.5 Route-Registrierung in mvsmf.c

```c
#include "ussapi.h"

/* USS File Operations — Phase 1 */
add_route(&router, GET,    "/zosmf/restfiles/fs",           ussListHandler);
add_route(&router, GET,    "/zosmf/restfiles/fs/{*filepath}", ussGetHandler);
add_route(&router, PUT,    "/zosmf/restfiles/fs/{*filepath}", ussPutHandler);
add_route(&router, POST,   "/zosmf/restfiles/fs/{*filepath}", ussCreateHandler);
add_route(&router, DELETE, "/zosmf/restfiles/fs/{*filepath}", ussDeleteHandler);

/* USS Filesystem Management — Phase 4 (Zukunft) */
add_route(&router, GET,    "/zosmf/restfiles/mfs/",            mfsListHandler);
add_route(&router, POST,   "/zosmf/restfiles/mfs/zfs/{*fsname}", mfsCreateHandler);
add_route(&router, DELETE, "/zosmf/restfiles/mfs/zfs/{*fsname}", mfsDeleteHandler);
add_route(&router, PUT,    "/zosmf/restfiles/mfs/{*fsname}",    mfsMountUnmountHandler);
```

---

## 5. Endpoint-Spezifikationen (Phase 1)

### 5.1 Endpoint A: List Files & Directories

**z/OSMF:** `GET /zosmf/restfiles/fs?path=<filepath-name>`

**Route:** `GET /zosmf/restfiles/fs` (Query-Parameter `path` — kein Router-Änderung nötig)

**Request:**
- Query-Param `path` (required): UNIX-Verzeichnispfad
- Header `X-IBM-Max-Items` (optional): Max Einträge (default 1000, 0 = alle)

**libufs-Mapping:**
```
ufs_diropen(ufs, path, NULL)  → UFSDDESC *
ufs_dirread(ddesc)            → UFSDLIST * (pro Entry)
ufs_dirclose(&ddesc)
```

**Response (HTTP 200, application/json):**
```json
{
  "items": [
    {
      "name": "file.txt",
      "mode": "-rwxr-xr-x",
      "size": 1234,
      "uid": 0,
      "user": "IBMUSER",
      "gid": 0,
      "group": "SYS1",
      "mtime": "2026-03-15T10:30:00"
    }
  ],
  "returnedRows": 5,
  "totalRows": 5,
  "JSONversion": 1
}
```

**UFSDLIST → JSON Mapping:**

| UFSDLIST Feld | JSON Feld | Transformation |
|---------------|-----------|---------------|
| `name[60]` | `name` | Direkt |
| `attr[11]` | `mode` | Direkt (schon "drwxrwxrwx" Format) |
| `filesize` | `size` | Direkt (unsigned → JSON number) |
| `owner[9]` | `user` | Direkt |
| `group[9]` | `group` | Direkt |
| `nlink` | `links` | Direkt |
| `mtime` | `mtime` | mtime64_t → ISO 8601 String |
| `inode_number` | `inode` | Direkt |

**Nicht unterstützte z/OSMF Filter-Parameter (Phase 1):**
- `name`, `type`, `size`, `mtime`, `perm`, `user`, `group` — Filter im Handler implementierbar
- `depth`, `filesys`, `symlinks` — rekursive Traversierung nicht in Phase 1
- `X-IBM-Lstat` — kein separater lstat() in libufs

**Aufwand:** MITTEL — Hauptlogik einfach, JSON-Aufbau mit `UFSDLIST`-Feldern, mtime-Konvertierung

---

### 5.2 Endpoint B: Read File Content

**z/OSMF:** `GET /zosmf/restfiles/fs/<filepath-name>`

**Route:** `GET /zosmf/restfiles/fs/{*filepath}`

**Request:**
- Path: vollqualifizierter UNIX-Pfad
- Header `X-IBM-Data-Type` (optional): `text` (default) oder `binary`
- Header `X-IBM-Record-Range` (optional): `SSS-EEE` oder `SSS,NNN`
- Header `Range` (optional, nur bei binary): `bytes=start-end`

**libufs-Mapping:**
```
ufs_fopen(ufs, filepath, "r")  → UFSFILE *
ufs_fread(buf, 1, size, fp)    → bytes gelesen
ufs_fclose(&fp)
```

**Text-Modus:** EBCDIC→ASCII Konvertierung via `mvsmf_etoa()` nach jedem `ufs_fread()` Chunk. Dateien im UFSD sind per Konvention in EBCDIC gespeichert. Die REST-API liefert UTF-8/ASCII.
**Binary-Modus:** Raw bytes, keine Konvertierung. Content-Type: application/octet-stream

**Maximale Dateigröße:** 64 KB (UFSD Phase 1). Bei darüberliegenden Dateien bricht `ufs_fread` nach den letzten Direct Blocks ab.

**Response-Headers:**
- `ETag` — für conditional GET (Zukunft, Phase 1: optional)
- `Content-Type: text/plain; charset=UTF-8` (text) oder `application/octet-stream` (binary)
- `Content-Length`

**Aufwand:** MITTEL — Analog zu `datasetGetHandler`, aber mit ufs_fread statt fread

---

### 5.3 Endpoint C: Write File Content

**z/OSMF:** `PUT /zosmf/restfiles/fs/<filepath-name>`

**Route:** `PUT /zosmf/restfiles/fs/{*filepath}`

**Request:**
- Path: vollqualifizierter UNIX-Pfad
- Body: Dateiinhalt
- Header `X-IBM-Data-Type`: `text` (default) oder `binary`
- Header `If-Match` (optional): ETag für optimistic locking
- Header `Content-Type`

**libufs-Mapping:**
```
ufs_fopen(ufs, filepath, "w")   → UFSFILE * (create-if-not-exists)
ufs_fwrite(data, 1, len, fp)    → bytes geschrieben
ufs_fclose(&fp)
```

**Text-Modus:** ASCII→EBCDIC Konvertierung via `mvsmf_atoe()` **vor** `ufs_fwrite()`. LF-Handling: REST-API liefert LF-terminated Lines, die als-is geschrieben werden.
**Binary-Modus:** Raw bytes direkt, keine Konvertierung

**Maximale Dateigröße:** 64 KB. Schreiben über 64 KB → UFSD_RC_NOSPACE (44) → HTTP 507.

**Response:**
- HTTP 201 Created (neue Datei)
- HTTP 204 No Content (bestehende Datei überschrieben)

**Aufwand:** MITTEL — Analog zu `datasetPutHandler`, HTTP body via `receive_raw_data()` (ACHTUNG: off-limits Funktion, nur nutzen, nicht ändern!)

---

### 5.4 Endpoint D: Create File or Directory

**z/OSMF:** `POST /zosmf/restfiles/fs/<file-path>`

**Route:** `POST /zosmf/restfiles/fs/{*filepath}`

**Request Body (JSON):**
```json
{
  "type": "file",        // "file" oder "directory"/"dir"
  "mode": "rwxr-xr-x"   // Permission string (optional)
}
```

**libufs-Mapping:**

| type | libufs-Aufruf | Anmerkung |
|------|--------------|-----------|
| `directory` / `dir` | `ufs_mkdir(ufs, path)` | Permission via `ufs_set_create_perm()` vorher setzen |
| `file` | `ufs_fopen(ufs, path, "w")` + `ufs_fclose()` | Leere Datei erzeugen |

**Permission-Handling:**
- `mode`-String parsen ("rwxr-xr-x" → Oktalwert)
- `ufs_set_create_perm(ufs, octal_mode)` VOR dem mkdir/fopen aufrufen
- Nach Aufruf wieder auf Default (0755) zurücksetzen

**Response:** HTTP 201 Created

**Aufwand:** NIEDRIG — Einfachster Handler, hauptsächlich JSON-Parsing und Mode-Konvertierung

---

### 5.5 Endpoint E: Delete File or Directory

**z/OSMF:** `DELETE /zosmf/restfiles/fs/<file-pathname>`

**Route:** `DELETE /zosmf/restfiles/fs/{*filepath}`

**Request:**
- Path: Datei oder Verzeichnis
- Header `X-IBM-Option`: `recursive` (optional) — rekursives Löschen

**libufs-Mapping:**

| Ziel | X-IBM-Option | libufs-Aufruf | Fehlerfall |
|------|-------------|--------------|------------|
| Datei | — | `ufs_remove(ufs, path)` | UFSD_RC_NOFILE(28)→404 |
| Leeres Dir | — | `ufs_rmdir(ufs, path)` | UFSD_RC_NOTEMPTY(60)→409 |
| Dir mit Inhalt | `recursive` | Handler-Implementierung (s.u.) | — |

**Delete-Strategie im Handler:**
```c
int ussDeleteHandler(Session *session, UFS *ufs) {
    char *filepath = getPathParam(session, "filepath");
    char *option = getHeaderParam(session, "X-IBM-Option");
    int is_recursive = (option && strcmp(option, "recursive") == 0);
    
    /* Try file delete first */
    int rc = ufs_remove(ufs, filepath);
    if (rc == 0) return send_204(session);
    
    if (rc == 40) {  /* UFSD_RC_ISDIR — it's a directory */
        if (is_recursive) {
            rc = recursive_delete(ufs, filepath);
        } else {
            rc = ufs_rmdir(ufs, filepath);  /* fails with 60 if not empty */
        }
        if (rc == 0) return send_204(session);
    }
    
    return sendErrorResponse(session, ufsd_rc_to_http(rc), 
        ufsd_rc_to_category(rc), rc, rc, 
        ufsd_rc_message(rc), NULL, 0);
}
```
```c
static int recursive_delete(UFS *ufs, const char *path) {
    UFSDDESC *dd = ufs_diropen(ufs, path, NULL);
    if (!dd) return -1;
    
    UFSDLIST *entry;
    while ((entry = ufs_dirread(dd)) != NULL) {
        if (strcmp(entry->name, ".") == 0 || 
            strcmp(entry->name, "..") == 0) continue;
        
        char fullpath[UFS_PATH_MAX];
        snprintf(fullpath, sizeof(fullpath), "%s/%s", path, entry->name);
        
        if (entry->attr[0] == 'd') {
            recursive_delete(ufs, fullpath);  /* recurse */
        } else {
            ufs_remove(ufs, fullpath);
        }
    }
    ufs_dirclose(&dd);
    return ufs_rmdir(ufs, path);
}
```

**Response:** HTTP 204 No Content

**Aufwand:** MITTEL — Einfach für Dateien, rekursives Dir-Delete benötigt sorgfältige Implementierung

---

## 6. Endpoint-Spezifikationen (Phase 2 — erfordert libufs-Erweiterung)

### 6.1 Endpoint F: File Utilities (chmod, chown, copy, move)

**z/OSMF:** `PUT /zosmf/restfiles/fs/<path>` mit JSON body `{"request":"chmod|chown|copy|move|chtag"}`

**Problem:** Keine dieser Operationen existiert in libufs. Die Unterscheidung zu normalem Write (Endpoint C) erfolgt über `Content-Type: application/json` im Request.

**Benötigte libufs/UFSD-Erweiterungen:**

| Operation | Neuer UFSD SSI Request | libufs Funktion | Aufwand |
|-----------|----------------------|-----------------|---------|
| chmod | `UFSREQ_CHMOD` | `ufs_chmod(ufs, path, mode)` | Mittel |
| chown | `UFSREQ_CHOWN` | `ufs_chown(ufs, path, uid, gid)` | Mittel |
| copy | Kein neuer SSI — Handler-Level mit fread/fwrite | `ufs_copy()` oder Handler-Code | Niedrig–Mittel |
| move | `UFSREQ_RENAME` | `ufs_rename(ufs, old, new)` | Mittel |
| chtag | N/A (MVS 3.8j hat kein Tagging) | Stub / 501 Not Implemented | — |
| extattr | N/A | Stub / 501 | — |
| getfacl/setfacl | N/A (kein ACL in UFSD) | Stub / 501 | — |

**Handler-Dispatch im ussPutHandler:**
```c
int ussPutHandler(Session *session) {
    char *content_type = getHeaderParam(session, "Content-Type");
    
    if (content_type && strstr(content_type, "application/json")) {
        /* Utility-Operation (chmod, chown, copy, move) */
        return ussUtilitiesHandler(session);
    } else {
        /* Normal write operation */
        return ussWriteHandler(session);
    }
}
```

**Empfehlung:** Phase 2 nur mit copy (Handler-Level) und chmod starten. Move und chown erfordern UFSD-Änderungen.

---

## 7. Endpoint-Spezifikationen (Phase 3+4 — Filesystem Management)

### 7.1 Endpoints G–K: List/Create/Delete/Mount/Unmount Filesystems

Diese Endpoints betreffen `/zosmf/restfiles/mfs/` und erfordern fundamentale UFSD-Kernänderungen:

| Endpoint | Was fehlt | Aufwand |
|----------|----------|---------|
| **G: List FS** `GET /mfs/` | UFSD-internes Filesystem-Registry, VSAM-Aggregate-Info | HOCH |
| **H: Create ZFS** `POST /mfs/zfs/<name>` | VSAM Linear Dataset anlegen, Format-Routine | SEHR HOCH |
| **I: Delete ZFS** `DELETE /mfs/zfs/<name>` | IDCAMS DELETE, Unmount-Check | HOCH |
| **J: Mount** `PUT /mfs/<name>` (action:mount) | UFSD Mount-Interface, BPXPRMxx-Äquivalent | HOCH |
| **K: Unmount** `PUT /mfs/<name>` (action:unmount) | UFSD Unmount-Interface | MITTEL |

**Empfehlung:** Phase 4 — nur nach Stabilisierung von Phase 1–2. Diese Endpoints sind für Zowe CLI-Kompatibilität nicht zwingend erforderlich (Zowe verwendet primär die File-Endpoints, nicht die MFS-Endpoints).

---

## 8. Implementierungsplan

### Phase 1: Full CRUD File Operations (MVP)

**Ziel:** Zowe CLI `zowe files` USS-Befehle funktionieren vollständig gegen mvsMF

**Scope:** Endpoints A–E (List, Read, Write, Create, Delete)

| # | Task | Modul | Abhängigkeit | Aufwand |
|---|------|-------|-------------|---------|
| 1.1 | Router: `{*var}` Wildcard-Pattern implementieren | router.c | — | Klein |
| 1.2 | `ussapi.h` — Header mit Handler-Deklarationen | include/ | — | Klein |
| 1.3 | `ussapi.c` — UFS-Session-Lifecycle Boilerplate | src/ | libufs via MBT | Klein |
| 1.4 | `ussListHandler` — Directory Listing | ussapi.c | 1.1, 1.3 | Mittel |
| 1.5 | `ussGetHandler` — File Read (text + binary) | ussapi.c | 1.1, 1.3 | Mittel |
| 1.6 | `ussPutHandler` — File Write (text + binary) | ussapi.c | 1.1, 1.3 | Mittel |
| 1.7 | `ussCreateHandler` — Create File/Directory | ussapi.c | 1.3 | Klein |
| 1.8 | `ussDeleteHandler` — Delete File/Dir + recursive | ussapi.c | 1.3 | Mittel |
| 1.9 | Route-Registration in mvsmf.c | mvsmf.c | 1.1–1.8 | Klein |
| 1.10 | project.toml Update (libufs via MBT) | Build | — | Klein |
| 1.11 | curl-Tests für alle Phase-1-Endpoints | tests/ | 1.9 | Mittel |
| 1.12 | Zowe CLI Integration Tests | tests/ | 1.9 | Mittel |
| 1.13 | Endpoint-Dokumentation (doc/endpoints/uss/) | doc/ | 1.4–1.8 | Klein |

**Estimated LOC:** ~1000–1500 (ussapi.c) + ~100 (router.c) + ~400 (tests)

**Definition of Done Phase 1:**
- [ ] Alle 5 Handlers kompilieren sauber mit clangd
- [ ] curl-Tests: List/Read/Write/Create/Delete — alle grün
- [ ] Zowe CLI: `zowe files list uss`, `zowe files download uss`, `zowe files upload file-to-uss`, `zowe files delete uss` funktionieren
- [ ] Rekursives Löschen von Verzeichnisbäumen (X-IBM-Option: recursive) getestet
- [ ] Kein ABEND bei Fehleingaben (leerer Pfad, nicht-existentes Verzeichnis, Permission denied)
- [ ] Dokumentation für jeden Endpoint vorhanden

### Phase 2: Basic Utilities (Copy)

**Scope:** Copy-Utility aus Endpoint F

| # | Task | Aufwand |
|---|------|---------|
| 2.1 | `ussUtilitiesHandler` — Dispatch für JSON body PUT | Klein |
| 2.2 | Copy-Operation (Handler-Level mit ufs_fread/fwrite) | Mittel |
| 2.3 | Tests + Dokumentation | Mittel |

**Definition of Done Phase 2:**
- [ ] Copy von USS→USS funktioniert
- [ ] PUT mit Content-Type application/json dispatched korrekt zu Utilities

### Phase 3: Extended Utilities (libufs-Erweiterung)

**Scope:** chmod, chown, move/rename aus Endpoint F

| # | Task | Repo | Aufwand |
|---|------|------|---------|
| 3.1 | UFSD: UFSREQ_CHMOD SSI-Request | ufsd | Mittel |
| 3.2 | libufs: `ufs_chmod()` | ufsd | Klein |
| 3.3 | UFSD: UFSREQ_RENAME SSI-Request | ufsd | Mittel |
| 3.4 | libufs: `ufs_rename()` | ufsd | Klein |
| 3.5 | mvsMF: chmod + move in ussUtilitiesHandler | mvsmf | Mittel |
| 3.6 | Tests + Dokumentation | mvsmf | Mittel |

### Phase 4: Filesystem Management (Langfristig)

**Scope:** Endpoints G–K (List/Create/Delete/Mount/Unmount Filesystems)

Erfordert UFSD-Kernänderungen. Separate Planung nach Stabilisierung Phase 1–3.

---

## 9. Technische Entscheidungen (geklärt)

Alle offenen Fragen sind beantwortet. Diese Sektion dient als verbindliche Referenz für die Implementierung.

### 9.1 Router-Strategie
> **Entscheidung:** `{*filepath}` Wildcard-Pattern im Router. Kleiner Eingriff in `is_pattern_match()` und `extract_path_vars()`.

### 9.2 libufs-Integration
> **Entscheidung:** libufs wird über MBT (MVS Build Tool) als Dependency gezogen. Kein Submodule, kein manuelles Linken. project.toml wird entsprechend erweitert.

### 9.3 UFSD-Verfügbarkeit
> **Entscheidung:** Kein Health-Check nötig. `ufsnew()` ruft intern `IEFSSREQ` (SVC 34) auf. Wenn UFSD STC nicht läuft oder das Subsystem nicht registriert ist, kommt SVC 34 mit Fehler-RC zurück → `ufsnew()` gibt `NULL` zurück. **Kein ABEND, kein Timeout.** Einfacher NULL-Check im Handler reicht, dann HTTP 503 Service Unavailable zurückgeben.

### 9.4 Authentication/ACEE
> **Noch offen** — `ufs_signon()` ist Phase-1-Stub. Klären: Soll `ufs_set_acee()` trotzdem mit dem RACF-ACEE aus der HTTP-Session aufgerufen werden? Für Phase 1 MVP: ACEE setzen aber ignorieren lassen, damit der Codepfad für spätere RACF-Integration vorbereitet ist.

### 9.5 Encoding / Text-Konvertierung
> **Entscheidung:** UFSD speichert **raw bytes**, kein Encoding. Die Konvertierung liegt beim Client.
>
> **Für mvsMF konkret:**
> - `ussPutHandler` (Text-Modus): ASCII→EBCDIC (`mvsmf_atoe`) **vor** `ufs_fwrite()`
> - `ussGetHandler` (Text-Modus): EBCDIC→ASCII (`mvsmf_etoa`) **nach** `ufs_fread()`
> - Binary-Modus: **keine Konvertierung**, Bytes werden durchgereicht
>
> **Konvention:** Dateien im UFSD werden in EBCDIC gespeichert (weil MVS-Programme sie sonst nicht lesen können). Die REST-API liefert/empfängt UTF-8/ASCII (z/OSMF Standard).

### 9.6 Scope Phase 1
> **Entscheidung:** Alle 5 CRUD-Endpoints in Phase 1: List, Read, Write, Create, Delete.

### 9.7 UFSD Error Codes → HTTP Mapping

Vollständig definiert in `ufsd.h`. Verbindliches Mapping für alle Handler:

> **Historisch.** Die Spalten *HTTP Status* und *z/OSMF Category* geben den
> Entwurfsstand wieder, nicht die Implementierung. Umgesetzt wurde eine andere
> Zuordnung: 409/507/414 sind nicht in der z/OSMF-Statusliste (#102), und die
> Kategorien weichen ab — ISDIR ist 400/**2**, nicht 400/6. Maßgeblich ist die
> Tabelle in `CLAUDE.md` bzw. `ufsd_rc_to_http()` / `ufsd_rc_to_category()` in
> `src/ussapi.c`. Bis #269 war der Unterschied folgenlos, weil ein Open die
> Zuordnung überhaupt nicht erreichte; seitdem sieht ein Client sie.

| RC | UFSD Konstante | HTTP Status | z/OSMF Category | Bedeutung |
|----|---------------|-------------|-----------------|-----------|
| 0 | `UFSD_RC_OK` | 200/201/204 | — | Erfolg |
| 28 | `UFSD_RC_NOFILE` | 404 | 4 | Pfad nicht gefunden |
| 32 | `UFSD_RC_EXIST` | 409 | 6 | Existiert bereits |
| 36 | `UFSD_RC_NOTDIR` | 400 | 6 | Kein Verzeichnis (erwartet aber eins) |
| 40 | `UFSD_RC_ISDIR` | 400 | 6 | Ist ein Verzeichnis (erwartet Datei) |
| 44 | `UFSD_RC_NOSPACE` | 507 | 1 | Kein Platz auf dem Filesystem |
| 48 | `UFSD_RC_NOINODES` | 507 | 1 | Keine freien Inodes |
| 52 | `UFSD_RC_IO` | 500 | 1 | I/O-Fehler |
| 56 | `UFSD_RC_BADFD` | 500 | 1 | Ungültiger File Descriptor |
| 60 | `UFSD_RC_NOTEMPTY` | 409 | 6 | Verzeichnis nicht leer |
| 64 | `UFSD_RC_NAMETOOLONG` | 414 | 6 | Name zu lang |

**Implementierung als Mapping-Funktion:**
```c
static int ufsd_rc_to_http(int ufsd_rc) {
    switch (ufsd_rc) {
        case 0:  return 200;  /* UFSD_RC_OK */
        case 28: return 404;  /* UFSD_RC_NOFILE */
        case 32: return 409;  /* UFSD_RC_EXIST */
        case 36: return 400;  /* UFSD_RC_NOTDIR */
        case 40: return 400;  /* UFSD_RC_ISDIR */
        case 44: return 507;  /* UFSD_RC_NOSPACE */
        case 48: return 507;  /* UFSD_RC_NOINODES */
        case 52: return 500;  /* UFSD_RC_IO */
        case 56: return 500;  /* UFSD_RC_BADFD */
        case 60: return 409;  /* UFSD_RC_NOTEMPTY */
        case 64: return 414;  /* UFSD_RC_NAMETOOLONG */
        default: return 500;
    }
}

static int ufsd_rc_to_category(int ufsd_rc) {
    switch (ufsd_rc) {
        case 28:             return 4;  /* not found */
        case 32: case 36:
        case 40: case 60:
        case 64:             return 6;  /* client error */
        case 44: case 48:
        case 52: case 56:   return 1;  /* server/resource error */
        default:             return 1;
    }
}
```

### 9.8 I/O-Limits und Chunking
> **Entscheidung:** Kein spezielles Chunking im Handler nötig. `ufs_fread()` und `ufs_fwrite()` chunken intern in 4K-Blöcken. Einfache Leseschleife reicht:
>
> ```c
> char buf[4096];
> UINT32 n;
> while ((n = ufs_fread(buf, 1, sizeof(buf), fp)) > 0) {
>     /* convert + send */
> }
> ```
>
> **Maximale Dateigröße:** 64 KB (16 Direct Blocks × 4096 Bytes). Kein Indirect-Block-Support in UFSD Phase 1. Für mvsMF-Webroot (Config-Files, Scripts, JCL) ausreichend.
>
> **Konsequenz für Handler:** Bei Dateien > 64 KB schlägt `ufs_fwrite` fehl → `UFSD_RC_NOSPACE` → HTTP 507.

---

## 10. Claude-Code Agent Instructions (CLAUDE.md Erweiterung)

Folgende Abschnitte sollten der mvsMF CLAUDE.md hinzugefügt werden:

```markdown
## USS/UFS Endpoints

### Architecture
- All USS handlers live in `ussapi.c` / `ussapi.h`
- UFS session lifecycle: ALWAYS use `ufsnew()` at handler start, `ufsfree()` before return
- Route pattern `{*filepath}` captures entire remaining path including `/` characters
- PUT to /fs/ dispatches by Content-Type: application/json → utilities (Phase 2), else → write
- libufs dependency is managed via MBT (project.toml)

### Handler Naming Convention and ASM Labels
- `ussListHandler`    — GET    /zosmf/restfiles/fs?path=         — asm("UAPI0001")
- `ussGetHandler`     — GET    /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0002")
- `ussPutHandler`     — PUT    /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0003")
- `ussCreateHandler`  — POST   /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0004")
- `ussDeleteHandler`  — DELETE /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0005")

### Encoding Rules (CRITICAL)
- UFSD stores RAW BYTES — no encoding transformation
- Convention: files stored in EBCDIC (so MVS programs can read them)
- ussPutHandler (text mode): ASCII→EBCDIC via mvsmf_atoe() BEFORE ufs_fwrite()
- ussGetHandler (text mode): EBCDIC→ASCII via mvsmf_etoa() AFTER ufs_fread()
- Binary mode: NO conversion, pass bytes through
- X-IBM-Data-Type header determines mode: "text" (default) or "binary"

### UFS Session Pattern (use in EVERY handler)
```c
int ussXxxHandler(Session *session) {
    UFS *ufs = ufsnew();
    if (!ufs) {
        return sendErrorResponse(session, 503, 1, 8, 1,
            "UFSD subsystem not available", NULL, 0);
    }
    
    /* Optional: pass RACF ACEE for future auth support */
    if (session->acee) {
        ufs_set_acee(ufs, session->acee);
    }
    
    /* ... handler logic ... */
    
    ufsfree(&ufs);  /* ALWAYS cleanup, even on error paths */
    return rc;
}
```

### Error Code Mapping (UFSD_RC_* → HTTP)
Use the ufsd_rc_to_http() and ufsd_rc_to_category() mapping functions.
ALWAYS call sendErrorResponse() with the mapped values. Key mappings:
- UFSD_RC_NOFILE (28) → 404
- UFSD_RC_EXIST (32) → 409
- UFSD_RC_NOTDIR (36) / UFSD_RC_ISDIR (40) → 400
- UFSD_RC_NOSPACE (44) / UFSD_RC_NOINODES (48) → 507
- UFSD_RC_IO (52) → 500
- UFSD_RC_NOTEMPTY (60) → 409

### I/O Pattern for File Read
```c
char buf[4096];
UINT32 n;
while ((n = ufs_fread(buf, 1, sizeof(buf), fp)) > 0) {
    if (is_text_mode) {
        mvsmf_etoa((UCHAR *)buf, n);  /* EBCDIC → ASCII */
    }
    http_write(session->httpc, buf, n);
}
```

### I/O Pattern for File Write
```c
char *body = receive_raw_data(session);  /* DO NOT MODIFY this function */
int body_len = get_content_length(session);

if (is_text_mode) {
    mvsmf_atoe((UCHAR *)body, body_len);  /* ASCII → EBCDIC */
}

UFSFILE *fp = ufs_fopen(ufs, filepath, "w");
if (!fp) { /* handle error using UFSFILE error field */ }
ufs_fwrite(body, 1, body_len, fp);
ufs_fclose(&fp);
```

### Recursive Delete Pattern
```c
static int recursive_delete(UFS *ufs, const char *path) {
    UFSDDESC *dd = ufs_diropen(ufs, path, NULL);
    if (!dd) return -1;
    
    UFSDLIST *entry;
    while ((entry = ufs_dirread(dd)) != NULL) {
        if (strcmp(entry->name, ".") == 0 || 
            strcmp(entry->name, "..") == 0) continue;
        
        char fullpath[UFS_PATH_MAX];
        snprintf(fullpath, sizeof(fullpath), "%s/%s", path, entry->name);
        
        if (entry->attr[0] == 'd') {
            recursive_delete(ufs, fullpath);
        } else {
            ufs_remove(ufs, fullpath);
        }
    }
    ufs_dirclose(&dd);
    return ufs_rmdir(ufs, path);
}
```

### File Size Limit
- Max file size: 64 KB (UFSD Phase 1 — direct blocks only)
- ufs_fwrite beyond 64K → UFSD_RC_NOSPACE → HTTP 507
- This is sufficient for mvsMF webroot content

### Off-Limits
- `receive_raw_data()` — DO NOT MODIFY (MVS TCP/IP bug workaround)
- Router core logic — modify ONLY for {*} wildcard support in is_pattern_match() and extract_path_vars()

### Testing Requirements
- Every handler needs matching curl test in tests/curl-uss.sh
- Every handler needs matching Zowe CLI test in tests/zowe-uss.sh
- Error paths MUST be tested:
  - UFSD not running → 503
  - Non-existent path → 404
  - Create existing → 409
  - Delete non-empty dir without recursive → 409
  - Write to directory → 400
  - Read directory as file → 400
  - Path too long → 414

### C89 Compliance Reminders
- Declare all variables at top of function/block
- No // comments in headers (use /* */ only)
- No inline functions
- Use __asm__ for function label directives
- All string literals must fit in EBCDIC character set
```

---

## 11. Test-Strategie (Phase 1)

### 11.1 curl-Tests (tests/curl-uss.sh)

```bash
# === USS List Files ===
# List root directory
curl -u $USER:$PASS "$BASE/zosmf/restfiles/fs?path=/"

# List with max items
curl -u $USER:$PASS -H "X-IBM-Max-Items: 5" "$BASE/zosmf/restfiles/fs?path=/"

# List non-existent path → 404
curl -u $USER:$PASS "$BASE/zosmf/restfiles/fs?path=/nonexistent"

# List without path param → 400
curl -u $USER:$PASS "$BASE/zosmf/restfiles/fs"

# === USS Read File ===
# Read text file
curl -u $USER:$PASS "$BASE/zosmf/restfiles/fs/etc/profile"

# Read binary file
curl -u $USER:$PASS -H "X-IBM-Data-Type: binary" "$BASE/zosmf/restfiles/fs/bin/test"

# Read non-existent file → 404
curl -u $USER:$PASS "$BASE/zosmf/restfiles/fs/nonexistent/file"

# === USS Write File ===
# Write text file
curl -u $USER:$PASS -X PUT -H "Content-Type: text/plain" \
  --data "Hello USS" "$BASE/zosmf/restfiles/fs/tmp/test.txt"

# Write binary file
curl -u $USER:$PASS -X PUT -H "X-IBM-Data-Type: binary" \
  --data-binary @/tmp/testfile "$BASE/zosmf/restfiles/fs/tmp/test.bin"

# === USS Create ===
# Create directory
curl -u $USER:$PASS -X POST -H "Content-Type: application/json" \
  --data '{"type":"directory","mode":"rwxr-xr-x"}' \
  "$BASE/zosmf/restfiles/fs/tmp/testdir"

# Create file
curl -u $USER:$PASS -X POST -H "Content-Type: application/json" \
  --data '{"type":"file","mode":"rw-r--r--"}' \
  "$BASE/zosmf/restfiles/fs/tmp/testfile"

# Create with invalid type → 400
curl -u $USER:$PASS -X POST -H "Content-Type: application/json" \
  --data '{"type":"invalid"}' \
  "$BASE/zosmf/restfiles/fs/tmp/bad"
```

### 11.2 Zowe CLI Tests (tests/zowe-uss.sh)

```bash
# List files
zowe files list uss-files "/tmp" --zosmf-p mvs38j

# Download file
zowe files download uss-file "/etc/profile" -f /tmp/profile.txt --zosmf-p mvs38j

# Upload file
echo "test content" > /tmp/upload-test.txt
zowe files upload file-to-uss /tmp/upload-test.txt "/tmp/uploaded.txt" --zosmf-p mvs38j

# Create directory
zowe files create uss-directory "/tmp/zowe-test-dir" --zosmf-p mvs38j

# Verify round-trip: upload → download → compare
echo "Round-trip test data" > /tmp/rt-input.txt
zowe files upload file-to-uss /tmp/rt-input.txt "/tmp/rt-test.txt" --zosmf-p mvs38j
zowe files download uss-file "/tmp/rt-test.txt" -f /tmp/rt-output.txt --zosmf-p mvs38j
diff /tmp/rt-input.txt /tmp/rt-output.txt
```

---

## Appendix A: z/OSMF USS API Quick Reference

| Endpoint | Method | Path | mvsMF Phase |
|----------|--------|------|-------------|
| List files/dirs | GET | `/zosmf/restfiles/fs?path=` | Phase 1 |
| Read file | GET | `/zosmf/restfiles/fs/<path>` | Phase 1 |
| Write file | PUT | `/zosmf/restfiles/fs/<path>` | Phase 1 |
| Create file/dir | POST | `/zosmf/restfiles/fs/<path>` | Phase 1 |
| Delete file/dir | DELETE | `/zosmf/restfiles/fs/<path>` | Phase 1 |
| File utilities | PUT | `/zosmf/restfiles/fs/<path>` (JSON) | Phase 2–3 |
| List filesystems | GET | `/zosmf/restfiles/mfs/` | Phase 4 |
| Create ZFS | POST | `/zosmf/restfiles/mfs/zfs/<name>` | Phase 4 |
| Delete ZFS | DELETE | `/zosmf/restfiles/mfs/zfs/<name>` | Phase 4 |
| Mount FS | PUT | `/zosmf/restfiles/mfs/<name>` (mount) | Phase 4 |
| Unmount FS | PUT | `/zosmf/restfiles/mfs/<name>` (unmount) | Phase 4 |

## Appendix B: libufs ↔ z/OSMF Feature Coverage

```
██████████████████░░░░░░░░░░░░░░░░░░  45% — libufs deckt z/OSMF USS API ab

████████████████████████████████████  100% — File Read/Write/Create
████████████████████████░░░░░░░░░░░░   65% — Directory Operations (kein recursive, kein filter)
░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░    0% — File Utilities (chmod/chown/move)
░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░    0% — Filesystem Management (create/mount/unmount)
```
