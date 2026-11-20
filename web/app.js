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
  return `${s.name} ${s.no} ${s.ip} ${s.code ?? ""} ${codeName(s.code)}`.toLowerCase().includes(q);
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

/* ---------- 节拍：按工位固定动作顺序统计（与 sim.py 流程一致，顺序不随频次跳动） ---------- */
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

function stepSegments(station, now) {
  const hist = station.history || [];
  const segs = [];
  for (let i = 0; i < hist.length; i++) {
    const a = hist[i];
    const end = i + 1 < hist.length ? hist[i + 1].t : now;
    segs.push({ code: a.code, t: a.t, sec: Math.max(0, end - a.t) });
  }
  return segs;
}

function beatRowFromSecs(code, secs) {
  if (!secs.length) {
    return { code, name: codeName(code), n: 0, last: null, avg: null, max: null, sum: 0 };
  }
  const sum = secs.reduce((a, b) => a + b, 0);
  return {
    code,
    name: codeName(code),
    n: secs.length,
    last: secs[secs.length - 1],
    avg: sum / secs.length,
    max: Math.max(...secs),
    sum,
  };
}

function beatStats(station, now) {
  const map = new Map();
  for (const seg of stepSegments(station, now)) {
    if (seg.code === null || seg.code === undefined) continue;
    const key = String(seg.code);
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(seg.sec);
  }
  const flow = actionFlow(station.type);
  const inFlow = new Set(flow);
  const rows = flow.map((code) => beatRowFromSecs(code, map.get(String(code)) || []));
  /* 流程外出现过的码（多为异常）固定挂在末尾，按码值排序，避免打乱主流程 */
  const extras = [...map.keys()]
    .map(Number)
    .filter((c) => !inFlow.has(c))
    .sort((a, b) => a - b)
    .map((code) => beatRowFromSecs(code, map.get(String(code)) || []));
  return rows.concat(extras);
}

function cycleBeat(station, now) {
  /* 用「周期完成 / 回到就绪」等标记码的出现间隔估整圈节拍 */
  const segs = stepSegments(station, now).filter((s) => s.code !== null && s.code !== undefined);
  const marks = segs.filter((s) => {
    const name = codeName(s.code);
    return name.includes("周期完成") || name.includes("回到就绪") || s.code === 187;
  });
  if (marks.length < 2) return null;
  const byCode = new Map();
  for (const m of marks) {
    const k = String(m.code);
    if (!byCode.has(k)) byCode.set(k, []);
    byCode.get(k).push(m.t);
  }
  let intervals = [];
  for (const ts of byCode.values()) {
    if (ts.length < 2) continue;
    const gs = [];
    for (let i = 1; i < ts.length; i++) {
      const g = ts[i] - ts[i - 1];
      if (g > 0.5) gs.push(g);
    }
    if (gs.length > intervals.length) intervals = gs;
  }
  if (!intervals.length) return null;
  const sum = intervals.reduce((a, b) => a + b, 0);
  return {
    n: intervals.length,
    last: intervals[intervals.length - 1],
    avg: sum / intervals.length,
    min: Math.min(...intervals),
    max: Math.max(...intervals),
  };
}

function avgForCode(station, code, now) {
  if (code === null || code === undefined) return null;
  const g = beatStats(station, now).find((x) => x.code === code);
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
      if (hasFault) step += ` · 异常 ${s.fault} ${codeName(s.fault)}`;
    }
  }
  const paused = s.paused ? `<span class="tag">已暂停</span>` : "";
  const curSec = now - s.since;
  const beatCode = s.action ?? s.code;
  const avg = s.known ? avgForCode(s, beatCode, now) : null;
  const cyc = s.known ? cycleBeat(s, now) : null;

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

  let beatText = s.known ? `本步 <b>${fmtDur(curSec)}</b>` : "本步 —";
  if (avg !== null && avg > 0) beatText += ` · 该动作近均 ${fmtDur(avg)}`;
  if (cyc) beatText += ` · 周期近均 ${fmtDur(cyc.avg)}`;
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
    const code = !s.known ? "···" : (s.code === null ? "OFF" : s.code);
    return `<button type="button" class="alarm-item ${lv}" data-id="${esc(s.id)}">
      <span class="ai-mark" aria-hidden="true"></span>
      <span class="ai-body"><b>${esc(codeName(s.code))}</b><small>${esc(s.name)} · #${esc(s.no)} · ${esc(code)}</small></span>
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
  return sec === null || sec === undefined ? "—" : fmtDur(sec);
}

function renderBeatSection(s, now) {
  const stats = beatStats(s, now);
  const cyc = cycleBeat(s, now);
  const cur = s.known ? (stats.find((x) => x.code === s.code) || null) : null;
  const flowLen = actionFlow(s.type).length;
  const summary = `
    <div class="beat-summary">
      <div><b>${fmtDur(now - s.since)}</b><span>当前动作</span></div>
      <div><b>${cur && cur.n ? fmtDur(cur.avg) : "—"}</b><span>该动作近均</span></div>
      <div><b>${cyc ? fmtDur(cyc.avg) : "—"}</b><span>周期近均${cyc ? ` · ${cyc.n}次` : ""}</span></div>
    </div>`;
  const rows = stats.map((g, i) => {
    const curCls = g.code === s.code ? "cur" : "";
    const extraCls = i >= flowLen ? "extra" : "";
    return `<tr class="${curCls} ${extraCls}">
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
      <thead><tr><th>码</th><th>动作</th><th>上次</th><th>近均</th><th>最长</th><th>次</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
    <p class="muted" style="margin-top:8px">按本工位固定动作流程排序（启动→循环）；下方灰色行为流程外出现的异常码。周期节拍用「周期完成 / 回到就绪」间隔估算。</p>`;
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
      if (s.fault) stepText += ` · 异常 ${s.fault} ${codeName(s.fault)}`;
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

let pollInFlight = false;

async function poll() {
  if (pollInFlight) return;
  pollInFlight = true;
  try {
    ui.state = await api("GET", "/api/state");
    ui.clockOffset = ui.state.now - Date.now() / 1000;
    $("conn").hidden = true;
    render();
  } catch (_) {
    $("conn").hidden = false;
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
    const avg = avgForCode(s, s.code, now);
    const cyc = cycleBeat(s, now);
    let beatText = `本步 <b>${fmtDur(curSec)}</b>`;
    if (avg !== null && avg > 0) beatText += ` · 该动作近均 ${fmtDur(avg)}`;
    if (cyc) beatText += ` · 周期近均 ${fmtDur(cyc.avg)}`;
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

init();
