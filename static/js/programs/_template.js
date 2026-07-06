/* ============================================================
   _template.js — documented program template (Phase 2 authors).

   This file is NOT imported by shell.js, so it registers nothing
   at runtime. To add a real program:
     1. Copy this file to js/programs/<your-id>.js
     2. Fill in the definition below
     3. Add `import "./programs/<your-id>.js";` to js/shell.js

   The plugin API is FINAL — keep the shape exactly as documented
   here; the shell and Phase 2 programs depend on it.
   ============================================================ */
import { Programs } from "./registry.js";

Programs.register({
  /* --- identity --- */
  id: "my-program",          // unique, kebab-case
  name: "My program",        // sentence case (never Title Case)
  icon: "ti-star",           // Tabler icon class (outline, no -filled)

  /* --- icon square colours (belong to the program, NOT the theme) --- */
  iconBg: "#4d8de8",
  iconColor: "#fff",

  /* --- default + minimum window size --- */
  defaultWidth: 500, defaultHeight: 400,
  minWidth: 300, minHeight: 200,

  /* --- shell integration --- */
  desktopIcon: true,         // show an icon on the desktop
  statusBar: true,           // render a status bar (ctx.setStatus writes to it)

  /* --- optional toolbar of raised 3D buttons --- */
  toolbar: [
    { label: "Refresh", icon: "ti-refresh", onClick(ctx) { /* ctx is the window context */ } }
  ],

  /* --- create: build and return the content DOM node ---
     ctx = {
       windowId,                       // this window's id
       system,                         // { name, host, port, baseUrl, user, demo, apiFetch(path, opts) }
       contentEl,                      // the .wps-content element
       setTitle(t),                    // update title bar + taskbar label
       setStatus(t),                   // write to the status bar (if statusBar)
       close()                         // close this window
     }
     system.apiFetch() prefixes baseUrl and sends X-CSRF-ZOSMF-HEADER; auth
     rides on the browser's LtpaToken2 session cookie (no password in JS). A
     401 signals session-expiry to the shell. In demo mode it throws —
     provide canned data. */
  create(ctx) {
    const el = document.createElement("div");
    el.className = "prog-pad";
    el.textContent = "Hello from " + ctx.system.name;
    return el;
  },

  /* --- confirmClose: optional veto before the window closes ---
     Return false — or a Promise resolving to false (e.g. from
     Dialog.confirm) — to keep the window open. Called before
     destroy(); omit it if the program has no dirty state. */
  confirmClose(ctx) { return true; },

  /* --- destroy: clean up timers / listeners (optional) --- */
  destroy(ctx) { /* ... */ }
});
