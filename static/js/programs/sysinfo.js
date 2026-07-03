/* ============================================================
   sysinfo.js — first program that actually talks to mvsMF.
   Fetches /zosmf/info via ctx.system.apiFetch and pretty-prints
   it. In demo mode apiFetch throws, so it shows canned data —
   the pattern every real Phase 2 program follows.
   ============================================================ */
import { Programs } from "./registry.js";

Programs.register({
  id: "sysinfo",
  name: "System info",
  icon: "ti-info-circle",
  iconBg: "#4db84d", iconColor: "#fff",
  defaultWidth: 480, defaultHeight: 340,
  desktopIcon: true,
  statusBar: true,
  toolbar: [
    { label: "Refresh", icon: "ti-refresh", onClick(ctx) { ctx._load && ctx._load(); } }
  ],
  create(ctx) {
    const d = document.createElement("div");
    d.className = "prog-mono";
    d.textContent = "Loading /zosmf/info …";

    ctx._load = async () => {
      ctx.setStatus("GET /zosmf/info …");
      if (ctx.system.demo) {
        // canned response so the shell can be explored without a backend
        d.textContent = JSON.stringify({
          zosmf_saf_realm: "SAFRealm",
          zosmf_port: "1080",
          zosmf_full_version: "2.0.0",
          api_version: "1",
          zos_version: "MVS 3.8j",
          zosmf_hostname: "demo.local",
          note: "demo mode — canned data, no backend call"
        }, null, 2);
        ctx.setStatus("Demo mode — canned data");
        return;
      }
      try {
        const resp = await ctx.system.apiFetch("/zosmf/info");
        const body = await resp.text();
        try { d.textContent = JSON.stringify(JSON.parse(body), null, 2); }
        catch (e) { d.textContent = body; }
        ctx.setStatus(`HTTP ${resp.status} — ${ctx.system.baseUrl}/zosmf/info`);
      } catch (e) {
        d.textContent = "Request failed: " + e.message;
        ctx.setStatus("Request failed");
      }
    };
    ctx._load();
    return d;
  }
});
