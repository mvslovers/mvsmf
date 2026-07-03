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
      <p>This is the <b>Phase 1 shell prototype</b>: window manager,
      taskbar, start menu, login and the program plugin API.</p>
      <p>Try it out:</p>
      <p>• Drag windows by their title bar<br>
         • Resize from any edge or corner<br>
         • Double-click the title bar to maximize<br>
         • Minimize to the taskbar and bring windows back<br>
         • Open several windows and watch the z-order</p>
      <p>Programs are plugins — each one registers with
      <code>Programs.register({...})</code> and receives a system context
      with an authenticated <code>apiFetch()</code>.</p>
      <p style="color:var(--wps-text-faint);">Connected to <code>${ctx.system.name}</code>
      as <code>${ctx.system.user || "demo"}</code>.</p>`;
    return d;
  }
});
