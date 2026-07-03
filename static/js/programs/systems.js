/* ============================================================
   systems.js (program) — systems manager window.
   Lists configured systems with a live connection LED, lets you
   add/remove remotes, and keeps the login dropdown + start-menu
   submenu in sync. The origin-derived local system is read-only.
   ============================================================ */
import { Programs } from "./registry.js";
import { SystemRegistry, checkSystem } from "../systems.js";
import { Login } from "../login.js";
import { StartMenu } from "../startmenu.js";

Programs.register({
  id: "systems",
  name: "Systems",
  icon: "ti-server",
  iconBg: "#888880", iconColor: "#fff",
  defaultWidth: 460, defaultHeight: 320,
  desktopIcon: false,
  statusBar: true,
  create(ctx) {
    const wrap = document.createElement("div");
    wrap.style.cssText = "display:flex;flex-direction:column;height:100%;";
    const listEl = document.createElement("div");
    listEl.style.cssText = "flex:1;overflow:auto;";
    wrap.appendChild(listEl);

    const addBar = document.createElement("div");
    addBar.className = "sys-add";
    addBar.innerHTML = `
      <input class="in-name" placeholder="NAME" maxlength="8">
      <input class="in-host" placeholder="host / IP">
      <input class="in-port" placeholder="1080" maxlength="5">
      <button class="lb-btn" style="padding:2px 10px;">Add</button>`;
    wrap.appendChild(addBar);

    async function render() {
      const systems = SystemRegistry.list();
      listEl.innerHTML = "";
      ctx.setStatus(`${systems.length} system(s) configured`);
      for (const s of systems) {
        const row = document.createElement("div");
        row.className = "sys-row";
        row.innerHTML = `
          <span class="led" style="background:var(--wps-led-off);"></span>
          <span class="name">${s.name}${s.local ? ' <span class="tag">(local)</span>' : ""}</span>
          <span class="host">${s.host}:${s.port}</span>
          <span class="stat">checking…</span>
          ${s.local ? "" : '<span class="rm" title="Remove"><i class="ti ti-trash"></i></span>'}`;
        const rm = row.querySelector(".rm");
        if (rm) rm.addEventListener("click", () => {
          SystemRegistry.remove(s.name);
          render();
        });
        listEl.appendChild(row);
        // async status check per system
        checkSystem(s).then(res => {
          const led = row.querySelector(".led");
          const stat = row.querySelector(".stat");
          if (res.status === "connected") { led.style.background = "var(--wps-led-green)"; stat.textContent = "connected"; }
          else if (res.status === "auth_failed") { led.style.background = "var(--wps-led-yellow)"; stat.textContent = "auth required"; }
          else if (res.status === "cors_blocked") { led.style.background = "var(--wps-led-yellow)"; stat.textContent = "cors blocked"; }
          else { led.style.background = "var(--wps-led-red)"; stat.textContent = res.status; }
        });
      }
    }

    addBar.querySelector("button").addEventListener("click", () => {
      const name = addBar.querySelector(".in-name").value.trim().toUpperCase();
      const host = addBar.querySelector(".in-host").value.trim();
      const port = parseInt(addBar.querySelector(".in-port").value.trim() || "1080", 10);
      if (!name || !host) return;
      SystemRegistry.add({ name, host, port });
      addBar.querySelectorAll("input").forEach(i => i.value = "");
      render();
      Login.refreshSystems();   // keep login dropdown in sync
      StartMenu.refreshSystems();
    });

    render();
    return wrap;
  }
});
