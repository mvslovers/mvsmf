# `fn=storage` — sampling free storage in the httpd address space

An instrument, not a fix. It exists because the degradation that ends in
`S80A` (issue #287, symptom in #282, model in #217) has never been measured:
the only evidence available so far was `IEC999I` lines counted out of the
Master Trace Table, and **the MTT rolls** — a run that produces hundreds of
them pushes its own evidence out of the buffer.

```
GET /zosmf/test?fn=storage
GET /zosmf/test?fn=storage&total=1
GET /zosmf/test?fn=storage&sp=1
```

Read-only, Basic-Auth like the rest of `/zosmf/test`, and it changes nothing
in the request paths.

## What it reports

```json
{ "fn": "storage", "sp": 0, "largest": 1048576, "largest_at": "0x0A2000",
  "link_stack": 262144, "granularity": 4096, "stack_at": "0x0B4A18",
  "probes": 12, "free_errors": 0 }
```

| Field | Meaning |
|---|---|
| `sp` | subpool probed (`&sp=`, 0–127; default 0 — the one the C startup uses) |
| `largest` | largest contiguous block GETMAIN would hand out **right now**, bytes |
| `largest_at` | where that block starts — tells you which end of the region is still open |
| `link_stack` | 262144, the unconditional GETMAIN libc370's C startup makes per LINK |
| `granularity` | 4096; `largest` is a multiple of it, so it is accurate to ±4 K |
| `stack_at` | address of a local in this request — where this LINK's own stack landed |
| `probes` | GETMAIN calls the bisect needed (≈12 without `total=1`) |
| `free_errors` | non-zero means a probe failed to give its block back. Must be 0 |

With `&total=1`, four more fields:

| Field | Meaning |
|---|---|
| `total` | every free byte in the subpool, in blocks of ≥ 4 K |
| `blocks` | how many blocks that took |
| `truncated` | `true` = there were more than 256 blocks; `total` is a floor, not the total |
| `sizes` | the first 32 block sizes, largest first — the fragmentation picture itself |

## How to read it

`link_stack` is the threshold everything turns on. httpd loads the CGI fresh
per request, and libc370's C startup (`@@crt0`) takes an **unconditional**
`GETMAIN` of 262144 bytes for the main stack — since libc370#81 every other
GETMAIN in libc370 is conditional and returns NULL, so an S80A can only be
that one. When `largest` falls below 262144, the next request cannot start:
`HTTPD908E … S80A`, before mvsMF's ESTAE exists to catch anything.

Sampled over a run, the two numbers separate the two hypotheses:

- **`total` falls with `largest`** → an ordinary leak. The slope is its rate
  per request, and `blocks` stays roughly constant.
- **`total` flat while `largest` shrinks** → fragmentation. Nothing is being
  lost; the region is being cut into pieces too small to fit a 262 K stack.
  `sizes` shows it directly: many mid-sized blocks instead of one large one.
- **Neither moves over 200 requests** → the consumer is not per-request. Look
  at what the test suites do that a loop does not: many distinct connections,
  large responses, concurrent workers.

## Caveats that change the numbers

1. **The sampler is itself a LINK.** Its own 262 K stack is already allocated
   when it measures, so `largest` is what would be left *while a request is
   running* — which is the right frame for "can the next one start", but it
   is not the idle figure. Every sample is also one more request against the
   very address space under test: count them.
2. **`&total=1` holds all free storage for the length of its loop.** Any
   request arriving in that window fails its startup GETMAIN, and per
   httpd#154 such an abend leaks storage permanently — the instrument would
   corrupt what it measures. Sample with `total=1` **between** load runs,
   never during one. The default (no `total`) holds its largest probe for
   microseconds only.
3. **`free_errors` is not decoration.** Anything but 0 means this probe just
   leaked storage into the address space, and every later sample from that
   server is suspect. Restart before continuing.
4. `truncated: true` means `total` is a lower bound.

## Sampling protocol (issue #287)

`P HTTPD` / `S HTTPD` between classes so each starts clean, then per class:

| Run | Load | Sample |
|---|---|---|
| baseline | none | once at start |
| info | 200 × `/zosmf/info` | every 50 |
| datasets | 200 × a member read | every 50 |
| jobs | 200 × `.../files` on a **small** job | every 50 |
| uss | 200 × a USS file read | every 50 |
| static | 200 × a plain httpd document (no CGI) | every 50 |

```sh
sample() { curl -s -u "$U:$P" "http://$H:$PORT/zosmf/test?fn=storage&total=1"; echo; }

sample                                    # baseline
for i in $(seq 1 200); do
    curl -s -o /dev/null -u "$U:$P" "http://$H:$PORT/zosmf/info"
    [ $((i % 50)) -eq 0 ] && sample
done
```

The `static` row is the one that decides ownership: if it drops too, the
consumer is in httpd's request handling and not in mvsMF at all.

## Why it is built the way it is

- **Register-form GETMAIN/FREEMAIN, issued inline.** MVSMF is link-edited
  RENT. The list forms (`GETMAIN VC` and friends) build their parameter list
  in the code stream and store into it — an S0C4 here. The register form
  expands to register setup, a read-only `ICM` against an inline constant,
  and `SVC 120`; verified in the assembler listing, not assumed.
- **Bisected, not asked for.** `GETMAIN VC` would report the largest
  available block in one call. The register form only answers yes or no, so
  the size is bisected to 4 K in ~12 conditional probes.
- **Not libc370's `getmain()`.** It WTOs on every failed request, and a
  bisect fails by design on about half its probes — that would feed the
  instrument's own noise into the Master Trace Table `consapi.c` reads back
  out, and into the console log this investigation reads for `IEC999I`.
