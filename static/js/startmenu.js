/* ============================================================
   startmenu.js — Start menu + systems submenu
   Program list (opens windows), Systems submenu with a live LED
   per configured system, Settings / About / Logout. Closes on
   outside click.
   ============================================================ */
import { Programs } from "./programs/registry.js";
import { WM } from "./wm.js";
import { SystemRegistry, checkSystem } from "./systems.js";
import { Login } from "./login.js";

export const StartMenu = (() => {
  const menu = () => document.getElementById("startmenu");
  const btn = () => document.getElementById("start-btn");
  const submenu = () => document.getElementById("sys-submenu");

  function build() {
    const host = document.getElementById("sm-programs");
    host.innerHTML = "";
    Programs.all().filter(p => p.id !== "about").forEach(p => {
      const item = document.createElement("div");
      item.className = "sm-item";
      item.innerHTML = `
        <span class="pico" style="background:${p.iconBg};">
          <i class="ti ${p.icon}" style="color:${p.iconColor};"></i>
        </span>${p.name}`;
      item.addEventListener("click", () => { hide(); WM.open(p); });
      host.appendChild(item);
    });

    document.getElementById("sm-systems").addEventListener("click", ev => {
      ev.stopPropagation();
      toggleSubmenu();
    });
    document.getElementById("sm-settings").addEventListener("click", () => {
      hide();
      WM.open(Programs.get("systems"));   // settings = systems manager for now
    });
    document.getElementById("sm-about").addEventListener("click", () => {
      hide(); WM.open(Programs.get("about"));
    });
    document.getElementById("sm-logout").addEventListener("click", () => {
      hide(); Login.logout();
    });

    btn().addEventListener("click", ev => { ev.stopPropagation(); toggle(); });
    document.addEventListener("pointerdown", ev => {
      if (!menu().contains(ev.target) && !btn().contains(ev.target) && !submenu().contains(ev.target)) hide();
    });
  }

  function refreshSystems() {
    const sm = submenu();
    sm.innerHTML = "";
    SystemRegistry.list().forEach(s => {
      const item = document.createElement("div");
      item.className = "sm-item";
      item.innerHTML = `
        <span class="led" style="background:var(--wps-led-off);"></span>
        <span class="mono">${s.name}</span>
        <span class="hostinfo">${s.host}:${s.port}</span>`;
      item.addEventListener("click", () => {
        hideSubmenu(); hide();
        // Phase 1: open the systems manager focused on that system
        WM.open(Programs.get("systems"));
      });
      sm.appendChild(item);
      checkSystem(s).then(res => {
        item.querySelector(".led").style.background =
          res.status === "connected" ? "var(--wps-led-green)" :
          (res.status === "auth_failed" || res.status === "cors_blocked") ? "var(--wps-led-yellow)" : "var(--wps-led-red)";
      });
    });
    const manage = document.createElement("div");
    manage.className = "sm-item";
    manage.innerHTML = `<span class="gico"><i class="ti ti-settings"></i></span>Manage systems…`;
    manage.addEventListener("click", () => { hideSubmenu(); hide(); WM.open(Programs.get("systems")); });
    sm.appendChild(manage);
  }

  function toggleSubmenu() {
    const sm = submenu();
    if (sm.classList.contains("open")) { hideSubmenu(); return; }
    refreshSystems();
    const anchor = document.getElementById("sm-systems").getBoundingClientRect();
    sm.style.left = (anchor.right + 2) + "px";
    sm.style.top = Math.max(4, anchor.top - 4) + "px";
    sm.style.bottom = "auto";
    sm.classList.add("open");
  }
  function hideSubmenu() { submenu().classList.remove("open"); }
  function show() { menu().classList.add("open"); btn().classList.add("open"); }
  function hide() { menu().classList.remove("open"); btn().classList.remove("open"); hideSubmenu(); }
  function toggle() { menu().classList.contains("open") ? hide() : show(); }

  return { build, refreshSystems, hide };
})();
