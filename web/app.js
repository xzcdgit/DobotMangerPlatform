"use strict";

/* 总览看板：工位位置稳定；筛选只变暗不拆 DOM；告警在固定侧栏 */
const POLL_MS = PAGE_POLL_MS;
const NO_TYPE = "未分类";
/* 总览按产线 group 分组；组/站顺序均跟随 config.json stations 数组 */
const CMD = {
  reset: { label: "复位", confirm: "将依次：清除报警 → 下使能并等待完成 → 上使能并等待完成（约数秒到十几秒）。设备可能动作，请先确认现场安全。", danger: true },
  start: { label: "开始", confirm: "将向该工作站脉冲「开始」线圈（需已配置默认运行工程且处于自动模式）。请先确认现场安全。", danger: false },
  stop: { label: "停止", confirm: "将向该工作站脉冲「停止」线圈，正在进行的动作会被中断。", danger: true },
};

const view = {
  level: "all",
  query: "",
  seenStops: new Set(),
  firstRender: true,
  soundOn: false,
  alertsClearedAt: 0,
  audio: null,
  busy: false,
  switching: false,
  boardBuilt: false,
  boardSig: "",
  stationOrder: [],
};

/* ---------- 顶栏 ---------- */
function renderHost(host) {
  const ip = host && host.primary;
  const ips = (host && host.ips) || [];
  const others = ips.filter((x) => x !== ip);
  $("hostIp").textContent = ip || "未检测到";
  $("host").classList.toggle("warn", !ip);
  $("host").classList.toggle("off-net", Boolean(ip) && !host.matched);
  $("hostMore").textContent = others.length ? `+${others.length}` : "";
  $("hostMore").hidden = !others.length;
  const hint = !ip ? "没有检测到可用的 IPv4 地址，请确认电脑已连接到工作站所在的网络"
    : host.matched ? "与工作站在同一网段，可作为 Modbus TCP 主站地址"
    : "与各工作站不在同一网段，请确认网线接在工作站所在的网络上";
  $("hostHint").textContent = hint;
  setHTML($("hostList"), ips.map((x) => `<li class="${x === ip ? "cur" : ""}"><span>${esc(x)}</span>${x === ip ? "<em>当前使用</em>" : ""}</li>`).join(""));
  $("hostList").hidden = !ips.length;
}

async function copyHostIp() {
  const ip = ui.state && ui.state.host && ui.state.host.primary;
  if (!ip) return;
  try {
    await navigator.clipboard.writeText(ip);
    toast(`已复制本机 IP：${ip}`, "ok");
  } catch (_) {
    toast(`本机 IP：${ip}`, "info");
  }
}

/* ---------- 模式 ---------- */
const LIVE_NAME = { modbus: "Modbus 实时", report: "设备上报" };

function renderMode(s) {
  $("mode").setAttribute("aria-checked", String(s.test));
  $("modeName").textContent = s.test ? "测试模式" : "真实模式";
  $("modeSub").textContent = s.test ? "虚拟数据" : LIVE_NAME[s.liveMode] || "真实数据";
  document.body.classList.toggle("is-test", s.test);
  $("testBanner").hidden = !s.test;
}

function renderSampleRate(s) {
  const el = $("sampleRate");
  if (!el || !s) return;
  const mb = fmtPollSec(s.pollInterval);
  const page = fmtPollSec(POLL_MS / 1000);
  const regs = (s.actionRegister != null && s.faultRegister != null)
    ? ` · 寄存器 ${s.actionRegister}/${s.faultRegister}`
    : "";
  el.innerHTML = `Modbus <b>${esc(mb)}</b> · 页面 <b>${esc(page)}</b>${esc(regs)}`;
}

function resetViewState() {
  view.seenStops = new Set();
  view.firstRender = true;
  view.alertsClearedAt = 0;
  view.boardBuilt = false;
  view.boardSig = "";
  view.stationOrder = [];
  closeDrawer();
}

async function toggleMode() {
  const s = ui.state;
  if (view.switching) return;
  if (!s) { toast("还没有连上监控服务，请稍后再试", "error"); return; }
  const toTest = !s.test;
  const live = LIVE_NAME[s.liveMode] || "真实";
  const answer = await ask(toTest
    ? { title: "切换到测试模式", okText: "切换到测试模式", danger: false,
        text: "工作站将显示虚拟的模拟状态，不再读取真实设备；复位 / 开始 / 停止也只作用于模拟数据，不会发给设备。当前显示的状态和提醒会清空。" }
    : { title: "切换到真实模式", okText: "切换到真实模式", danger: true,
        text: `将改为读取真实设备状态（${live}）；复位 / 开始 / 停止会真正下发给设备。当前显示的模拟状态和提醒会清空。` });
  if (!answer) return;
  view.switching = true;
  pollSeq += 1; // 丢掉切换前还在飞的 /api/state，避免旧快照把看板画回去
  $("mode").disabled = true;
  try {
    const res = await api("POST", "/api/mode", { test: toTest, pin: answer.pin });
    if (res.changed) resetViewState();
    toast(!res.changed ? "已经是这个模式了（可能刚被其他电脑切换）"
      : toTest ? "已切换到测试模式：显示虚拟状态" : "已切换到真实模式：正在读取设备", "ok");
  } catch (e) {
    toast(`切换失败。${e.message}`, "error");
  } finally {
    view.switching = false;
    $("mode").disabled = false;
    await poll();
    refreshLogsIfOpen();
  }
}

/* ---------- KPI（只改数字，不重建结构） ---------- */
function setLevelFilter(level) {
  view.level = level;
  document.querySelectorAll("#levelFilter [data-level]").forEach((b) => {
    b.setAttribute("aria-pressed", String(b.dataset.level === level));
  });
  document.querySelectorAll(".kpi-cell[data-level]").forEach((b) => {
    b.setAttribute("aria-pressed", String(b.dataset.level === level));
  });
  applyFilter();
}

function renderTally(stations) {
  const n = { ok: 0, warn: 0, stop: 0, offline: 0, pending: 0 };
  for (const s of stations) n[viewLevel(s)] += 1;
  $("kpiAll").textContent = String(stations.length);
  $("kpiStop").textContent = String(n.stop);
  $("kpiWarn").textContent = String(n.warn);
  $("kpiOff").textContent = String(n.offline);
  $("kpiOk").textContent = String(n.ok);
  document.querySelector('.kpi-cell[data-level="stop"]').classList.toggle("is-hot", n.stop > 0);

  const bar = [
    ["ok", n.ok], ["warn", n.warn], ["stop", n.stop], ["offline", n.offline], ["pending", n.pending],
  ].filter(([, c]) => c);
  const color = (lv) => (lv === "offline" || lv === "pending" ? "off" : lv);
  setHTML($("health"), bar.map(([lv, c]) => `<i style="flex:${c};background:var(--${color(lv)})"></i>`).join(""));
  const bad = n.stop + n.warn + n.offline;
  $("healthText").textContent = bad ? `${bad} 台告警` : "全部正常";
}

function isMatch(s) {
  const lv = viewLevel(s);
  if (view.level === "attention") {
    if (lv !== "stop" && lv !== "warn" && lv !== "offline") return false;
  } else if (view.level !== "all" && lv !== view.level) {
    return false;
  }
  const q = view.query.trim().toLowerCase();
  if (!q) return true;
  return `${s.name} ${s.no} ${s.ip} ${s.action ?? ""} ${s.code ?? ""} ${s.fault || ""} ${codeName(s.action ?? s.code)} ${s.fault ? codeName(s.fault) : ""}`.toLowerCase().includes(q);
}

function applyFilter() {
  if (!ui.state) return;
  const byId = new Map(ui.state.stations.map((s) => [s.id, s]));
  document.querySelectorAll(".card[data-id]").forEach((el) => {
    const s = byId.get(el.dataset.id);
    el.classList.toggle("is-dim", !(s && isMatch(s)));
    el.classList.toggle("is-sel", ui.openStation === el.dataset.id);
  });
}

/* ---------- 看板：首次建 DOM，之后只更新内容与 class ---------- */
function groupOf(s) {
  return (s.group && String(s.group).trim()) || s.type || NO_TYPE;
}

function stableStations(stations) {
  /* 后端已按 config.json 数组顺序下发，前端不再重排 */
  return stations.slice();
}

function cardShell(s) {
  return `<button type="button" class="card" data-id="${esc(s.id)}" data-level="pending" aria-label="">
    <span class="name">${esc(s.name)} <span class="code">···</span></span>
    <span class="lv">连接中</span>
    <span class="step">等待第一次读数</span>
    <span class="beat">本步 —</span>
    <span class="meta"><span class="addr">${esc(s.ip)}:${esc(s.port)}</span><span class="dur" data-since="${s.since}">—</span></span>
  </button>`;
}

/* ---------- 节拍：按工位固定动作顺序。只计已走完的步，典型值用中位数，偏长的圈不抬高节拍 ---------- */
const FLOW_STARTUP = [100, 101, 104, 105, 110, 111, 112, 113, 114];
const FLOW_BY_TYPE = {
  "上料臂": [180, 181, 182, 200, 201, 202, 204, 205, 206, 209, 210, 212, 213, 214, 220, 221, 223, 184, 185, 186, 187],
  "托举臂": [400, 401, 402, 404, 405, 406, 407],
  "灌装": [180, 181, 182, 500, 501, 502, 503, 505, 184, 185, 186, 187],
  "开盖": [180, 181, 182, 200, 204, 206, 506, 507, 508, 184, 185, 186, 187],
  "气垫取放": [180, 181, 200, 204, 206, 210, 212, 514, 515, 213, 214, 184, 185, 186, 187],
  "粉扑": [180, 181, 182, 200, 204, 205, 206, 210, 212, 213, 214, 510, 511, 184, 185, 186, 187],
};
const FLOW_GENERIC = [180, 181, 182, 184, 185, 186, 187];

function actionFlow(type) {
  const custom = ui.state && ui.state.beats;
  // 配置里的 _beats 优先于内置表里没有的工位（如上纸板的 250/251/252）
  if (custom && custom.length && !FLOW_BY_TYPE[type]) return custom.slice();
  const body = FLOW_BY_TYPE[type] || FLOW_GENERIC;
  const out = [];
  const seen = new Set();
  for (const c of FLOW_STARTUP.concat(body)) {
    if (seen.has(c)) continue;
    seen.add(c);
    out.push(c);
  }
  return out;
}

const STARTUP_CATS = new Set(["启动", "EAP初始化"]);

function isStartupCode(code) {
  if (code === null || code === undefined) return false;
  const info = ui.codes[String(code)];
  return Boolean(info && STARTUP_CATS.has(info.category));
}

function median(xs) {
  const s = xs.slice().sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

/* 去掉把节拍抬高的长尾。少于 3 个样本时，只有「长的那次超过短的 3 倍且多出 5 秒」才丢掉。 */
function trimLong(items, secOf) {
  const pool = items.slice();
  let guard = pool.length;
  while (pool.length >= 2 && guard--) {
    let hi = pool[0];
    for (const item of pool) if (secOf(item) > secOf(hi)) hi = item;
    const rest = pool.filter((item) => item !== hi);
    const medRest = median(rest.map(secOf));
    const hiSec = secOf(hi);
    if (!(hiSec > medRest * 3 && hiSec - medRest > 5)) break;
    pool.splice(pool.indexOf(hi), 1);
  }
  return pool;
}

function completedSegments(station) {
  const hist = station.history || [];
  const segs = [];
  for (let i = 0; i < hist.length - 1; i++) {
    const a = hist[i];
    const sec = hist[i + 1].t - a.t;
    if (!(sec > 0)) continue;
    segs.push({ code: a.code, t: a.t, end: hist[i + 1].t, sec, fault: Boolean(a.fault) });
  }
  return segs;
}

function faultWindows(station) {
  const alerts = (ui.state && ui.state.alerts) || [];
  const wins = [];
  let open = null;
  for (const e of alerts) {
    if (e.id !== station.id) continue;
    if (e.level === "stop" || e.level === "warn") {
      if (open == null) open = e.t;
    } else if (e.level === "ok" && open != null) {
      wins.push([open, e.t]);
      open = null;
    }
  }
  if (open != null) wins.push([open, Infinity]);
  return wins;
}

function overlapsFault(t0, t1, wins) {
  return wins.some((w) => t0 < w[1] && t1 > w[0]);
}

function pointInFault(t, wins) {
  return wins.some((w) => t >= w[0] && t < w[1]);
}

function cycleMarker(station, flow) {
  const counts = new Map();
  for (const h of station.history || []) {
    if (h.code === null || h.code === undefined) continue;
    const k = String(h.code);
    counts.set(k, (counts.get(k) || 0) + 1);
  }
  const pick = (pred) => {
    let best = null;
    for (const [k, n] of counts) {
      if (n < 2 || !pred(Number(k))) continue;
      if (!best || n > best.n) best = { code: Number(k), n };
    }
    return best;
  };
  const done = pick((c) => c === 187 || codeName(c) === "周期完成");
  if (done) return { code: done.code, how: "周期完成" };
  const ready = pick((c) => c === 186 || codeName(c) === "回到就绪");
  if (ready) return { code: ready.code, how: "回到就绪" };
  for (const c of flow) {
    if (isStartupCode(c)) continue;
    if ((counts.get(String(c)) || 0) >= 2) return { code: c, how: codeName(c) };
  }
  let best = null;
  for (const [k, n] of counts) {
    const code = Number(k);
    if (n < 2 || isStartupCode(code)) continue;
    if (!best || n > best.n) best = { code, n };
  }
  return best ? { code: best.code, how: codeName(best.code) } : null;
}

function analyzeBeats(station) {
  const flow = actionFlow(station.type);
  const wins = faultWindows(station);
  const segs = completedSegments(station);
  for (const seg of segs) {
    seg.bad = seg.code === null || seg.code === undefined || seg.fault || overlapsFault(seg.t, seg.end, wins);
  }
  const byCode = new Map();
  for (const seg of segs) {
    if (seg.code === null || seg.code === undefined) continue;
    const k = String(seg.code);
    if (!byCode.has(k)) byCode.set(k, []);
    byCode.get(k).push(seg);
  }

  const marker = cycleMarker(station, flow);
  const cycles = [];
  if (marker) {
    const hist = station.history || [];
    let prev = null;
    let dirty = false;
    for (const h of hist) {
      if (h.code === null || h.code === undefined || h.fault || isStartupCode(h.code) || pointInFault(h.t, wins)) {
        dirty = true;
      }
      if (h.code !== marker.code) continue;
      if (prev != null) {
        const sec = h.t - prev;
        if (sec > 0.5) cycles.push({ sec, dirty, t: h.t });
      }
      prev = h.t;
      dirty = Boolean(h.fault) || pointInFault(h.t, wins);
    }
  }
  const clean = cycles.filter((c) => !c.dirty);
  const base = clean.length ? clean : cycles;
  const kept = trimLong(base, (c) => c.sec);
  const last = cycles.length ? cycles[cycles.length - 1] : null;
  const cyc = kept.length ? {
    n: kept.length,
    avg: median(kept.map((c) => c.sec)),
    last: last ? last.sec : null,
    lastKept: Boolean(last && kept.includes(last)),
    lastDirty: Boolean(last && last.dirty),
    dropped: cycles.length - kept.length,
    how: marker.how,
    max: Math.max(...cycles.map((c) => c.sec)),
  } : null;

  const rowOf = (code, kind) => {
    const list = byCode.get(String(code)) || [];
    const blank = { code, name: codeName(code), kind, n: 0, last: null, avg: null, max: null };
    if (!list.length) return blank;
    const good = list.filter((s) => !s.bad);
    const pool = trimLong(good.length ? good : list, (s) => s.sec);
    return {
      code,
      name: codeName(code),
      kind,
      n: list.length,
      last: list[list.length - 1].sec,
      avg: median(pool.map((s) => s.sec)),
      max: Math.max(...list.map((s) => s.sec)),
    };
  };

  const inFlow = new Set(flow);
  const body = [];
  const startup = [];
  for (const code of flow) {
    if (isStartupCode(code)) {
      const row = rowOf(code, "startup");
      if (row.n) startup.push(row);
    } else {
      body.push(rowOf(code, "body"));
    }
  }
  const outside = [...byCode.keys()].map(Number).filter((c) => !inFlow.has(c)).sort((a, b) => a - b);
  const startupExtra = outside.filter(isStartupCode).map((code) => rowOf(code, "startup"));
  const extras = outside.filter((c) => !isStartupCode(c)).map((code) => rowOf(code, "extra"));
  const rows = body.concat(startup, startupExtra, extras);
  return { rows, cyc, byCode: new Map(rows.map((r) => [r.code, r])) };
}

function beatModel(station) {
  const hist = station.history || [];
  const last = hist.length ? hist[hist.length - 1].t : 0;
  const alertN = ui.state && ui.state.alerts ? ui.state.alerts.length : 0;
  const key = `${hist.length}:${last}:${alertN}:${station.type}`;
  if (station._beatKey === key && station._beatModel) return station._beatModel;
  const model = analyzeBeats(station);
  station._beatKey = key;
  station._beatModel = model;
  return model;
}

function cycleBeat(station) {
  return beatModel(station).cyc;
}

function avgForCode(station, code) {
  if (code === null || code === undefined) return null;
  const g = beatModel(station).byCode.get(code);
  return g && g.n ? g.avg : null;
}

function buildBoard(stations) {
  const list = stableStations(stations);
  view.stationOrder = list.map((s) => s.id);
  view.boardSig = list.map((s) => `${s.id}@${groupOf(s)}`).join("|");
  const groups = new Map();
  for (const s of list) {
    const g = groupOf(s);
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(s);
  }
  /* Map 插入顺序 = config.json 中各组首次出现顺序 */
  const order = [...groups.keys()];
  $("fleet").innerHTML = order.map((g) => {
    const items = groups.get(g);
    return `<section class="group" data-group="${esc(g)}">
      <div class="group-head"><h2>${esc(g)}</h2><span data-group-meta>${items.length} 台</span></div>
      <div class="cards">${items.map(cardShell).join("")}</div>
    </section>`;
  }).join("");
  view.boardBuilt = true;
}

function patchCard(el, s, now) {
  const lv = viewLevel(s);
  const lvText = s.known ? levelLabel(s, now) : LEVEL_TEXT.pending;
  // 动作码与异常码分开展示：大码/步骤跟动作；有异常时另标异常，不再用异常盖住动作
  const hasFault = s.known && s.fault;
  const code = !s.known ? "···" : (s.code === null ? "OFF" : String(s.action ?? s.code ?? "···"));
  let step = "等待第一次读数";
    if (s.known) {
    if (s.code === null) step = codeName(null);
    else {
      step = codeName(s.action ?? s.code);
      if (hasFault) {
        step += ` · 异常 ${s.fault} ${codeName(s.fault)}`;
        if (s.faultSince) step += ` ${fmtDur(now - s.faultSince)}`;
      }
    }
  }
  const paused = s.paused ? `<span class="tag">已暂停</span>` : "";
  const curSec = now - s.since;
  const beatCode = s.action ?? s.code;
  const avg = s.known ? avgForCode(s, beatCode) : null;
  const cyc = s.known ? cycleBeat(s) : null;

  if (el.dataset.level !== lv) el.dataset.level = lv;
  const lvEl = el.querySelector(".lv");
  const nameEl = el.querySelector(".name");
  const stepEl = el.querySelector(".step");
  const beatEl = el.querySelector(".beat");
  const durEl = el.querySelector(".dur");

  if (lvEl.textContent !== lvText) lvEl.textContent = lvText;
  const nameHtml = `${esc(s.name)}${paused} <span class="code">${esc(code)}</span>`;
  if (nameEl._html !== nameHtml) { nameEl._html = nameHtml; nameEl.innerHTML = nameHtml; }
  if (stepEl.textContent !== step) stepEl.textContent = step;

  let beatText = s.known ? `本步 <b>${fmtBeat(curSec)}</b>` : "本步 —";
  if (avg !== null && avg > 0) beatText += ` · 典型 ${fmtBeat(avg)}`;
  if (cyc) beatText += ` · 节拍 ${fmtBeat(cyc.avg)}`;
  if (beatEl && beatEl._html !== beatText) { beatEl._html = beatText; beatEl.innerHTML = beatText; }

  if (durEl) {
    durEl.dataset.since = String(s.since);
    durEl.textContent = fmtDur(curSec);
  }
  el.setAttribute("aria-label", `${stationLabel(s)} ${lvText} ${step}`);
}

function renderFleet(state) {
  const list = stableStations(state.stations);
  const sig = list.map((s) => `${s.id}@${groupOf(s)}`).join("|");
  if (!view.boardBuilt || view.boardSig !== sig) buildBoard(state.stations);

  const byId = new Map(state.stations.map((s) => [s.id, s]));
  document.querySelectorAll(".card[data-id]").forEach((el) => {
    const s = byId.get(el.dataset.id);
    if (s) patchCard(el, s, state.now);
  });

  document.querySelectorAll(".group").forEach((g) => {
    const cards = [...g.querySelectorAll(".card")];
    const bad = cards.filter((c) => {
      const lv = c.dataset.level;
      return lv === "stop" || lv === "warn" || lv === "offline";
    }).length;
    const meta = g.querySelector("[data-group-meta]");
    if (meta) meta.innerHTML = `${cards.length} 台${bad ? ` · <em>${bad} 告警</em>` : ""}`;
  });

  applyFilter();
}

function badStations(stations) {
  return stations
    .filter((s) => {
      const lv = viewLevel(s);
      return lv === "stop" || lv === "warn" || lv === "offline";
    })
    .sort((a, b) => {
      const rank = { stop: 0, warn: 1, offline: 2 };
      return rank[viewLevel(a)] - rank[viewLevel(b)] || a.no - b.no;
    });
}

function renderActive(state) {
  const list = badStations(state.stations);
  const badge = $("activeCount");
  badge.textContent = String(list.length);
  badge.classList.toggle("has-alarm", list.length > 0);

  const html = list.map((s) => {
    const lv = viewLevel(s);
    const code = !s.known ? "···" : (s.code === null ? "OFF" : (s.fault || (s.action ?? s.code)));
    return `<button type="button" class="alarm-item ${lv}" data-id="${esc(s.id)}">
      <span class="ai-mark" aria-hidden="true"></span>
      <span class="ai-body"><b>${esc(attentionText(s))}</b><small>${esc(s.name)} · #${esc(s.no)} · ${esc(code)}</small></span>
      <span class="ai-dur dur" data-since="${s.since}">${fmtDur(state.now - s.since)}</span>
    </button>`;
  }).join("");
  setHTML($("activeList"), html);
  $("activeEmpty").hidden = list.length > 0;
}

function alertHTML(ev) {
  const recovered = ev.level === "ok";
  const cls = recovered ? "recover" : ev.level;
  const title = recovered
    ? `${esc(ev.name)} 恢复`
    : `${esc(codeName(ev.code))}`;
  const sub = recovered
    ? `${esc(codeName(ev.code))} · 此前 ${esc(codeName(ev.from))}（${esc(ev.from ?? "OFF")}）`
    : `${esc(ev.name)} · ${esc(LEVEL_TEXT[ev.level])} · ${esc(ev.code ?? "OFF")}`;
  return `<li class="event-item ${cls}" data-id="${esc(ev.id)}">
    <time>${fmtTime(ev.t)}</time><span class="ai-mark" aria-hidden="true"></span>
    <span class="ai-body"><span class="t1">${title}</span><span class="t2">${sub}</span></span>
  </li>`;
}

function renderAlerts(state) {
  const list = state.alerts.filter((e) => e.t > view.alertsClearedAt).slice().reverse();
  setHTML($("alerts"), list.map(alertHTML).join(""));
  $("alertsEmpty").hidden = list.length > 0;
}

/* ---------- 停机提醒 ---------- */
function beep() {
  try {
    view.audio = view.audio || new (window.AudioContext || window.webkitAudioContext)();
    const ctx = view.audio;
    for (let i = 0; i < 3; i++) {
      const osc = ctx.createOscillator(), gain = ctx.createGain();
      osc.type = "square";
      osc.frequency.value = 880;
      gain.gain.value = 0.06;
      osc.connect(gain).connect(ctx.destination);
      osc.start(ctx.currentTime + i * 0.25);
      osc.stop(ctx.currentTime + i * 0.25 + 0.15);
    }
  } catch (_) { /* 浏览器不允许播放时静默 */ }
}

function checkNewStops(state) {
  const stopping = state.stations.filter((s) => s.level === "stop");
  const keys = new Set(stopping.map((s) => `${s.id}@${s.since}`));
  const fresh = [...keys].some((k) => !view.seenStops.has(k));
  view.seenStops = keys;
  if (fresh && view.soundOn && !view.firstRender) beep();
  view.firstRender = false;
  const n = stopping.length;
  document.title = `${n ? `(${n} 停机) ` : ""}${state.test ? "【测试】" : ""}美国线 · 工作站状态监控`;
}

/* ---------- 详情抽屉 ---------- */
function jumpToStation(id) {
  if (!id) return;
  openDrawer(id);
  applyFilter();
}

function openDrawer(id) {
  ui.openStation = id;
  $("drawerBody").innerHTML = `
    <div id="dHead"></div>
    <section class="ctrl" aria-label="操作">
      <h3 class="d-sec">操作</h3>
      <div class="ctrl-btns">
        <button class="btn" data-cmd="reset">复位</button>
        <button class="btn primary" data-cmd="start">开始</button>
        <button class="btn danger" data-cmd="stop">停止</button>
      </div>
      <p class="ctrl-note" id="ctrlNote"></p>
    </section>
    <div id="dTail"></div>`;
  $("drawer").classList.add("open");
  $("drawer").setAttribute("aria-hidden", "false");
  renderDrawer();
  applyFilter();
  $("closeDrawer").focus();
}

function closeDrawer() {
  ui.openStation = null;
  $("drawer").classList.remove("open");
  $("drawer").setAttribute("aria-hidden", "true");
  applyFilter();
}

function syncControls() {
  const s = ui.state;
  if (!s) return;
  const can = s.canControl && !view.busy;
  document.querySelectorAll("#drawerBody [data-cmd]").forEach((b) => { b.disabled = !can; });
  const pin = s.pinRequired ? "操作前需输入操作密码；" : "";
  const modeHint = s.commandMode === "dobot"
    ? "真实模式按越疆线圈控制：开始/停止为上升沿脉冲；复位=清报警→下使能(等待)→上使能(等待)。"
    : "真实模式写入保持寄存器（command_register）。";
  $("ctrlNote").textContent = !s.canControl
    ? "真实模式下未启用命令通道（请将 command_mode 设为 dobot，或配置 command_register）。"
    : s.test ? `${pin}测试模式：命令只作用于模拟数据，不会发给真实设备。` : `${pin}${modeHint}所有操作都会记入日志。`;
}

function fmtBeat(sec) {
  if (sec === null || sec === undefined || !Number.isFinite(Number(sec))) return "—";
  const ms = Math.max(0, Math.round(Number(sec) * 1000));
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60000) {
    const s = ms / 1000;
    return `${(s < 10 ? s.toFixed(2) : s.toFixed(1))}s`;
  }
  return fmtDur(sec);
}

function beatCaption(cyc) {
  let text = "只统计已经走完的动作，正在进行的这一步不算。典型是中位数；停机、补料或空等太久的那一次不会把数字抬高。";
  if (!cyc) return `${text}至少走完两圈才有节拍。`;
  const how = cyc.how === "周期完成" ? "「周期完成」" : `「${cyc.how}」`;
  text += `节拍是相邻两次${how}的间隔，取了 ${cyc.n} 圈。`;
  if (cyc.last != null) {
    text += cyc.lastKept
      ? `最近一圈 ${fmtBeat(cyc.last)}。`
      : `最近一圈 ${fmtBeat(cyc.last)}${cyc.lastDirty ? "（含故障、离线或启动）" : "（偏长）"}，没有算进节拍。`;
  }
  if (cyc.dropped > 1) text += `窗口里有 ${cyc.dropped} 圈没有算进节拍。`;
  return text;
}

function renderBeatSection(s, now) {
  const model = beatModel(s);
  const cyc = model.cyc;
  const curCode = s.action ?? s.code;
  const cur = s.known ? (model.byCode.get(curCode) || null) : null;
  const summary = `
    <div class="beat-summary">
      <div><b>${fmtBeat(now - s.since)}</b><span>当前动作</span></div>
      <div><b>${cur && cur.n ? fmtBeat(cur.avg) : "—"}</b><span>该步典型</span></div>
      <div><b>${cyc ? fmtBeat(cyc.avg) : "—"}</b><span>常见节拍${cyc ? ` · ${cyc.n}圈` : ""}</span></div>
    </div>`;
  let seenStartup = false;
  let seenExtra = false;
  const rows = model.rows.map((g) => {
    let split = "";
    if (g.kind === "startup" && !seenStartup) {
      seenStartup = true;
      split = `<tr class="beat-split"><td colspan="6">启动，不计入节拍</td></tr>`;
    }
    if (g.kind === "extra" && !seenExtra) {
      seenExtra = true;
      split = `<tr class="beat-split"><td colspan="6">流程外</td></tr>`;
    }
    const curCls = g.code === curCode ? "cur" : "";
    const dim = g.kind === "body" ? "" : "extra";
    return `${split}<tr class="${curCls} ${dim}">
      <td class="bn">${esc(g.code)}</td>
      <td class="bt">${esc(g.name)}</td>
      <td class="bs">${fmtBeat(g.last)}</td>
      <td class="bs">${fmtBeat(g.avg)}</td>
      <td class="bs">${fmtBeat(g.max)}</td>
      <td class="bs">${g.n || "—"}</td>
    </tr>`;
  }).join("");
  return `${summary}
    <table class="beattable">
      <thead><tr><th>码</th><th>动作</th><th>上次</th><th>典型</th><th>最长</th><th>次</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
    <p class="muted" style="margin-top:8px">${esc(beatCaption(cyc))}</p>`;
}

function renderDrawer() {
  if (!ui.openStation || !ui.state) return;
  const s = findStation(ui.openStation);
  if (!s) return;
  const showCode = s.action ?? s.code;
  const info = ui.codes[String(showCode)];
  const now = ui.state.now;
  const mine = new Set(ui.stationCodes[s.type] || []);
  const chips = [...mine]
    .sort((x, y) => x - y)
    .map((c) => {
      const i = ui.codes[String(c)];
      const lv = i ? (i.stop ? "stop" : i.category === "过程异常" ? "warn" : "") : "";
      const nowChip = c === (s.action ?? s.code);
      return `<span class="chip ${lv} ${nowChip ? "now" : ""}" title="${esc(i ? i.name : "")}">${c}</span>`;
    })
    .join("");
  const hist = s.history.slice().reverse().slice(0, 30)
    .map((h) => `<li><time>${fmtTime(h.t)}</time><span>${esc(codeName(h.code))}</span><b class="${levelOf(h.code)}">${esc(h.code ?? "OFF")}</b></li>`)
    .join("");
  const row = (k, v) => `<dt>${k}</dt><dd>${v}</dd>`;
  let stepText = "等待第一次读数";
  if (s.known) {
    if (s.code === null) stepText = codeName(null);
    else {
      stepText = codeName(s.action ?? s.code);
      if (s.fault) {
        stepText += ` · 异常 ${s.fault} ${codeName(s.fault)}`;
        if (s.faultSince) stepText += ` ${fmtDur(ui.state.now - s.faultSince)}`;
      }
    }
  }
  $("dHead").innerHTML = `
    <div class="d-head" data-level="${viewLevel(s)}">
      <span class="d-no">${esc(s.no)}</span>
      <h2>${esc(s.name)}${s.paused ? `<span class="tag">已暂停</span>` : ""}</h2>
      <div class="step-big">${esc(stepText)}</div>
      <div class="code-row">
        <b>${esc(s.known ? (showCode ?? "OFF") : "···")}</b>
        <span>${esc(s.known ? levelLabel(s, now) : LEVEL_TEXT.pending)}</span>
        <span class="sub">${esc(s.ip)}:${esc(s.port)}${s.type ? ` · ${esc(s.type)}` : ""}</span>
      </div>
    </div>`;
  const staleSec = s.known && s.code != null ? now - s.since : null;
  const bit = (v) => (v === true ? "1" : v === false ? "0" : "?");
  const rawBits = `触点 停止=${bit(s.stopped)} 暂停=${bit(s.paused)} 运行=${bit(s.running)} 报警=${bit(s.alarmed)}`;
  const statusNote = s.known
    ? `两层：①控制器停机/暂停/报警←触点1/2/4（不用「运行」触点判停，Wait时它常为0）；②工艺动作←${ui.state.actionRegister ?? 4100}，过程异常←${ui.state.faultRegister ?? 4101}。${rawBits}。${staleSec != null && staleSec >= 15 ? ` 动作码已保持 ${fmtDur(staleSec)} 未变。` : ""}`
    : "";
  $("dTail").innerHTML = `
    <p class="muted">${esc(`采样：Modbus ${fmtPollSec(ui.state.pollInterval)} · 页面 ${fmtPollSec(POLL_MS / 1000)} · 动作/异常寄存器 ${ui.state.actionRegister ?? "—"}/${ui.state.faultRegister ?? "—"}`)}</p>
    ${statusNote ? `<p class="muted">${esc(statusNote)}</p>` : ""}
    <h3 class="d-sec">节拍统计</h3>
    ${renderBeatSection(s, now)}
    <dl>
      ${row("动作码", esc(s.action == null ? "—" : `${s.action} ${codeName(s.action)}`))}
      ${row("异常码", esc(!s.fault ? "0（无异常）" : `${s.fault} ${codeName(s.fault)}`))}
      ${row("类别", esc(info ? info.category : "—"))}
      ${row("什么时候报", esc(info ? info.when : "—"))}
      ${row("随后怎么走", esc(info ? info.next : "—"))}
      ${row("脚本依据", esc(info ? info.source : "—"))}
      ${row("持续", fmtDur(now - s.since))}
      ${row("最后读到", s.lastSeen ? fmtTime(s.lastSeen) : "从未")}
    </dl>
    ${mine.size ? `<h3 class="d-sec">本站会报的状态码（${mine.size}）</h3><div class="chips">${chips}</div>` : ""}
    <h3 class="d-sec">最近变化</h3>
    <ul class="hist">${hist || "<li>暂无</li>"}</ul>`;
  syncControls();
}

async function runCommand(cmd) {
  const s = findStation(ui.openStation);
  if (!s || view.busy) return;
  const c = CMD[cmd];
  const answer = await ask({ title: `${c.label}：${stationLabel(s)}`, text: c.confirm, okText: `确认${c.label}`, danger: c.danger });
  if (!answer) return;
  view.busy = true;
  syncControls();
  try {
    const res = await api("POST", "/api/command", { id: s.id, command: cmd, pin: answer.pin });
    toast(`${s.name}：${c.label}${res.ok ? "已执行" : "失败"}。${res.detail}`, res.ok ? "ok" : "error");
  } catch (e) {
    toast(`${s.name}：${c.label}失败。${e.message}`, "error");
  } finally {
    view.busy = false;
    syncControls();
    poll();
  }
}

/* ---------- 轮询 ---------- */
function render() {
  const s = ui.state;
  renderMode(s);
  renderSampleRate(s);
  renderHost(s.host);
  renderTally(s.stations);
  renderFleet(s);
  renderActive(s);
  renderAlerts(s);
  checkNewStops(s);
  renderDrawer();
  fillStationSelect();
}

let pollSeq = 0;
let pollInFlight = false;

async function poll() {
  const seq = ++pollSeq;
  while (pollInFlight) {
    await new Promise((resolve) => setTimeout(resolve, 20));
    if (seq !== pollSeq) return;
  }
  if (seq !== pollSeq) return;
  pollInFlight = true;
  try {
    const state = await api("GET", "/api/state");
    if (seq !== pollSeq || view.switching) return;
    ui.state = state;
    ui.clockOffset = ui.state.now - Date.now() / 1000;
    $("conn").hidden = true;
    render();
  } catch (_) {
    if (seq === pollSeq) $("conn").hidden = false;
  } finally {
    pollInFlight = false;
  }
}

function tickDurations() {
  if (!ui.state) return;
  const now = serverNow();
  document.querySelectorAll(".dur[data-since]").forEach((el) => {
    el.textContent = fmtDur(now - Number(el.dataset.since));
  });
  /* 卡片「本步」时长按 ms 刷新，不必等下一轮 poll */
  const byId = new Map(ui.state.stations.map((s) => [s.id, s]));
  document.querySelectorAll(".card[data-id]").forEach((el) => {
    const s = byId.get(el.dataset.id);
    const beatEl = el.querySelector(".beat");
    if (!s || !beatEl || !s.known) return;
    const curSec = now - s.since;
    const avg = avgForCode(s, s.action ?? s.code);
    const cyc = cycleBeat(s);
    let beatText = `本步 <b>${fmtBeat(curSec)}</b>`;
    if (avg !== null && avg > 0) beatText += ` · 典型 ${fmtBeat(avg)}`;
    if (cyc) beatText += ` · 节拍 ${fmtBeat(cyc.avg)}`;
    if (beatEl._html !== beatText) { beatEl._html = beatText; beatEl.innerHTML = beatText; }
  });
  $("clock").textContent = new Date().toLocaleTimeString("zh-CN", { hour12: false });
}

/* ---------- 页面切换与事件 ---------- */
function showView(name) {
  document.querySelectorAll(".tabs button").forEach((b) => b.setAttribute("aria-selected", String(b.dataset.view === name)));
  document.querySelectorAll(".view").forEach((v) => { v.hidden = v.id !== `view-${name}`; });
  closeDrawer();
  if (name === "logs") loadLogs();
  if (name === "messages") openMessages();
}

const THEMES = ["night", "zelda", "day"];
const THEME_KEY = "dmp-theme";

function applyTheme(name) {
  const theme = THEMES.includes(name) ? name : "night";
  document.documentElement.dataset.theme = theme;
  try { localStorage.setItem(THEME_KEY, theme); } catch (_) {}
  document.querySelectorAll(".themes [data-theme]").forEach((b) => {
    b.setAttribute("aria-checked", String(b.dataset.theme === theme));
  });
}

function bindTheme() {
  const box = document.querySelector(".themes");
  if (!box) return;
  applyTheme(document.documentElement.dataset.theme || "night");
  box.addEventListener("click", (e) => {
    const b = e.target.closest("[data-theme]");
    if (b) applyTheme(b.dataset.theme);
  });
}

function bind() {
  document.querySelector(".tabs").addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (b) showView(b.dataset.view);
  });
  bindSeg("levelFilter", "level", (v) => setLevelFilter(v));
  document.querySelector(".kpi").addEventListener("click", (e) => {
    const b = e.target.closest(".kpi-cell[data-level]");
    if (b) setLevelFilter(b.dataset.level);
  });
  $("search").addEventListener("input", (e) => { view.query = e.target.value; applyFilter(); });
  $("fleet").addEventListener("click", (e) => {
    const c = e.target.closest(".card");
    if (c && !c.classList.contains("is-dim")) jumpToStation(c.dataset.id);
  });
  $("activeList").addEventListener("click", (e) => {
    const b = e.target.closest("[data-id]");
    if (b) jumpToStation(b.dataset.id);
  });
  $("alerts").addEventListener("click", (e) => {
    const li = e.target.closest("[data-id]");
    if (li) jumpToStation(li.dataset.id);
  });
  $("clearAlerts").addEventListener("click", () => { view.alertsClearedAt = serverNow(); renderAlerts(ui.state); });
  $("closeDrawer").addEventListener("click", closeDrawer);
  $("scrim").addEventListener("click", closeDrawer);
  $("drawerBody").addEventListener("click", (e) => {
    const b = e.target.closest("[data-cmd]");
    if (b) runCommand(b.dataset.cmd);
  });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !$("dlg").open) closeDrawer(); });
  $("mode").addEventListener("click", toggleMode);
  $("testBannerBtn").addEventListener("click", toggleMode);
  $("host").addEventListener("click", copyHostIp);
  $("host").addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); copyHostIp(); } });
  $("sound").addEventListener("click", () => {
    view.soundOn = !view.soundOn;
    $("sound").setAttribute("aria-pressed", String(view.soundOn));
    $("sound").textContent = `声音 ${view.soundOn ? "开" : "关"}`;
    if (view.soundOn) beep();
  });
  bindTheme();
  bindLogs();
  bindMessages();
  bindCodes();
}

async function init() {
  const t = await (await fetch("/api/codes", { cache: "no-store" })).json();
  ui.codes = t.codes;
  ui.stationCodes = t.stationCodes;
  ui.retired = t.retired;
  bind();
  renderCodeTable();
  await poll();
  pollMessages();
  setInterval(poll, POLL_MS);
  setInterval(tickDurations, 100); /* 动作计时按 ms 显示，100ms 刷新一次 */
  setInterval(pollMessages, 8000);
  setInterval(refreshLogsIfOpen, 5000);
}

if (typeof document !== "undefined") {
  applyTheme(document.documentElement.dataset.theme || "night");
  init();
}
