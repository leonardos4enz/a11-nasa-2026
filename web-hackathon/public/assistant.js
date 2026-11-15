// Ember assistant sidebar for the Burning Activity Calendar.
// Pattern from erp-ai spec 047: a right panel opened from the top bar, pushes content on desktop, drawer on narrow
// screens (Esc / backdrop close), remembers if it was open, shows what the user is viewing, welcome + suggestions.
// Talks only to our own server (/api/chat): the Ember agent may answer with page actions, which agent.js plays.
(() => {
  const $ = (id) => document.getElementById(id);
  const app = document.querySelector(".app");
  const panel = $("ember-panel"), toggle = $("ember-toggle"), backdrop = $("ember-backdrop");
  const body = $("ember-body"), welcome = $("ember-welcome"), log = $("ember-log"), sugg = $("ember-sugg");
  const form = $("ember-form"), input = $("ember-input"), send = $("ember-send");
  const stateEl = $("ember-state"), ctxEl = $("ember-context"), sr = $("ember-sr");
  if (!panel || !toggle) return;

  const KEY_OPEN = "a11.ember.open", KEY_SID = "a11-chat-session", KEY_LOG = "a11.ember.log";
  const narrow = () => matchMedia("(max-width: 1200px)").matches;
  const get = (k, s) => { try { return (s || localStorage).getItem(k); } catch { return null; } };
  const set = (k, v, s) => { try { (s || localStorage).setItem(k, v); } catch {} };
  const newId = () => (crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(16) + Math.random().toString(16).slice(2));
  const esc = (t) => String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const md = (t) => esc(t)
    .replace(/^\s*[-*] /gm, "• ")
    .replace(/`([^`\n]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>");

  let sessionId = get(KEY_SID, sessionStorage);
  if (!sessionId) { sessionId = newId(); set(KEY_SID, sessionId, sessionStorage); }
  let history = [];
  try { history = JSON.parse(sessionStorage.getItem(KEY_LOG) || "[]"); } catch {}
  const save = () => set(KEY_LOG, JSON.stringify(history.slice(-40)), sessionStorage);
  let busy = false;

  // ---- Ember avatar: its gesture mirrors the conversation state ----
  const hasEmber = typeof window.Ember !== "undefined";
  const avatar = hasEmber ? Ember.create($("ember-avatar"), { follow: true }) : null;
  const mini = hasEmber ? Ember.create($("ember-mini")) : null;
  const TEXT = { idle: "Ready to help", curious: "Ready to help", reading: "Reading…", thinking: "Thinking…", working: "Still working on it…",
    done: "Ready to help", found: "Ready to help", thankful: "You're welcome", failed: "Something went wrong", sad: "Can't reach the assistant", sleeping: "Napping" };
  let settleT = null, sleepT = null;
  function mood(g, settleMs) {
    clearTimeout(settleT);
    [avatar, mini].forEach((m) => m && m.gesture(g));
    stateEl.textContent = TEXT[g] || "";
    if (g !== "reading") sr.textContent = TEXT[g] || "";
    if (settleMs) settleT = setTimeout(() => mood("idle"), settleMs);
    clearTimeout(sleepT);
    if (g === "idle") sleepT = setTimeout(() => mood("sleeping"), 120000);
  }

  // ---- What the user is looking at (from the calendar app) ----
  const ctx = () => (typeof window.A11Context === "function" ? window.A11Context() : null);
  function renderContext() {
    const c = ctx();
    ctxEl.innerHTML = c
      ? `<svg class="i" style="width:14px;height:14px" aria-hidden="true"><use href="#i-eye"/></svg><span>Viewing <strong>${esc(c.area)} · ${esc(c.period)}</strong></span>`
      : "";
    const list = c
      ? [`Is ${c.period} unusual for ${c.area}?`, `When is the fire season in ${c.area}?`, "What is a hotspot and how do satellites detect it?", "Why do MODIS and VIIRS count fires differently?"]
      : ["What is a hotspot and how do satellites detect it?", "Why do MODIS and VIIRS count fires differently?"];
    sugg.innerHTML = list.map((s) => `<li><button type="button">${esc(s)}</button></li>`).join("");
    sugg.querySelectorAll("button").forEach((b) => (b.onclick = () => ask(b.textContent)));
  }
  function contextSuffix() {
    const c = ctx();
    if (!c) return "";
    return `\n\n[App context — the user is viewing: ${c.area} (${c.kind}); ${c.period}; ${c.count} hotspots${c.partial ? " so far this month" : ""}; ` +
      `category "${c.category}"; a typical month like this has about ${c.typical}.` +
      (c.synthetic ? " The app currently shows illustrative data."
        : ` Counts are VIIRS-equivalent FIRMS hotspots${c.provisional ? " (provisional harmonization)" : ""}.`) + "]";
  }
  window.addEventListener("a11:context", () => { if (isOpen()) renderContext(); });

  // ---- Messages ----
  // All the page actions of one user turn render as a single collapsible stack (at the first action's place),
  // so a long run of steps does not flood the conversation.
  const openStacks = new Set();
  function actionStack(key, acts) {
    const el = document.createElement("div");
    const running = acts.find((a) => a.state === "run");
    const failed = acts.filter((a) => a.state === "fail").length;
    const open = openStacks.has(key);
    el.className = `ember-msg acts${acts.length > 1 ? " multi" : ""}${acts.length > 2 ? " many" : ""}${open ? " open" : ""}${running ? " run" : failed ? " fail" : acts.every((x) => x.state === "skip") ? " skip" : ""}`;
    const title = running
      ? `${esc(running.text)}…`
      : acts.length === 1 ? esc(acts[0].text) : `Used the page · ${acts.length} steps`;
    const meta = !running && failed ? `<small>${failed} failed</small>` : running && acts.length > 1 ? `<small>${acts.indexOf(running) + 1}/${acts.length}</small>` : "";
    el.innerHTML =
      `<button type="button" class="acts-head" aria-expanded="${open}"><i></i><span>${title}</span>${meta}` +
      `<svg class="i chev" aria-hidden="true"><use href="#i-down"/></svg></button>` +
      `<ol class="acts-list"${open ? "" : " hidden"}>${acts
        .map((a) => `<li class="${a.state || "ok"}"${a.error ? ` title="${esc(a.error)}"` : ""}><i></i><span>${esc(a.text)}</span></li>`)
        .join("")}</ol>`;
    // Toggle in place: a full render() would rebuild the log and jump to the bottom.
    el.querySelector(".acts-head").onclick = (e) => {
      const nowOpen = !openStacks.has(key);
      nowOpen ? openStacks.add(key) : openStacks.delete(key);
      el.classList.toggle("open", nowOpen);
      el.querySelector(".acts-list").hidden = !nowOpen;
      e.currentTarget.setAttribute("aria-expanded", String(nowOpen));
      if (nowOpen) el.scrollIntoView({ block: "nearest" });
    };
    return el;
  }

  // ---- Confirmation cards (agent.js calls EmberAgent.confirm before a download) ----
  let pendingConfirm = null; // { item, resolve }
  function answerConfirm(yes) {
    if (!pendingConfirm) return;
    const { item, resolve } = pendingConfirm;
    pendingConfirm = null;
    item.state = yes ? "yes" : "no";
    save(); render();
    if (narrow() && yes) setOpen(false, false); // get the drawer off the map again while Ember works
    resolve(yes);
  }
  function confirmInChat(text, yesLabel) {
    return new Promise((resolve) => {
      const item = { role: "confirm", text: String(text), yes: yesLabel || "Yes" };
      history.push(item);
      pendingConfirm = { item, resolve };
      if (!isOpen()) setOpen(true, false); // the question must be visible, also on narrow screens
      mood("curious");
      stateEl.textContent = "Waiting for your answer";
      render();
      setTimeout(() => panel.querySelector(".ember-msg.confirm.pending .yes")?.focus(), 0);
      // The Stop bar also answers "no".
      const poll = setInterval(() => {
        if (pendingConfirm?.item !== item) return clearInterval(poll);
        if (window.EmberAgent?.stopped) { clearInterval(poll); answerConfirm(false); }
      }, 300);
    });
  }
  if (window.EmberAgent) window.EmberAgent.confirm = confirmInChat;

  function render() {
    welcome.hidden = history.length > 0;
    log.innerHTML = "";
    const stacks = new Map(); // index of the turn's first action -> its actions
    let first = -1;
    history.forEach((m, i) => {
      if (m.role === "user") first = -1;
      else if (m.role === "act") {
        if (first < 0) { first = i; stacks.set(i, []); }
        stacks.get(first).push(m);
      }
    });
    history.forEach((m, i) => {
      if (m.role === "act") {
        if (stacks.has(i)) log.appendChild(actionStack(i, stacks.get(i)));
        return;
      }
      const el = document.createElement("div");
      el.className = "ember-msg " + m.role;
      if (m.role === "bot") el.innerHTML = md(m.text);
      else if (m.role === "confirm") {
        // Ember asks before doing something with consequences (a download). Only the live question has buttons.
        const live = pendingConfirm && pendingConfirm.item === m;
        el.classList.add(live ? "pending" : m.state === "yes" ? "yes" : "no");
        el.innerHTML =
          `<div class="cq">${md(m.text)}</div>` +
          (live
            ? `<div class="cb"><button type="button" class="yes">${esc(m.yes || "Yes")}</button><button type="button" class="no">Cancel</button></div>`
            : `<div class="cr">${m.state === "yes" ? "✓ Accepted" : "Cancelled"}</div>`);
        if (live) {
          el.querySelector(".yes").onclick = () => answerConfirm(true);
          el.querySelector(".no").onclick = () => answerConfirm(false);
        }
      } else if (m.role === "err") {
        el.innerHTML = `<span>${esc(m.text)}</span><button type="button">Try again</button>`;
        el.querySelector("button").onclick = () => { const q = m.retry; history.splice(i, 1); ask(q, true); };
      } else el.textContent = m.text;
      log.appendChild(el);
    });
    if (busy && !pendingConfirm) {
      const t = document.createElement("div");
      t.className = "ember-msg bot";
      t.innerHTML = '<span class="ember-typing" aria-label="Ember is typing"><i></i><i></i><i></i></span>';
      log.appendChild(t);
    }
    body.scrollTop = body.scrollHeight;
  }

  async function ask(text, isRetry) {
    const q = String(text || "").trim();
    if (!q || busy) return;
    if (!isRetry) history.push({ role: "user", text: q });
    busy = true; send.disabled = true; input.value = ""; autosize();
    save(); render();
    mood("thinking");
    const slow = setTimeout(() => { if (!pendingConfirm) mood("working"); }, 2500);
    const agentUI = window.EmberAgent;
    let hidPanel = false, halted = 0, ended = false;
    const MAX_STEPS = 8; // requests per question; the last one asks the agent to answer without more actions
    try {
      // The agent may answer with page actions; play them with the Ember cursor, send the results back, repeat.
      let req = { message: (q + contextSuffix()).slice(0, 2000), sessionId };
      for (let step = 0; step < MAX_STEPS; step++) {
        const r = await fetch("/api/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(req) });
        const data = await r.json();
        if (!r.ok || data.error) {
          history.push({ role: "err", text: data.error || "Something went wrong.", retry: q });
          mood("failed", 3000);
          ended = true;
          break;
        }
        const actions = Array.isArray(data.actions) ? data.actions : [];
        // Steps the server already ran (e.g. the document search) join the turn's action stack.
        if (Array.isArray(data.done)) data.done.forEach((d) => history.push({ role: "act", text: String(d.label || "Step"), state: d.ok === false ? "fail" : "ok" }));
        if (data.reply) history.push({ role: "bot", text: data.reply });
        if (!actions.length || !agentUI) {
          if (!data.reply) history.push({ role: "bot", text: "(empty reply)" });
          if (/\b(thanks|thank you|gracias)\b/i.test(q)) mood("thankful", 3000);
          else if (/\b(fire|fires|hotspots?|season|incendios?)\b/i.test(q)) mood("found", 2600);
          else mood("done", 1600);
          ended = true;
          break;
        }
        // After the user pressed Stop, answer further actions with "stopped" instead of playing them.
        if (halted) {
          if (halted++ > 1) break;
          req = { sessionId, final: true, toolResults: actions.map((a) => ({ id: a.id, result: { ok: false, error: "Stopped by the user." } })) };
          continue;
        }
        // On narrow screens the panel is a drawer over the map: get it out of the way while Ember works.
        if (narrow() && isOpen()) { setOpen(false, false); hidPanel = true; }
        agentUI.begin();
        mood("working");
        stateEl.textContent = "Using the page…";
        const results = [];
        for (const a of actions) {
          const item = { role: "act", text: agentUI.label(a), state: "run" };
          history.push(item); render();
          let result = await agentUI.run(a);
          item.state = result && result.declined ? "skip" : result && result.ok === false ? "fail" : "ok";
          if (result && result.error) item.error = result.error;
          const json = JSON.stringify(result ?? null);
          if (json.length > 3500) result = { ok: result.ok, truncated: json.slice(0, 3500) };
          results.push({ id: a.id, result });
          save(); render();
        }
        if (agentUI.stopped) { halted = 1; agentUI.end(); }
        req = { sessionId, toolResults: results, ...(halted || step >= MAX_STEPS - 2 ? { final: true } : {}) };
        mood("thinking");
      }
      // Never leave the chat hanging on "Thinking…" if the loop ran out without a final answer.
      if (!ended) {
        history.push({ role: "bot", text: "I did several steps but could not finish the answer. Could you ask it again, more specifically?" });
        mood("done", 1600);
      }
    } catch {
      history.push({ role: "err", text: "Network error. Check your connection.", retry: q });
      mood("sad", 3000);
    } finally {
      clearTimeout(slow);
      if (agentUI) agentUI.end();
      if (hidPanel) setOpen(true, false);
      busy = false; save(); render(); updateSend();
      if (!narrow()) input.focus();
    }
  }

  // ---- Composer ----
  function autosize() { input.style.height = "auto"; input.style.height = Math.min(140, input.scrollHeight) + "px"; }
  function updateSend() { send.disabled = busy || !input.value.trim(); }
  input.addEventListener("input", () => { autosize(); updateSend(); if (input.value.trim()) mood("reading", 1500); });
  input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); ask(input.value); } });
  form.addEventListener("submit", (e) => { e.preventDefault(); ask(input.value); });

  // ---- Open / close ----
  // Open/close slide: the panel stays in the layout until its closing animation ends (assistant.css: .ember-in / .ember-out).
  let closeTimer = 0, animReady = false;
  const ANIM_MS = 280, reduced = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
  function isOpen() { return app.classList.contains("cmp-open"); }
  function setOpen(open, focus = true) {
    const animate = animReady && !reduced() && open !== isOpen();
    clearTimeout(closeTimer); panel.classList.remove("ember-out");
    app.classList.toggle("cmp-open", open);
    if (open) {
      panel.hidden = false;
      if (animate) { panel.classList.add("ember-in"); void panel.offsetWidth; setTimeout(() => panel.classList.remove("ember-in"), 20); }
    } else if (animate && !panel.hidden) {
      panel.classList.add("ember-out");
      closeTimer = setTimeout(() => { panel.hidden = true; panel.classList.remove("ember-out"); }, ANIM_MS);
    } else panel.hidden = true;
    backdrop.hidden = !(open && narrow());
    toggle.setAttribute("aria-expanded", String(open));
    toggle.classList.toggle("on", open);
    toggle.title = open ? "Close Ember" : "Ask Ember, the A11 assistant";
    if (!narrow()) set(KEY_OPEN, open ? "1" : "0");
    if (open) {
      renderContext(); render();
      if (focus) { mood("curious", 1600); setTimeout(() => input.focus(), 0); }
    } else if (focus) toggle.focus();
  }
  toggle.addEventListener("click", () => setOpen(!isOpen()));
  $("ember-close").addEventListener("click", () => setOpen(false));
  backdrop.addEventListener("click", () => setOpen(false));
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && isOpen() && narrow()) setOpen(false); });
  $("ember-new").addEventListener("click", () => {
    if (busy) return;
    history = []; save();
    sessionId = newId(); set(KEY_SID, sessionId, sessionStorage);
    render(); mood("curious", 1200); input.focus();
  });
  if ($("ember-avatar")) $("ember-avatar").addEventListener("click", () => avatar && avatar.flare());

  mood("idle");
  updateSend();
  setOpen(!narrow() && get(KEY_OPEN) === "1", false);
  animReady = true; // no animation for the state restored on load
})();
