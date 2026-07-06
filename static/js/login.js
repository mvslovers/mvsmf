/* ============================================================
   login.js — login screen + auth flow
   System selector, live /zosmf/info connection check (401 = still
   reachable, no-cors fallback), token login (POST once to
   /zosmf/services/authenticate — the password is never stored),
   demo mode, inline "Manage systems…" add, real server-side logout.
   On success it enters the desktop and opens the Welcome window.
   A live session (LtpaToken2 cookie) is restored across a reload;
   a 401 from any API call returns to the login screen.
   ============================================================ */
import { Session, SystemRegistry, checkSystem, authenticate, SafeStore } from "./systems.js";
import { WM } from "./wm.js";
import { Programs } from "./programs/registry.js";
import { Dialog } from "./dialog.js";

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
    // POST the credentials once to /zosmf/services/authenticate; on success the
    // browser holds the LtpaToken2 cookie and the password is never stored.
    const res = await authenticate(sys, { user, pass });
    if (res.status === "ok") {
      Session.system = sys;
      Session.user = user.toUpperCase();
      Session.demo = false;
      Session.save();
      const d = SystemRegistry.load();
      d.defaultSystem = sys.name;
      SystemRegistry.save(d);
      enterDesktop();
    } else if (res.status === "auth_failed") {
      setStatus("bad", "var(--wps-led-red)", "Login failed — check credentials");
    } else {
      // fetch rejected — host unreachable, or a cross-origin login blocked by
      // CORS (the token flow is same-origin: serve the SPA from the HTTPD).
      setStatus("bad", "var(--wps-led-red)", "System unreachable (serve the SPA from the HTTPD, or use demo mode)");
    }
  }

  function demoLogin() {
    Session.system = null;
    Session.user = "DEMO";
    Session.demo = true;
    Session.save();
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

  async function logout() {
    // real server-side logout (DELETE the token), then reload for a clean slate
    await Session.logout();
    location.reload();
  }

  // A 401 from any API call means the token expired or was reaped by the HTTPD
  // (idle SESSION_TIMEOUT, default 30 min). Drop the stored session so the
  // reload boots to the login screen — not straight back into a dead desktop —
  // and leave a one-shot notice to explain why. The guard collapses the burst
  // of 401s that concurrent requests produce into a single teardown.
  let tearingDown = false;
  function onSessionExpired() {
    if (tearingDown) return;
    tearingDown = true;
    Session.clearStored();
    SafeStore.set("mvsmf.notice", "Session expired — please log in again");
    location.reload();
  }

  function init() {
    refreshSystems();
    window.addEventListener("mvsmf:session-expired", onSessionExpired);
    sel().addEventListener("change", checkSelected);
    document.getElementById("login-submit").addEventListener("click", submit);
    document.getElementById("login-pass").addEventListener("keydown", e => { if (e.key === "Enter") submit(); });
    document.getElementById("login-user").addEventListener("keydown", e => { if (e.key === "Enter") document.getElementById("login-pass").focus(); });
    document.getElementById("login-cancel").addEventListener("click", () => {
      document.getElementById("login-user").value = "";
      document.getElementById("login-pass").value = "";
    });
    document.getElementById("login-demo").addEventListener("click", demoLogin);
    document.getElementById("login-manage").addEventListener("click", async () => {
      // quick add from the login screen; the Systems program offers
      // full management once logged in
      const r = await Dialog.show({
        title: "Add system", icon: "ti-server", okLabel: "Add",
        fields: [
          { key: "name", label: "System name", maxLength: 8, upper: true, placeholder: "MVSD" },
          { key: "host", label: "Host or IP", placeholder: "mvs.example.lan" },
          { key: "port", label: "Port", value: "1080", maxLength: 5 }
        ]
      });
      if (!r || !r.name || !r.host) return;
      SystemRegistry.add({ name: r.name, host: r.host, port: parseInt(r.port || "1080", 10) });
      refreshSystems();
      checkSelected();
    });

    // A prior session-expiry (or logout) may have left a one-shot notice.
    const notice = SafeStore.get("mvsmf.notice", null);
    if (notice) SafeStore.set("mvsmf.notice", null);

    // Restore a live session across a reload: the LtpaToken2 cookie survives,
    // so a valid session skips the login screen entirely.
    if (Session.restore()) { enterDesktop(); return; }

    if (notice) setStatus("warn", "var(--wps-led-yellow)", notice);
    else checkSelected();
  }

  return { init, refreshSystems, logout };
})();
