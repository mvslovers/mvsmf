# mvsMF Desktop — Specification

Browser-based management frontend for mvsMF, inspired by the OS/2 Workplace
Shell: overlapping windows, taskbar, start menu, desktop icons. Served as
static files from the HTTPD UFS — pure vanilla HTML/JS/CSS, no frameworks,
no build step.

Concept & tracking: Notion Concepts DB → "mvsMF Desktop — OS/2 Workplace
Shell inspired web frontend" (Status: Approved), task TSK-281.

## Current state

A feature-complete Phase 1 PoC exists as a single file. It is the
**behavioral reference** for the production implementation: every feature,
interaction and visual detail of the shell has been validated in it
(deployed on a real HTTPD/UFS, login against a live mvsMF).

Phase 1 task: port the PoC into the module structure below with feature
parity, plus the theme-hardening pass. Phase 2+ adds real programs
(Dataset browser, JES spool browser, Console, REXX workbench, …) one task
at a time — the plugin API is final and must not change shape.

## Repo layout

```
static/
├── index.html              # entry point, loads shell as ES modules
├── css/
│   └── desktop.css         # all styles, OS/2 theme via --wps-* variables
├── js/
│   ├── shell.js            # boot, desktop icons, glue
│   ├── wm.js               # window manager
│   ├── taskbar.js          # taskbar component
│   ├── startmenu.js        # start menu + systems submenu
│   ├── login.js            # login screen + auth flow
│   ├── dialog.js           # OS/2-style modal dialogs (no native popups)
│   ├── systems.js          # SystemRegistry, checkSystem, SafeStore
│   ├── prism-jcl.js        # custom Prism grammars (JCL, HLASM, REXX —
│   ├── prism-hlasm.js      #   REXX has no upstream Prism component)
│   ├── prism-rexx.js
│   └── programs/
│       ├── _template.js    # documented program template
│       ├── welcome.js
│       ├── sysinfo.js      # fetches /zosmf/info via ctx.system.apiFetch
│       ├── systems.js      # systems manager program
│       ├── datasets.js     # dataset browser (Phase 2.1)
│       └── spool.js        # JES spool browser (Phase 2.2)
├── vendor/
│   ├── prism.js            # Prism 1.29.0 core+clike+c (pinned, air-gap safe)
│   └── prism.css           # Prism default theme
└── (img/ optional — Tabler icons come from CDN)
```

ES modules via `<script type="module">`. English code comments.
The PoC file is preserved as `docs/desktop-poc.html` for reference and
removed once feature parity is confirmed.

## Deployment

Target on the UFS: `<DOCROOT>/mvsmf/` → `http://<host>:<port>/mvsmf/`.
The HTTPD prepends its configured `DOCROOT` (default `/www`) to every
request path, so with the stock docroot the desktop lives at
`/www/mvsmf/`. Set `DESKTOP_UFS_DIR` to override for a custom docroot.

Add a make target (e.g. `make deploy-desktop`) that uploads `static/`
recursively via the mvsMF USS API (`PUT /zosmf/restfiles/fs/www/mvsmf/...`)
— dogfooding our own API. Text files go through the normal IBM-1047 USS
conversion; no binary assets exist yet. HTTPD serves character files
(`.html`/`.css`/`.js`) with EBCDIC→ASCII translation and the right MIME
type (`.js` → `application/x-javascript`, valid for `type="module"`).

Same-origin note: served from the HTTPD itself, all API calls are
same-origin — no CORS needed for the local system. Cross-origin
(multi-system) is blocked until HTTPD has CORS support (TSK-283).

## Visual design — OS/2 Workplace Shell

All chrome colors live in `--wps-*` CSS custom properties on `:root`.

### Theme tokens (validated in the PoC)
```css
:root {
  --wps-desktop-bg: linear-gradient(145deg, #1a3a5c 0%, #0d2137 60%, #1a2a3c 100%);
  --wps-title-active: linear-gradient(90deg, #00007b 0%, #1084d0 100%);
  --wps-title-inactive: linear-gradient(90deg, #555 0%, #888 100%);
  --wps-title-text: #ffffff;
  --wps-title-system: #aac8ff;
  --wps-chrome: #d4d4d4;
  --wps-chrome-dark: #c8c8c8;
  --wps-chrome-darker: #b0b0b0;
  --wps-border-light: #e8e8e8;
  --wps-border-mid: #aaaaaa;
  --wps-border-dark: #999999;
  --wps-text: #1a1a1a;
  --wps-text-dim: #555555;
  --wps-accent: #00007b;
  --wps-led-green: #33cc33;
  --wps-led-red: #cc3333;
  --wps-led-yellow: #cccc33;
  --wps-console-bg: #1a1a1a;
  --wps-console-fg: #33ff33;
  --wps-shadow: 3px 3px 8px rgba(0,0,0,0.4);
  --wps-font-ui: "Segoe UI", system-ui, sans-serif;
  --wps-font-mono: "Cascadia Mono", "Consolas", "Menlo", monospace;
}
```

### Theme-hardening pass (part of Phase 1)
The PoC still has stray inline hex values. For the production port:
- Move ALL remaining colors into `--wps-*` variables: logo gradient
  (`#1084d0 → #00007b`, used in login, start menu, start button, about),
  login status tints (ok/bad/warn/wait), window content background,
  program-content grays.
- Bezel style as a variable: `--wps-bezel-out: 2px outset var(--wps-border-light)`
  and `--wps-bezel-in: 1px inset var(--wps-border-mid)` (plus the 1px
  variants) so a flat theme can override the *style*, not just colors.
- `data-theme` attribute on `<html>`, persisted via SafeStore. Only the
  default theme ships in Phase 1 — the mechanism must work, a second
  theme is future work.

### Window chrome
- Title bar: `--wps-title-active` gradient, 22px, small icon (14×14 gray
  raised), title 12px/500 white, "— SYSTEMNAME" in `--wps-title-system`
- Controls right: three 15×15 raised buttons `_` `□` `×`, inset on :active
- Chrome: `--wps-chrome` with outset bezel, drop shadow `--wps-shadow`
- Optional toolbar (raised 3D buttons) and status bar (sunken text) per program
- Content area: white by default

### Taskbar (28px, bottom)
Start button (logo square + "Start", inset when menu open) · separator ·
window buttons (inset+accent = focused; click toggles minimize/restore) ·
system tray in sunken container: LED · system name (mono, accent,
dotted underline, click → systems manager) · username · clock (updates 1/s)

### Start menu
Blue-gradient header (logo, name, version) · program list (20×20 colored
icon squares) · separator · Systems (chevron → submenu with live LEDs per
system + "Manage systems…") · Settings · About · Logout. Closes on
outside click.

### Login screen
Fullscreen desktop background, centered OS/2 dialog. System dropdown
(`NAME — host:port (local)`), live connection status bar, username,
password, Cancel/Login, "Manage systems…" and "Demo mode" links,
version string bottom-right.

### Program icon colors
| Program          | iconBg    | icon (Tabler)   | iconColor |
|------------------|-----------|-----------------|-----------|
| Dataset browser  | `#e8d44d` | `ti-database`   | `#5a4e00` |
| USS file manager | `#4d8de8` | `ti-folder`     | `#fff`    |
| JES spool browser| `#4db84d` | `ti-list`       | `#fff`    |
| MVS console      | `#1a1a1a` | `ti-terminal-2` | `#33ff33` |
| REXX workbench   | `#b84d4d` | `ti-code`       | `#fff`    |
| Job submit       | `#8855bb` | `ti-upload`     | `#fff`    |
| Local files      | `#dd8833` | `ti-files`      | `#fff`    |

Icon colors belong to the program definition, not the theme.

Tabler icons via CDN (outline only, no `-filled`):
`https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@latest/dist/tabler-icons.min.css`

All UI text is sentence case, never Title Case.

## Window manager

Validated behaviors (all present in the PoC):
- Open with cascade offset; close (calls program `destroy`); minimize to
  taskbar; maximize fills desktop area (not the taskbar); restore;
  double-click on title bar toggles maximize
- Drag via title bar (pointer events); constraints: ≥60px of the window
  stays on screen horizontally, title bar never above y=0
- Resize from all 8 edges/corners via invisible handle strips; respects
  program `minWidth`/`minHeight`; north/west resizing moves the origin
- Focus on pointerdown anywhere in the window → z-index bump, titlebar
  active gradient, taskbar button pressed
- Multiple instances of the same program allowed
- z-layers: desktop 0 · icons 1 · windows 10+ · start menu 9999 · login 10000

## Program plugin API (final — do not change shape)

```javascript
Programs.register({
  id: "my-program",
  name: "My program",
  icon: "ti-star",
  iconBg: "#4d8de8",
  iconColor: "#fff",
  defaultWidth: 500, defaultHeight: 400,
  minWidth: 300, minHeight: 200,
  desktopIcon: true,          // show on the desktop
  statusBar: true,            // optional status bar
  toolbar: [                  // optional toolbar buttons
    { label: "Refresh", icon: "ti-refresh", onClick(ctx) { /* ... */ } }
  ],
  create(ctx) {               // return the content DOM node
    // ctx: { windowId, system, contentEl, setTitle(t), setStatus(t), close() }
    // ctx.system: { name, host, port, baseUrl, user, demo, apiFetch(path, opts) }
    const el = document.createElement("div");
    return el;
  },
  confirmClose(ctx) {         // OPTIONAL: return false — or a Promise
    return true;              // resolving to false (Dialog.confirm) — to
  },                          // veto the close (added in 2.1)
  destroy(ctx) { /* cleanup timers, listeners */ }
});
```

`apiFetch()` prefixes `baseUrl` and sends `X-CSRF-ZOSMF-HEADER` with
`credentials: same-origin`; authentication rides on the browser's
`LtpaToken2` session cookie — no `Authorization` header, no password in JS.
A `401` dispatches a `mvsmf:session-expired` window event (the shell then
returns to the login screen). In demo mode it throws — programs provide
canned data instead (see sysinfo).

## Systems & login

### SystemRegistry
Persisted via SafeStore (localStorage with in-memory fallback) under
`mvsmf.systems`: `{ systems: [{name, host, port, local?}], defaultSystem }`.

### ensureLocal() — origin-derived default system
On boot, if the page is served over http(s): host+port from
`window.location` become the local system. Name = first hostname label,
uppercase, max 8 chars (`MVSDEV` from `mvsdev.lan`), fallback `LOCAL` on
collision. Existing host+port entries are reused (marked `local`), never
duplicated. The local system is the default, shown as `(local)`, and
cannot be removed. `baseUrl()` follows the page protocol for the local
system (TLS-proxy safe), plain `http:` for remotes.

### Connection check — checkSystem(sys)
Anonymous LED probe only. `GET {base}/zosmf/info`, 4s timeout via AbortController.
- 200 → `connected` (+parsed info)
- 401/403 → `auth_failed` — **counts as reachable** (yellow LED)
- fetch TypeError → retry with `mode: "no-cors"`: resolves → `cors_blocked`
  (yellow, "serve this page from the HTTPD"), rejects → `unreachable` (red)
- Sends NO custom headers (CORS simple request, no preflight)

### Token login — authenticate(sys, {user, pass})
`POST {base}/zosmf/services/authenticate` **once** with `Authorization: Basic`
+ `X-CSRF-ZOSMF-HEADER`, `credentials: same-origin`. On `200` the server sets
`LtpaToken2` (a session cookie); the browser replays it on every later call, so
the password is never stored. `401/403` → `auth_failed`; a fetch reject →
`unreachable` (a cross-origin login blocked by CORS — the token flow is
same-origin, i.e. the SPA must be served from the HTTPD).

### Login flow
System select → live check → username/password → `authenticate()` → success
stores the **non-secret** session (`user` + system name + demo flag in
`SafeStore`, no password/token; system becomes `defaultSystem`), enter desktop,
open Welcome. Demo mode link enters the desktop without a backend
(`Session.demo`, canned data).

### Session persistence & logout
The `LtpaToken2` cookie survives a page reload, so on boot `Session.restore()`
re-enters the desktop directly when the cookie (and stored identity) are still
present — no re-login. A `401` from any API call (token expired or reaped by
the HTTPD idle `SESSION_TIMEOUT`, default 30 min) clears the stored session and
reloads to the login screen with a "Session expired" notice. Logout is a real
server-side `DELETE {base}/zosmf/services/authenticate` (invalidates the token)
followed by a clean reload.

## Phase 1 acceptance

- Feature parity with `docs/desktop-poc.html` (side-by-side check)
- 4-5 overlapping windows behave correctly (drag, resize, focus, taskbar)
- Login against the local system works when served from the HTTPD
- Demo mode works from `file://`
- Theme-hardening pass complete (no stray hex values, bezel variables,
  data-theme mechanism)
- `make deploy-desktop` uploads static/ to `<DOCROOT>/mvsmf/` (default
  `/www/mvsmf/`) via mvsMF

## Out of scope (Phase 2+)

Real programs (dataset/USS/spool/console/REXX/job-submit/local-files),
cross-system operations, drag & drop between windows, keyboard shortcuts,
additional themes, notifications.
