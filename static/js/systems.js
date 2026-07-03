/* ============================================================
   systems.js — persistence, theme, system registry, session
   Leaf module: imports nothing from the shell, so every other
   module can import from here without a cycle.
   Exports: SafeStore, Theme, SystemRegistry, checkSystem, Session
   ============================================================ */

/* ---------- SafeStore: localStorage with in-memory fallback ----------
   Sandboxed previews may block localStorage; a real deployment
   on the HTTPD UFS uses it normally. */
export const SafeStore = (() => {
  let mem = {};
  let ok = false;
  try { localStorage.setItem("__t", "1"); localStorage.removeItem("__t"); ok = true; } catch (e) { ok = false; }
  return {
    get(key, fallback) {
      try {
        const raw = ok ? localStorage.getItem(key) : mem[key];
        return raw ? JSON.parse(raw) : fallback;
      } catch (e) { return fallback; }
    },
    set(key, value) {
      const raw = JSON.stringify(value);
      if (ok) { try { localStorage.setItem(key, raw); } catch (e) {} }
      mem[key] = raw;
    }
  };
})();

/* ---------- Theme: data-theme on <html>, persisted ----------
   Only the default "os2" theme ships in Phase 1; the mechanism
   (attribute + persistence) is what Phase 2 themes build on. */
export const Theme = {
  KEY: "mvsmf.theme",
  DEFAULT: "os2",
  get() { return SafeStore.get(this.KEY, this.DEFAULT); },
  set(name) {
    SafeStore.set(this.KEY, name);
    document.documentElement.setAttribute("data-theme", name);
  },
  /* Apply the stored (or default) theme to <html> on boot. */
  apply() {
    document.documentElement.setAttribute("data-theme", this.get());
  }
};

/* ---------- System registry ---------- */
export const SystemRegistry = {
  KEY: "mvsmf.systems",
  defaults: { systems: [], defaultSystem: null },
  load() { return SafeStore.get(this.KEY, this.defaults); },
  save(data) { SafeStore.set(this.KEY, data); },
  list() { return this.load().systems; },
  get(name) { return this.list().find(s => s.name === name); },
  add(sys) {
    const d = this.load();
    d.systems = d.systems.filter(s => s.name !== sys.name);
    d.systems.push(sys);
    this.save(d);
  },
  remove(name) {
    const d = this.load();
    d.systems = d.systems.filter(s => s.name !== name);
    this.save(d);
  },
  baseUrl(sys) {
    // local system follows the page protocol (works behind a TLS proxy);
    // remote MVS 3.8j systems are plain http
    const proto = sys.local ? location.protocol : "http:";
    return `${proto}//${sys.host}:${sys.port}`;
  },
  /* Derive the "local" system from the URL this page was served from.
     When the desktop is deployed on the HTTPD UFS, that host IS the
     default mvsMF system — no manual configuration needed. */
  ensureLocal() {
    if (!/^https?:$/.test(location.protocol) || !location.hostname) return null;
    const host = location.hostname;
    const port = location.port ? parseInt(location.port, 10)
                               : (location.protocol === "https:" ? 443 : 80);
    const d = this.load();
    let sys = d.systems.find(s => s.host === host && s.port === port);
    if (!sys) {
      // derive a system name from the first hostname label,
      // e.g. MVSDEV from mvsdev.lan (max 8 chars, mainframe style)
      let name = host.split(".")[0].toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 8) || "LOCAL";
      if (d.systems.some(s => s.name === name)) name = "LOCAL";
      sys = { name, host, port, local: true };
      d.systems.unshift(sys);
    } else {
      sys.local = true;
    }
    d.systems.forEach(s => { if (s !== sys) delete s.local; });
    d.defaultSystem = sys.name;
    this.save(d);
    return sys;
  }
};

/* ---------- Connection check via /zosmf/info ---------- */
export async function checkSystem(sys, auth) {
  // auth: optional {user, pass} to verify credentials
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 4000);
  try {
    // Anonymous probe stays a "simple request" (no custom headers) so it
    // avoids a CORS preflight; authenticated checks send the full headers.
    const headers = {};
    if (auth) {
      headers["Authorization"] = "Basic " + btoa(auth.user + ":" + auth.pass);
      headers["X-CSRF-ZOSMF-HEADER"] = "true";
    }
    const resp = await fetch(SystemRegistry.baseUrl(sys) + "/zosmf/info", { headers, signal: ctl.signal });
    clearTimeout(timer);
    if (resp.ok) {
      let info = null;
      try { info = await resp.json(); } catch (e) {}
      return { status: "connected", info };
    }
    if (resp.status === 401 || resp.status === 403) return { status: "auth_failed" };
    return { status: "error", code: resp.status };
  } catch (e) {
    clearTimeout(timer);
    // Fetch failed — either the host is down or the browser blocked the
    // response (missing CORS headers on a cross-origin request). An
    // opaque no-cors probe still resolves when the host is reachable.
    try {
      const ctl2 = new AbortController();
      const t2 = setTimeout(() => ctl2.abort(), 4000);
      await fetch(SystemRegistry.baseUrl(sys) + "/zosmf/info", { mode: "no-cors", signal: ctl2.signal });
      clearTimeout(t2);
      return { status: "cors_blocked" };
    } catch (e2) {
      return { status: "unreachable" };
    }
  }
}

/* ---------- Session (current login) ---------- */
export const Session = {
  system: null,     // system object from registry
  user: null,
  pass: null,
  demo: false,
  /* Build a system context handed to every program window. */
  contextFor(systemName) {
    const sys = systemName ? SystemRegistry.get(systemName) : this.system;
    const self = this;
    return {
      name: sys ? sys.name : (self.demo ? "DEMO" : "?"),
      host: sys ? sys.host : "demo.local",
      port: sys ? sys.port : 0,
      baseUrl: sys ? SystemRegistry.baseUrl(sys) : "",
      user: self.user,
      demo: self.demo,
      async apiFetch(path, options = {}) {
        if (self.demo) throw new Error("demo mode: no backend");
        options.headers = Object.assign({
          "Authorization": "Basic " + btoa(self.user + ":" + self.pass),
          "X-CSRF-ZOSMF-HEADER": "true"
        }, options.headers || {});
        return fetch(this.baseUrl + path, options);
      }
    };
  }
};
