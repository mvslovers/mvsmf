/* ============================================================
   registry.js — the program plugin registry
   Leaf module (imports nothing from the shell) so every program
   file can `import { Programs }` and self-register at load time
   without a temporal-dead-zone problem.

   Plugin API (final — do not change shape; Phase 2 builds on it):

     Programs.register({
       id, name, icon, iconBg, iconColor,
       defaultWidth, defaultHeight, minWidth, minHeight,
       desktopIcon, statusBar, toolbar,
       create(ctx) { return <DOM node>; },
       destroy(ctx) { ... }
     });

   ctx: { windowId, system, contentEl, setTitle(t), setStatus(t), close() }
   ctx.system: { name, host, port, baseUrl, user, demo, apiFetch(path, opts) }
   ============================================================ */
export const Programs = (() => {
  const list = [];
  function register(p) { list.push(p); }
  function get(id) { return list.find(p => p.id === id); }
  function all() { return list.slice(); }
  return { register, get, all };
})();
