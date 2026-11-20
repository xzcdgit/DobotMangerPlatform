# 美国线工作站状态监控

按 `../美国线状态码对照表.xlsx` 做的网页端状态监控。仅依赖 Python 3 标准库，前端无外部依赖，可离线使用。

## 启动

双击 `start.bat`，或：

    python server.py

终端会打印本机 IP，并按 `config.json` 的 `port` 自动打开浏览器。局域网内其它电脑用 `http://本机IP:端口`（与配置里的 `port` 一致）。
配置文件有误时程序会拒绝启动，并用中文指出是哪一项、哪一行出了问题。

## 打包部署

在本机执行 `python pack_release.py`，会在 `发布/` 生成**便携版** zip（内置官方嵌入式 Python，目标机一般不用再装 Python）。解压后双击 `start.bat`，说明见包内 `部署说明.txt`。

## 配置文件（换线 / 加码只改配置，不改代码）

- 根目录 `config.json`：**当前生效**运行配置（工作站、端口、Modbus），启动时只读这一份。
- 根目录 `codes.json`：**状态码对照表**（独立配置）。新增/改名/停用码只改这个文件，重启软件即可，不必改 Python 或前端。
- `configs/`：各产线完整运行配置（如 `软管泡罩-上纸板.json`）。换线把对应文件复制覆盖 `config.json` 后重启即可。

```json
{
  "port": 8080,
  "mode": "modbus",
  "poll_interval": 0.05,
  "control_pin": "",
  "modbus": {
    "action_register": 4100,
    "fault_register": 4101,
    "register_type": "holding",
    "slave_id": 1,
    "timeout": 1.0,
    "offline_after_failures": 3,
    "command_mode": "dobot",
    "coil_pulse_ms": 200,
    "coil_gap_ms": 200,
    "coils": { "start": 0, "stop": 1, "enable": 3, "disable": 4, "clear_alarm": 5 }
  },
  "stations": [
    { "no": 24, "name": "上纸板", "ip": "192.168.15.24", "port": 502, "type": "气垫取放", "group": "软管泡罩" }
  ]
}
```

### 状态码表 codes.json

与 `config.json` 平级，专管码名、颜色等级和按工位筛选。**加新动作/异常码：只改 `codes.json`，保存后重启。**

| 字段 | 说明 |
|---|---|
| `codes` | 码号 → `{ category, name, when, next, stop, stations, source }`。`stop: true` 显示停机红；`category` 为「过程异常」显示黄；其它为正常绿 |
| `stationCodes` | 工位类型 → 常用码列表（页面筛选 / 测试模式抽样池）；引用的码必须已在 `codes` 里 |
| `retired` | 停用码 → `{ use, reason }`，页面提示改用哪个码 |
| `_说明` | 备注，程序忽略 |

也可从 Excel 重新生成：`python gen_codes.py`（覆盖写入 `codes.json`）。

### 工作站 stations

页面上显示哪些工作站，完全由这个数组决定。增删改后重启程序生效。

| 字段 | 必填 | 说明 |
|---|---|---|
| `no` | 是 | 序号，1~9999 的整数，不能重复；页面按 `stations` 数组书写顺序显示 |
| `name` | 是 | 站名，1~30 个字 |
| `ip` | 是 | 该站的 IPv4 地址，写成文字 |
| `port` | 是 | 端口，1~65535，Modbus TCP 一般是 502 |
| `type` | 否 | 工位类型，用于对照状态码表；可填 上料臂、托举臂、灌装、开盖、气垫取放、粉扑 |
| `group` | 否 | 总览产线分组。例如「上内胆」把上内胆1/2与料台放一起，「上上盖」同理；不填则回退用 `type` |

同一个 IP+端口不能出现两次。以 `_` 开头的字段（如 `_说明`）会被忽略，可以用来写备注。

### 其它配置项

| 配置项 | 说明 |
|---|---|
| `mode` | 启动时的模式：`sim` 测试模式（虚拟数据，默认，用于演示）；`modbus` 轮询真实设备；`report` 只接收 `POST /api/report` 上报。运行中可在页面右上角切换，见下文“测试模式与真实模式” |
| `poll_interval` | Modbus 轮询间隔，秒（当前配置 0.05=50ms；浏览器刷新仍约 1 秒） |
| `modbus.action_register` | 动作码寄存器（工艺步骤 1xx~5xx），默认 4100，勿占用业务地址 |
| `modbus.fault_register` | 异常码寄存器（8xx/9xx，0=无异常），默认 4101，与动作码分开 |
| `modbus.offline_after_failures` | 连续读取失败多少次后判为离线 |
| `modbus.command_mode` | `dobot`（默认，写越疆 map1 线圈）或 `register`（写保持寄存器） |
| `modbus.coils` | Dobot 线圈地址：start/stop/enable/disable/clear_alarm |
| `modbus.coil_pulse_ms` / `coil_gap_ms` | 上升沿脉冲宽度、清报警后短间隔（毫秒） |
| `modbus.disable_settle_ms` / `enable_settle_ms` | 下/上使能后的最少等待（默认 3s / 5s） |
| `modbus.enable_status_addr` | map1 触点「使能状态」地址（默认 7）；`null` 则只按 settle 等待 |
| `modbus.stop_status_addr` | map1 触点「停止状态」（默认 1）；为 1 时显示已停止；`null` 不读 |
| `modbus.running_status_addr` | map1「运行」触点（默认 3，多为运动中）；仅展示，**不**单独判停机（Wait 时常为 0） |
| `modbus.paused_status_addr` / `alarm_status_addr` | 暂停(2)、报警(4)；`null` 表示不读 |
| `modbus.enable_timeout_ms` / `enable_poll_ms` | 轮询使能状态的超时与间隔 |
| `modbus.command_register` | 仅 `command_mode=register` 时使用 |
| `control_pin` | 操作密码。非空时，复位 / 开始 / 停止和删除留言都要输入；留空表示不需要 |

## 页面

- **总览**：按工位类型分组的工作站卡片，显示序号、站名、IP:端口、当前状态码。绿=运行，黄=过程异常（8xx），红=停机（9xx，卡片闪烁），灰=离线。底部色条是最近 24 次变化。右侧是异常 / 恢复时间线。
- **工作站详情**：点卡片或时间线条目，右侧滑出详情。顶部有 **复位 / 开始 / 停止** 三个按钮，点击后先确认（配置了密码还要输入密码）。
- **日志**：自动记录每次异常、停机、离线和恢复（含持续时长），每一次复位 / 开始 / 停止操作（含操作者的 IP 和结果），以及测试 / 真实模式的切换；测试模式下产生的记录带“测试”标记，导出 CSV 时备注前加“[测试模式]”。可按日期、类型、关键字筛选，可导出 CSV。按天存放在 `data/logs/YYYY-MM-DD.jsonl`。
- **留言**：交接班、设备情况留言，所有访问者共用，可关联到某个工作站。保存在 `data/messages.json`。有新留言时标签上出现红点。
- **状态码表**：136 个码，可按类别、是否停机、关键字筛选。
- **本机 IP**：页面右上角显示运行本软件的电脑的 IP，即 Modbus TCP 主站地址，点击可复制。程序综合路由探测、主机名解析、系统网卡列表（ipconfig / ip addr）和浏览器连过来用的地址几种来源，优先选与工作站同一网段的地址；有多块网卡时，鼠标悬停或键盘聚焦可看到全部。显示橙色表示该地址与各工作站不在同一网段，红色表示没有检测到可用地址（检测失败只缓存几秒，网线插上后很快恢复）。
- **测试 / 真实模式开关**：右上角的开关。测试模式顶部有黄黑警示条和横幅，浏览器标签标题带“【测试】”，工作站显示虚拟状态，三个按钮只作用于模拟数据；真实模式读取真实设备状态（`modbus` 轮询或 `report` 上报），按钮会真正下发。尚未读到第一次数据的工作站显示“连接中”。
- **声音开关**：出现新的停机时蜂鸣；标签页标题会显示停机台数。

## 测试模式与真实模式

- 页面右上角的开关随时可切换，切换前会弹出确认（配置了 `control_pin` 时需输入密码）。切换会清空当前工作站状态、异常时间线和提醒，避免虚拟数据与真实数据混在一起，并写一条“模式”日志。
- 真实模式取决于 `config.json` 的 `mode`：配置为 `sim` 时，真实模式即 `modbus`；配置为 `modbus` / `report` 时就是它本身。
- 最近一次的选择保存在 `data/mode.json`，重启后沿用；修改了 `config.json` 的 `mode` 后，旧选择自动作废。
- 接口：`GET /api/state` 返回 `test`（是否测试模式）、`liveMode`；`POST /api/mode`，请求体 `{"test": true|false, "pin": "…"}`。测试模式下 `POST /api/report` 返回 409，避免真实上报混进虚拟数据。

## 复位 / 开始 / 停止如何生效

- 测试模式（`sim`）：作用于模拟器（复位→状态码 100，停止→该站暂停，开始→恢复）。
- 真实模式默认 `command_mode: "dobot"`，按越疆手册附录 A.2 写 **map1 线圈**（功能码 05，上升沿脉冲）：
  - **开始**：线圈 0
  - **停止**：线圈 1
  - **复位**：线圈 5 清除报警 → 线圈 4 下使能并等待（`disable_settle_ms` + 轮询使能状态 OFF）→ 线圈 3 上使能并等待（`enable_settle_ms` + 轮询使能状态 ON）
- 若改用旧的保持寄存器方案：设 `command_mode: "register"` 并填写 `command_register` / `command_values`。
- 所有操作无论成功失败都会写入日志。

现场注意：机器人需开启 **IO/Modbus 配置**，且「开始」通常要求处于**自动模式**并已配置默认运行工程。

## 切到真实数据前必须确认

状态由各站脚本写入**监控专用**保持寄存器（与 EAP/旋转等业务地址分开），平台轮询：

1. **动作码** `action_register=4100`：当前工艺步骤；**异常码** `fault_register=4101`：异常/停机（0=正常）。两者分开展示，异常不再盖住动作码；卡片颜色仍按异常等级加重。
2. 命令已按越疆线圈实现，一般不必再配 `command_register`。
3. 禁止占用：3095、3751~3754、3703、3811~3814（EAP 出）、3911~3914（EAP 入）、5678/5679（旋转）、8888、3155、2400、2031、2032、4600 等。

当前默认四站：`上内胆1/2`（73/71）、`上卡圈1/2`（81/80），`mode` 为 `modbus`。对应 Lua 工程在 `工程/` 下，各站写 `4100/4101`，旋转异步下发、不等待到位。

## 其它

- 默认清单里的站名取自 `eapconfig.xml`，IP 按 192.168.5.序号 推测。74 在 EAP 里没有对应条目，名称是临时写的；72 在 EAP 里是“产品异常处理 / 双工位夹爪Seg”，状态码表把它归入气垫取放。请按现场核对。
- 任何一台电脑都能打开页面并下发指令，而服务监听在 0.0.0.0。现场使用建议设置 `control_pin`，并只在受控的局域网内运行。
- 也可以主动上报：`curl -X POST localhost:8080/api/report -H "Content-Type: application/json" -d "{\"id\":\"71\",\"code\":917}"`，`id` 是序号，`code` 传 `null` 表示离线。
- 状态码表也可从 Excel 更新：运行 `python gen_codes.py` 覆盖根目录 `codes.json`（需要 `openpyxl`）；手工改 `codes.json` 后重启即可。
- 测试：`python -m unittest test_server -v`
