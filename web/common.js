"use strict";

/* 公共工具：所有页面脚本共用 */
const LEVEL_TEXT = { ok: "运行", warn: "过程异常", stop: "停机", offline: "离线", unknown: "未知码", pending: "连接中" };
const PAGE_POLL_MS = 1000; /* 浏览器拉 /api/state 的间隔；与 config poll_interval（Modbus）分开 */

/* 控制器：报警/停止状态/暂停；「运行」触点只展示不判停（脚本 Wait 时经常为0） */
function levelLabel(s, now) {
  if (!s.known) return LEVEL_TEXT.pending;
  if (s.code === null) return LEVEL_TEXT.offline;
  if (s.alarmed) return "报警";
  if (s.stopped) return "已停止";
  if (s.paused) return "已暂停";
  const lv = viewLevel(s);
  if (lv === "ok" && s.code != null && typeof now === "number" && now - s.since >= 15) {
    return "码未更新";
  }
  return LEVEL_TEXT[lv] || lv;
}

function fmtPollSec(sec) {
  if (typeof sec !== "number" || !(sec > 0)) return "—";
  if (sec < 1) return `${Math.round(sec * 1000)}ms`;
  return `${sec}s`;
}

const $ = (id) => document.getElementById(id);
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const ui = {
  codes: {},
  stationCodes: {},
  retired: {},
  state: null,
  openStation: null,
  clockOffset: 0,  // 服务器时间 - 浏览器时间，避免两台电脑时钟不一致时持续时长出现负数或跳变
};

const serverNow = () => Date.now() / 1000 + ui.clockOffset;

/* 等级：动作码、异常码、暂停/停止触点取更严重的一档。未知码在页面上按过程异常显示。 */
const LEVEL_RANK = { ok: 0, unknown: 1, warn: 2, stop: 3 };

function worseLevel(a, b) {
  return (LEVEL_RANK[a] || 0) >= (LEVEL_RANK[b] || 0) ? a : b;
}

function viewLevel(s) {
  if (!s.known) return "pending";
  if (s.code === null) return "offline";
  let lv = levelOf(s.action ?? s.code);
  if (s.fault) lv = worseLevel(lv, levelOf(s.fault));
  if (s.paused) lv = worseLevel(lv, "warn");
  if (s.alarmed || s.stopped) lv = worseLevel(lv, "stop");
  return lv === "unknown" ? "warn" : lv;
}

function attentionText(s) {
  if (!s.known) return "连接中";
  if (s.code === null) return codeName(null);
  if (s.alarmed) return "报警";
  if (s.fault) return codeName(s.fault);
  if (s.stopped) return "已停止";
  if (s.paused) return "已暂停";
  return codeName(s.action ?? s.code);
}

/* 内容没变就不重写 DOM，避免每秒刷新打断悬停、焦点和文字选择 */
function setHTML(el, html) {
  if (el._html === html) return false;
  el._html = html;
  el.innerHTML = html;
  return true;
}

function levelOf(code) {
  if (code === null || code === undefined) return "offline";
  const info = ui.codes[String(code)];
  if (!info) return "unknown";
  if (info.stop) return "stop";
  return info.category === "过程异常" ? "warn" : "ok";
}

function codeName(code) {
  if (code === null || code === undefined) return "无响应";
  const info = ui.codes[String(code)];
  if (info) return info.name;
  const r = ui.retired[String(code)];
  return r ? `已停用，改用 ${r.use}` : "表中无此状态码";
}

/* 动作计时以毫秒为单位；满 1 分钟起用分/时，避免超长数字 */
function fmtDur(sec) {
  const ms = Math.max(0, Math.round(Number(sec) * 1000));
  if (ms < 60_000) return `${ms}ms`;
  const s = Math.floor(ms / 1000);
  if (s < 3600) return `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s`;
  return `${Math.floor(s / 3600)}h${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}m`;
}

const pad2 = (n) => String(n).padStart(2, "0");

function fmtTime(t) {
  const d = new Date(t * 1000);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

function fmtDateTime(t) {
  const d = new Date(t * 1000);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${fmtTime(t)}`;
}

function stationLabel(s) {
  return s ? `${s.name}（${s.no}）` : "";
}

function findStation(id) {
  return ui.state ? ui.state.stations.find((s) => s.id === id) : undefined;
}

let toastTimer = 0;
function toast(text, kind = "info") {
  const el = $("toast");
  el.textContent = text;
  el.className = `toast ${kind}`;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, kind === "error" ? 6000 : 3000);
}

/* 统一的接口调用：失败时抛出带中文说明的 Error */
async function api(method, path, body, headers = {}) {
  const init = { method, cache: "no-store", headers: { ...headers } };
  if (body !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  let res;
  try {
    res = await fetch(path, init);
  } catch (_) {
    throw new Error("无法连接监控服务");
  }
  let data = null;
  try { data = await res.json(); } catch (_) { /* 非 JSON 响应 */ }
  if (!res.ok) throw new Error((data && data.error) || `请求失败（${res.status}）`);
  return data;
}

/* 确认对话框；服务端配置了 control_pin 时同时要求输入操作密码。取消返回 null，确认返回 { pin } */
function ask({ title, text, okText = "确定", danger = false }) {
  const needPin = Boolean(ui.state && ui.state.pinRequired);
  const dlg = $("dlg");
  $("dlgTitle").textContent = title;
  $("dlgText").textContent = text;
  $("dlgPinRow").hidden = !needPin;
  $("dlgPin").value = "";
  $("dlgPin").required = needPin;
  $("dlgOk").textContent = okText;
  $("dlgOk").className = danger ? "btn danger" : "btn primary";
  return new Promise((resolve) => {
    dlg.onclose = () => resolve(dlg.returnValue === "ok" ? { pin: $("dlgPin").value } : null);
    dlg.returnValue = "";
    dlg.showModal();
    (needPin ? $("dlgPin") : $("dlgOk")).focus();
  });
}

/* 开启/关闭一个"单选按钮组"按钮条 */
function bindSeg(id, attr, onChange) {
  $(id).addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    $(id).querySelectorAll("button").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    onChange(b.dataset[attr]);
  });
}
