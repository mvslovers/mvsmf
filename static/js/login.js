/* ============================================================
   login.js — login screen + auth flow
   System selector, token login (POST once to
   /zosmf/services/authenticate — the password is never stored),
   demo mode, real server-side logout. On success it enters the
   desktop and opens the Welcome window. A live session (LtpaToken2
   cookie) is restored across a reload; a 401 from any API call
   returns to the login screen.

   No pre-login reachability probe: the local system IS this page's
   origin (so it is online by definition), and remote systems don't
   work yet (CORS) — a failed login just reports the error.
   ============================================================ */
import { Session, SystemRegistry, authenticate, SafeStore } from "./systems.js";
import { WM } from "./wm.js";
import { Programs } from "./programs/registry.js";

export const Login = (() => {
  const layer = () => document.getElementById("login-layer");
  const sel = () => document.getElementById("login-system");

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

  /* Neutral idle status — no live probe; just name the login target. */
  function idleStatus() {
    const sys = SystemRegistry.get(sel().value);
    setStatus("wait", "var(--wps-led-off)",
      sys ? `Ready — sign in to ${sys.name}` : "No system — use Demo mode");
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
      // fetch rejected. The local system is this page's origin, so this means
      // the server is down; a remote system fails the cross-origin login (CORS
      // is not supported yet) — report whichever applies.
      setStatus("bad", "var(--wps-led-red)", sys.local
        ? "System unreachable — is the server up?"
        : "Remote systems are not supported yet (CORS) — use the local system or Demo mode");
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
    sel().addEventListener("change", idleStatus);
    document.getElementById("login-submit").addEventListener("click", submit);
    document.getElementById("login-pass").addEventListener("keydown", e => { if (e.key === "Enter") submit(); });
    document.getElementById("login-user").addEventListener("keydown", e => { if (e.key === "Enter") document.getElementById("login-pass").focus(); });
    document.getElementById("login-cancel").addEventListener("click", () => {
      document.getElementById("login-user").value = "";
      document.getElementById("login-pass").value = "";
    });
    document.getElementById("login-demo").addEventListener("click", demoLogin);

    // A prior session-expiry (or logout) may have left a one-shot notice.
    const notice = SafeStore.get("mvsmf.notice", null);
    if (notice) SafeStore.set("mvsmf.notice", null);

    // Restore a live session across a reload: the LtpaToken2 cookie survives,
    // so a valid session skips the login screen entirely.
    if (Session.restore()) { enterDesktop(); return; }

    // No session to restore — reveal the login screen (hidden by default in
    // the markup so a restored session never flashes it first).
    layer().style.display = "flex";
    if (notice) setStatus("warn", "var(--wps-led-yellow)", notice);
    else idleStatus();
  }

  return { init, refreshSystems, logout };
})();
