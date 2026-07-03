/* ============================================================
   wm.js — window manager
   Open/close/minimize/maximize/restore, drag, 8-way resize,
   focus + z-order, cascade. Imports Session for the per-window
   system context and Taskbar for the button strip.
   The wm <-> taskbar import cycle is safe: each only calls the
   other inside event handlers (runtime), never at module load.
   ============================================================ */
import { Session } from "./systems.js";
import { Taskbar } from "./taskbar.js";

export const WM = (() => {
  const windows = new Map();   // id -> win record
  let zTop = 10;
  let seq = 0;
  let cascade = 0;
  const desktop = () => document.getElementById("desktop");

  function focus(id) {
    const w = windows.get(id);
    if (!w) return;
    zTop += 1;
    w.el.style.zIndex = zTop;
    windows.forEach(x => x.el.classList.toggle("focused", x.id === id));
    Taskbar.setActive(id);
  }

  function focusTopmost() {
    let best = null;
    windows.forEach(w => {
      if (w.state === "minimized") return;
      const z = parseInt(w.el.style.zIndex || "0", 10);
      if (!best || z > best.z) best = { id: w.id, z };
    });
    if (best) focus(best.id); else Taskbar.setActive(null);
  }

  function open(program, systemName) {
    const id = "win_" + (++seq);
    const ctx = Session.contextFor(systemName);
    const dsk = desktop().getBoundingClientRect();

    const width = Math.min(program.defaultWidth || 500, dsk.width - 40);
    const height = Math.min(program.defaultHeight || 380, dsk.height - 40);
    cascade = (cascade + 1) % 8;
    const x = 60 + cascade * 26;
    const y = 30 + cascade * 24;

    const el = document.createElement("div");
    el.className = "wps-window focused";
    el.style.cssText = `left:${x}px; top:${y}px; width:${width}px; height:${height}px; z-index:${++zTop};`;

    // Title bar
    const tb = document.createElement("div");
    tb.className = "wps-titlebar";
    tb.innerHTML = `
      <div class="tleft">
        <div class="ticon"><i class="ti ${program.icon}"></i></div>
        <span class="ttext">${program.name}<span class="tsys">— ${ctx.name}</span></span>
      </div>
      <div class="tbtns">
        <div class="tbtn" data-act="min">_</div>
        <div class="tbtn" data-act="max">□</div>
        <div class="tbtn" data-act="close" style="font-weight:500;">×</div>
      </div>`;
    el.appendChild(tb);

    // Optional toolbar
    if (program.toolbar && program.toolbar.length) {
      const bar = document.createElement("div");
      bar.className = "wps-toolbar";
      program.toolbar.forEach(item => {
        const b = document.createElement("div");
        b.className = "tb-btn";
        b.innerHTML = (item.icon ? `<i class="ti ${item.icon}" style="font-size:13px;"></i>` : "") + item.label;
        b.addEventListener("click", () => item.onClick && item.onClick(winCtx));
        bar.appendChild(b);
      });
      el.appendChild(bar);
    }

    // Content
    const content = document.createElement("div");
    content.className = "wps-content";
    el.appendChild(content);

    // Optional status bar
    let statusEl = null;
    if (program.statusBar) {
      statusEl = document.createElement("div");
      statusEl.className = "wps-statusbar";
      statusEl.innerHTML = `<span class="sb-l"></span><span class="sb-r">${ctx.name} — ${ctx.user || ""}</span>`;
      el.appendChild(statusEl);
    }

    // Resize handles
    ["n","s","e","w","ne","nw","se","sw"].forEach(dir => {
      const h = document.createElement("div");
      h.className = "rs rs-" + dir;
      h.dataset.dir = dir;
      el.appendChild(h);
    });

    desktop().appendChild(el);

    const win = {
      id, program, el, content, statusEl,
      state: "normal",
      prevRect: null,
      title: program.name,
      systemName: ctx.name
    };
    windows.set(id, win);

    // Context object handed to the program instance
    const winCtx = {
      windowId: id,
      system: ctx,
      contentEl: content,
      setTitle(t) {
        win.title = t;
        tb.querySelector(".ttext").innerHTML = `${t}<span class="tsys">— ${ctx.name}</span>`;
        Taskbar.rename(id, t);
      },
      setStatus(text) { if (statusEl) statusEl.querySelector(".sb-l").textContent = text; },
      close() { close(id); }
    };
    win.ctx = winCtx;

    // Mount program content
    try {
      const node = program.create(winCtx);
      if (node) content.appendChild(node);
    } catch (e) {
      content.innerHTML = `<div class="prog-pad prog-err">Program error: ${e.message}</div>`;
    }

    // --- events ---
    el.addEventListener("pointerdown", () => focus(id));

    tb.addEventListener("pointerdown", ev => {
      if (ev.target.closest(".tbtn")) return;
      startDrag(win, ev);
    });
    tb.addEventListener("dblclick", ev => {
      if (ev.target.closest(".tbtn")) return;
      toggleMax(id);
    });
    tb.querySelectorAll(".tbtn").forEach(btn => {
      btn.addEventListener("click", ev => {
        ev.stopPropagation();
        const act = btn.dataset.act;
        if (act === "close") close(id);
        else if (act === "min") minimize(id);
        else if (act === "max") toggleMax(id);
      });
    });

    el.querySelectorAll(".rs").forEach(h => {
      h.addEventListener("pointerdown", ev => startResize(win, ev, h.dataset.dir));
    });

    Taskbar.add(id, program, win.title);
    focus(id);
    return id;
  }

  function close(id) {
    const w = windows.get(id);
    if (!w) return;
    // Optional veto hook (additive): a program with unsaved state may
    // return false — or a Promise resolving to false (in-app confirm
    // dialog) — from confirmClose(ctx) to keep the window open.
    if (w.program.confirmClose) {
      let ok = true;
      try { ok = w.program.confirmClose(w.ctx); } catch (e) {}
      if (ok && typeof ok.then === "function") {
        ok.then(really => { if (really) forceClose(id); });
        return;   // decision deferred to the dialog
      }
      if (!ok) return;
    }
    forceClose(id);
  }

  function forceClose(id) {
    const w = windows.get(id);
    if (!w) return;
    try { w.program.destroy && w.program.destroy(w.ctx); } catch (e) {}
    w.el.remove();
    windows.delete(id);
    Taskbar.remove(id);
    focusTopmost();
  }

  function minimize(id) {
    const w = windows.get(id);
    if (!w) return;
    w.state = "minimized";
    w.el.classList.add("minimized");
    Taskbar.setActive(null);
    focusTopmost();
  }

  function restore(id) {
    const w = windows.get(id);
    if (!w) return;
    w.state = w.prevRect ? "maximized" : "normal";
    w.el.classList.remove("minimized");
    focus(id);
  }

  function toggleMax(id) {
    const w = windows.get(id);
    if (!w) return;
    const dsk = desktop().getBoundingClientRect();
    if (w.state !== "maximized") {
      w.prevRect = {
        left: w.el.style.left, top: w.el.style.top,
        width: w.el.style.width, height: w.el.style.height
      };
      w.el.style.left = "0px"; w.el.style.top = "0px";
      w.el.style.width = dsk.width + "px"; w.el.style.height = dsk.height + "px";
      w.el.classList.add("maximized");
      w.state = "maximized";
    } else {
      const p = w.prevRect || { left: "60px", top: "40px", width: "500px", height: "380px" };
      w.el.style.left = p.left; w.el.style.top = p.top;
      w.el.style.width = p.width; w.el.style.height = p.height;
      w.el.classList.remove("maximized");
      w.state = "normal";
      w.prevRect = null;
    }
  }

  /* Dragging via pointer events; keeps the title bar reachable. */
  function startDrag(win, ev) {
    if (win.state === "maximized") return;
    ev.preventDefault();
    focus(win.id);
    const startX = ev.clientX, startY = ev.clientY;
    const rect = win.el.getBoundingClientRect();
    const dsk = desktop().getBoundingClientRect();
    const offX = startX - rect.left, offY = startY - rect.top;

    function move(e) {
      let nx = e.clientX - offX;
      let ny = e.clientY - offY;
      // constraints: keep >= 60px of window on screen, titlebar never above top
      nx = Math.max(-(rect.width - 60), Math.min(nx, dsk.width - 60));
      ny = Math.max(0, Math.min(ny, dsk.height - 24));
      win.el.style.left = nx + "px";
      win.el.style.top = ny + "px";
    }
    function up() {
      document.removeEventListener("pointermove", move);
      document.removeEventListener("pointerup", up);
    }
    document.addEventListener("pointermove", move);
    document.addEventListener("pointerup", up);
  }

  /* Resizing from any edge/corner; respects program min sizes. */
  function startResize(win, ev, dir) {
    if (win.state === "maximized") return;
    ev.preventDefault();
    ev.stopPropagation();
    focus(win.id);
    const rect = win.el.getBoundingClientRect();
    const dskRect = desktop().getBoundingClientRect();
    const startX = ev.clientX, startY = ev.clientY;
    const minW = win.program.minWidth || 240;
    const minH = win.program.minHeight || 140;
    const orig = { left: rect.left - dskRect.left, top: rect.top - dskRect.top, w: rect.width, h: rect.height };

    function move(e) {
      const dx = e.clientX - startX, dy = e.clientY - startY;
      let { left, top, w, h } = orig;
      if (dir.includes("e")) w = Math.max(minW, orig.w + dx);
      if (dir.includes("s")) h = Math.max(minH, orig.h + dy);
      if (dir.includes("w")) { w = Math.max(minW, orig.w - dx); left = orig.left + (orig.w - w); }
      if (dir.includes("n")) { h = Math.max(minH, orig.h - dy); top = Math.max(0, orig.top + (orig.h - h)); h = orig.h + (orig.top - top); }
      win.el.style.left = left + "px";
      win.el.style.top = top + "px";
      win.el.style.width = w + "px";
      win.el.style.height = h + "px";
    }
    function up() {
      document.removeEventListener("pointermove", move);
      document.removeEventListener("pointerup", up);
    }
    document.addEventListener("pointermove", move);
    document.addEventListener("pointerup", up);
  }

  function isMinimized(id) {
    const w = windows.get(id);
    return w ? w.state === "minimized" : false;
  }
  function isFocused(id) {
    const w = windows.get(id);
    return w ? w.el.classList.contains("focused") : false;
  }

  return { open, close, minimize, restore, focus, isMinimized, isFocused };
})();
