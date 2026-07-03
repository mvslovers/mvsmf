/* ============================================================
   taskbar.js — window button strip in the taskbar
   One button per open window: click toggles minimize / restore /
   focus. WM keeps the "active" (focused) button in sync.
   Imports WM only for the click behaviour (runtime); the
   wm <-> taskbar cycle is safe (see wm.js).
   ============================================================ */
import { WM } from "./wm.js";

export const Taskbar = (() => {
  const container = () => document.getElementById("task-buttons");
  const buttons = new Map();

  function add(id, program, title) {
    const b = document.createElement("div");
    b.className = "task-btn active";
    b.innerHTML = `<i class="ti ${program.icon}" style="font-size:12px;flex:0 0 auto;"></i><span>${title}</span>`;
    b.addEventListener("click", () => {
      if (WM.isMinimized(id)) WM.restore(id);
      else if (WM.isFocused(id)) WM.minimize(id);
      else WM.focus(id);
    });
    container().appendChild(b);
    buttons.set(id, b);
  }
  function remove(id) {
    const b = buttons.get(id);
    if (b) b.remove();
    buttons.delete(id);
  }
  function rename(id, title) {
    const b = buttons.get(id);
    if (b) b.querySelector("span").textContent = title;
  }
  function setActive(id) {
    buttons.forEach((b, key) => b.classList.toggle("active", key === id));
  }
  return { add, remove, rename, setActive };
})();
