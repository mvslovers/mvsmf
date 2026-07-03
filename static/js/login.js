/* ============================================================
   login.js — login screen + auth flow
   System selector, live /zosmf/info connection check (401 = still
   reachable, no-cors fallback), authenticated login, demo mode,
   inline "Manage systems…" add, logout. On success it enters the
   desktop and opens the Welcome window.
   ============================================================ */
import { Session, SystemRegistry, checkSystem } from "./systems.js";
import { WM } from "./wm.js";
import { Programs } from "./programs/registry.js";

export const Login = (() => {
  const layer = () => document.getElementById("login-layer");
  const sel = () => document.getElementById("login-system");
  let checkSeq = 0;

  function refreshSystems() {
    const s = sel();
    const current = s.value;
    s.innerHTML = "";
    SystemRegistry.list().forEach(sys => {
      const o = document.createElement("option");
      o.value = sys.name;
      o.textContent = `${sys.name} — ${sys.host}:${sys.port}` + (sys.local ? " (local)" : "");
      s.appendChild(o);
    });
    const def = SystemRegistry.load().defaultSystem;
    s.value = current && [...s.options].some(o => o.value === current) ? current : def;
  }

  function setStatus(cls, ledColor, text) {
    const st = document.getElementById("login-status");
    st.className = cls;
    st.querySelector(".led").style.background = ledColor;
    document.getElementById("login-status-text").textContent = text;
  }

  async function checkSelected() {
    const mySeq = ++checkSeq;
    const sys = SystemRegistry.get(sel().value);
    if (!sys) { setStatus("warn", "var(--wps-led-yellow)", "No systems configured — use Manage systems…"); return; }
    setStatus("wait", "var(--wps-led-off)", `Checking ${sys.name} …`);
    const res = await checkSystem(sys);
    if (mySeq !== checkSeq) return;   // stale response, selection changed
    // Green whenever the endpoint is reachable at all; only "unreachable"
    // is red. The distinct texts keep the detail the LED no longer encodes.
    if (res.status === "connected") {
      const ver = res.info && (res.info.zos_version || res.info.zosmf_full_version);
      setStatus("ok", "var(--wps-led-green)", `Connected${ver ? " — " + ver : ""}`);
    } else if (res.status === "auth_failed") {
      setStatus("ok", "var(--wps-led-green)", "Connected — login required");
    } else if (res.status === "cors_blocked") {
      setStatus("ok", "var(--wps-led-green)", "Connected — cross-origin (CORS pending)");
    } else if (res.status === "unreachable") {
      setStatus("bad", "var(--wps-led-red)", "Unreachable — check host and port");
    } else {
      // reachable, but /zosmf/info returned an unexpected HTTP status
      setStatus("ok", "var(--wps-led-green)", `Reachable — HTTP ${res.code || "?"}`);
    }
  }

  async function submit() {
    const sys = SystemRegistry.get(sel().value);
    const user = document.getElementById("login-user").value.trim();
    const pass = document.getElementById("login-pass").value;
    if (!sys) return;
    if (!user) { setStatus("warn", "var(--wps-led-yellow)", "Enter a username"); return; }

    setStatus("wait", "var(--wps-led-off)", "Authenticating …");
    const res = await checkSystem(sys, { user, pass });
    if (res.status === "connected") {
      Session.system = sys;
      Session.user = user.toUpperCase();
      Session.pass = pass;
      Session.demo = false;
      const d = SystemRegistry.load();
      d.defaultSystem = sys.name;
      SystemRegistry.save(d);
      enterDesktop();
    } else if (res.status === "auth_failed") {
      setStatus("bad", "var(--wps-led-red)", "Login failed — check credentials");
    } else if (res.status === "cors_blocked") {
      // reachable, but cross-origin blocks reading the auth response
      setStatus("ok", "var(--wps-led-green)", "Connected — cross-origin (CORS pending); serve from the HTTPD or use demo mode");
    } else {
      setStatus("bad", "var(--wps-led-red)", "System unreachable");
    }
  }

  function demoLogin() {
    Session.system = null;
    Session.user = "DEMO";
    Session.pass = "";
    Session.demo = true;
    enterDesktop();
  }

  function enterDesktop() {
    layer().style.display = "none";
    document.getElementById("desktop").style.display = "block";
    document.getElementById("taskbar").style.display = "flex";
    document.getElementById("tray-sys").textContent = Session.demo ? "DEMO" : Session.system.name;
    document.getElementById("tray-user").textContent = Session.user;
    document.getElementById("tray-led").style.background =
      Session.demo ? "var(--wps-led-yellow)" : "var(--wps-led-green)";
    // greet with the welcome window on first entry
    WM.open(Programs.get("welcome"));
  }

  function logout() {
    // close everything by reloading state — simplest clean slate
    location.reload();
  }

  function init() {
    refreshSystems();
    checkSelected();
    sel().addEventListener("change", checkSelected);
    document.getElementById("login-submit").addEventListener("click", submit);
    document.getElementById("login-pass").addEventListener("keydown", e => { if (e.key === "Enter") submit(); });
    document.getElementById("login-user").addEventListener("keydown", e => { if (e.key === "Enter") document.getElementById("login-pass").focus(); });
    document.getElementById("login-cancel").addEventListener("click", () => {
      document.getElementById("login-user").value = "";
      document.getElementById("login-pass").value = "";
    });
    document.getElementById("login-demo").addEventListener("click", demoLogin);
    document.getElementById("login-manage").addEventListener("click", () => {
      // Phase 1: quick inline prompt-based add; the Systems program
      // offers full management once logged in.
      const name = prompt("System name (e.g. MVSD):");
      if (!name) return;
      const host = prompt("Host or IP:");
      if (!host) return;
      const port = parseInt(prompt("Port:", "1080") || "1080", 10);
      SystemRegistry.add({ name: name.toUpperCase(), host, port });
      refreshSystems();
      checkSelected();
    });
  }

  return { init, refreshSystems, logout };
})();
