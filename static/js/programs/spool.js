/* ============================================================
   spool.js — JES spool browser (Desktop Phase 2.2)

   Split view: filter bar (prefix/owner/status) → job tree (left,
   lazy DD loading per job expand) → spool output panel (right).
   Reuses the dataset browser's tree classes (.dsb-node etc.).

   API (all via ctx.system.apiFetch, see docs/endpoints/jobs/):
     GET    /zosmf/restjobs/jobs?prefix=&owner=&status=   list (JSON array)
     GET    .../jobs/{name}/{id}/files                    DD list (JSON array)
     GET    .../jobs/{name}/{id}/files/{ddid}/records     output (text/plain)
     DELETE .../jobs/{name}/{id}                          purge

   Notes validated against the backend docs:
   - retcode may be null for completed jobs (MVS 3.8j NOTIFY quirk) —
     shown dimmed as "-".
   - No record-range paging in the API: the full output is fetched
     once, but RENDERING is capped and extended via "Load more" so a
     huge SYSPRINT cannot freeze the window.
   - Auto-refresh (5s) re-lists jobs/statuses only and preserves tree
     expansion + selection; the open output is never touched (manual
     "Reload output" instead).
   - Purge is the only cancel-style action (server refuses active
     STC/TSU); confirmation dialog, extra confirm for ACTIVE jobs.
   ============================================================ */
import { Programs } from "./registry.js";
import { Dialog } from "../dialog.js";

const RENDER_CHUNK = 2000;   // lines rendered initially / per "Load more"

/* ---------- demo-mode canned data ---------- */
const DEMO_JOBS = [
  { jobname: "TSTCOMP", jobid: "JOB00101", owner: "IBMUSER", type: "JOB",
    class: "A", status: "OUTPUT", retcode: "CC 0000" },
  { jobname: "TSTASM",  jobid: "JOB00102", owner: "IBMUSER", type: "JOB",
    class: "A", status: "OUTPUT", retcode: "ABEND S0C4" },
  { jobname: "TSTNTFY", jobid: "JOB00103", owner: "IBMUSER", type: "JOB",
    class: "A", status: "OUTPUT", retcode: null },
  { jobname: "HTTPD",   jobid: "STC00042", owner: "IBMUSER", type: "STC",
    class: "S", status: "ACTIVE", retcode: null }
];
const DEMO_FILES = {
  "TSTCOMP/JOB00101": [
    { id: 2, ddname: "JESMSGLG", stepname: "JES2", procstep: "", "record-count": 4 },
    { id: 3, ddname: "JESJCL",   stepname: "JES2", procstep: "", "record-count": 3 },
    { id: 4, ddname: "SYSPRINT", stepname: "CC",   procstep: "", "record-count": 6 },
    { id: 5, ddname: "SYSUT2",   stepname: "CC",   procstep: "", "record-count": 4500 }
  ],
  "TSTASM/JOB00102": [
    { id: 2, ddname: "JESMSGLG", stepname: "JES2", procstep: "", "record-count": 5 },
    { id: 4, ddname: "SYSPRINT", stepname: "ASM",  procstep: "", "record-count": 7 }
  ],
  "TSTNTFY/JOB00103": [
    { id: 2, ddname: "JESMSGLG", stepname: "JES2", procstep: "", "record-count": 3 }
  ],
  "HTTPD/STC00042": [
    { id: 2, ddname: "JESMSGLG", stepname: "JES2", procstep: "", "record-count": 3 }
  ]
};
const DEMO_RECORDS = {
  "TSTCOMP/JOB00101/2":
    "1                    J E S 2  J O B  L O G\n" +
    "0\n 09.15.01 JOB00101  $HASP373 TSTCOMP  STARTED - INIT  1 - CLASS A\n" +
    " 09.15.02 JOB00101  $HASP395 TSTCOMP  ENDED - RC=0000\n",
  "TSTCOMP/JOB00101/3":
    "1 //TSTCOMP  JOB (ACCT),'COMPILE',CLASS=A,MSGCLASS=H\n" +
    "  //CC       EXEC PGM=CC370\n  //SYSPRINT DD SYSOUT=*\n",
  "TSTCOMP/JOB00101/4":
    "1cc370 (GCC 3.4.6 MVS370)                     page   1\n" +
    "0  source: HELLO.C\n   0 errors, 0 warnings\n" +
    "   text     data      bss      dec  filename\n" +
    "    1234       56        8     1298  hello.o\n" +
    "0compilation complete\n",
  "TSTASM/JOB00102/2":
    "1                    J E S 2  J O B  L O G\n" +
    "0\n 09.20.11 JOB00102  $HASP373 TSTASM   STARTED - INIT  1 - CLASS A\n" +
    " 09.20.12 JOB00102  IEF450I TSTASM ASM - ABEND=S0C4 U0000\n" +
    " 09.20.12 JOB00102  $HASP395 TSTASM   ENDED - ABEND S0C4\n",
  "TSTASM/JOB00102/4":
    "1  ASSEMBLER H  LISTING                                page   1\n" +
    "0  LOC  OBJECT CODE    ADDR1 ADDR2  STMT   SOURCE STATEMENT\n" +
    "   000000                          1      TEST     CSECT\n" +
    "   000000 05C0                     2               BALR  R12,0\n" +
    "   000002                          3               USING *,R12\n" +
    "   000002 0000           00000     4               L     R1,0(,R0)\n" +
    "0  *** ABEND S0C4 AT +000002\n",
  "TSTNTFY/JOB00103/2":
    "1                    J E S 2  J O B  L O G\n" +
    " 09.30.00 JOB00103  $HASP373 TSTNTFY  STARTED\n" +
    " 09.30.01 JOB00103  $HASP395 TSTNTFY  ENDED\n",
  "HTTPD/STC00042/2":
    "1                    J E S 2  J O B  L O G\n" +
    " 08.00.00 STC00042  $HASP373 HTTPD    STARTED\n" +
    " 08.00.01 STC00042  HTTPD001I LISTENING ON PORT 1080\n"
};
// large canned DD so the render cap / "Load more" is demoable offline
{
  let big = "1  SYSUT2 LISTING                               page   1\n";
  for (let i = 1; i <= 4500; i++)
    big += ` ${String(i).padStart(6)}  RECORD ${String(i).padStart(6, "0")}  DATA DATA DATA\n`;
  DEMO_RECORDS["TSTCOMP/JOB00101/5"] = big;
}

/* ---------- helpers ---------- */
function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
}
function jobKey(j) { return j.jobname + "/" + j.jobid; }
function wildcardToRegex(pat) {
  return new RegExp("^" + (pat || "*").toUpperCase()
    .replace(/[.]/g, "\\.").replace(/\*+/g, "[A-Z0-9@#$]*") + "$");
}
/* type icon per job class: JOB / STC / TSU */
function typeIcon(t) {
  return t === "STC" ? "ti-settings-automation"
       : t === "TSU" ? "ti-user"
       : "ti-file-invoice";
}

Programs.register({
  id: "spool",
  name: "JES spool browser",
  icon: "ti-list",
  iconBg: "#4db84d", iconColor: "#fff",
  defaultWidth: 800, defaultHeight: 500,
  minWidth: 560, minHeight: 340,
  desktopIcon: true,
  statusBar: true,

  create(ctx) {
    const sys = ctx.system;
    const st = {
      prefix: "*",
      owner: sys.demo ? "IBMUSER" : (sys.user || "*").toUpperCase(),
      status: "*",
      jobs: [],
      ddCache: new Map(),      // jobKey -> files array
      expanded: new Set(),     // jobKeys with open DD list
      demoJobs: sys.demo ? JSON.parse(JSON.stringify(DEMO_JOBS)) : null,
      sel: null,               // { job, dd } | { job } | null
      outText: "",             // full output of the open DD
      outShown: 0,             // lines currently rendered
      autoTimer: null
    };
    ctx._spl = st;

    /* ---------------- DOM skeleton ---------------- */
    const root = el("div", "dsb-root");

    const bar1 = el("div", "wps-toolbar dsb-bar");
    const prefixIn = el("input", "spl-in");
    prefixIn.value = st.prefix; prefixIn.spellcheck = false;
    const ownerIn = el("input", "spl-in");
    ownerIn.value = st.owner; ownerIn.spellcheck = false;
    const statusSel = document.createElement("select");
    [["*", "all"], ["ACTIVE", "active"], ["OUTPUT", "output"], ["INPUT", "input"]]
      .forEach(([v, label]) => {
        const o = document.createElement("option");
        o.value = v; o.textContent = label;
        statusSel.appendChild(o);
      });
    const listBtn = el("div", "tb-btn", "List");
    bar1.append(el("label", null, "Prefix:"), prefixIn,
                el("label", null, "Owner:"), ownerIn,
                el("label", null, "Status:"), statusSel, listBtn);

    const bar2 = el("div", "wps-toolbar dsb-bar");
    const btn = {};
    [["refresh", "Refresh", "ti-refresh"],
     ["reload",  "Reload output", "ti-rotate"],
     ["purge",   "Purge", "ti-trash"]].forEach(([key, label, icon]) => {
      const b = el("div", "tb-btn");
      b.innerHTML = `<i class="ti ${icon}" style="font-size:13px;"></i>${label}`;
      bar2.appendChild(b);
      btn[key] = b;
    });
    bar2.appendChild(el("div", "tb-spacer"));
    const autoLbl = el("label", "spl-auto");
    const autoCb = document.createElement("input");
    autoCb.type = "checkbox";
    autoLbl.append(autoCb, document.createTextNode(" auto 5s"));
    bar2.appendChild(autoLbl);

    const split = el("div", "dsb-split");
    const treeEl = el("div", "dsb-tree spl-tree");
    const viewEl = el("div", "dsb-view");
    split.append(treeEl, viewEl);
    root.append(bar1, bar2, split);

    /* ---------------- API (demo-aware) ---------------- */
    async function api(path, opts) {
      const resp = await sys.apiFetch(path, opts);
      if (!resp.ok) throw new Error("HTTP " + resp.status);
      return resp;
    }
    async function listJobs() {
      if (sys.demo) {
        const pr = wildcardToRegex(st.prefix);
        const ow = wildcardToRegex(st.owner);
        return st.demoJobs.filter(j =>
          pr.test(j.jobname) && ow.test(j.owner) &&
          (st.status === "*" || j.status === st.status));
      }
      const q = new URLSearchParams();
      if (st.prefix && st.prefix !== "*") q.set("prefix", st.prefix);
      q.set("owner", st.owner || "*");
      if (st.status !== "*") q.set("status", st.status);
      const resp = await api("/zosmf/restjobs/jobs?" + q.toString());
      return resp.json();   // plain JSON array
    }
    async function listFiles(job) {
      const key = jobKey(job);
      if (st.ddCache.has(key)) return st.ddCache.get(key);
      let files;
      if (sys.demo) {
        files = DEMO_FILES[key] || [];
      } else {
        const resp = await api(`/zosmf/restjobs/jobs/${job.jobname}/${job.jobid}/files`);
        files = await resp.json();
      }
      st.ddCache.set(key, files);
      return files;
    }
    async function readRecords(job, dd) {
      if (sys.demo) return DEMO_RECORDS[jobKey(job) + "/" + dd.id] || "";
      const resp = await api(`/zosmf/restjobs/jobs/${job.jobname}/${job.jobid}/files/${dd.id}/records`);
      return resp.text();
    }
    async function purgeJob(job) {
      if (sys.demo) {
        st.demoJobs = st.demoJobs.filter(j => jobKey(j) !== jobKey(job));
        return;
      }
      await api(`/zosmf/restjobs/jobs/${job.jobname}/${job.jobid}`, { method: "DELETE" });
    }

    /* ---------------- tree ---------------- */
    function rcBadge(job) {
      const span = el("span", "spl-rc");
      if (job.status === "ACTIVE" || job.status === "INPUT") {
        span.classList.add("spl-active");
        span.textContent = "●";
        span.title = job.status;
      } else if (!job.retcode) {
        span.classList.add("spl-rc-dim");
        span.textContent = "-";
        span.title = "no retcode (NOTIFY quirk)";
      } else {
        const bad = !/^CC 0000$/.test(job.retcode);
        span.classList.add(bad ? "spl-rc-bad" : "spl-rc-ok");
        span.textContent = job.retcode;
      }
      return span;
    }

    function renderTree() {
      treeEl.innerHTML = "";
      if (!st.jobs.length) {
        treeEl.appendChild(el("div", "dsb-empty", "No jobs — adjust the filter"));
        return;
      }
      st.jobs.forEach(job => {
        const key = jobKey(job);
        const row = el("div", "dsb-node");
        row.dataset.job = key;
        const chev = el("span", "dsb-chev", st.expanded.has(key) ? "▾" : "▸");
        const ico = el("i", "dsb-ico ti " + typeIcon(job.type));
        const label = el("span", "spl-jobname", `${job.jobname}(${job.jobid})`);
        row.append(chev, ico, label, rcBadge(job));
        treeEl.appendChild(row);

        const kidsEl = el("div", "dsb-kids");
        treeEl.appendChild(kidsEl);
        if (st.expanded.has(key)) fillDDs(job, kidsEl);

        row.addEventListener("click", () => {
          st.sel = { job };
          markSelected(row);
          updateButtons();
          if (st.expanded.has(key)) {
            st.expanded.delete(key);
            chev.textContent = "▸";
            kidsEl.innerHTML = "";
          } else {
            st.expanded.add(key);
            chev.textContent = "▾";
            fillDDs(job, kidsEl);
          }
        });
      });
      restoreSelection();
    }

    async function fillDDs(job, kidsEl) {
      kidsEl.innerHTML = "";
      const loading = el("div", "dsb-node spl-dd", "loading…");
      loading.style.paddingLeft = "26px";
      kidsEl.appendChild(loading);
      try {
        const files = await listFiles(job);
        kidsEl.innerHTML = "";
        if (!files.length) {
          const none = el("div", "dsb-node spl-dd", "(no spool files)");
          none.style.paddingLeft = "26px";
          kidsEl.appendChild(none);
        }
        files.forEach(dd => {
          const row = el("div", "dsb-node spl-dd");
          row.style.paddingLeft = "26px";
          row.dataset.dd = jobKey(job) + "/" + dd.id;
          const where = dd.stepname ? ` <span class="spl-step">${dd.stepname}${dd.procstep ? "." + dd.procstep : ""} · ${dd["record-count"]} recs</span>` : "";
          row.innerHTML = `<span class="dsb-chev"></span><i class="dsb-ico ti ti-file-text"></i><span>${dd.ddname}</span>${where}`;
          row.addEventListener("click", ev => {
            ev.stopPropagation();
            openDD(job, dd, row);
          });
          kidsEl.appendChild(row);
        });
        restoreSelection();
      } catch (e) {
        // degrade gracefully: error row, tree stays usable
        kidsEl.innerHTML = "";
        const err = el("div", "dsb-node spl-dd", "error: " + e.message);
        err.style.paddingLeft = "26px";
        kidsEl.appendChild(err);
      }
    }

    function markSelected(row) {
      treeEl.querySelectorAll(".dsb-node.selected").forEach(n => n.classList.remove("selected"));
      if (row) row.classList.add("selected");
    }
    function restoreSelection() {
      if (!st.sel) return;
      const key = st.sel.dd
        ? `[data-dd="${jobKey(st.sel.job)}/${st.sel.dd.id}"]`
        : `[data-job="${jobKey(st.sel.job)}"]`;
      const row = treeEl.querySelector(key);
      if (row) row.classList.add("selected");
    }

    /* ---------------- output panel ---------------- */
    function renderEmpty(msg) {
      viewEl.innerHTML = "";
      viewEl.appendChild(el("div", "dsb-empty", msg || "Select a spool file"));
    }

    // Render capped: huge SYSPRINTs must not freeze the window.
    // The full text is kept in st.outText; "Load more" extends the DOM.
    function renderOutput(reset) {
      if (reset) {
        viewEl.innerHTML = "";
        const pre = el("pre", "spl-out");
        pre.appendChild(el("code"));
        viewEl.appendChild(pre);
        st.outShown = 0;
      }
      const pre = viewEl.querySelector("pre.spl-out");
      const code = pre.querySelector("code");
      const lines = st.outText.split("\n");
      const next = Math.min(lines.length, st.outShown + RENDER_CHUNK);
      code.textContent = lines.slice(0, next).join("\n");
      st.outShown = next;
      const old = viewEl.querySelector(".spl-more");
      if (old) old.remove();
      if (next < lines.length) {
        const more = el("div", "spl-more");
        const b = el("div", "tb-btn", `Load more (${lines.length - next} lines remaining)`);
        b.addEventListener("click", () => renderOutput(false));
        more.appendChild(b);
        viewEl.appendChild(more);
      }
    }

    async function openDD(job, dd, row) {
      st.sel = { job, dd };
      markSelected(row);
      updateButtons();
      renderEmpty("Loading…");
      try {
        st.outText = await readRecords(job, dd);
        renderOutput(true);
        const lines = st.outText.split("\n").length;
        ctx.setStatus(`${job.jobname}(${job.jobid}) ${dd.ddname} — ${lines} line(s)`);
      } catch (e) {
        // degrade gracefully (TSK-253 edge case): error in panel only
        renderEmpty("Output failed: " + e.message);
        ctx.setStatus("Output failed — " + e.message);
      }
    }

    /* ---------------- actions ---------------- */
    function updateButtons() {
      btn.purge.classList.toggle("disabled", !st.sel);
      btn.reload.classList.toggle("disabled", !(st.sel && st.sel.dd));
    }

    async function doList(fromAuto) {
      st.prefix = prefixIn.value.trim().toUpperCase() || "*";
      st.owner = ownerIn.value.trim().toUpperCase() || "*";
      st.status = statusSel.value;
      prefixIn.value = st.prefix; ownerIn.value = st.owner;
      if (!fromAuto) ctx.setStatus("Listing jobs …");
      try {
        st.jobs = await listJobs() || [];
        // auto-refresh keeps expansion/selection; the open output is
        // never touched here
        renderTree();
        if (!fromAuto) ctx.setStatus(`${st.jobs.length} job(s) — ${st.prefix} / ${st.owner}`);
      } catch (e) {
        if (!fromAuto) {
          treeEl.innerHTML = "";
          treeEl.appendChild(el("div", "dsb-empty", "List failed: " + e.message));
          ctx.setStatus("List failed — " + e.message);
        }
      }
    }

    function doRefresh() {
      st.ddCache.clear();
      doList();
    }

    async function doReloadOutput() {
      if (!(st.sel && st.sel.dd)) return;
      await openDD(st.sel.job, st.sel.dd,
        treeEl.querySelector(`[data-dd="${jobKey(st.sel.job)}/${st.sel.dd.id}"]`));
    }

    async function doPurge() {
      if (!st.sel) return;
      const job = st.sel.job;
      const what = `${job.jobname}(${job.jobid})`;
      if (!(await Dialog.confirm("Purge job", `Purge ${what}?`,
        { okLabel: "Purge", danger: true, icon: "ti-trash" }))) return;
      if (job.status === "ACTIVE" &&
          !(await Dialog.confirm("Job is active",
            `${what} is ACTIVE (${job.type}). Purge anyway?`,
            { okLabel: "Purge active job", danger: true }))) return;
      try {
        await purgeJob(job);
        st.ddCache.delete(jobKey(job));
        st.expanded.delete(jobKey(job));
        if (st.sel && jobKey(st.sel.job) === jobKey(job)) {
          st.sel = null;
          renderEmpty();
        }
        await doList();
        ctx.setStatus(`Purged ${what}`);
      } catch (e) {
        ctx.setStatus(`Purge failed — ${e.message}`);
      }
      updateButtons();
    }

    /* auto-refresh: job list + statuses only (5s) */
    function setAuto(on) {
      if (st.autoTimer) { clearInterval(st.autoTimer); st.autoTimer = null; }
      if (on) st.autoTimer = setInterval(() => doList(true), 5000);
    }

    /* ---------------- wire up ---------------- */
    listBtn.addEventListener("click", () => doList());
    [prefixIn, ownerIn].forEach(inp =>
      inp.addEventListener("keydown", e => { if (e.key === "Enter") doList(); }));
    statusSel.addEventListener("change", () => doList());
    btn.refresh.addEventListener("click", doRefresh);
    btn.reload.addEventListener("click", doReloadOutput);
    btn.purge.addEventListener("click", doPurge);
    autoCb.addEventListener("change", () => setAuto(autoCb.checked));

    renderEmpty();
    updateButtons();
    doList();   // initial listing with the default filters
    return root;
  },

  destroy(ctx) {
    // stop the auto-refresh timer with the window
    const st = ctx._spl;
    if (st && st.autoTimer) clearInterval(st.autoTimer);
  }
});
