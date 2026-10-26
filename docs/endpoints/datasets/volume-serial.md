# Addressing a Data Set by Volume Serial

Seven routes take a volume serial in front of the data set name, as z/OSMF does:

| Method | Path |
|--------|------|
| GET | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}` |
| PUT | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}` |
| DELETE | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}` |
| GET | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}/member` |
| GET | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}({member-name})` |
| PUT | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}({member-name})` |
| DELETE | `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}({member-name})` |

The rename request (`PUT` on the volume form with a `from-dataset` body) takes
the same prefix. The volume applies to the data set that exists: the old name of
a data set rename, and the library of a member rename.

## What the volume means

mvsMF serves **cataloged** data sets only. The volume serial is therefore a
check, not a different way to reach the data: the request is served exactly like
the cataloged form when the catalog entry of the data set is on that volume,
and refused otherwise. A data set that is cataloged on another volume is never
served silently.

| Case | Status | `reason` | `message` |
|------|--------|----------|-----------|
| Cataloged on the volume named | as the cataloged form | | |
| Cataloged on another volume | 404 | 13 | Dataset not found on the requested volume |
| Not cataloged | 404 | 4 | Dataset not found (the answer of the route without a volume) |
| Volume serial malformed | 400 | 1 | Invalid volume serial |

`category` is 6 and `rc` 8 in all three. A refused request reads, writes and
deletes nothing.

A volume serial that no volume carries is the same case as a wrong one: 404 with
reason 13. The reference z/OSMF answers a read of it with 500; mvsMF does not
copy that, because a wrong operand is not a server fault. `category` and
`reason` of the reference's own reports are ISPF library-management codes that
mvsMF does not have, so the numbers differ; the status and the sense of the
message agree (see `internals/zosmf-conformance.md`).

A volume serial is one to six characters from `A-Z`, `0-9`, `$`, `#` and `@`,
and is case-insensitive. Anything else, including a seventh character or a
period, is 400.

The check runs after the authorization check, so a caller without access to the
data set gets the usual denial and learns nothing about where it lives.

## Limitations

- **Uncataloged data sets cannot be reached.** Reading or writing a data set
  that is on a volume but not in the catalog needs OBTAIN and an open by volume,
  which mvsMF does not do. Such a request gets the same 404 as a name that exists nowhere.
- **One volume serial is compared.** The catalog lookup returns a single volume
  serial, and that is the one the volume in the path is compared with. A request
  that names any other volume of a multi-volume data set is 404 with reason 13.
- **The volume serial is a consistency check, not an access control.** The
  check and the operation look up the catalog separately. If the data set is
  recataloged in between, the operation can hit a different volume than the one
  that was checked. Authorization hangs on the data set name.
- The `volser` query parameter of the list request is a separate matter and is
  unchanged: the list reads it and ignores it; see [list.md](list.md).

## Example

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restfiles/ds/-(MVSRES)/SYS1.PARMLIB(IEASYS00)"
```
