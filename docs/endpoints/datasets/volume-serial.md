# Addressing a Data Set by Volume Serial

Seven routes take a volume serial in front of the data set name, as z/OSMF does
and as Zowe Explorer and the Zowe CLI send it when a volume is given:

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
the same prefix; the volume applies to the existing data set being renamed.

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
| Not cataloged | 404 | 14 | Dataset is not cataloged; only a cataloged dataset can be addressed by volume |
| Volume serial malformed | 400 | 1 | Invalid volume serial |

`category` is 6 and `rc` 8 in all three answers. A refused request reads, writes and deletes nothing.

A volume serial is one to six characters from `A-Z`, `0-9`, `$`, `#` and `@`,
and is case-insensitive. Anything else, including a seventh character or a
period, is 400.

The check runs after the authorization check, so a caller without access to the
data set gets the usual denial and learns nothing about where it lives.

## Limitations

- **Uncataloged data sets cannot be reached.** Reading or writing a data set
  that is on a volume but not in the catalog needs OBTAIN and an open by volume,
  which mvsMF does not do. Such a request is 404 with reason 14.
- **Only the first volume of a catalog entry is compared.** A multi-volume
  data set is on its volume when the volume named is the first one in its
  catalog entry.
- The volume parameter of the list request (`volser`) is a separate filter and
  is unchanged; see [list.md](list.md).

## Examples

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restfiles/ds/-(MVSRES)/SYS1.PARMLIB(IEASYS00)"
```
```bash
zowe files view ds "SYS1.PARMLIB(IEASYS00)" --volume-serial MVSRES
zowe files delete ds "IBMUSER.TEST.DATA" --volume MVSRES -f
```
