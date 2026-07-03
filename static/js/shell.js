/* ============================================================
   shell.js — boot + glue
   Entry point loaded by index.html as an ES module (implicitly
   deferred, so the DOM is ready when this runs). It:
     - imports every program module for its self-registration
     - applies the persisted theme
     - derives the local system from the page origin
     - builds the desktop icons + start menu
     - starts the tray clock and initialises the login screen

   To add a Phase 2 program, drop js/programs/<id>.js next to the
   others (copy _template.js) and add one import line below.
   ============================================================ */
import { Theme, SystemRegistry } from "./systems.js";
import { Programs } from "./programs/registry.js";
import { WM } from "./wm.js";
import { StartMenu } from "./startmenu.js";
import { Login } from "./login.js";

/* Program modules — imported for their Programs.register() side effect.
   Order here is the registration order (desktop icons + start menu). */
import "./programs/welcome.js";
import "./programs/sysinfo.js";
import "./programs/systems.js";
import "./programs/about.js";
import "./programs/datasets.js";
import "./programs/stubs.js";

/* ---------- Desktop icons ---------- */
function buildDesktopIcons() {
  const host = document.getElementById("desktop-icons");
  host.innerHTML = "";
  Programs.all().filter(p => p.desktopIcon).forEach(p => {
    const ic = document.createElement("div");
    ic.className = "desk-icon";
    ic.innerHTML = `
      <div class="box" style="background:${p.iconBg};">
        <i class="ti ${p.icon}" style="color:${p.iconColor};"></i>
      </div>
      <span class="label">${p.name}</span>`;
    ic.addEventListener("click", () => {
      document.querySelectorAll(".desk-icon.selected").forEach(x => x.classList.remove("selected"));
      ic.classList.add("selected");
    });
    ic.addEventListener("dblclick", () => WM.open(p));
    host.appendChild(ic);
  });
  // click on empty desktop clears selection
  document.getElementById("desktop").addEventListener("pointerdown", ev => {
    if (ev.target.id === "desktop")
      document.querySelectorAll(".desk-icon.selected").forEach(x => x.classList.remove("selected"));
  });
}

/* ---------- Tray clock (updates once a second) ---------- */
setInterval(() => {
  const el = document.getElementById("tray-clock");
  if (el) el.textContent = new Date().toTimeString().slice(0, 8);
}, 1000);

/* ---------- Tray system name → open systems manager ---------- */
document.getElementById("tray-sys").addEventListener("click", () => {
  WM.open(Programs.get("systems"));
});

/* ---------- Boot ---------- */
Theme.apply();                  // data-theme on <html> from SafeStore (default "os2")
SystemRegistry.ensureLocal();   // page origin = default system when served from the HTTPD
buildDesktopIcons();
StartMenu.build();
Login.init();
