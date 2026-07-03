/* ============================================================
   about.js — the About window (opened from the start menu).
   Not shown as a desktop icon and excluded from the start-menu
   program list (it has its own menu entry).
   ============================================================ */
import { Programs } from "./registry.js";

Programs.register({
  id: "about",
  name: "About",
  icon: "ti-info-circle",
  iconBg: "#666", iconColor: "#fff",
  defaultWidth: 380, defaultHeight: 260,
  desktopIcon: false,
  create() {
    const d = document.createElement("div");
    d.className = "prog-pad";
    d.innerHTML = `
      <div style="display:flex;align-items:center;gap:10px;margin-bottom:12px;">
        <div style="width:40px;height:40px;border-radius:4px;background:var(--wps-logo-gradient);display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:500;color:var(--wps-title-text);">M</div>
        <div><div style="font-size:15px;font-weight:500;">mvsMF Desktop</div>
        <div style="color:var(--wps-text-faint);font-size:11px;">Version 2.0.0-alpha1 — Phase 1 shell</div></div>
      </div>
      <p>A browser desktop for MVS 3.8j, inspired by the OS/2 Workplace Shell.</p>
      <p>Backend: <code>mvsMF</code> (z/OSMF-compatible REST API),
      <code>httprexx</code>, <code>httpjes</code> on <code>HTTPD</code>.</p>
      <p style="color:var(--wps-text-faint);">mvslovers — running modern APIs on 1981 iron.</p>`;
    return d;
  }
});
