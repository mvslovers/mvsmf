# Code Pages for Data Sets and Members

A text transfer translates between ASCII on the client and EBCDIC in the data
set. Which EBCDIC code page the stored data is in decides how that goes, and
the request can say so.

## Default: CP037

Data sets and members are translated through **IBM-037 (CP037)** unless the
request asks for something else. MVS 3.8j predates IBM-1047, and the data the
system was built with -- IBM-supplied libraries, JCL, assembler source, job
output -- is CP037. Translating it through 1047 would swap `^` and `¬` (X'5F'
and X'B0'), and `¬` is everywhere in JCL and assembler.

USS files are the other way round: they default to **IBM-1047**, the z/OS UNIX
convention and what z/OSMF and Zowe assume for USS files, and
`fileEncoding=IBM-037` selects CP037 there. See
[../uss/get.md](../uss/get.md#encoding).

## Choosing the code page: `fileEncoding`

```
X-IBM-Data-Type: text;fileEncoding=IBM-1047
```

This is the header Zowe sends when an encoding is chosen (Zowe CLI
`--encoding`, the encoding setting in Zowe Explorer). It matters most for C
source: the two code pages put `[` and `]` in different places, and source
typed with the brackets at X'AD' / X'BD' is IBM-1047.

| `[` `]` stored as | Code page | Read through CP037 |
|---|---|---|
| X'BA' X'BB' | IBM-037 | `[` `]` |
| X'AD' X'BD' | IBM-1047 | `Ý` `¨` (X'DD' X'A8') |

Supported values, case-insensitive:

| Value | Code page |
|---|---|
| `IBM-037`, `037` | CP037 (the default) |
| `IBM-1047`, `1047` | IBM-1047 |

The header applies to `GET` and `PUT` on
[data sets](get.md) and [members](members-get.md) alike. It is parsed the way
the reference z/OSMF parses it (measured, issue #391):

- The type before the first `;` and the key `fileEncoding` are
  case-insensitive. Further parameters may precede or follow it.
- Parameters are not trimmed: `text; fileEncoding=IBM-1047`, with a blank
  after the `;`, is not recognised, and the default applies.
- An empty value (`fileEncoding=`) means the default.
- `binary` and `record` move bytes untranslated and ignore `fileEncoding`
  altogether, even an unsupported value.
- The ETag does not depend on the encoding: it is computed over the stored
  bytes, not over the bytes sent.

## Unsupported values

Any other value on a text request -- `IBM-1140`, and also `IBM-37` or `CP037`,
which the reference refuses as well -- answers **HTTP 500** with the
reference's error report:

```json
{"rc":121,"category":16,"reason":-1037303780,
 "message":"iconv_open() failed.",
 "details":["Unsupported encoding in X-IBM-Data-Type 'text;fileEncoding=IBM-1140': IBM-037 and IBM-1047 are supported."]}
```

On a `PUT` the check runs before the target is opened, so a refused write
leaves the data set or member as it was.

## Not covered

- The ASCII side of the translation (`Content-Type: …;charset=`, Zowe's
  `localEncoding`) is not interpreted -- see issue #234.
- Jobs (JCL submit, spool) do not take `fileEncoding` yet.
