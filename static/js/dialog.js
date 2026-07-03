/* ============================================================
   dialog.js — OS/2-style modal dialogs
   Replaces the native browser popups (alert/confirm/prompt) with
   themed in-desktop modals. Promise-based:

     Dialog.show({ title, message?, fields?, okLabel?, cancelLabel?,
                   danger?, icon? })
       → Promise<null | object>       null = cancelled,
                                      object = field values (may be {})
     Dialog.confirm(title, message, opts?) → Promise<boolean>
     Dialog.prompt(title, label, opts?)    → Promise<string|null>

   fields: [{ key, label, value?, placeholder?, maxLength?, upper? }]
   Keyboard: Enter = OK, Escape = Cancel. Focus returns to the
   previously focused element when the dialog closes.
   ============================================================ */
export const Dialog = (() => {

  function show(opts) {
    return new Promise(resolve => {
      const prev = document.activeElement;
      const layer = document.createElement("div");
      layer.className = "dlg-layer";
      const box = document.createElement("div");
      box.className = "dlg-box";

      // title bar (window-style)
      const tb = document.createElement("div");
      tb.className = "dlg-title";
      tb.innerHTML = `<div class="ticon"><i class="ti ${opts.icon || "ti-alert-square"}"></i></div><span class="t"></span>`;
      tb.querySelector(".t").textContent = opts.title || "mvsMF Desktop";

      const body = document.createElement("div");
      body.className = "dlg-body";
      if (opts.message) {
        const m = document.createElement("div");
        m.className = "dlg-msg";
        m.textContent = opts.message;
        body.appendChild(m);
      }

      // optional input fields
      const inputs = [];
      (opts.fields || []).forEach(f => {
        const fld = document.createElement("div");
        fld.className = "dlg-field";
        const lab = document.createElement("label");
        lab.textContent = f.label || "";
        const inp = document.createElement("input");
        if (f.value) inp.value = f.value;
        if (f.placeholder) inp.placeholder = f.placeholder;
        if (f.maxLength) inp.maxLength = f.maxLength;
        if (f.upper) inp.classList.add("dlg-upper");
        inp.spellcheck = false;
        fld.append(lab, inp);
        body.appendChild(fld);
        inputs.push({ key: f.key, inp, upper: !!f.upper });
      });

      const btns = document.createElement("div");
      btns.className = "dlg-buttons";
      const cancelBtn = document.createElement("button");
      cancelBtn.className = "lb-btn";
      cancelBtn.textContent = opts.cancelLabel || "Cancel";
      const okBtn = document.createElement("button");
      okBtn.className = "lb-btn primary" + (opts.danger ? " danger" : "");
      okBtn.textContent = opts.okLabel || "OK";
      btns.append(cancelBtn, okBtn);
      body.appendChild(btns);

      box.append(tb, body);
      layer.appendChild(box);
      document.body.appendChild(layer);

      function collect() {
        const out = {};
        inputs.forEach(i => {
          let v = i.inp.value.trim();
          if (i.upper) v = v.toUpperCase();
          out[i.key] = v;
        });
        return out;
      }
      function done(result) {
        document.removeEventListener("keydown", onKey, true);
        layer.remove();
        if (prev && prev.focus) { try { prev.focus(); } catch (e) {} }
        resolve(result);
      }
      function onKey(ev) {
        // modal: swallow keys while the dialog is open
        if (ev.key === "Escape") { ev.preventDefault(); ev.stopPropagation(); done(null); }
        else if (ev.key === "Enter") { ev.preventDefault(); ev.stopPropagation(); done(collect()); }
      }
      document.addEventListener("keydown", onKey, true);
      cancelBtn.addEventListener("click", () => done(null));
      okBtn.addEventListener("click", () => done(collect()));
      // click on the scrim (outside the box) = cancel
      layer.addEventListener("pointerdown", ev => { if (ev.target === layer) done(null); });

      (inputs.length ? inputs[0].inp : okBtn).focus();
    });
  }

  async function confirm(title, message, opts = {}) {
    const r = await show(Object.assign({ title, message }, opts));
    return r !== null;
  }

  async function prompt(title, label, opts = {}) {
    const field = Object.assign({ key: "v", label }, opts.field || {});
    const r = await show(Object.assign({ title, fields: [field] }, opts));
    return r === null ? null : r.v;
  }

  return { show, confirm, prompt };
})();
