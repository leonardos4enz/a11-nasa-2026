// Ember agent hands: plays the page actions the Ember agent (server, chat-agent.js) asks for, with a visible cursor
// that glides to each control, clicks with a ripple and types character by character, while a glowing frame and a
// "Ember is using the page · Stop" bar show that the agent is in control.
// Every action goes through the real controls (the same buttons, inputs and handlers a person uses), so what the
// user sees is exactly what happened. Exposes window.EmberAgent = { run(action), begin(), end(), label(action) }.
// Relies on the globals of the calendar script in index.html (AREAS, area, select, Y0, CY, NOW_M, V0, SPAN, ...).
(() => {
  const $ = (id) => document.getElementById(id);
  const reduce = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
  const sleep = (ms) => new Promise((r) => setTimeout(r, reduce() ? Math.min(ms, 60) : ms));
  const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  const norm = (s) => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();

  // ---------- overlay: cursor, frame, control bar ----------
  const cursor = document.createElement("div");
  cursor.className = "eag-cursor";
  cursor.setAttribute("aria-hidden", "true");
  cursor.innerHTML =
    '<svg viewBox="0 0 24 24" width="26" height="26"><path d="M4 2.5 20 11l-7 1.8L9.6 20z" fill="var(--eag-ink)" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>' +
    '<span class="eag-tag">Ember</span>';
  const frame = document.createElement("div");
  frame.className = "eag-frame";
  frame.setAttribute("aria-hidden", "true");
  const bar = document.createElement("div");
  bar.className = "eag-bar";
  bar.setAttribute("role", "status");
  bar.innerHTML = '<span class="eag-dot"></span><span class="eag-what">Ember is using the page</span><button type="button">Stop</button>';
  document.body.append(frame, bar, cursor);

  let active = false, stopped = false, pos = null;
  bar.querySelector("button").onclick = () => { stopped = true; bar.querySelector(".eag-what").textContent = "Stopping…"; };

  function begin() {
    stopped = false;
    if (active) return;
    active = true;
    // Enter from the composer, like the agent reaching out of the chat.
    const from = $("ember-input")?.getBoundingClientRect();
    pos = from && from.width ? { x: from.left + 40, y: from.top + 10 } : { x: innerWidth - 60, y: innerHeight - 80 };
    cursor.style.transition = "none";
    cursor.style.transform = `translate(${pos.x}px, ${pos.y}px)`;
    void cursor.offsetWidth;
    document.documentElement.classList.add("eag-on");
    bar.querySelector(".eag-what").textContent = "Ember is using the page";
  }
  function end() {
    if (!active) return;
    active = false;
    document.documentElement.classList.remove("eag-on");
  }
  const say = (t) => { bar.querySelector(".eag-what").textContent = t; };

  async function moveTo(target, dur = 650) {
    let x, y;
    if (target instanceof Element) {
      const r0 = target.getBoundingClientRect();
      if (r0.bottom < 0 || r0.top > innerHeight || r0.right < 0 || r0.left > innerWidth) {
        target.scrollIntoView({ block: "center", inline: "nearest", behavior: reduce() ? "auto" : "smooth" });
        await sleep(350);
      }
      const r = target.getBoundingClientRect();
      x = r.left + Math.min(r.width / 2, 60);
      y = r.top + r.height / 2;
    } else ({ x, y } = target);
    const d = pos ? Math.hypot(x - pos.x, y - pos.y) : 400;
    const ms = reduce() ? 0 : Math.round(Math.max(280, Math.min(dur, 250 + d * 0.9)));
    cursor.style.transition = `transform ${ms}ms cubic-bezier(.45,.05,.2,1)`;
    cursor.style.transform = `translate(${x}px, ${y}px)`;
    pos = { x, y };
    await sleep(ms + 40);
  }
  function ripple() {
    if (!pos) return;
    const r = document.createElement("span");
    r.className = "eag-ripple";
    r.style.left = pos.x + "px";
    r.style.top = pos.y + "px";
    document.body.appendChild(r);
    cursor.classList.add("press");
    setTimeout(() => cursor.classList.remove("press"), 160);
    setTimeout(() => r.remove(), 650);
  }
  function halo(el) {
    if (!el) return;
    el.classList.add("eag-halo");
    setTimeout(() => el.classList.remove("eag-halo"), 900);
  }
  async function click(el) {
    if (!el) throw new Error("Control not found on the page.");
    await moveTo(el);
    ripple();
    halo(el);
    await sleep(120);
    el.click();
    await sleep(260);
  }
  async function type(input, text) {
    await moveTo(input);
    ripple();
    input.focus();
    input.value = "";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    for (const ch of String(text)) {
      if (stopped) throw new Error("Stopped by the user.");
      input.value += ch;
      input.dispatchEvent(new Event("input", { bubbles: true }));
      await sleep(55 + Math.random() * 45);
    }
    await sleep(220);
  }
  const check = () => { if (stopped) throw new Error("Stopped by the user."); };
  const view = () => (typeof window.A11Context === "function" ? window.A11Context() : null);
  const ready = () => { if (typeof AREAS === "undefined" || !AREAS.length || typeof area === "undefined" || !area) throw new Error("The calendar is still loading."); };

  // ---------- reading the page ----------
  const countryOf = (a) => (typeof areaCountry === "function" ? areaCountry(a) : "other");
  function state() {
    const tab = document.querySelector(".tabs button[aria-selected='true']")?.dataset.t || null;
    const ft = ["vegetation", "volcano", "industrial", "offshore"];
    const frp = { lo: "low", mid: "moderate", hi: "high" };
    return {
      view: view(),
      tab,
      layers: { hotspots: $("lyHot")?.checked, area_outline: $("lyArea")?.checked, forecast: $("lyFc")?.checked },
      hotspot_filter: {
        fire_types: [...document.querySelectorAll("#lyFilters [data-ft]")].filter((i) => i.checked).map((i) => ft[+i.dataset.ft]),
        intensity: [...document.querySelectorAll("#lyFilters [data-frp]")].filter((i) => i.checked).map((i) => frp[i.dataset.frp]),
      },
      theme: document.documentElement.dataset.theme === "dark" ? "dark" : "light",
      playing: typeof playing !== "undefined" && Boolean(playing),
      timeline: typeof Y0 !== "undefined" ? { first: `January ${Y0}`, latest: `${MONTHS[NOW_M]} ${CY}` } : null,
    };
  }
  function matches(q, country = "all") {
    const n = norm(q);
    const scored = [];
    for (const a of AREAS) {
      const c = countryOf(a);
      if (country !== "all" && c !== country) continue;
      const name = norm(a.name), hay = norm(`${a.name} ${a.kind}`);
      let s = 0;
      if (!n) s = 1;
      else if (name === n) s = 100;
      else if (name.startsWith(n)) s = 80;
      else if (name.includes(n)) s = 60;
      else if (hay.includes(n)) s = 40;
      else if (n.split(/\s+/).every((w) => hay.includes(w))) s = 30;
      if (s) scored.push({ a, s });
    }
    return scored.sort((x, y) => y.s - x.s || x.a.name.length - y.a.name.length).map((x) => x.a);
  }
  const brief = (a) => ({ name: a.name, kind: a.kind, country: countryOf(a) });

  // ---------- actions ----------
  const DOWNLOADS = {
    hotspots_csv: { id: "hotcsv", label: "the hotspots CSV", wait: 40 },
    monthly_csv: { id: "csv", label: "the monthly calendar CSV" },
    calendar_png: { id: "calpng", label: "the calendar picture (PNG)" },
    charts_png: { id: "chartpng", label: "the charts picture (PNG)" },
    summary_pdf: { id: "report", label: "the one-page summary (PDF)", wait: 4 },
  };
  const RANGES = {
    this_year: { preset: "year", label: "this year" },
    last_12_months: { preset: "12", label: "last 12 months" },
    last_fire_season: { preset: "season", label: "last fire season" },
    full_record: { preset: "all", label: "full record" },
  };
  const FT = { vegetation: "0", volcano: "1", industrial: "2", offshore: "3" };
  const FRP = { low: "lo", moderate: "mid", high: "hi" };
  const ACTIONS = {
    async get_view() {
      ready();
      return { ok: true, ...state() };
    },
    async get_month_data({ year }) {
      ready();
      const y = year ? Math.round(+year) : sel.y;
      if (!(y >= Y0 && y <= CY)) return { ok: false, error: `Years go from ${Y0} to ${CY}.` };
      const months = MONTHS.map((name, m) => {
        const v = val(area, y, m);
        if (v == null) return { month: name, future: true };
        const c = classify(v, base(area, y, m));
        const l = lo(area, y, m), h = hi(area, y, m);
        return { month: name, count: v, ...(l !== v || h !== v ? { estimate_low: l, estimate_high: h } : {}), category: CATS[c.k].l, typical: Math.round(c.med), ...(isPartial(y, m) ? { partial: true } : {}) };
      });
      const typ = typeof typical === "function" ? typical() : [];
      const peak = typ.map((t, m) => ({ month: MONTHS[m], typical: t })).sort((a, b) => b.typical - a.typical).slice(0, 3);
      return { ok: true, area: area.name, year: y, months, peak_months_typical: peak, baseline: `${typeof B0 !== "undefined" ? B0 : Y0}–${Y1}` };
    },
    async list_areas({ query = "", country = "all" }) {
      ready();
      const list = matches(query, country);
      return { ok: true, total: list.length, areas: list.slice(0, 25).map(brief) };
    },
    async select_area({ query }) {
      ready();
      const found = matches(query);
      if (!found.length) {
        const words = norm(query).split(/\s+/).filter((w) => w.length > 2);
        const near = AREAS.filter((a) => words.some((w) => norm(a.name).includes(w.slice(0, 4)))).slice(0, 8).map(brief);
        return { ok: false, error: `No area matches "${query}".`, suggestions: near };
      }
      const target = found[0];
      say(`Searching “${target.name}”`);
      if ($("pickPop").hidden) await click($("pickBtn"));
      check();
      if (typeof pickCountry !== "undefined" && pickCountry !== "all" && countryOf(target) !== pickCountry) {
        await click(document.querySelector('.segc button[data-c="all"]'));
      }
      // Type the exact name so the picker's own search lists it.
      await type($("pickQ"), target.name);
      check();
      const i = typeof pickItems !== "undefined" ? pickItems.indexOf(target) : -1;
      const li = i >= 0 ? $(`po-${i}`) : null;
      if (li) await click(li);
      else { if (typeof chooseArea === "function") chooseArea(target); }
      await sleep(350);
      return { ok: true, selected: brief(target), other_matches: found.slice(1, 5).map((a) => a.name), view: view() };
    },
    async set_month({ year, month }) {
      ready();
      const y = Math.round(+year), m = Math.round(+month) - 1;
      if (!(m >= 0 && m < 12)) return { ok: false, error: "Month must be 1 to 12." };
      if (y < Y0 || y > CY || (y === CY && m > NOW_M))
        return { ok: false, error: `Out of range. The timeline goes from January ${Y0} to ${MONTHS[NOW_M]} ${CY}.` };
      say(`Moving to ${MONTHS[m]} ${y}`);
      const strip = $("stripes"), r = strip.getBoundingClientRect(), i = (y - Y0) * 12 + m;
      const inView = typeof V0 !== "undefined" && SPAN && i >= V0 && i < V0 + SPAN;
      await moveTo(inView ? { x: r.left + ((i - V0 + 0.5) / SPAN) * r.width, y: r.top + r.height * 0.55 } : strip);
      ripple();
      select(y, m);
      await sleep(150);
      await moveTo($("cursor"), 400);
      halo($("nowLabel"));
      await sleep(250);
      return { ok: true, view: view() };
    },
    async jump_fire_month({ direction }) {
      ready();
      const b = $(direction === "previous" ? "prevFire" : "nextFire");
      if (b.disabled) return { ok: false, error: `There is no ${direction} month with hotspots.`, view: view() };
      say(direction === "previous" ? "Previous month with fires" : "Next month with fires");
      await click(b);
      return { ok: true, view: view() };
    },
    async open_tab({ tab }) {
      const b = document.querySelector(`.tabs button[data-t="${tab}"]`);
      if (!b) return { ok: false, error: `Unknown tab ${tab}.` };
      say(`Opening ${b.getAttribute("aria-label") || tab}`);
      if (b.getAttribute("aria-selected") !== "true") await click(b);
      else { await moveTo(b); halo(b); }
      return { ok: true, tab };
    },
    async set_layer({ layer, visible }) {
      const id = { hotspots: "lyHot", area_outline: "lyArea", forecast: "lyFc" }[layer];
      const box = id && $(id);
      if (!box) return { ok: false, error: `Unknown layer ${layer}.` };
      say(`${visible ? "Showing" : "Hiding"} ${layer.replace("_", " ")}`);
      if (box.checked !== Boolean(visible)) await click(box);
      else { await moveTo(box); halo(box.closest("label")); }
      return { ok: true, layers: state().layers };
    },
    async set_hotspot_filter({ fire_types, intensity }) {
      ready();
      if (!$("lyHot").checked) await click($("lyHot"));
      const btn = $("lyFBtn");
      if (btn.getAttribute("aria-expanded") !== "true") await click(btn);
      say("Filtering hotspots");
      const want = (list, map, attr) => {
        if (!Array.isArray(list)) return [];
        const on = new Set(list.map((k) => map[k]).filter(Boolean));
        return [...document.querySelectorAll(`#lyFilters [${attr}]`)].filter((i) => i.checked !== on.has(i.getAttribute(attr)));
      };
      for (const box of [...want(fire_types, FT, "data-ft"), ...want(intensity, FRP, "data-frp")]) {
        check();
        await click(box);
      }
      return { ok: true, hotspot_filter: state().hotspot_filter, view: view() };
    },
    async area_around_point({ lat, lon, radius_km = 25 }) {
      ready();
      if (!(Math.abs(lat) <= 90 && Math.abs(lon) <= 180)) return { ok: false, error: "Invalid coordinates." };
      say("Creating an area around a point");
      if ($("coord").hidden) await click($("coordBtn"));
      await type($("cLat"), String(+(+lat).toFixed(5)));
      await type($("cLon"), String(+(+lon).toFixed(5)));
      await type($("cRad"), String(Math.max(1, Math.min(150, Math.round(radius_km)))));
      check();
      const before = area;
      await click($("coord").querySelector('button[type="submit"]'));
      for (let t = 0; t < 40 && area === before && !$("cErr").textContent; t++) await sleep(250);
      if ($("cErr").textContent) return { ok: false, error: $("cErr").textContent };
      return { ok: area !== before, view: view() };
    },
    async download_report({ file, range }) {
      ready();
      const f = DOWNLOADS[file];
      if (!f) return { ok: false, error: `Unknown file ${file}.` };
      const r = range ? RANGES[range] : null;
      if (range && !r) return { ok: false, error: `Unknown range ${range}.` };
      // Nothing is downloaded without the user's yes, asked in the chat (assistant.js provides confirm()).
      const ask = `Download **${f.label}** for **${area.name}**${r ? ` (${r.label})` : ""}?`;
      const yes = typeof window.EmberAgent.confirm === "function" ? await window.EmberAgent.confirm(ask, "Download") : false;
      if (!yes) return { ok: false, declined: true, error: "The user declined the download." };
      check();
      // Move fast: browsers only let a page open a new window (the PDF summary) shortly after the user's click.
      say(`Downloading ${f.label}`);
      const tab = document.querySelector('.tabs button[data-t="data"]');
      if (tab.getAttribute("aria-selected") !== "true") await click(tab);
      if (r) await click(document.querySelector(`#rgPresets [data-p="${r.preset}"]`));
      $("dlMsg").textContent = "";
      await click($(f.id));
      for (let t = 0; t < (f.wait || 6) && !$("dlMsg").textContent; t++) await sleep(500);
      const msg = $("dlMsg").textContent;
      if (/allow pop-ups|could not|failed|error/i.test(msg)) return { ok: false, error: msg };
      return { ok: true, file: f.label, range: `${$("rgFrom").value} to ${$("rgTo").value}`, message: msg || "Started." };
    },
    async set_theme({ theme }) {
      const isDark = document.documentElement.dataset.theme === "dark";
      say(`Switching to ${theme} mode`);
      if ((theme === "dark") !== isDark) await click($("theme"));
      else { await moveTo($("theme")); halo($("theme")); }
      return { ok: true, theme: state().theme };
    },
    async play_timeline({ playing: want }) {
      ready();
      say(want ? "Playing the timeline" : "Pausing the timeline");
      if (Boolean(playing) !== Boolean(want)) await click($("play"));
      return { ok: true, playing: Boolean(playing), view: view() };
    },
  };

  const LABELS = {
    get_view: () => "Reading the screen",
    get_month_data: (a) => `Reading the numbers${a.year ? ` for ${a.year}` : ""}`,
    list_areas: (a) => (a.query ? `Looking up areas: “${a.query}”` : "Listing areas"),
    select_area: (a) => `Searching “${a.query}”`,
    set_month: (a) => `Setting ${MONTHS[(a.month | 0) - 1] || "month"} ${a.year}`,
    jump_fire_month: (a) => `${a.direction === "previous" ? "Previous" : "Next"} month with fires`,
    open_tab: (a) => `Opening the ${a.tab} tab`,
    set_layer: (a) => `${a.visible ? "Showing" : "Hiding"} ${String(a.layer).replace("_", " ")}`,
    set_hotspot_filter: () => "Filtering hotspots",
    area_around_point: (a) => `Area around ${a.lat}, ${a.lon}`,
    set_theme: (a) => `${a.theme === "dark" ? "Dark" : "Light"} mode`,
    download_report: (a) => `Download: ${(DOWNLOADS[a.file] || { label: a.file }).label}${a.range && RANGES[a.range] ? ` · ${RANGES[a.range].label}` : ""}`,
    play_timeline: (a) => (a.playing ? "Playing the timeline" : "Pausing the timeline"),
  };
  const label = (a) => (LABELS[a.name] ? LABELS[a.name](a.args || {}) : a.name);

  async function run(action) {
    const fn = ACTIONS[action.name];
    if (!fn) return { ok: false, error: `Unknown action ${action.name}.` };
    if (stopped) return { ok: false, error: "Stopped by the user." };
    try {
      return await fn(action.args || {});
    } catch (err) {
      // Don't leave a half-used popover open (e.g. stopped while typing in the area search).
      if ($("pickPop") && !$("pickPop").hidden && typeof openPick === "function") openPick(false);
      return { ok: false, error: err.message || String(err) };
    }
  }

  window.EmberAgent = { run, begin, end, label, get stopped() { return stopped; } };
})();
