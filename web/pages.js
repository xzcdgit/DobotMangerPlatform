"use strict";

/* 日志、留言、状态码表三个页面 */
const logView = { kind: "all", query: "", date: "", entries: [], dates: [] };

/* ---------- 日志 ---------- */
const LOG_BADGE = { stop: "停机", warn: "过程异常", offline: "离线", unknown: "未知码", ok: "运行" };
const LOG_KIND_LABEL = { command: "操作", recover: "恢复", mode: "模式" };

function logKindOf(e) {
  if (e.kind === "command" || e.kind === "recover" || e.kind === "mode") return e.kind;
  return e.level === "unknown" ? "warn" : e.level;
}

function logBadge(e) {
  const k = logKindOf(e);
  const label = LOG_KIND_LABEL[k] || LOG_BADGE[e.level] || "异常";
  return `<span class="badge ${k}">${label}</span>`;
}

function logDesc(e) {
  return logText(e) + (e.test ? ` <span class="tag test">测试</span>` : "");
}

function logText(e) {
  if (e.kind === "mode") {
    return `${esc(e.text)} <span class="muted">${esc(e.detail)} · 来自 ${esc(e.client)}</span>`;
  }
  if (e.kind === "command") {
    const result = e.ok ? "成功" : "失败";
    return `${esc(e.text)} <span class="${e.ok ? "okx" : "errx"}">${result}</span> <span class="muted">${esc(e.detail)} · 来自 ${esc(e.client)}</span>`;
  }
  if (e.kind === "recover") {
    return `${esc(e.text)} <span class="muted">${esc(e.detail)}${e.prevSec !== undefined ? `，持续 ${fmtDur(e.prevSec)}` : ""}</span>`;
  }
  return esc(e.text);
}

function renderLogs() {
  const q = logView.query.trim().toLowerCase();
  const rows = logView.entries.filter((e) => {
    if (logView.kind !== "all" && logKindOf(e) !== logView.kind) return false;
    return !q || `${e.name} ${e.no} ${e.ip} ${e.code ?? ""} ${e.text}`.toLowerCase().includes(q);
  });
  $("logRows").innerHTML = rows
    .map((e) => `<tr class="${logKindOf(e)}"><td class="t">${fmtTime(e.t)}</td><td>${logBadge(e)}</td><td class="n">${esc(e.no)}</td><td>${esc(e.name)}</td><td class="ip">${e.ip ? `${esc(e.ip)}:${esc(e.port)}` : ""}</td><td class="n">${esc(e.code ?? "")}</td><td>${logDesc(e)}</td></tr>`)
    .join("");
  $("logCount").textContent = `${rows.length} / ${logView.entries.length} 条`;
  $("logEmpty").hidden = rows.length > 0;
}

function fillLogDates() {
  const today = ui.state ? new Date(ui.state.now * 1000) : new Date();
  const todayText = `${today.getFullYear()}-${pad2(today.getMonth() + 1)}-${pad2(today.getDate())}`;
  const dates = [...new Set([todayText, ...logView.dates])].sort().reverse();
  if (!logView.date) logView.date = todayText;
  const sel = $("logDate");
  const sig = dates.join("|");
  if (sel.dataset.sig !== sig) {  // 日期列表没变就不重建，避免用户正在下拉选择时被刷新打断
    sel.innerHTML = dates.map((d) => `<option value="${esc(d)}">${esc(d)}${d === todayText ? "（今天）" : ""}</option>`).join("");
    sel.dataset.sig = sig;
  }
  sel.value = logView.date;
  $("logCsv").href = `/api/logs.csv?date=${encodeURIComponent(logView.date)}`;
}

let logSeq = 0;

async function loadLogs() {
  const seq = ++logSeq;
  try {
    const data = await api("GET", `/api/logs?date=${encodeURIComponent(logView.date || "")}`.replace(/date=$/, ""));
    if (seq !== logSeq) return;  // 已有更新的请求，丢弃过期响应（例如快速切换日期时）
    logView.date = data.date;
    logView.dates = data.dates;
    logView.entries = data.entries;
    fillLogDates();
    renderLogs();
  } catch (e) {
    toast(`读取日志失败：${e.message}`, "error");
  }
}

function refreshLogsIfOpen() {
  if (!$("view-logs").hidden) loadLogs();
}

function bindLogs() {
  bindSeg("logKind", "kind", (v) => { logView.kind = v; renderLogs(); });
  $("logSearch").addEventListener("input", (e) => { logView.query = e.target.value; renderLogs(); });
  $("logDate").addEventListener("change", (e) => { logView.date = e.target.value; loadLogs(); });
}

/* ---------- 留言 ---------- */
const msgView = { items: [], seen: 0, loaded: false };
const AUTHOR_KEY = "monitor.author";

function storage(fn) {
  try { return fn(window.localStorage); } catch (_) { return null; }
}

function fillStationSelect() {
  const sel = $("msgStation");
  if (!ui.state || sel.options.length - 1 === ui.state.stations.length) return;
  const keep = sel.value;
  const list = typeof stableStations === "function" ? stableStations(ui.state.stations) : ui.state.stations;
  sel.innerHTML = `<option value="">不关联</option>` + list
    .map((s) => `<option value="${esc(s.id)}">${esc(stationLabel(s))}</option>`).join("");
  sel.value = keep;
}

function msgHTML(m) {
  const st = m.station ? findStation(m.station) : null;
  const tag = m.station ? `<span class="tag st">${esc(st ? stationLabel(st) : `站 ${m.station}`)}</span>` : "";
  return `<li class="msg"><div class="msg-head"><b>${esc(m.author)}</b>${tag}<time>${fmtDateTime(m.t)}</time><button class="link danger-link" data-del="${esc(m.id)}">删除</button></div><p>${esc(m.text)}</p></li>`;
}

function renderMessages() {
  $("msgList").innerHTML = msgView.items.map(msgHTML).join("");
  $("msgEmpty").hidden = msgView.items.length > 0;
}

function updateMsgDot() {
  const newest = msgView.items.length ? msgView.items[0].id : 0;
  const onPage = !$("view-messages").hidden;
  if (onPage) msgView.seen = newest;
  $("msgDot").hidden = onPage || newest <= msgView.seen;
}

async function pollMessages() {
  try {
    const data = await api("GET", "/api/messages");
    msgView.items = data.messages;
    if (!msgView.loaded) {  // 首次加载时已有的留言不算"新留言"
      msgView.seen = msgView.items.length ? msgView.items[0].id : 0;
      msgView.loaded = true;
    }
    renderMessages();
    updateMsgDot();
  } catch (_) { /* 连接状态由状态轮询统一提示 */ }
}

function openMessages() {
  $("msgAuthor").value = $("msgAuthor").value || storage((s) => s.getItem(AUTHOR_KEY)) || "";
  pollMessages();
  updateMsgDot();
}

async function submitMessage(e) {
  e.preventDefault();
  const btn = $("msgSubmit");
  btn.disabled = true;
  try {
    const author = $("msgAuthor").value.trim();
    await api("POST", "/api/messages", { author, text: $("msgText").value, station: $("msgStation").value || null });
    storage((s) => s.setItem(AUTHOR_KEY, author));
    $("msgText").value = "";
    $("msgCount").textContent = "0 / 500";
    toast("留言已发布", "ok");
    await pollMessages();
  } catch (err) {
    toast(err.message, "error");
  } finally {
    btn.disabled = false;
  }
}

async function deleteMessage(id) {
  const answer = await ask({ title: "删除留言", text: "删除后无法恢复。", okText: "删除", danger: true });
  if (!answer) return;
  try {
    await api("DELETE", `/api/messages/${encodeURIComponent(id)}`, undefined, { "X-Control-Pin": answer.pin });
    toast("已删除", "ok");
    await pollMessages();
  } catch (err) {
    toast(err.message, "error");
  }
}

function bindMessages() {
  $("msgForm").addEventListener("submit", submitMessage);
  $("msgText").addEventListener("input", (e) => { $("msgCount").textContent = `${e.target.value.length} / 500`; });
  $("msgList").addEventListener("click", (e) => {
    const b = e.target.closest("[data-del]");
    if (b) deleteMessage(b.dataset.del);
  });
}

/* ---------- 状态码表 ---------- */
function renderCodeTable() {
  const cat = $("catFilter").value || "all";
  const stop = document.querySelector("#stopFilter [aria-pressed=true]").dataset.stop;
  const q = $("codeSearch").value.trim().toLowerCase();
  const rows = Object.entries(ui.codes)
    .filter(([code, i]) => {
      if (cat !== "all" && i.category !== cat) return false;
      if (stop !== "all" && (i.stop ? "1" : "0") !== stop) return false;
      return !q || `${code} ${i.name} ${i.when} ${i.next}`.toLowerCase().includes(q);
    })
    .sort((a, b) => a[0] - b[0]);
  $("codeCount").textContent = `${rows.length} / ${Object.keys(ui.codes).length}`;
  $("codeRows").innerHTML = rows
    .map(([code, i]) => {
      const lv = i.stop ? "stop" : i.category === "过程异常" ? "warn" : "ok";
      return `<tr class="${lv} ${i.stop ? "stoptag" : ""}"><td class="n">${esc(code)}</td><td>${esc(i.category)}</td><td>${esc(i.name)}</td><td>${esc(i.when)}</td><td>${esc(i.next)}</td><td class="stations">${esc(i.stations)}</td></tr>`;
    })
    .join("");
}

function bindCodes() {
  const cats = [...new Set(Object.values(ui.codes).map((c) => c.category))];
  $("catFilter").innerHTML = `<option value="all">全部类别</option>` + cats.map((c) => `<option>${esc(c)}</option>`).join("");
  bindSeg("stopFilter", "stop", renderCodeTable);
  $("catFilter").addEventListener("change", renderCodeTable);
  $("codeSearch").addEventListener("input", renderCodeTable);
}
