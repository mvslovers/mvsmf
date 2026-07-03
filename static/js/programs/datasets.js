/* ============================================================
   datasets.js — Dataset browser (Desktop Phase 2.1)

   Split view: DSN filter bar → qualifier tree (left, lazy member
   loading per PDS expand) → content panel (right) with Prism
   syntax highlighting and a textarea-overlay editor.

   API (all via ctx.system.apiFetch, see docs/endpoints/datasets/):
     GET    /zosmf/restfiles/ds?dslevel=<pattern>     list datasets
     GET    /zosmf/restfiles/ds/{dsn}/member          list PDS members
     GET    /zosmf/restfiles/ds/{dsn}({mem})          read member
     GET    /zosmf/restfiles/ds/{dsn}                 read PS dataset
     PUT    /zosmf/restfiles/ds/{dsn}({mem})          write member
     DELETE /zosmf/restfiles/ds/{dsn}({mem})          delete member

   Etag: member reads request X-IBM-Return-Etag and a PUT sends
   If-Match when an ETag was received. mvsMF does not implement
   this yet, so today it degrades to a plain PUT (see the Etag
   follow-up issue); the protocol here is ready for the backend.

   Demo mode: canned datasets/members (pattern: sysinfo program).
   ============================================================ */
import { Programs } from "./registry.js";

/* ---------- demo-mode canned data ---------- */
const DEMO_DATASETS = [
  { dsname: "IBMUSER.MACLIB",     dsorg: "PO", recfm: "FB", lrecl: 80 },
  { dsname: "IBMUSER.NOTES.TEXT", dsorg: "PS", recfm: "FB", lrecl: 80 },
  { dsname: "IBMUSER.SOURCE",     dsorg: "PO", recfm: "FB", lrecl: 80 },
  { dsname: "IBMUSER.SYSEXEC",    dsorg: "PO", recfm: "FB", lrecl: 80 },
  { dsname: "IBMUSER.TEST.JCL",   dsorg: "PO", recfm: "FB", lrecl: 80 }
];
const DEMO_MEMBERS = {
  "IBMUSER.MACLIB":   ["SAVEREG"],
  "IBMUSER.SOURCE":   ["HELLO", "TESTPGM"],
  "IBMUSER.SYSEXEC":  ["HELLO"],
  "IBMUSER.TEST.JCL": ["ASMJOB", "COMPILE", "IEFBR14"]
};
const DEMO_CONTENT = {
  "IBMUSER.SOURCE(HELLO)":
    '#include <stdio.h>\n\nint main(int argc, char **argv)\n{\n    printf("hello from MVS 3.8j\\n");\n    return 0;\n}\n',
  "IBMUSER.SOURCE(TESTPGM)":
    '#include <stdio.h>\n\n/* demo member - edit me and press Save */\nint test(void)\n{\n    return 42;\n}\n',
  "IBMUSER.TEST.JCL(COMPILE)":
    "//COMPILE  JOB (ACCT),'COMPILE',CLASS=A,MSGCLASS=H\n//* compile a C program with cc370\n//CC       EXEC PGM=CC370,PARM='-O2'\n//STEPLIB  DD DSN=CC370.LOAD,DISP=SHR\n//SYSIN    DD DSN=IBMUSER.SOURCE(HELLO),DISP=SHR\n//SYSPRINT DD SYSOUT=*\n//SYSLIN   DD DSN=&&OBJ,DISP=(NEW,PASS),UNIT=SYSDA\n//\n",
  "IBMUSER.TEST.JCL(ASMJOB)":
    "//ASMJOB   JOB (ACCT),'ASSEMBLE',CLASS=A,MSGCLASS=H\n//ASM      EXEC PGM=IFOX00\n//SYSLIB   DD DSN=SYS1.MACLIB,DISP=SHR\n//SYSIN    DD DSN=IBMUSER.SOURCE(TESTPGM),DISP=SHR\n//SYSPRINT DD SYSOUT=*\n//\n",
  "IBMUSER.TEST.JCL(IEFBR14)":
    "//IEFBR14  JOB (ACCT),'NOP',CLASS=A,MSGCLASS=H\n//STEP1    EXEC PGM=IEFBR14\n//\n",
  "IBMUSER.SYSEXEC(HELLO)":
    "/* REXX - demo exec */\nsay 'hello from REXX on MVS 3.8j'\ndo i = 1 to 3\n  say 'iteration' i\nend\nexit 0\n",
  "IBMUSER.MACLIB(SAVEREG)":
    "         MACRO\n&LABEL   SAVEREG\n&LABEL   STM   R14,R12,12(R13)    SAVE CALLER REGS\n         BALR  R12,0              ESTABLISH BASE\n         USING *,R12\n         MEND\n",
  "IBMUSER.NOTES.TEXT":
    "notes - sequential dataset (read-only in the browser)\n\n- PS datasets open directly from the tree\n- PDS members are loaded lazily on expand\n"
};

/* ---------- language auto-detection (spec heuristic) ---------- */
function detectLanguage(dsn, member, text) {
  const lastQ = (dsn || "").split(".").pop() || "";
  const head = (text || "").slice(0, 400);
  const firstLine = ((text || "").split("\n").find(l => l.trim() !== "") || "");
  if (/^\/\//.test(firstLine)) return "jcl";
  if (/\/\*[^*]*rexx/i.test(head)) return "rexx";
  if (/^(?:CNTL|JCL)$/.test(lastQ)) return "jcl";
  if (/^(?:EXEC|SYSEXEC|REXX)$/.test(lastQ)) return "rexx";
  if (/^\s*#include\b/m.test(text || "")) return "c";
  if (/^(?:MACLIB|ASM|ASSEMBLE)$/.test(lastQ)) return "hlasm";
  // opcode pattern: label/blank + mnemonic in the operation field
  const opRx = /^(?:[A-Z@#$&][A-Z0-9@#$_]*)?\s+(?:USING|CSECT|DSECT|MACRO|MEND|EQU|DC|DS|STM|LM|BALR?|LA?|LR|ST|MVC|CLC|SR|AR|END|SAVE|RETURN)\b/;
  let hits = 0;
  for (const line of (text || "").split("\n").slice(0, 40)) {
    if (opRx.test(line)) hits++;
    if (hits >= 2) return "hlasm";
  }
  if (/^(?:C|H)$/.test(lastQ) || /\/\*/.test(head)) return "c";
  return "plain";
}

/* ---------- small helpers ---------- */
function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
}
function patternToRegex(pattern) {
  return new RegExp("^" + pattern.toUpperCase()
    .replace(/[.]/g, "\\.").replace(/\*+/g, "[A-Z0-9@#$.\\-]*") + "$");
}

Programs.register({
  id: "datasets",
  name: "Dataset browser",
  icon: "ti-database",
  iconBg: "#e8d44d", iconColor: "#5a4e00",
  defaultWidth: 780, defaultHeight: 500,
  minWidth: 540, minHeight: 340,
  desktopIcon: true,
  statusBar: true,

  /* veto window close while the editor has unsaved changes */
  confirmClose(ctx) {
    const st = ctx._dsb;
    if (st && st.dirty) return confirm("Discard unsaved changes?");
    return true;
  },

  create(ctx) {
    const sys = ctx.system;
    const st = {
      pattern: (sys.demo ? "IBMUSER" : (sys.user || "IBMUSER").toUpperCase()) + ".*",
      items: [],            // dataset list from the current filter
      mcache: new Map(),    // dsn -> [member names] (until Refresh)
      demoContent: sys.demo ? Object.assign({}, DEMO_CONTENT) : null,
      demoMembers: sys.demo ? JSON.parse(JSON.stringify(DEMO_MEMBERS)) : null,
      sel: null,            // { type:'po'|'ps'|'member', dsn, member?, meta }
      text: "",             // loaded content
      etag: null,           // ETag from last read (If-Match on save)
      editing: false,
      dirty: false,
      lang: "auto"
    };
    ctx._dsb = st;

    /* ---------------- DOM skeleton ---------------- */
    const root = el("div", "dsb-root");

    const bar1 = el("div", "wps-toolbar dsb-bar");
    const dsnLabel = el("label", null, "DSN:");
    const dsnInput = el("input", "dsb-dsn");
    dsnInput.value = st.pattern;
    dsnInput.spellcheck = false;
    const listBtn = el("div", "tb-btn", "List");
    bar1.append(dsnLabel, dsnInput, listBtn);

    const bar2 = el("div", "wps-toolbar dsb-bar");
    const btn = {};
    [["refresh", "Refresh", "ti-refresh"],
     ["newmem",  "New member", "ti-file-plus"],
     ["edit",    "Edit", "ti-pencil"],
     ["save",    "Save", "ti-device-floppy"],
     ["cancel",  "Cancel", "ti-x"],
     ["del",     "Delete", "ti-trash"]].forEach(([key, label, icon]) => {
      const b = el("div", "tb-btn");
      b.innerHTML = `<i class="ti ${icon}" style="font-size:13px;"></i>${label}`;
      bar2.appendChild(b);
      btn[key] = b;
    });
    bar2.appendChild(el("div", "tb-spacer"));
    const langSel = document.createElement("select");
    ["auto", "jcl", "hlasm", "c", "rexx", "plain"].forEach(l => {
      const o = document.createElement("option");
      o.value = l; o.textContent = l;
      langSel.appendChild(o);
    });
    bar2.appendChild(langSel);

    const split = el("div", "dsb-split");
    const treeEl = el("div", "dsb-tree");
    const viewEl = el("div", "dsb-view");
    split.append(treeEl, viewEl);
    root.append(bar1, bar2, split);

    /* ---------------- API (demo-aware) ---------------- */
    async function api(path, opts) {
      const resp = await sys.apiFetch(path, opts);
      if (!resp.ok) throw new Error("HTTP " + resp.status);
      return resp;
    }
    async function listDatasets(pattern) {
      if (sys.demo) {
        const rx = patternToRegex(pattern);
        return { items: DEMO_DATASETS.filter(d => rx.test(d.dsname)), moreRows: false };
      }
      const resp = await api("/zosmf/restfiles/ds?dslevel=" + encodeURIComponent(pattern),
        { headers: { "X-IBM-Max-Items": "500" } });
      return resp.json();
    }
    async function listMembers(dsn) {
      if (st.mcache.has(dsn)) return st.mcache.get(dsn);
      let names;
      if (sys.demo) {
        names = (st.demoMembers[dsn] || []).slice().sort();
      } else {
        const resp = await api("/zosmf/restfiles/ds/" + dsn + "/member");
        const json = await resp.json();
        // dsapi pads member names to 8 chars (z/OSMF returns them
        // unpadded) — trim defensively so keys and URLs stay clean
        names = (json.items || []).map(i => (i.member || "").trim())
          .filter(Boolean).sort();
      }
      st.mcache.set(dsn, names);
      return names;
    }
    async function readContent(sel) {
      if (sys.demo) {
        const key = sel.member ? `${sel.dsn}(${sel.member})` : sel.dsn;
        st.etag = null;
        return st.demoContent[key] || "";
      }
      const path = sel.member
        ? `/zosmf/restfiles/ds/${sel.dsn}(${sel.member})`
        : `/zosmf/restfiles/ds/${sel.dsn}`;
      const resp = await api(path, { headers: { "X-IBM-Return-Etag": "true" } });
      st.etag = resp.headers.get("ETag");
      return resp.text();
    }
    async function writeMember(dsn, member, text) {
      if (sys.demo) {
        st.demoContent[`${dsn}(${member})`] = text;
        if (!(st.demoMembers[dsn] || []).includes(member)) {
          (st.demoMembers[dsn] = st.demoMembers[dsn] || []).push(member);
        }
        return;
      }
      const headers = { "Content-Type": "text/plain" };
      if (st.etag) headers["If-Match"] = st.etag;   // no-op until mvsMF supports it
      await api(`/zosmf/restfiles/ds/${dsn}(${member})`,
        { method: "PUT", headers, body: text });
    }
    async function deleteMember(dsn, member) {
      if (sys.demo) {
        st.demoMembers[dsn] = (st.demoMembers[dsn] || []).filter(m => m !== member);
        delete st.demoContent[`${dsn}(${member})`];
        return;
      }
      await api(`/zosmf/restfiles/ds/${dsn}(${member})`, { method: "DELETE" });
    }

    /* ---------------- tree ---------------- */
    function buildTrie(items) {
      const rootNode = { kids: new Map(), ds: null };
      for (const it of items) {
        let node = rootNode;
        for (const part of it.dsname.split(".")) {
          if (!node.kids.has(part)) node.kids.set(part, { kids: new Map(), ds: null });
          node = node.kids.get(part);
        }
        node.ds = it;
      }
      return rootNode;
    }

    function renderTree() {
      treeEl.innerHTML = "";
      if (!st.items.length) {
        treeEl.appendChild(el("div", "dsb-empty", "No datasets — adjust the filter"));
        return;
      }
      const trie = buildTrie(st.items);
      const walk = (node, prefix, depth, parentEl) => {
        [...node.kids.keys()].sort().forEach(part => {
          const kid = node.kids.get(part);
          const dsn = prefix ? prefix + "." + part : part;
          parentEl.appendChild(renderNode(kid, part, dsn, depth, parentEl));
        });
      };
      walk(trie, "", 0, treeEl);
      restoreSelection();
    }

    function renderNode(node, label, dsn, depth) {
      const frag = document.createDocumentFragment();
      const row = el("div", "dsb-node");
      row.style.paddingLeft = (6 + depth * 14) + "px";
      const isPO = node.ds && node.ds.dsorg === "PO";
      const isPS = node.ds && !isPO;
      const isQual = !node.ds;

      const chev = el("span", "dsb-chev", isPS ? "" : "▸");
      const ico = el("i", "dsb-ico ti " +
        (isQual ? "ti-folder" : isPO ? "ti-database" : "ti-file"));
      row.append(chev, ico, el("span", null, label));
      frag.appendChild(row);

      const kidsEl = el("div", "dsb-kids");
      kidsEl.style.display = "none";
      frag.appendChild(kidsEl);

      let expanded = false;
      const toggle = async () => {
        expanded = !expanded;
        chev.textContent = expanded ? "▾" : "▸";
        kidsEl.style.display = expanded ? "" : "none";
        if (!expanded || kidsEl.childElementCount) return;
        if (isQual) {
          const walk = (n, prefix, d) => {
            [...n.kids.keys()].sort().forEach(part => {
              const kid = n.kids.get(part);
              kidsEl.appendChild(renderNode(kid, part, prefix + "." + part, d));
            });
          };
          walk(node, dsn, depth + 1);
        } else if (isPO) {
          // lazy member load, cached until Refresh
          const loading = el("div", "dsb-node", "loading…");
          loading.style.paddingLeft = (6 + (depth + 1) * 14) + "px";
          kidsEl.appendChild(loading);
          try {
            const members = await listMembers(dsn);
            kidsEl.innerHTML = "";
            if (!members.length) {
              const none = el("div", "dsb-node", "(no members)");
              none.style.paddingLeft = (6 + (depth + 1) * 14) + "px";
              kidsEl.appendChild(none);
            }
            members.forEach(m => kidsEl.appendChild(renderMemberRow(dsn, m, depth + 1, node.ds)));
          } catch (e) {
            kidsEl.innerHTML = "";
            const err = el("div", "dsb-node", "error: " + e.message);
            err.style.paddingLeft = (6 + (depth + 1) * 14) + "px";
            kidsEl.appendChild(err);
          }
        }
      };

      row.addEventListener("click", () => {
        if (isQual) { toggle(); return; }
        if (isPO) { select({ type: "po", dsn, meta: node.ds }, row); toggle(); return; }
        select({ type: "ps", dsn, meta: node.ds }, row);   // PS: load content
      });
      // auto-expand qualifier levels so datasets are visible immediately
      if (isQual) toggle();
      return frag;
    }

    function renderMemberRow(dsn, member, depth, meta) {
      const row = el("div", "dsb-node");
      row.style.paddingLeft = (6 + depth * 14) + "px";
      row.append(el("span", "dsb-chev", ""),
                 Object.assign(el("i", "dsb-ico ti ti-file-text"), {}),
                 el("span", null, member));
      row.dataset.key = `${dsn}(${member})`;
      row.addEventListener("click", () => select({ type: "member", dsn, member, meta }, row));
      return row;
    }

    function markSelected(row) {
      treeEl.querySelectorAll(".dsb-node.selected").forEach(n => n.classList.remove("selected"));
      if (row) row.classList.add("selected");
    }
    function restoreSelection() {
      if (!st.sel || st.sel.type !== "member") return;
      const row = treeEl.querySelector(`[data-key="${st.sel.dsn}(${st.sel.member})"]`);
      if (row) row.classList.add("selected");
    }

    /* ---------------- selection / content ---------------- */
    async function select(sel, row) {
      if (st.dirty && !confirm("Discard unsaved changes?")) return;
      st.dirty = false; st.editing = false;
      st.sel = sel;
      markSelected(row);
      if (sel.type === "po") { updateButtons(); return; }   // PO row only selects/expands
      renderLoading();
      try {
        st.text = await readContent(sel);
        renderView();
        const meta = sel.meta || {};
        const where = sel.member ? `${sel.dsn}(${sel.member})` : sel.dsn;
        ctx.setStatus(`${where} — ${meta.recfm || "?"}/${meta.lrecl || "?"}`);
      } catch (e) {
        st.text = "";
        renderEmpty("Load failed: " + e.message);
        ctx.setStatus("Load failed — " + e.message);
      }
      updateButtons();
    }

    /* ---------------- right panel rendering ---------------- */
    function effectiveLang() {
      if (st.lang !== "auto") return st.lang;
      if (!st.sel) return "plain";
      return detectLanguage(st.sel.dsn, st.sel.member, st.text);
    }
    function highlightInto(codeEl, text) {
      const lang = effectiveLang();
      codeEl.textContent = text;
      if (lang !== "plain" && window.Prism && window.Prism.languages[lang]) {
        codeEl.className = "language-" + lang;
        window.Prism.highlightElement(codeEl);
      } else {
        codeEl.className = "";
      }
    }
    function renderEmpty(msg) {
      viewEl.innerHTML = "";
      viewEl.appendChild(el("div", "dsb-empty", msg || "Select a member"));
    }
    function renderLoading() { renderEmpty("Loading…"); }

    function renderView() {
      viewEl.innerHTML = "";
      const pre = el("pre", "dsb-code");
      const code = el("code");
      pre.appendChild(code);
      viewEl.appendChild(pre);
      highlightInto(code, st.text);
    }

    function renderEditor() {
      viewEl.innerHTML = "";
      const pre = el("pre", "dsb-code dsb-under");
      const code = el("code");
      pre.appendChild(code);
      const ta = document.createElement("textarea");
      ta.spellcheck = false;
      ta.value = st.text;
      viewEl.append(pre, ta);
      highlightInto(code, ta.value);
      ta.addEventListener("input", () => {
        st.dirty = true;
        highlightInto(code, ta.value);
        updateButtons();
      });
      // keep the highlight layer aligned with the textarea scroll position
      ta.addEventListener("scroll", () => {
        pre.scrollTop = ta.scrollTop;
        pre.scrollLeft = ta.scrollLeft;
      });
      ta.focus();
      st._ta = ta;
      st._rehighlight = () => highlightInto(code, ta.value);
    }

    /* ---------------- toolbar actions ---------------- */
    function updateButtons() {
      const isMember = st.sel && st.sel.type === "member";
      const pdsCtx = st.sel && (st.sel.type === "member" || st.sel.type === "po");
      btn.newmem.classList.toggle("disabled", !pdsCtx || st.editing);
      btn.edit.classList.toggle("disabled", !isMember || st.editing);
      btn.save.classList.toggle("disabled", !st.editing);
      btn.cancel.classList.toggle("disabled", !st.editing);
      btn.del.classList.toggle("disabled", !isMember || st.editing);
    }

    async function doList() {
      st.pattern = dsnInput.value.trim().toUpperCase() || st.pattern;
      dsnInput.value = st.pattern;
      ctx.setStatus("Listing " + st.pattern + " …");
      treeEl.innerHTML = "";
      treeEl.appendChild(el("div", "dsb-empty", "Loading…"));
      try {
        const json = await listDatasets(st.pattern);
        st.items = json.items || [];
        st.mcache.clear();
        renderTree();
        ctx.setStatus(`${st.items.length} dataset(s) — ${st.pattern}` +
          (json.moreRows ? " — more available, narrow the filter" : ""));
      } catch (e) {
        treeEl.innerHTML = "";
        treeEl.appendChild(el("div", "dsb-empty", "List failed: " + e.message));
        ctx.setStatus("List failed — " + e.message);
      }
    }

    function doRefresh() {
      if (st.dirty && !confirm("Discard unsaved changes?")) return;
      st.dirty = false; st.editing = false;
      st.mcache.clear();
      doList();
    }

    function doEdit() {
      if (!st.sel || st.sel.type !== "member") return;
      st.editing = true;
      renderEditor();
      updateButtons();
    }

    async function doSave() {
      if (!st.editing || !st.sel) return;
      const text = st._ta ? st._ta.value : st.text;
      ctx.setStatus(`Saving ${st.sel.dsn}(${st.sel.member}) …`);
      try {
        await writeMember(st.sel.dsn, st.sel.member, text);
        st.text = text;
        st.dirty = false; st.editing = false;
        renderView();
        updateButtons();
        ctx.setStatus(`Saved ${st.sel.dsn}(${st.sel.member})`);
      } catch (e) {
        ctx.setStatus("Save failed — " + e.message);
      }
    }

    function doCancel() {
      if (!st.editing) return;
      if (st.dirty && !confirm("Discard unsaved changes?")) return;
      st.dirty = false; st.editing = false;
      renderView();
      updateButtons();
    }

    async function doNewMember() {
      const dsn = st.sel && (st.sel.type === "po" ? st.sel.dsn
                : st.sel.type === "member" ? st.sel.dsn : null);
      if (!dsn) return;
      let name = prompt("New member name (1-8 chars):");
      if (!name) return;
      name = name.trim().toUpperCase();
      if (!/^[A-Z@#$][A-Z0-9@#$]{0,7}$/.test(name)) {
        ctx.setStatus("Invalid member name: " + name);
        return;
      }
      const members = st.mcache.get(dsn) || [];
      if (members.includes(name)) {
        ctx.setStatus(`${dsn}(${name}) already exists`);
        return;
      }
      try {
        await writeMember(dsn, name, "");
        st.mcache.delete(dsn);
        await doList();          // rebuild tree (caches were touched)
        st.sel = { type: "member", dsn, member: name, meta: st.sel ? st.sel.meta : {} };
        st.text = "";
        st.etag = null;
        st.editing = true;
        renderEditor();
        updateButtons();
        ctx.setStatus(`Created ${dsn}(${name}) — editing`);
      } catch (e) {
        ctx.setStatus("Create failed — " + e.message);
      }
    }

    async function doDelete() {
      if (!st.sel || st.sel.type !== "member") return;
      const { dsn, member } = st.sel;
      if (!confirm(`Delete ${dsn}(${member})?`)) return;
      try {
        await deleteMember(dsn, member);
        st.mcache.delete(dsn);
        st.sel = null;
        st.text = "";
        renderEmpty();
        await doList();
        ctx.setStatus(`Deleted ${dsn}(${member})`);
      } catch (e) {
        ctx.setStatus("Delete failed — " + e.message);
      }
    }

    /* ---------------- wire up ---------------- */
    listBtn.addEventListener("click", doList);
    dsnInput.addEventListener("keydown", e => { if (e.key === "Enter") doList(); });
    btn.refresh.addEventListener("click", doRefresh);
    btn.newmem.addEventListener("click", doNewMember);
    btn.edit.addEventListener("click", doEdit);
    btn.save.addEventListener("click", doSave);
    btn.cancel.addEventListener("click", doCancel);
    btn.del.addEventListener("click", doDelete);
    langSel.addEventListener("change", () => {
      st.lang = langSel.value;
      // while editing, only re-highlight the underlay — rebuilding the
      // textarea would discard unsaved input
      if (st.editing && st._rehighlight) st._rehighlight();
      else if (st.sel && st.sel.type !== "po") renderView();
    });

    renderEmpty();
    updateButtons();
    doList();   // initial listing with the default pattern
    return root;
  }
});
