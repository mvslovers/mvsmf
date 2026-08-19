# Authorization (data set endpoints)

Every data set endpoint makes an explicit RACF decision before it touches
anything. Before issue #228 the decision happened by accident, inside OPEN,
under whatever ACEE the address space held at the time; now the operation is
authorized against the caller's own identity first, and the open is a second
net rather than the only one.

## Attribute per operation

The class is always `DATASET`. A member operation is authorized on the
**library**, never on `DSN(MEMBER)`: RACF profiles cover data sets, and there is
no member-level profile to ask about.

| Endpoint | Operation | Resource | Attribute |
|---|---|---|---|
| `GET /ds/{dsn}` | read a sequential data set | the data set | READ |
| `GET /ds/{dsn}/member` | list members | the library | READ |
| `GET /ds/{dsn}({mbr})` | read a member | the library | READ |
| `PUT /ds/{dsn}` | write a sequential data set | the data set | UPDATE |
| `PUT /ds/{dsn}({mbr})` | write a member | the library | UPDATE |
| `PUT /ds/{dsn}({mbr})` + `request:rename` | rename a member | the library | UPDATE |
| `PUT /ds/{dsn}` + `request:rename` | rename a data set | **both names** | ALTER |
| `DELETE /ds/{dsn}({mbr})` | delete a member (STOW) | the library | UPDATE |
| `DELETE /ds/{dsn}` | uncatalog and scratch | the data set | ALTER |

A data set rename checks the **source and the target**. Checking only the source
would let a caller with ALTER over their own qualifier move a data set into a
namespace they have no authority over.

## Not authorized here

- `GET /zosmf/restfiles/ds?dslevel=` — the listing reads the catalog and the
  VTOC and opens nothing, so it has no check at all. That is deliberate and
  matches the reference implementation; see issue #229 and the *Authorization*
  section of `CLAUDE.md`.
- `POST /zosmf/restfiles/ds/{dsn}` — allocation goes through SVC 99 rather than
  an open. It is gated only by whatever the allocation itself enforces.

## What a refusal looks like

```
HTTP/1.1 500 Internal Server Error
Content-Type: application/json

{"rc":8,"category":4,"reason":0,"message":"LMOPEN error",
 "details":["Authorization failed - You may not use this protected data set."]}
```

**500 is the conformant status, not 403.** Measured against a real z/OSMF
(version 29 / z/OS 05.29.00): a read of a data set the caller may not open
answers 500 with `category 4`, `rc 8`, `reason 0` and the explanation in
`details[]`. 403 is absent from the z/OSMF status list *and* is not what the
reference sends. `category 4` here is measured rather than documented.

The reference's own `details[]` text ends `Open 913 abend.`, because OPEN is what
refused it. mvsMF refuses before the open, so it stops one clause earlier — it
does not claim an abend it did not take. The variant that *does* carry the abend
belongs to the recovery path (#315).

## The refusal is decided before existence

Every check runs ahead of the operation's first catalog or VTOC access —
including ahead of the `is_pds()` probe on the read and write paths. A caller who
may not touch a name therefore gets the same answer whether or not it exists, so
the check cannot be used to enumerate. A 404 from these endpoints always means
"you were allowed to ask, and it is not there".

## Console

A refused request writes **nothing** to the console. RAKF logs `RAKF0005` for a
denial it catches inside OPEN, but not for the RACHECK this pre-check issues, and
mvsMF does not add a message of its own: a client polling a denied endpoint would
turn one refusal into a flood, which its own console API would then serve back
(see *Operator Messages* in `CLAUDE.md`).
