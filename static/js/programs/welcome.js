/* ============================================================
   welcome.js — greeting window opened on first desktop entry.
   Pure presentation; a good minimal example of the plugin API.
   ============================================================ */
import { Programs } from "./registry.js";

Programs.register({
  id: "welcome",
  name: "Welcome",
  icon: "ti-home",
  iconBg: "#1084d0", iconColor: "#fff",
  defaultWidth: 460, defaultHeight: 330,
  desktopIcon: true,
  create(ctx) {
    const d = document.createElement("div");
    d.className = "prog-pad";
    d.innerHTML = `
      <h1>Welcome to mvsMF Desktop</h1>
      <p>A browser desktop for MVS 3.8j: window manager, taskbar,
      start menu, login — and the first real program, the
      <b>Dataset browser</b>.</p>
      <p>Try it out:</p>
      <p>• Open the <b>Dataset browser</b> and list your datasets<br>
         • Browse the qualifier tree, open a member — JCL, HLASM,
           C and REXX are syntax-highlighted<br>
         • Edit a member: line numbers, block cursor, save via PUT<br>
         • Drag, resize, maximize and minimize windows as you like</p>
      <p>Programs are plugins — each one registers with
      <code>Programs.register({...})</code> and receives a system context
      with an authenticated <code>apiFetch()</code>. More programs
      (spool browser, console, REXX workbench) follow in Phase 2.</p>
      <p style="color:var(--wps-text-faint);">Connected to <code>${ctx.system.name}</code>
      as <code>${ctx.system.user || "demo"}</code>.</p>`;
    return d;
  }
});
