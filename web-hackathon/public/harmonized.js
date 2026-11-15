// Loads the harmonized monthly series (contract: ../DATA_CONTRACT.md) and turns it into the shape the
// calendar uses. This is the only place in the page that knows the file format.
//
//   const H = await A11Harmonized.load();
//   H.areas[0].d[2024][2]   -> March 2024 count (null for months with no data)
//   H.areas[0].lo / .hi / .src have the same [year][month] layout
//   const a = await A11Harmonized.drawn([[lat, lon], ...])   -> same layout for a drawn polygon (needs the API)
//
// Source: the server API (/api/harmonized/, backed by a11-db). If it is not there — e.g. a plain static
// server in local preview — the fake files in /data/harmonized/ are used instead.
(function () {
  const SOURCES = ["/api/harmonized/", "/data/harmonized/"];
  const SCHEMA = 1;
  let span = null; // { y0, y1, ty, tm } of the last load, used to shape drawn areas

  async function getJson(url) {
    const res = await fetch(url, { cache: "no-cache" });
    if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
    return res.json();
  }

  function grid(y0, y1, fill) {
    const g = {};
    for (let y = y0; y <= y1; y++) g[y] = Array(12).fill(fill);
    return g;
  }

  function toArea(raw, y0, y1) {
    const a = { id: raw.id, name: raw.name, kind: raw.kind, poly: raw.polygon,
      d: grid(y0, y1, null), lo: grid(y0, y1, null), hi: grid(y0, y1, null), src: grid(y0, y1, null) };
    for (const r of raw.months) {
      const y = +r.month.slice(0, 4), m = +r.month.slice(5, 7) - 1;
      if (!(y in a.d) || m < 0 || m > 11) continue;
      a.d[y][m] = r.count;
      a.lo[y][m] = r.low ?? r.count;
      a.hi[y][m] = r.high ?? r.count;
      a.src[y][m] = r.source || "VIIRS";
    }
    // Months with no row inside the covered period count as 0 (no detections), never as missing.
    for (let y = y0; y <= y1; y++) for (let m = 0; m < 12; m++) if (a.d[y][m] == null) {
      a.d[y][m] = 0; a.lo[y][m] = 0; a.hi[y][m] = 0; a.src[y][m] = "VIIRS";
    }
    return a;
  }

  // Future months of the current year go back to null so the page treats them as "no data yet".
  function clipFuture(a) {
    for (let m = span.tm; m < 12; m++) a.d[span.ty][m] = a.lo[span.ty][m] = a.hi[span.ty][m] = a.src[span.ty][m] = null;
    return a;
  }

  async function load() {
    let lastErr;
    for (const base of SOURCES) {
      try { return await loadFrom(base); } catch (err) { lastErr = err; console.warn("Harmonized source failed:", base, err.message); }
    }
    throw lastErr;
  }

  async function loadFrom(base) {
    const meta = await getJson(base + (base.startsWith("/api/") ? "index" : "index.json"));
    if (meta.error) throw new Error(meta.error);
    if (meta.schema_version !== SCHEMA) throw new Error(`Unsupported harmonized schema_version ${meta.schema_version}`);
    const [ty, tm, td] = meta.data_through.split("-").map(Number);
    const y0 = meta.baseline.first_year, y1 = ty;
    span = { y0, y1, ty, tm };
    const raws = await Promise.all(meta.areas.map((a) => getJson(base + a.file)));
    const areas = raws.map((r) => clipFuture(toArea(r, y0, y1)));
    // Last year that still has MODIS-derived months: the "MODIS era" shown with uncertainty.
    let eraEnd = y0 - 1;
    areas.forEach((a) => { for (let y = y0; y <= y1; y++) if (a.src[y].some((s) => s && s !== "VIIRS")) eraEnd = Math.max(eraEnd, y); });
    return {
      meta, areas, source: base, synthetic: meta.synthetic !== false, provisional: Boolean(meta.provisional),
      firstYear: y0, baselineLast: meta.baseline.last_year,
      currentYear: ty, currentMonth: tm - 1, currentDay: td, eraEnd,
      generatedAt: new Date(meta.generated_at),
    };
  }

  // Series for a polygon drawn in the page, computed by the database. Throws if the API is not available.
  async function drawn(points) {
    if (!span) throw new Error("Call load() first");
    const res = await fetch(SOURCES[0] + "polygon", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ polygon: points }),
    });
    const body = res.ok ? await res.json() : { error: `HTTP ${res.status}` };
    if (body.error) throw new Error(body.error);
    const a = clipFuture(toArea({ id: "drawn", name: "", kind: "", polygon: points, months: body.months }, span.y0, span.y1));
    a.km2 = body.area_km2;
    return a;
  }

  // ---- Detections and raw sensor counts (need the API; they throw on a plain static server) ----
  // `spec` is { area: "<id>" } for an area of the picker or { polygon: [[lat, lon], ...] } for a drawn one.
  async function post(url, body) {
    const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res;
  }

  // Raw monthly counts per satellite family, before harmonization: [{ month, modis, noaa20, snpp, noaa21 }].
  async function raw(spec) {
    const body = await (await post(SOURCES[0] + "raw", spec)).json();
    if (body.error) throw new Error(body.error);
    return body.months;
  }

  // Strongest detections for the map: { total, byType, points: [[lat, lon, frp, conf_class, satellite, fire_type], ...] }.
  // types: FIRMS fire types to include (0 vegetation, 1 volcano, 2 static land source, 3 offshore); default [0].
  async function points(spec, from, to, satellites, types) {
    // Nominal/high confidence only, the detections the harmonized count uses, so dots and count agree.
    const body = await (await post("/api/hotspots", { ...spec, from, to, satellites, types, format: "json", minConfidence: "nominal" })).json();
    if (body.error) throw new Error(body.error);
    // Older server without the filter: drop low-confidence points here (exact when every point was returned).
    if (body.points.some((p) => p[3] === "l")) {
      const complete = body.points.length >= body.total;
      body.points = body.points.filter((p) => p[3] !== "l");
      if (complete) {
        body.total = body.points.length;
        body.byType = {};
        for (const p of body.points) body.byType[p[5] || 0] = (body.byType[p[5] || 0] || 0) + 1;
      }
    }
    return body;
  }

  // Every detection in the area and dates as CSV: { blob, rows, truncated }.
  async function csv(spec, from, to) {
    const res = await post("/api/hotspots", { ...spec, from, to, format: "csv" });
    if (!/text\/csv/.test(res.headers.get("Content-Type") || "")) {
      const body = await res.json().catch(() => ({}));
      throw new Error(body.error || "The server did not return a CSV file.");
    }
    return { blob: await res.blob(), rows: Number(res.headers.get("X-Rows") || 0), truncated: res.headers.get("X-Truncated") === "1" };
  }

  window.A11Harmonized = { load, drawn, raw, points, csv };
})();
