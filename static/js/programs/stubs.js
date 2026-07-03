/* ============================================================
   stubs.js — Phase 2 placeholder programs.
   Each real program (Dataset browser, JES spool browser, MVS
   console, REXX workbench, …) arrives in its own Phase 2 task
   and uses exactly this plugin interface. Registering the stubs
   now proves the desktop icons, start menu, cascade and multiple
   instances all work. Icon colours come from the spec's table
   and belong to the program definition, not the theme.
   ============================================================ */
import { Programs } from "./registry.js";

function registerStub(id, name, icon, iconBg, iconColor) {
  Programs.register({
    id, name, icon, iconBg, iconColor,
    defaultWidth: 400, defaultHeight: 220,
    desktopIcon: true,
    stub: true,
    create() {
      const d = document.createElement("div");
      d.className = "prog-pad";
      d.innerHTML = `
        <h1>${name}</h1>
        <p>This program arrives in <b>Phase 2</b>.</p>
        <p>The window you are looking at is served by the plugin API —
        the real implementation will use the same interface and the
        system context's <code>apiFetch()</code>.</p>`;
      return d;
    }
  });
}

// datasets (Dataset browser) graduated to a real program in Phase 2.1 —
// see programs/datasets.js
registerStub("ussfiles",  "USS file manager", "ti-folder",     "#4d8de8", "#fff");
registerStub("spool",     "JES spool browser","ti-list",       "#4db84d", "#fff");
registerStub("console",   "MVS console",      "ti-terminal-2", "#1a1a1a", "#33ff33");
registerStub("rexx",      "REXX workbench",   "ti-code",       "#b84d4d", "#fff");
registerStub("jobsubmit", "Job submit",       "ti-upload",     "#8855bb", "#fff");
registerStub("localfiles","Local files",      "ti-files",      "#dd8833", "#fff");
