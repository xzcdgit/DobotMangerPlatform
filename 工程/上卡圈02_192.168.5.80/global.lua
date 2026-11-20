-- global.lua  上料臂 R2 (192.168.5.80)
-- 通信、互锁、相机、IO、配置，以及 src0 以外的流程工具。
-- 本文件只定义变量和函数，顶层不运动、不写现场 IO。

-- ============================================================================
-- 网络
-- ============================================================================
local g_self_ip = '192.168.5.80'
local g_self_port = 502
local g_slave_id = 1
local g_r3_ip = '192.168.5.94'
local g_peer_ip = '192.168.5.81' -- 对臂 R1
local g_cam_ip = '192.168.5.9'
local g_cam_port = 1002
local g_rot_ip = '192.168.5.157' -- 旋转机构

local SEG_REG_OUT = 3811 -- 机械臂 -> EAP
local SEG_REG_IN = 3911 -- EAP -> 机械臂

-- ============================================================================
-- 现场配置
-- ============================================================================
CFG = {
    cfg_version = 'v21-2026-11-19', -- 与本文件 EXPECTED_CFG_VERSION 比对
    do_suck_1 = 4, -- 吸盘1吸气 DO
    do_blow_1 = 3, -- 吸盘1吹气 DO
    do_suck_2 = 2, -- 吸盘2吸气 DO
    do_blow_2 = 1, -- 吸盘2吹气 DO
    do_suck = 4, -- 单盘吸气，与吸盘1同一路
    do_blow = 3, -- 单盘吹气，与吹气1同一路
    do_varpitch = 6, -- 变距 DO
    varpitch_close = 0, -- 窄距电平，起机时写入
    di_vacuum_1 = 5, -- 吸盘1真空反馈 DI，1=吸住
    vacuum_step_dz = 2.0, -- 真空不到位时每次再下降(mm)
    vacuum_max_dz = 6.1, -- 真空补偿最多再下降(mm)
    vacuum_settle = 100, -- 读真空 DI 前的等待(ms)
    cup1_place_rot_comp = 0.0, -- 吸盘1放料角补偿(度)，加在相机角上再写入 5678
    interlock_enabled = true, -- true 时目标越出安全区才和另一臂互锁
    interlock_axis = 'xy', -- 参与判定的轴：x / y / xy
    interlock_x_min = -999, -- X 安全下限(mm)
    interlock_x_max = 999, -- X 安全上限(mm)
    interlock_y_min = -60, -- Y 安全下限(mm)
    interlock_y_max = 400, -- Y 安全上限(mm)
    grab_above_dz = 30.0, -- 抓取点上方接近高度(mm)
    lift_dz = 50.0, -- 吸住后抬升、放料后抬升(mm)
    grab_approach_speed = 60, -- 下降到抓取点的速度(1~100)
    grab_approach_accel = 10, -- 下降到抓取点的加速度(1~100)
    grab_lift_speed = 60, -- 吸住后抬升速度(1~100)
    grab_lift_accel = 10, -- 吸住后抬升加速度(1~100)
    place_approach_speed = 60, -- 下降到放料点的速度(1~100)
    place_approach_accel = 10, -- 下降到放料点的加速度(1~100)
    grab_cp = 0, -- 抓取点过渡半径，0=到点停稳
    place_cp = 0, -- 放料点过渡半径，0=到点停稳
    cam_timeout = 5, -- 相机 TCP 读超时(秒)
    cam_start_cmd = 'start', -- 触发拍照的报文
    cam_retry_wait = 5000, -- 拍照结果无效后的重试间隔(ms)
    photo_settle = 500, -- 停在拍照点后、触发前的稳定时间(ms)
    cam_response_wait = 0, -- 发出拍照指令后、读报文前的等待(ms)
    wait_io_settle = 50, -- 初始化吹吸气后的等待(ms)
    wait_coil_poll = 10, -- 线圈轮询间隔(ms)，src1 也按这个间隔看 5666
    wait_rot_poll = 200, -- 旋转机构写后间隔/状态轮询(ms)
    wait_seg_poll = 15, -- EAP Seg 轮询间隔(ms)
    wait_conn_retry = 500, -- Modbus 或相机连接失败后的重试间隔(ms)
    wait_grab_lock = 10, -- 抓取互锁轮询间隔(ms)
    wait_pick_settle = 200, -- 开吸气后、判真空前的等待(ms)
    place_release_settle = 300, -- 放料开吹气后、抬起前的等待(ms)
    tray_release_settle = 100, -- 抛盘开吹气后、抬起前的等待(ms)
    quality_check_enabled = false, -- true 时保持寄存器 3703==10 才下降放料
    rot_holdreg_type = 'F32' -- 角度寄存器 5678 的类型，F32 占用 5678 和 5679
}

-- [校验] 通用配置表校验：启动时由 src0.lua 的 Validate_Config 调用，及早发现配置错误。
function Validate_CFG()
    local function chk_num(name, v, min, max)
        if type(v) ~= 'number' or v ~= v or v < min or v > max then
            error('[CONFIG_ERROR] ' .. name .. ' 必须是 ' .. min .. '~' .. max .. ' 的有限数值，当前=' .. tostring(v), 0)
        end
    end
    local function chk_int(name, v, min, max)
        chk_num(name, v, min, max)
        if math.floor(v) ~= v then
            error('[CONFIG_ERROR] ' .. name .. ' 必须是整数，当前=' .. tostring(v), 0)
        end
    end
    if type(CFG) ~= 'table' then
        error('[CONFIG_ERROR] CFG 配置表缺失', 0)
    end
    chk_int('CFG.do_blow', CFG.do_blow, 0, 255)
    chk_int('CFG.do_suck', CFG.do_suck, 0, 255)
    chk_num('CFG.grab_above_dz', CFG.grab_above_dz, 0, 200)
    chk_num('CFG.lift_dz', CFG.lift_dz, 0, 500)
    chk_num('CFG.grab_approach_speed', CFG.grab_approach_speed, 1, 100)
    chk_num('CFG.grab_approach_accel', CFG.grab_approach_accel, 1, 100)
    chk_num('CFG.grab_lift_speed', CFG.grab_lift_speed, 1, 100)
    chk_num('CFG.grab_lift_accel', CFG.grab_lift_accel, 1, 100)
    chk_num('CFG.place_approach_speed', CFG.place_approach_speed, 1, 100)
    chk_num('CFG.place_approach_accel', CFG.place_approach_accel, 1, 100)
    chk_num('CFG.grab_cp', CFG.grab_cp, 0, 100)
    chk_num('CFG.place_cp', CFG.place_cp, 0, 100)
    chk_num('CFG.cam_timeout', CFG.cam_timeout, 0.1, 60)
    if type(CFG.cam_start_cmd) ~= 'string' or CFG.cam_start_cmd == '' then
        error('[CONFIG_ERROR] CFG.cam_start_cmd 不能为空', 0)
    end
    chk_num('CFG.cam_retry_wait', CFG.cam_retry_wait, 0, 60000)
    chk_num('CFG.photo_settle', CFG.photo_settle, 0, 5000)
    chk_num('CFG.cam_response_wait', CFG.cam_response_wait, 0, 60000)
    chk_num('CFG.wait_io_settle', CFG.wait_io_settle, 10, 5000)
    chk_num('CFG.wait_coil_poll', CFG.wait_coil_poll, 10, 5000)
    chk_num('CFG.wait_rot_poll', CFG.wait_rot_poll, 50, 5000)
    chk_num('CFG.wait_seg_poll', CFG.wait_seg_poll, 10, 5000)
    chk_num('CFG.wait_conn_retry', CFG.wait_conn_retry, 100, 30000)
    chk_num('CFG.wait_grab_lock', CFG.wait_grab_lock, 10, 5000)
    chk_num('CFG.wait_pick_settle', CFG.wait_pick_settle, 10, 5000)
    chk_num('CFG.place_release_settle', CFG.place_release_settle, 10, 5000)
    chk_num('CFG.tray_release_settle', CFG.tray_release_settle, 10, 5000)
    if type(CFG.quality_check_enabled) ~= 'boolean' then
        error('[CONFIG_ERROR] CFG.quality_check_enabled 必须是布尔值', 0)
    end
    -- 【v3】一抓二新增配置校验
    chk_int('CFG.do_suck_1', CFG.do_suck_1, 0, 255)
    chk_int('CFG.do_blow_1', CFG.do_blow_1, 0, 255)
    chk_int('CFG.do_suck_2', CFG.do_suck_2, 0, 255)
    chk_int('CFG.do_blow_2', CFG.do_blow_2, 0, 255)
    chk_int('CFG.do_varpitch', CFG.do_varpitch, 0, 255)
    chk_num('CFG.varpitch_close', CFG.varpitch_close, 0, 1)
    chk_num('CFG.cup1_place_rot_comp', CFG.cup1_place_rot_comp, -180, 180)
    if
        type(CFG.rot_holdreg_type) ~= 'string' or
            not (CFG.rot_holdreg_type == 'U16' or CFG.rot_holdreg_type == 'U32' or CFG.rot_holdreg_type == 'F32' or
                CFG.rot_holdreg_type == 'F64')
     then
        error('[CONFIG_ERROR] CFG.rot_holdreg_type 无效=' .. tostring(CFG.rot_holdreg_type), 0)
    end
    -- 【v4】真空/偏移/下降补偿配置校验
    chk_int('CFG.di_vacuum_1', CFG.di_vacuum_1, 0, 255)
    chk_num('CFG.vacuum_step_dz', CFG.vacuum_step_dz, 0.1, 100)
    chk_num('CFG.vacuum_max_dz', CFG.vacuum_max_dz, 0.1, 200)
    -- 【v5】真互锁配置校验
    if type(CFG.interlock_enabled) ~= 'boolean' then
        error('[CONFIG_ERROR] CFG.interlock_enabled 必须是布尔值', 0)
    end
    if
        type(CFG.interlock_axis) ~= 'string' or
            not (CFG.interlock_axis == 'x' or CFG.interlock_axis == 'y' or CFG.interlock_axis == 'xy')
     then
        error('[CONFIG_ERROR] CFG.interlock_axis 无效=' .. tostring(CFG.interlock_axis) .. ' (应为 x / y / xy)', 0)
    end
    chk_num('CFG.interlock_x_min', CFG.interlock_x_min, -100000, 100000)
    chk_num('CFG.interlock_x_max', CFG.interlock_x_max, -100000, 100000)
    chk_num('CFG.interlock_y_min', CFG.interlock_y_min, -100000, 100000)
    chk_num('CFG.interlock_y_max', CFG.interlock_y_max, -100000, 100000)
    if CFG.interlock_x_min > CFG.interlock_x_max then
        error('[CONFIG_ERROR] CFG.interlock_x_min 不能大于 interlock_x_max', 0)
    end
    if CFG.interlock_y_min > CFG.interlock_y_max then
        error('[CONFIG_ERROR] CFG.interlock_y_min 不能大于 interlock_y_max', 0)
    end
    print('[校验] CFG 配置校验通过')
end

-- ============================================================================
-- 1a. 抓取互锁线圈映射（全部位于 R3 控制器）
-- ============================================================================
-- 说明: 以下互锁线圈地址、IO 与偏移常量为全局变量，供 global.lua 与 src0.lua 共用；
--       三臂取值一致，仅上面的 IP 配置不同。
-- R1/R2 作为主站连接 R3 后，可读写 R3 的以下线圈寄存器；
-- R3 通过本臂连接(id)直接读写自身这些线圈。
COIL_R1_GRABBED = 2001 -- R1 写 / R3 读: R1 已抓完
COIL_R2_GRABBED = 2010 -- R2 写 / R3 读: R2 已抓完
COIL_R2_DUMPED = 2020 -- R2 写 / R1 读: R2 抛空完成
COIL_R3_DETECT = 2100 -- R3 写 / R1、R2 读: R3 感应到物料/料盘(拍照触发)
COIL_R3_CONTINUE = 2200 -- R3 写 / R1、R2 读: R3 通知继续工作
COIL_R3_READY = 2300 -- R3 写 / R1、R2 读: R3 二次抬升到位(继续流程)
COIL_R3_SWITCH_FACE = 2400 -- R2 写 / R3 读: 相机 130 空托盘 → 请求 R3 换面(A↔B)

-- R1/R2 抓取互斥锁（防止两臂同时伸入同一托盘；全部位于 R3 控制器）
COIL_GRAB_BUSY = 2030 -- 共享: 1 = 某臂正在抓取（互斥持有）
COIL_GRAB_REQ_R1 = 2031 -- R1 请求进入抓取区
COIL_GRAB_REQ_R2 = 2032 -- R2 请求进入抓取区
COIL_GRAB_TURN = 2033 -- 仲裁令牌: 0 = 优先 R1, 1 = 优先 R2（交替，防饿死）

-- 【v2 新增】入组重连协议线圈（位于 R3 控制器；2040~2042 需现场核实可用且上电初值为 0）
COIL_JOIN_REQ_R1 = 2040 -- R1 写 / R3 读: R1 入组请求（起机/重启/周期被作废后重新对齐）
COIL_JOIN_REQ_R2 = 2041 -- R2 写 / R3 读: R2 入组请求
COIL_JOIN_ACK = 2042 -- R3 写 / 三臂读: 入组应答，兼“周期作废”电平

-- 【v2 新增】线圈所有权表：每个线圈只有唯一写者；Init_IO 只复位本臂拥有的线圈。
-- 这是“单臂可随意重启”的基础：重启臂绝不会抹掉另外两臂/R3 的在途信号。
-- 唯一特例：R3 在做周期回卷时统一清零 2001/2010/2020（见 R3 src0 Handle_Join_Response），
-- 且只在“两臂都不在托盘内”时执行，随后两臂都会重拍照重报，不丢真实信息。
OWN_COILS = {
    R1 = {COIL_R1_GRABBED, COIL_GRAB_REQ_R1, COIL_JOIN_REQ_R1},
    R2 = {COIL_R2_GRABBED, COIL_R2_DUMPED, COIL_GRAB_REQ_R2, COIL_JOIN_REQ_R2},
    R3 = {COIL_R3_DETECT, COIL_R3_CONTINUE, COIL_R3_READY, COIL_JOIN_ACK, COIL_GRAB_BUSY, COIL_GRAB_TURN}
}

-- 取料后旋转(各臂自身控制器; 仅 R1/R2 使用，R3 无此动作但常量/函数保持一致)
HREG_ROT_ANGLE = 5678 -- 吸盘1 保寄存器: 物料旋转角度(写入/复位)
COIL_ROT_DONE = 4444 -- 自身线圈: 旋转到位(src1 确认机构运动完成后置1，src0 放料前等待)
COIL_ROT_REQ = 5666 -- 自身线圈: 请求旋转(src0 置1，src1 下发后清0)

-- ============================================================================
-- 5. [核心] 本臂 Modbus 连接（连接本臂控制器）
-- ============================================================================
local function Connect_Modbus(label, ip)
    while true do
        print('[' .. label .. '] 创建 Modbus TCP，目标=' .. ip .. ':' .. tostring(g_self_port) .. '，站号=' .. tostring(g_slave_id))
        local err, newid = ModbusCreate(ip, g_self_port, g_slave_id)
        if newid ~= nil and err == 0 then
            print('[' .. label .. '] 成功 id=' .. tostring(newid))
            return newid
        end
        print('[' .. label .. '] 失败 err=' .. tostring(err) .. '，重试')
        Wait(CFG.wait_conn_retry)
    end
end

function PLC_Connet()
    id = Connect_Modbus('本臂连接', g_self_ip)
    Init_Monitor_Regs(101)
end

function Connect_R3()
    id_r3 = Connect_Modbus('R3连接', g_r3_ip)
end

function Connect_Peer()
    id_peer = Connect_Modbus('对臂连接', g_peer_ip)
end

-- 控制线圈：5清报警 1停止 4下使能 3上使能 0开始。脉冲：0 → 100ms → 1 → 100ms → 0
local RESTART_COILS = {5, 1, 4, 3, 0}
local RESTART_PULSE_MS = 100
local COIL_RESTART_BY_PEER = 4600 -- 本臂线圈。1=这次是对臂拉起的，不再回发重启

local function Pulse_Coil(conn, addr)
    Set_Coil(conn, addr, 0)
    Wait(RESTART_PULSE_MS)
    Set_Coil(conn, addr, 1)
    Wait(RESTART_PULSE_MS)
    Set_Coil(conn, addr, 0)
end

function Restart_Peer_If_Needed()
    local mark = Read_Coil(id, COIL_RESTART_BY_PEER)
    if mark == nil then
        error('[RESTART] 读本臂重启标记失败 addr=' .. tostring(COIL_RESTART_BY_PEER), 0)
    end
    if mark == 1 then
        Set_Coil(id, COIL_RESTART_BY_PEER, 0)
        print('[重启] 本次由对臂触发，不再回发重启')
        return
    end
    Connect_Peer()
    Set_Stage('重启对臂')
    print('[重启] 连接对臂 ' .. g_peer_ip .. '，置标记后按 5,1,4,3,0 发脉冲')
    Set_Coil(id_peer, COIL_RESTART_BY_PEER, 1)
    for _, addr in ipairs(RESTART_COILS) do
        print('[重启] 脉冲线圈 ' .. tostring(addr))
        Pulse_Coil(id_peer, addr)
    end
    print('[重启] 对臂重启线圈已发送')
end

-- [核心] 2D 相机 TCP 连接（仅 R1/R2 调用；R3 自身无需调用）
function Open_Camera()
    ::create_cam::
    print('[相机] 创建 TCP 客户端，目标=' .. g_cam_ip .. ':' .. tostring(g_cam_port))
    local err, sock = TCPCreate(false, g_cam_ip, g_cam_port)
    if err ~= 0 then
        print('[相机] 创建失败 err=' .. tostring(err) .. '，重试')
        Wait(CFG.wait_conn_retry)
        goto create_cam
    end
    local rc = TCPStart(sock, 0)
    if rc ~= 0 then
        print('[相机] 连接失败 rc=' .. tostring(rc) .. '，重试')
        Wait(CFG.wait_conn_retry)
        goto create_cam
    end
    cam_socket = sock
    print('[相机] 连接成功')
end

-- ============================================================================
-- 6. [核心] 相机 触发 / 接收 / 解析
-- ============================================================================

-- [相机] 发送触发指令（默认不设超时，一直等到对端接收）。
-- 【v2】失败不再原地 Pause()：改为返回错误码，由 Take_Photo_Checked 无限重试，
--       相机抖一下不至于整机停线，但也绝不会拿不到结果就往下走。
function Send_Camera(cmd)
    local rc = TCPWrite(cam_socket, cmd, 0)
    if rc ~= 0 then
        print('[相机] 发送失败 cmd=' .. tostring(cmd) .. ' rc=' .. tostring(rc))
    end
    return rc
end

-- [相机] 接收相机返回串；失败返回 nil。
function Receive_Camera()
    local recv_err, recv = TCPRead(cam_socket, CFG.cam_timeout, 'string')
    if recv_err ~= 0 then
        print('[相机] 接收失败 err=' .. tostring(recv_err))
        return nil
    end
    return recv
end

-- [相机] 解析 2D 相机报文。
-- 兼容两种线格式:
--   {310,{物料类型,x,y,z,rx,ry,rz,旋转角,保留1,保留2}...}  -> 有物料（带外层花括号）
--   {120,{物料类型,x,y,z,rx,ry,rz,旋转角,保留1,保留2}}      -> 有料盘
--   {130}                                                  -> 空托盘
--   `310,{1,...}`（无外层花括号，仅状态码 + 条目）同样兼容
-- 其中 物料类型: 1=物料, 10=料盘。
-- 返回: { code= <status|nil>, items={ {mat_type=,x=,y=,z=,rx=,ry=,rz=,rot=,r1=,r2=}, ... } }
-- 说明: 该函数只做纯字符串解析，不依赖任何外部 API，便于离线校验。
function Parse_Camera_Data(recv)
    if type(recv) ~= 'string' or recv == '' then
        print('[相机] 报文为空或类型异常: ' .. tostring(recv))
        return {code = nil, items = {}}
    end
    local result = {code = nil, items = {}}
    local s = recv:gsub('%s+', '')
    -- 去掉可能存在的“外层包裹花括号”：{310,{...}} -> 310,{...}
    -- 仅当跳过前导 '{' 后仍能以数字开头时才当成信封剥掉（避免误剥条目）。
    local body = s
    if s:match('^%{%d+') then
        body = s:sub(2, -2)
    end
    local code_str = body:match('^(%d+)')
    if not code_str then
        print('[相机] 无法解析状态码: ' .. tostring(recv))
        return result
    end
    result.code = tonumber(code_str)
    if result.code == 130 then
        return result -- 空托盘，无物料
    end
    -- 逐个提取被花括号包裹的条目（此时 body 已是 "310,{..},{..}"，%b{} 只匹配条目）。
    for inner in body:gmatch('%b{}') do
        local tuple = inner:sub(2, -2)
        local fields = {}
        local parsed = true
        local idx = 0
        for f in tuple:gmatch('[^,]+') do
            idx = idx + 1
            local n = tonumber(f)
            if n == nil then
                parsed = false
                break
            end
            fields[idx] = n
        end
        -- 需要至少 7 个有效字段才认为是一个可用物料/料盘坐标。
        if parsed and #fields >= 7 then
            table.insert(
                result.items,
                {
                    mat_type = fields[1],
                    x = fields[2],
                    y = fields[3],
                    z = fields[4],
                    rx = fields[5],
                    ry = fields[6],
                    rz = fields[7],
                    rot = fields[8],
                    r1 = fields[9],
                    r2 = fields[10]
                }
            )
        end
    end
    return result
end

-- [相机] 完整拍照流程: 触发拍照，接收并解析。
-- 说明: 互锁线圈(2001/2010/2020)的复位已改到各臂【生产周期开始】统一执行，
--       拍照时不再复位，避免“陈旧信号”被当作本周期结果。见 src0.lua Production_Cycle。
function Take_Photo()
    print('[相机] 触发拍照: ' .. tostring(CFG.cam_start_cmd))
    local rc = Send_Camera(CFG.cam_start_cmd)
    if rc ~= 0 then
        return {code = nil, items = {}, recv_fail = true}
    end
    -- 【v15】触发后先等 cam_response_wait(默认1.5s)，让相机完成新扫描再读报文，避免读到过期/上一帧导致抓空位
    Wait(CFG.cam_response_wait)
    local recv = Receive_Camera()
    if recv == nil then
        return {code = nil, items = {}, recv_fail = true}
    end
    print('[相机] 收到报文: ' .. tostring(recv))
    local parsed = Parse_Camera_Data(recv)
    parsed.recv_fail = false
    return parsed
end

-- 【v2 新增】无限重试直到拿到有效拍照结果（code 必为 310/120/130 之一）。
-- 修复初版缺陷：补拍时相机失败返回 code=nil，被误判成“空托盘已抓完”从而错误放行。
-- 现场决策：不设次数上限、不报警停机；相机没结果就一直等在拍照环节，流程绝不推进。
function Take_Photo_Checked()
    local tries = 0
    while true do
        local photo = Take_Photo()
        local code = photo and photo.code
        if code == 310 or code == 120 or code == 130 then
            if tries > 0 then
                print('[相机] 第 ' .. tostring(tries + 1) .. ' 次拍照有效, code=' .. tostring(code))
            end
            return photo
        end
        tries = tries + 1
        print(
            '[相机] 第 ' ..
                tostring(tries) ..
                    ' 次拍照无有效结果(code=' .. tostring(code) .. ')，' .. tostring(CFG.cam_retry_wait) .. 'ms 后重试（流程不推进）'
        )
        Wait(CFG.cam_retry_wait)
    end
end

-- ============================================================================
-- 7. [核心] 线圈寄存器读写与等待（conn_id 由调用方传入）
-- ============================================================================
-- R1/R2 传 id_r3，R3 传本臂 id。
function Read_Coil(conn_id, addr)
    local coils = GetCoils(conn_id, addr, 1)
    if coils == nil then
        return nil
    end
    return coils[1]
end

-- 【v2】校验 SetCoils 返回值（文档: 0=成功, -1=失败）；写失败立即报错 -> 顶层报警。
--       初版不校验，会出现“日志以为已上报、实际没写进去”，让另外两臂/R3 永久等待。
function Set_Coil(conn_id, addr, val)
    local rc = SetCoils(conn_id, addr, 1, {val})
    if rc ~= 0 then
        error(
            '[PLC_WRITE_ERROR] 写线圈失败 会话=' ..
                tostring(conn_id) .. ' 地址=' .. tostring(addr) .. ' 值=' .. tostring(val) .. ' rc=' .. tostring(rc),
            0
        )
    end
end

-- 持续读取线圈直到等于 expect；不设超时（现场决策：卡住就重启卡住的臂）。
-- 【v2】abort 为可选表 {addr=<线圈>, val=<值>}：轮询期间若 abort 线圈命中 val，
--       说明 R3 已把本周期回卷（入组应答 2042=1），此时抛 [RESTART_CYCLE]，
--       由 src0.lua 的 Main 捕获并从周期起点重入（重新拍照、重新上报）。
-- 2001~2042 一次读回。阶段判断和“目标+作废”都落在这段里时，每拍只打一包 Modbus。
local HANDSHAKE_BASE = 2001
local HANDSHAKE_COUNT = 42 -- 2001..2042

function Read_Arm_State(conn_id)
    local raw = GetCoils(conn_id, HANDSHAKE_BASE, HANDSHAKE_COUNT)
    if type(raw) ~= 'table' then
        return nil
    end
    local state = {}
    local addrs = {
        COIL_R1_GRABBED,
        COIL_R2_GRABBED,
        COIL_R2_DUMPED,
        COIL_GRAB_REQ_R1,
        COIL_GRAB_REQ_R2,
        COIL_JOIN_REQ_R1,
        COIL_JOIN_REQ_R2,
        COIL_JOIN_ACK
    }
    for _, addr in ipairs(addrs) do
        state[addr] = raw[addr - HANDSHAKE_BASE + 1]
    end
    return state
end

local function In_Handshake(addr)
    return type(addr) == 'number' and addr >= HANDSHAKE_BASE and addr < HANDSHAKE_BASE + HANDSHAKE_COUNT
end

local function Abort_If(abort, value)
    if abort ~= nil and value == abort.val then
        error(
            '[RESTART_CYCLE] 等待期间检测到周期作废(addr=' .. tostring(abort.addr) .. '==' .. tostring(abort.val) .. ')，本臂从周期起点重入',
            0
        )
    end
end

function Wait_Coil(conn_id, addr, expect, abort)
    local hit
    repeat
        hit = nil
        if In_Handshake(addr) and (abort == nil or In_Handshake(abort.addr)) then
            local state = Read_Arm_State(conn_id)
            if state ~= nil then
                if abort ~= nil then
                    Abort_If(abort, state[abort.addr])
                end
                hit = state[addr]
            end
        else
            if abort ~= nil then
                Abort_If(abort, Read_Coil(conn_id, abort.addr))
            end
            local coils = GetCoils(conn_id, addr, 1)
            hit = coils and coils[1]
        end
        if hit ~= expect then
            Wait(CFG.wait_coil_poll)
        end
    until hit == expect
    print('[线圈] 等待 addr=' .. tostring(addr) .. ' == ' .. tostring(expect) .. ' 完成')
end

-- ============================================================================
-- 7a. 取料后旋转（旋转机构 IP 见 g_rot_ip。68=脉冲(6000脉冲/360°)，70=0复位 / 1反向 / 2正向）
--     角度是相对转角。下发后轮询旋转机构状态寄存器 75 的 bit7(运动完成)，到位后 src1 才置 4444。
--     src0 抬升后只写 5678 并置请求线圈 5666，然后继续走。src1 看到 5666 后调用 RotatingMachineControl。
-- ============================================================================
local ROT_MACHINE_PORT = 501
local HOLDREG_TYPE_COUNT = {U16 = 1, U32 = 2, F32 = 2, F64 = 4}

local function HoldReg_Count(dtype)
    local n = HOLDREG_TYPE_COUNT[dtype]
    if n == nil then
        error('[CONFIG_ERROR] 不支持的数据类型: ' .. tostring(dtype), 0)
    end
    return n
end

-- 【v2 新增】旋转寄存器统一写入（带返回码校验）。初版复位 4321 时不校验返回值，
-- 写失败会让下一次握手从脏值开始，且没有任何痕迹。
-- 【v3】旋转寄存器统一写入（带返回码校验）。addr 决定写 4321(吸盘1) 还是 4331(吸盘2)。
local function Write_Rotate_Angle(addr, value)
    local dtype = CFG.rot_holdreg_type
    local cnt = HoldReg_Count(dtype)
    local rc = SetHoldRegs(id, addr, cnt, {value}, dtype)
    if rc ~= 0 then
        error(
            '[PLC_WRITE_ERROR] 写旋转寄存器 ' .. tostring(addr) .. ' 失败 value=' .. tostring(value) .. ' rc=' .. tostring(rc),
            0
        )
    end
end

local function Write_Rot_Reg(rot_id, addr, values)
    local rc = SetHoldRegs(rot_id, addr, 1, values)
    if rc ~= 0 then
        error('[PLC_WRITE_ERROR] 旋转机构写寄存器 ' .. tostring(addr) .. ' 失败 rc=' .. tostring(rc), 0)
    end
end

-- 旋转机构状态寄存器 75：bit7(运动完成) 为 1 表示内部脉冲发送完成，为 0 表示正在运动。
local ROT_STATUS_REG = 75
local ROT_MOTION_DONE_BIT = 7
local ROT_START_WINDOW_MS = 1000

-- 返回 true=运动完成，false=运动中，nil=读取失败。
local function Rot_Motion_Done(rot_id)
    local regs = GetHoldRegs(rot_id, ROT_STATUS_REG, 1)
    if type(regs) ~= 'table' or regs[1] == nil then
        return nil
    end
    return math.floor(regs[1] / 2 ^ ROT_MOTION_DONE_BIT) % 2 == 1
end

-- 启动后轮询是否进入“运动中”。返回 false 表示窗口内未观察到运动（可能已极快完成，也可能未启动），
-- 调用方只告警并按到位处理，绝不重发脉冲（重发会导致同一件多转）。
local function Wait_Rot_Started(rot_id)
    local elapsed = 0
    while elapsed < ROT_START_WINDOW_MS do
        if Rot_Motion_Done(rot_id) == false then
            return true
        end
        Wait(CFG.wait_rot_poll)
        elapsed = elapsed + CFG.wait_rot_poll
    end
    return false
end

-- 等待到位。不设超时（与 Wait_Coil 的现场策略一致），读失败时继续轮询，不重发脉冲。
local function Wait_Rot_Done(rot_id)
    repeat
        Wait(CFG.wait_rot_poll)
    until Rot_Motion_Done(rot_id) == true
end

function RotatingMachineControl(rotationAngle)
    local total = rotationAngle + 0
    local dir, data
    if total < 0 then
        dir = {1}
        data = {math.floor(-total / 360 * 6000 + 0.5)}
    else
        dir = {2}
        data = {math.floor(total / 360 * 6000 + 0.5)}
    end
    if data[1] == 0 then
        print('[旋转] 角度=' .. tostring(total) .. ' 脉冲=0，不下发')
        return
    end
    local err, rot_id = ModbusCreate(g_rot_ip, ROT_MACHINE_PORT, 1)
    if err ~= 0 then
        error('[PLC_WRITE_ERROR] 旋转机构Modbus连接失败 ip=' .. g_rot_ip .. ' err=' .. tostring(err), 0)
    end
    local ok, fail =
        pcall(
        function()
            Wait(CFG.wait_rot_poll)
            Write_Rot_Reg(rot_id, 70, {0}) -- 重置启动电机信号
            Wait(CFG.wait_rot_poll)
            print(
                '[旋转] ip=' ..
                    g_rot_ip .. ' 角度=' .. tostring(total) .. ' 脉冲=' .. tostring(data[1]) .. ' 方向=' .. tostring(dir[1])
            )
            Write_Rot_Reg(rot_id, 68, data)
            Wait(CFG.wait_rot_poll)
            Write_Rot_Reg(rot_id, 70, dir) -- 启动电机；写入后立即开始轮询，不再重发脉冲
            if not Wait_Rot_Started(rot_id) then
                print('[旋转][WARN] ' .. ROT_START_WINDOW_MS .. 'ms 内未观察到运动中(寄存器75 bit7 未变0)，可能已极快完成，按到位处理，请核对现场')
            end
            Wait_Rot_Done(rot_id)
            print('[旋转] 到位确认: 寄存器75 bit7=1，运动完成')
        end
    )
    pcall(ModbusClose, rot_id)
    if not ok then
        error(fail, 0)
    end
end

local ROT_REQ_TRIES = 3

local function Try_Set_Coil(conn_id, addr, val)
    if conn_id == nil then
        return false, 'no_conn'
    end
    local ok, rc =
        pcall(
        function()
            return SetCoils(conn_id, addr, 1, {val})
        end
    )
    if not ok then
        return false, rc
    end
    return rc == 0, rc
end

local function Try_Write_Rotate_Angle(addr, value)
    if id == nil then
        return false, 'no_conn'
    end
    local ok, rc =
        pcall(
        function()
            local dtype = CFG.rot_holdreg_type
            local cnt = HoldReg_Count(dtype)
            return SetHoldRegs(id, addr, cnt, {value}, dtype)
        end
    )
    if not ok then
        return false, rc
    end
    return rc == 0, rc
end

-- 清旧到位标志 -> 写角度 -> 置请求。清标志必须最先做，否则上一件的 4444=1 会让本件假到位。
local function Try_Post_Rotate_Request(total)
    local clr_ok, clr_rc = Try_Set_Coil(id, COIL_ROT_DONE, 0)
    if not clr_ok then
        return false, '清到位 rc=' .. tostring(clr_rc)
    end
    local ang_ok, ang_rc = Try_Write_Rotate_Angle(HREG_ROT_ANGLE, total)
    if not ang_ok then
        return false, '写角度 rc=' .. tostring(ang_rc)
    end
    local req_ok, req_rc = Try_Set_Coil(id, COIL_ROT_REQ, 1)
    if not req_ok then
        return false, '置请求 rc=' .. tostring(req_rc)
    end
    return true, nil
end

-- 返回 true 表示已交给 src1，需要放料前等待 4444；false 表示请求未送达，不能等待。
function Request_Rotate_Single(angle, cup)
    local total = angle or 0
    print('[旋转] 吸盘' .. tostring(cup or 1) .. ' 请求角度=' .. tostring(total) .. '，交给 src1，轨迹继续')
    local last = nil
    for i = 1, ROT_REQ_TRIES do
        local ok
        ok, last = Try_Post_Rotate_Request(total)
        if ok then
            return true
        end
        print('[旋转] 第 ' .. tostring(i) .. ' 次请求写入失败(' .. tostring(last) .. ')，轨迹不停止')
        if i < ROT_REQ_TRIES then
            Wait(CFG.wait_coil_poll)
        end
    end
    print('[旋转] 请求写入仍失败，本件不旋转，放料前不等待旋转到位 角度=' .. tostring(total))
    return false
end

-- src1 自己的本臂连接。不使用 src0 的 id，避免和轨迹线程抢同一条 Modbus。
id_rot_thread = nil

local function Close_Rotate_Thread()
    if id_rot_thread ~= nil then
        pcall(ModbusClose, id_rot_thread)
        id_rot_thread = nil
    end
end

local function Ensure_Rotate_Thread()
    if id_rot_thread ~= nil then
        return true
    end
    local err, newid = ModbusCreate(g_self_ip, g_self_port, g_slave_id)
    if err ~= 0 or newid == nil then
        print('[旋转] src1 连接本臂失败 err=' .. tostring(err))
        return false
    end
    id_rot_thread = newid
    print('[旋转] src1 已连接本臂 id=' .. tostring(newid))
    return true
end

-- 旋转已完成但 4444 置位失败时保持挂起，之后每轮重试置位，绝不重复下发脉冲。
local rot_done_pending = false

local function Publish_Rot_Done()
    local done_ok, done_rc = Try_Set_Coil(id_rot_thread, COIL_ROT_DONE, 1)
    if done_ok then
        rot_done_pending = false
        print('[旋转] src1 到位确认完成，4444 已置1')
    else
        rot_done_pending = true
        print('[旋转] src1 写完成线圈失败 rc=' .. tostring(done_rc) .. '，保持挂起重试，不重复旋转')
        Wait(CFG.wait_conn_retry)
    end
    return true
end

function Rotate_Thread_Step()
    if not Ensure_Rotate_Thread() then
        Wait(CFG.wait_conn_retry)
        return false
    end
    if rot_done_pending then
        return Publish_Rot_Done()
    end
    local coils = GetCoils(id_rot_thread, COIL_ROT_REQ, 1)
    if coils == nil then
        print('[旋转] src1 读请求线圈失败，重连')
        Close_Rotate_Thread()
        return false
    end
    if coils[1] ~= 1 then
        return false
    end
    local dtype = CFG.rot_holdreg_type
    local regs = GetHoldRegs(id_rot_thread, HREG_ROT_ANGLE, HoldReg_Count(dtype), dtype)
    if type(regs) ~= 'table' or regs[1] == nil then
        print('[旋转] src1 读角度失败，保持请求，稍后重试')
        Wait(CFG.wait_conn_retry)
        return false
    end
    local angle = regs[1]
    local cleared, clear_rc = Try_Set_Coil(id_rot_thread, COIL_ROT_REQ, 0)
    if not cleared then
        print('[旋转] src1 清请求失败 rc=' .. tostring(clear_rc) .. '，保持请求稍后重试')
        return false
    end
    print('[旋转] src1 开始下发 角度=' .. tostring(angle))
    local sent = false
    local last_err = nil
    for i = 1, ROT_REQ_TRIES do
        local ok_rot, rot_err = pcall(RotatingMachineControl, angle)
        if ok_rot then
            sent = true
            break
        end
        last_err = rot_err
        print('[旋转] src1 第 ' .. tostring(i) .. ' 次下发失败: ' .. tostring(rot_err))
        if i < ROT_REQ_TRIES then
            Wait(CFG.wait_conn_retry)
        end
    end
    if not sent then
        print('[旋转] src1 下发/到位确认仍失败，4444 不置位，src0 将停在放料前等待，需人工处理 角度=' .. tostring(angle) .. ' 原因=' .. tostring(last_err))
        return true
    end
    rot_done_pending = true
    return Publish_Rot_Done()
end

function Rotate_Thread_Main()
    local ok, err = pcall(Ensure_Rotate_Thread)
    if ok and id_rot_thread ~= nil then
        Try_Set_Coil(id_rot_thread, COIL_ROT_REQ, 0)
        Try_Set_Coil(id_rot_thread, COIL_ROT_DONE, 0)
        print('[旋转] src1 已清掉上次残留请求')
    else
        print('[旋转] src1 首次连接未成功，跳过清请求，避免清掉已经发出的旋转: ' .. tostring(err))
    end
    while true do
        local ok, result = pcall(Rotate_Thread_Step)
        if not ok then
            print('[旋转] src1 异常: ' .. tostring(result))
            Close_Rotate_Thread()
            Wait(CFG.wait_conn_retry)
        elseif result ~= true then
            Wait(CFG.wait_coil_poll)
        end
    end
end

-- 初始化复位(自身): 清空旋转角度寄存器 5678、完成线圈 4444 与请求 5666。
function Reset_Rotate_Registers()
    Write_Rotate_Angle(HREG_ROT_ANGLE, 0)
    Set_Coil(id, COIL_ROT_DONE, 0)
    Set_Coil(id, COIL_ROT_REQ, 0)
end

-- ============================================================================
-- 7b. 抓取互斥锁（R1/R2 共用；基于 R3 控制器线圈，防止两臂同时伸入同一托盘）
-- ============================================================================
-- 说明: 两臂仅在“任一抓取目标点越出安全区间(进入两臂共享/干涉区)”时才互斥；
--       安全区间内两臂可并行，不申请互斥（替代原“强制令牌互斥”，消除 A1 缺陷）。
--       互斥算法用 Peterson 两进程互斥(基于 R3 共享线圈)：
--         REQ_R1/REQ_R2(2031/2032) = 该臂“想进共享区”兴趣位
--         COIL_GRAB_TURN(2033)     = 回合归属(0=R1,1=R2)，用于解决同时请求，且无死锁
--       CFG 参数: interlock_enabled / interlock_axis / interlock_{x,y}_{min,max}
--       由 R1/R2 通过 id_r3 访问这些线圈；R3 自身不抓取，无需调用。
-- 返回: true=已进入抓取临界区(需配对 Grab_Lock_Release)；false=无需互斥。
-- 传入: 目标抓取点(相机 item，含 x/y)。任一点越出安全区间才互斥。
local function Point_Outside_Safe_Zone(x, y)
    local axis = CFG.interlock_axis or 'xy'
    local ok_x, ok_y = true, true
    if axis ~= 'y' then
        ok_x = (x >= CFG.interlock_x_min and x <= CFG.interlock_x_max)
    end
    if axis ~= 'x' then
        ok_y = (y >= CFG.interlock_y_min and y <= CFG.interlock_y_max)
    end
    return not (ok_x and ok_y)
end

function Grab_Lock_Acquire(arm, ...)
    if not CFG.interlock_enabled then
        return false -- 未启用互锁：不互斥(先跑通其余流程)
    end
    local need_lock = false
    for _, pt in ipairs({...}) do
        if pt and Point_Outside_Safe_Zone(pt.x, pt.y) then
            need_lock = true
            break
        end
    end
    if not need_lock then
        return false -- 目标点都在安全区间内：两臂可并行，不互斥
    end
    local flag_me = (arm == 'R1') and COIL_GRAB_REQ_R1 or COIL_GRAB_REQ_R2
    local flag_other = (arm == 'R1') and COIL_GRAB_REQ_R2 or COIL_GRAB_REQ_R1
    local other_idx = (arm == 'R1') and 1 or 0 -- 自己的回合号让给对臂
    Set_Coil(id_r3, flag_me, 1) -- 我想进共享区
    Set_Coil(id_r3, COIL_GRAB_BUSY, 1)
    Set_Coil(id_r3, COIL_GRAB_TURN, other_idx)
    -- Peterson：对臂也想进 且 轮到对臂 -> 等待；否则进入
    while Read_Coil(id_r3, flag_other) == 1 and Read_Coil(id_r3, COIL_GRAB_TURN) == other_idx do
        Wait(CFG.wait_grab_lock)
    end
    return true
end

function Grab_Lock_Release(arm)
    local flag_me = (arm == 'R1') and COIL_GRAB_REQ_R1 or COIL_GRAB_REQ_R2
    local flag_other = (arm == 'R1') and COIL_GRAB_REQ_R2 or COIL_GRAB_REQ_R1
    Set_Coil(id_r3, flag_me, 0) -- 退出共享区(清兴趣位)
    local other = Read_Coil(id_r3, flag_other) == 1
    if not other then
        Set_Coil(id_r3, COIL_GRAB_BUSY, 0)
    end
end

-- ============================================================================
-- 8. [现场 IO] 吹气 / 吸气 / 关闭全部 DO
-- ============================================================================

-- [现场 IO] 吹气 DO 控制: on=true 打开吹气。
function Set_Blow(on)
    DO(CFG.do_blow, on and ON or OFF)
end

-- [现场 IO] 吸气 DO 控制: on=true 打开吸气。
function Set_Suck(on)
    DO(CFG.do_suck, on and ON or OFF)
end

-- [现场 IO] 关闭全部 DO。吸盘2和变距没有动作，启动时仍关掉，避免残留输出。
function Close_All_DO()
    DO(CFG.do_blow, OFF)
    DO(CFG.do_suck, OFF)
    DO(CFG.do_suck_1, OFF)
    DO(CFG.do_blow_1, OFF)
    DO(CFG.do_suck_2, OFF)
    DO(CFG.do_blow_2, OFF)
    DO(CFG.do_varpitch, CFG.varpitch_close) -- 变距默认回到窄距(抓取态)
    -- TODO 现场: 若还有其他 DO 输出，在此一并关闭。
    print('[DO] 已关闭全部 DO')
end

-- 【v2 弃用于自动流程】整机总复位：清零 R3 上全部互锁/仲裁/入组线圈。
-- 只允许在“三臂全部停机 + 确认末端无料 + 托盘区无人”的冷启动总复位时手工调用。
-- 严禁出现在任何臂的自动起机路径上：它会抹掉另外两臂与 R3 的在途信号，
-- 这正是初版 P0-2“单臂重启撕裂三臂状态”的根因。单臂起机请用 Init_IO(arm, conn)。
-- 【v2 新增】只复位“本臂拥有”的互锁线圈（见 OWN_COILS）：单臂重启的安全动作。
function Reset_Own_Signals(arm, conn)
    local list = OWN_COILS[arm]
    if type(list) ~= 'table' then
        error('[INTERNAL] Reset_Own_Signals 未知臂名: ' .. tostring(arm), 0)
    end
    local c = conn or id
    for _, addr in ipairs(list) do
        Set_Coil(c, addr, 0)
    end
    print('[信号] ' .. tostring(arm) .. ' 已复位自身拥有的互锁线圈（不触碰其它臂与 R3 的信号）')
end

-- 【v2 新增】入组重连（单臂随意重启的安全通道，仅 R1/R2 调用）：
--   置自己的入组请求(2040/2041)=1 -> 等 R3 应答(2042)=1 -> 撤回请求 -> 等应答归 0
--   -> 从周期起点重入（重新拍照，靠相机重建物料真相）。
-- R3 只在“两臂都不在托盘内(2031/2032=0)”的边界应答；2042 同时充当“周期作废”电平，
-- 使另一臂即便正停在 2200/2300 等待中也能同步回到周期起点（见 Wait_Coil 的 abort 参数）。
-- 不设超时（现场决策）：R3 尚未起机时本臂就停在入组点等待，R3 起机后会主动应答。
function Join_As_Arm(arm)
    local req = (arm == 'R1') and COIL_JOIN_REQ_R1 or COIL_JOIN_REQ_R2
    print(
        '[入组] ' ..
            tostring(arm) .. ' 请求入组: 置 addr=' .. tostring(req) .. '=1，等待 R3 应答 addr=' .. tostring(COIL_JOIN_ACK) .. '=1'
    )
    Set_Coil(id_r3, req, 1)
    Wait_Coil(id_r3, COIL_JOIN_ACK, 1)
    -- 请求位多留 100ms。R3 轮询 10ms，足够看到“请求与应答同时为 1”，不会把入组脉冲看丢。
    Wait(100)
    Set_Coil(id_r3, req, 0)
    Wait_Coil(id_r3, COIL_JOIN_ACK, 0)
    print('[入组] ' .. tostring(arm) .. ' 入组完成，按周期起点重入（会重拍照重建物料状态）')
end

-- [现场 IO] 初始化时序: 复位【本臂拥有】的信号 -> 关闭所有 DO -> 打开吹气/关闭吸气 -> 50ms -> 关闭所有 DO。
-- 【v2】签名增加臂名 arm：R1 传 Init_IO('R1', id_r3)，R2 传 Init_IO('R2', id_r3)，
--       R3 传 Init_IO('R3', id)。初版在这里调 Reset_Signals() 清零全部共享线圈，
--       是“单臂重启撕裂三臂状态”的直接原因，现已改为只清本臂拥有的线圈。
-- 注意：Close_All_DO 会让吸盘失电，起机前必须确认末端无料（见现场操作规程）。
function Init_IO(arm, conn)
    print('[IO初始化] 复位本臂(' .. tostring(arm) .. ')拥有的信号并关闭所有 DO')
    Reset_Own_Signals(arm, conn)
    Reset_Rotate_Registers() -- 复位本臂取料后旋转寄存器/线圈(5678/5666/4444)
    Close_All_DO()
    Set_Blow(true) -- 打开吹气
    Set_Suck(false) -- 关闭吸气
    Wait(CFG.wait_io_settle)
    Close_All_DO()
    print('[IO初始化] 完成')
end

-- ============================================================================
-- 9. [核心] EAP 与机械臂 Seg 握手
-- ============================================================================

-- [核心] 机械臂向 EAP 输出 Seg；写 SEG_REG_OUT 并读回用于日志。
-- 【v2】校验写返回码：写失败会直接抛错报警（否则 EAP 永远收不到请求，三臂一起干等）。
function Out_Seg(num)
    local rc = SetHoldRegs(id, SEG_REG_OUT, 4, {num}, 'F64')
    if rc ~= 0 then
        error('[PLC_WRITE_ERROR] Seg输出失败 num=' .. tostring(num) .. ' rc=' .. tostring(rc), 0)
    end
    local back = GetHoldRegs(id, SEG_REG_OUT, 4, 'F64')
    if num == 1000 then
        print('机械臂给出程序号完成: ' .. tostring(num))
    elseif num == 1 then
        print('初始化完成: ' .. tostring(num))
    end
    print(
        '[Seg输出] 机械臂->EAP，寄存器=' ..
            tostring(SEG_REG_OUT) .. '，请求=' .. tostring(num) .. '，读回=' .. tostring(back and back[1])
    )
end

-- [核心] 等待 EAP 输入目标 Seg；轮询 SEG_REG_IN，当前实现不设超时。
function Wait_Seg(num)
    local seg
    repeat
        seg = GetHoldRegs(id, SEG_REG_IN, 4, 'F64')
        if seg == nil or seg[1] ~= num then
            Wait(CFG.wait_seg_poll)
        end
    until seg ~= nil and seg[1] == num
    print('[Seg等待] EAP->机械臂，寄存器=' .. tostring(SEG_REG_IN) .. '，期望=' .. tostring(num) .. ' 已收到')
end

-- ============================================================================
-- 10. [核心] 全局会话号与连接句柄（供 src0.lua 引用）
-- ============================================================================
-- id     : 本臂 Modbus 连接句柄（PLC_Connet 建立）
-- id_r3  : R3  Modbus 连接句柄（Connect_R3 建立，仅 R1/R2）
-- cam_socket: 本臂相机 socket（Open_Camera 建立，仅 R1/R2）

-- ============================================================================
-- 上料臂运行时。src0 只保留运动和 Main。
-- ============================================================================
ARM_NAME = 'R2'
COIL_DONE = COIL_R2_GRABBED
TEMPLATE_VERSION = '2026-08-05-3arm-r2-monitor'
STATION_NAME = '上料臂R2'
EXPECTED_PROGRAM_NO = 2
TEMPLATE_PRODUCTION_ENABLED = true
PRODUCTION_FLOW_IMPLEMENTED = true
LOG_LEVEL = 'INFO'
CHECK_REACHABLE = true
EXPECTED_CFG_VERSION = 'v21-2026-11-19'

-- 可视化监控：监控专用保持寄存器（勿占用 EAP/旋转/程序号等已用地址）
-- 4100=动作码(1xx~5xx)  4101=异常码(8xx/9xx，0=无异常)
HREG_ACTION = 4100
HREG_FAULT = 4101
STAGE_ACTION = {
    ['配置校验'] = 100,
    ['连接本臂'] = 101,
    ['PLC连接'] = 101,
    ['连接相机'] = 102,
    ['连接协同方'] = 103,
    ['安全回原'] = 104,
    ['输出复位'] = 105,
    ['入组同步'] = 106,
    ['重启对臂'] = 108,
    ['程序号校验'] = 110,
    ['初始化握手'] = 112,
    ['等待周期启动'] = 180,
    ['等待动子'] = 181,
    ['周期完成'] = 187,
    ['去拍照点'] = 200,
    ['等待R3拍照触发'] = 201,
    ['拍照'] = 202,
    ['抓取物料'] = 204,
    ['等待继续'] = 220,
    ['通知R3抓完'] = 220,
    ['等待R3继续'] = 221,
    ['等待托举继续'] = 221,
    ['等待R3就绪'] = 223,
    ['等待托举就绪'] = 223,
    ['取放托盘'] = 230,
    ['抛空托盘'] = 231,
    ['空托盘'] = 241,
    ['周期作废'] = 300
}
STAGE_FAULT = {
    ['故障停机'] = 939
}
ERROR_TYPE_FAULT = {
    CONFIG_ERROR = 905,
    CONFIG_LOCK = 909,
    API_MISSING = 911,
    API_ERROR = 912,
    PLC_CONNECT_ERROR = 913,
    R3_CONNECT_ERROR = 914,
    PLC_WRITE_ERROR = 915,
    PLC_READ_ERROR = 916,
    PROGRAM_MISMATCH = 917,
    RUNTIME_ERROR = 919,
    SEG_CONFIG_ERROR = 920,
    PHOTO_POINT_ERROR = 921
}

SEG_READY = 0
SEG_INITIALIZED = 1
SEG_CYCLE_START = 2
SEG_MOVER_READY = 3
SEG_PROCESS_DONE = 4
SEG_DOWNSTREAM_DONE = 5
SEG_PROGRAM_CONFIRMED = 1000
VALID_SEG_VALUES = {
    [SEG_READY] = true,
    [SEG_INITIALIZED] = true,
    [SEG_CYCLE_START] = true,
    [SEG_MOVER_READY] = true,
    [SEG_PROCESS_DONE] = true,
    [SEG_DOWNSTREAM_DONE] = true,
    [SEG_PROGRAM_CONFIRMED] = true
}
HREG_MOVER_QUALITY = 3703
HREG_PROG_NUM = 3095
HREG_SET_PROG = 3751
HOME_ACCEL = 25
HOME_SPEED = 50
HOME_CP = 100
RUN_ACCEL = 40
RUN_SPEED = 75
RUN_CP = 100
HOME_Y_LIMIT = -250 -- y 小于此值：先抬到 P6.z 再回 Home
HOME_X_LIMIT = 200 -- 其余区域 x 小于此值：经 P10 回 Home
TRAY_LIFT_ACCEL = 15 -- 吸住料盘后抬到 P10 高度
TRAY_LIFT_SPEED = 65
TRAY_LIFT_CP = 100
TRAY_BACK_ACCEL = 60 -- 抛盘后从 P12 返回
TRAY_BACK_SPEED = 100
PHOTO_POS_TOL = 1.0
PHOTO_POINT_STRICT = true
PHOTO_DRAIN = true
GRAB_DEDUP_TOL = 5.0
LOG_LEVEL_RANK = {DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40}
Runtime = {stage = '启动', cycle_no = 0,
    action_code = nil,
    fault_code = 0,
    fault_source = nil
}
Grabbed = {}
CYCLE_ABORT = {addr = COIL_JOIN_ACK, val = 1}

function Log(level, message, ...)
    local level_rank = LOG_LEVEL_RANK[level] or LOG_LEVEL_RANK.INFO
    local configured_rank = LOG_LEVEL_RANK[LOG_LEVEL] or LOG_LEVEL_RANK.INFO
    if level_rank < configured_rank then
        return
    end
    local format_ok, formatted = pcall(string.format, message, ...)
    if not format_ok then
        formatted = tostring(message) .. ' [日志格式失败: ' .. tostring(formatted) .. ']'
    end
    print(string.format('[%s][%s站][%s][周期=%d] %s', level, STATION_NAME, Runtime.stage, Runtime.cycle_no, formatted))
end


local function Write_Monitor_Reg(addr, code, label)
    if type(code) ~= 'number' or code ~= code then
        return false
    end
    code = math.floor(code)
    if id == nil or type(SetHoldRegs) ~= 'function' then
        return false
    end
    local ok, rc = pcall(SetHoldRegs, id, addr, 1, {code}, 'U16')
    if not ok then
        print(string.format('[监控] 写寄存器失败 addr=%s label=%s code=%s err=%s', tostring(addr), tostring(label), tostring(code), tostring(rc)))
        return false
    end
    if rc ~= nil and rc ~= 0 and rc ~= true then
        print(string.format('[监控] 写寄存器返回异常 addr=%s label=%s code=%s rc=%s', tostring(addr), tostring(label), tostring(code), tostring(rc)))
        return false
    end
    return true
end

function Report_Action(code, label)
    if type(code) ~= 'number' or code ~= code then
        return false
    end
    code = math.floor(code)
    if Runtime.action_code == code then
        return true
    end
    -- 必须先写寄存器成功再缓存，否则 id 未就绪时会把内存标成已写入，后续永远不再清 4101
    if not Write_Monitor_Reg(HREG_ACTION, code, label or 'action') then
        return false
    end
    Runtime.action_code = code
    return true
end

function Report_Fault(code, label, source)
    if type(code) ~= 'number' or code ~= code then
        return false
    end
    code = math.floor(code)
    source = source or 'process'
    if Runtime.fault_code == code and (code == 0 or Runtime.fault_source == source) then
        return true
    end
    if not Write_Monitor_Reg(HREG_FAULT, code, label or 'fault') then
        return false
    end
    Runtime.fault_code = code
    Runtime.fault_source = (code == 0) and nil or source
    return true
end

-- 本臂 Modbus 连上后强制刷一次监控寄存器（清掉上次停机残留的 4101）
function Init_Monitor_Regs(action_code)
    Runtime.action_code = nil
    Runtime.fault_code = nil
    Runtime.fault_source = nil
    Clear_Fault('本臂已连接')
    Report_Action(action_code or 101, 'PLC连接')
end

function Clear_Fault(label)
    return Report_Fault(0, label or 'clear', 'process')
end

function Report_Status(code, label)
    if type(code) ~= 'number' then
        return false
    end
    if code >= 800 then
        return Report_Fault(code, label, 'process')
    end
    return Report_Action(code, label)
end


function Set_Stage(stage)
    Runtime.stage = stage
    local action = STAGE_ACTION[stage]
    if action ~= nil then
        Report_Action(action, stage)
    end
    local fault = STAGE_FAULT[stage]
    if fault ~= nil then
        Report_Fault(fault, stage, 'process')
    elseif stage == '启动' or stage == '配置校验' or stage == '初始化握手'
        or stage == '等待周期启动' or stage == '周期完成' or stage == '入组同步' then
        -- 清异常码，避免 4101 残留导致平台一直优先显示旧故障(如939)
        Clear_Fault(stage)
    end
end

function Already_Grabbed(item)
    local x, y = item.x or 0, item.y or 0
    for _, g in ipairs(Grabbed) do
        if math.abs(g.x - x) <= GRAB_DEDUP_TOL and math.abs(g.y - y) <= GRAB_DEDUP_TOL then
            return true
        end
    end
    return false
end

function Mark_Grabbed(item)
    table.insert(Grabbed, {x = item.x or 0, y = item.y or 0})
end

function Clear_Grabbed()
    Grabbed = {}
end

function Check_CFG_Version()
    if CFG.cfg_version ~= EXPECTED_CFG_VERSION then
        Log(
            'WARN',
            'CFG 版本不一致 global=%s src期望=%s，请把新版 global.lua 一起下发',
            tostring(CFG.cfg_version),
            EXPECTED_CFG_VERSION
        )
    end
end

function Is_Finite_Number(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

function Raise_Error(error_type, message)
    local fault = ERROR_TYPE_FAULT[error_type] or 939
    Report_Fault(fault, tostring(error_type), 'process')
    error(string.format('[%s] %s', error_type, message), 0)
end

function Call_Or_Error(action_name, fn, ...)
    if type(fn) ~= 'function' then
        Raise_Error('API_MISSING', action_name .. '不可用')
    end
    local results = table.pack(pcall(fn, ...))
    if not results[1] then
        Raise_Error('API_ERROR', string.format('%s失败: %s', action_name, tostring(results[2])))
    end
    return table.unpack(results, 2, results.n)
end

function Require_Number_In_Range(name, value, minimum, maximum)
    if not Is_Finite_Number(value) or value < minimum or value > maximum then
        Raise_Error('CONFIG_ERROR', string.format('%s必须是%s到%s之间的有限数值，当前值=%s', name, minimum, maximum, tostring(value)))
    end
end

function Require_Integer_In_Range(name, value, minimum, maximum)
    Require_Number_In_Range(name, value, minimum, maximum)
    if math.floor(value) ~= value then
        Raise_Error('CONFIG_ERROR', name .. '必须是整数，当前值=' .. tostring(value))
    end
end

function Require_Connection_Id()
    if id == nil then
        Raise_Error('PLC_CONNECT_ERROR', '本臂连接 id 为空')
    end
    if id_r3 == nil then
        Raise_Error('R3_CONNECT_ERROR', 'R3 连接 id_r3 为空')
    end
end

function Require_Seg_Value(seg_value)
    if not VALID_SEG_VALUES[seg_value] then
        Raise_Error('SEG_CONFIG_ERROR', '不允许的 Seg 值=' .. tostring(seg_value))
    end
end

function Require_Home_Point()
    if type(P1) ~= 'table' or type(P1.pose) ~= 'table' then
        Raise_Error('CONFIG_ERROR', 'P1/Home 点位无效')
    end
    for index = 1, 6 do
        if not Is_Finite_Number(P1.pose[index]) then
            Raise_Error('CONFIG_ERROR', string.format('P1.pose[%d]无效', index))
        end
    end
end

function Validate_Config()
    Set_Stage('配置校验')
    Validate_CFG()
    Check_CFG_Version()
    Require_Integer_In_Range('EXPECTED_PROGRAM_NO', EXPECTED_PROGRAM_NO, 0, 9999)
    Require_Number_In_Range('RUN_ACCEL', RUN_ACCEL, 1, 100)
    Require_Number_In_Range('RUN_SPEED', RUN_SPEED, 1, 100)
    Require_Home_Point()
    Log('INFO', '基础配置校验通过')
end

function Validate_Write_Result(action_name, result)
    if result == nil or result == 0 or result == true then
        return
    end
    Raise_Error('PLC_WRITE_ERROR', string.format('%s返回失败状态: %s', action_name, tostring(result)))
end

function Extract_Register_Table(action_name, first_result, second_result)
    if type(first_result) == 'table' then
        return first_result
    end
    if (first_result == 0 or first_result == true) and type(second_result) == 'table' then
        return second_result
    end
    Raise_Error('PLC_READ_ERROR', string.format('%s返回格式无效', action_name))
end

function Traceback_Handler(runtime_error)
    local error_text = tostring(runtime_error)
    if type(debug) == 'table' and type(debug.traceback) == 'function' then
        local traceback_ok, traceback = pcall(debug.traceback, error_text, 2)
        if traceback_ok then
            return traceback
        end
    end
    return error_text
end

function Move_Opts(user, tool, a, v, cp)
    return {user = user or 0, tool = tool or 0, a = a or RUN_ACCEL, v = v or RUN_SPEED, cp = cp or RUN_CP}
end

function Pose_With_Z(base, dz)
    local pose = base.pose
    return {pose = {pose[1], pose[2], pose[3] + dz, pose[4], pose[5], pose[6]}}
end

function Keep_Pose(cur, x, y, z)
    return {pose = {x, y, z, cur.pose[4], cur.pose[5], cur.pose[6]}}
end

function Home_Opts()
    return Move_Opts(0, 0, HOME_ACCEL, HOME_SPEED, HOME_CP)
end

function Run_Opts()
    return Move_Opts(0, 0)
end

function Pick_Opts()
    return Move_Opts(1, 0, CFG.grab_approach_accel, CFG.grab_approach_speed, CFG.grab_cp)
end

function Place_Opts()
    return Move_Opts(0, 0, CFG.place_approach_accel, CFG.place_approach_speed, CFG.place_cp)
end

function Overwrite_Pose(base, item)
    base.pose[1] = item.x
    base.pose[2] = item.y
    base.pose[3] = item.z
end

function Merge_Opts(opts, override)
    if override == nil then
        return opts
    end
    local merged = {}
    for k, v in pairs(opts or {}) do
        merged[k] = v
    end
    for k, v in pairs(override) do
        merged[k] = v
    end
    return merged
end

function Safe_MovJ(point, opts, override)
    Set_Stage('MovJ')
    local merged = Merge_Opts(opts, override)
    Call_Or_Error('MovJ', MovJ, point, merged or Move_Opts())
end

function Safe_MovL(point, opts, override)
    Set_Stage('MovL')
    local merged = Merge_Opts(opts, override)
    Call_Or_Error('MovL', MovL, point, merged or Move_Opts())
end

function Safe_RelMovLUser(vec)
    Set_Stage('相对移动')
    Call_Or_Error('RelMovLUser', RelMovLUser, vec)
end

function Safe_Set_Speed(speed)
    Require_Number_In_Range('SpeedFactor', speed, 1, 100)
    Call_Or_Error('SpeedFactor', SpeedFactor, speed)
end

function Safe_Slow_Lift(dz)
    local cur = GetPose(1, 0)
    Safe_MovL(
        {pose = {cur.pose[1], cur.pose[2], cur.pose[3] + dz, cur.pose[4], cur.pose[5], cur.pose[6]}},
        Move_Opts(1, 0, CFG.grab_lift_accel, CFG.grab_lift_speed)
    )
end

function Safe_Out_Seg(seg_value)
    Require_Seg_Value(seg_value)
    Call_Or_Error('Out_Seg', Out_Seg, seg_value)
end

function Safe_Wait_Seg(seg_value)
    Require_Seg_Value(seg_value)
    Call_Or_Error('Wait_Seg', Wait_Seg, seg_value)
end

function Seg_Close()
    Safe_Out_Seg(SEG_PROCESS_DONE)
    Safe_Wait_Seg(SEG_DOWNSTREAM_DONE)
    Safe_Out_Seg(SEG_READY)
    Safe_Wait_Seg(SEG_CYCLE_START)
end

function Read_Mover_Quality()
    local first, second = Call_Or_Error('GetHoldRegs', GetHoldRegs, id, HREG_MOVER_QUALITY, 1)
    local tbl = Extract_Register_Table('读取动子质量', first, second)
    return tbl and tbl[1]
end

function Wait_Mover_OK(note)
    while true do
        Safe_Out_Seg(SEG_CYCLE_START)
        Safe_Wait_Seg(SEG_MOVER_READY)
        if not CFG.quality_check_enabled then
            return
        end
        local qv = Read_Mover_Quality()
        if qv == 10 then
            return
        end
        Log('WARN', note, tostring(qv))
        Seg_Close()
    end
end

function At_Photo_Point()
    local cur = GetPose(1, 0)
    local dev =
        math.max(
        math.abs(cur.pose[1] - P3.pose[1]),
        math.abs(cur.pose[2] - P3.pose[2]),
        math.abs(cur.pose[3] - P3.pose[3])
    )
    return dev <= PHOTO_POS_TOL, dev, cur
end

function Drain_Camera_Buffer()
    if not PHOTO_DRAIN or type(TCPRead) ~= 'function' or cam_socket == nil then
        return
    end
    local dropped = 0
    for _ = 1, 10 do
        local err, data = TCPRead(cam_socket, 0.05, 'string')
        if err ~= 0 or data == nil or data == '' then
            break
        end
        dropped = dropped + 1
    end
    if dropped > 0 then
        Log('WARN', '触发相机前丢弃过期帧 %d', dropped)
    end
end

local function Move_To_Photo()
    Safe_MovJ(P2, Move_Opts(0, 0))
    Safe_MovL(P3, Move_Opts(1, 0, RUN_ACCEL, RUN_SPEED, 0))
end

function Ensure_At_Photo_Point()
    for attempt = 1, 2 do
        local ok, dev = At_Photo_Point()
        if ok then
            return true
        end
        Log(PHOTO_POINT_STRICT and 'ERROR' or 'WARN', '不在拍照点，偏差=%.2fmm，第%d次重走', dev, attempt)
        Move_To_Photo()
    end
    return false
end

function Go_Photo_Point()
    if At_Photo_Point() then
        return
    end
    Set_Stage('去拍照点')
    Move_To_Photo()
end

function Safe_Take_Photo()
    if not Ensure_At_Photo_Point() then
        local _, _, cur = At_Photo_Point()
        if PHOTO_POINT_STRICT then
            Raise_Error('PHOTO_POINT_ERROR', '两次走位后仍未到拍照点，拒绝拍照')
        end
        Log('ERROR', '仍未到拍照点，调试模式继续 x=%.2f', cur.pose[1])
    end
    Set_Stage('拍照')
    Drain_Camera_Buffer()
    Wait(CFG.photo_settle)
    return Call_Or_Error('Take_Photo_Checked', Take_Photo_Checked)
end

function Wait_For_R3(addr, expect, label)
    Set_Stage(label)
    Log('INFO', '等待 R3 线圈 %s == %s', tostring(addr), tostring(expect))
    Wait_Coil(id_r3, addr, expect, CYCLE_ABORT)
end

function Safe_Reset_Elapsed_Time()
    Call_Or_Error('ResetElapsedTime', ResetElapsedTime)
end

function Safe_Elapsed_Time()
    local elapsed = Call_Or_Error('ElapsedTime', ElapsedTime)
    if not Is_Finite_Number(elapsed) then
        Raise_Error('RUNTIME_ERROR', 'ElapsedTime 返回无效值')
    end
    return elapsed
end

function Check_Program_Number()
    Set_Stage('程序号校验')
    local first, second = Call_Or_Error('GetHoldRegs', GetHoldRegs, id, HREG_PROG_NUM, 2, 'U32')
    local program_values = Extract_Register_Table('读取PLC程序号', first, second)
    local plc_program_no = program_values[1]
    local write_result = Call_Or_Error('SetHoldRegs', SetHoldRegs, id, HREG_SET_PROG, 4, {EXPECTED_PROGRAM_NO}, 'F64')
    Validate_Write_Result('SetHoldRegs', write_result)
    if plc_program_no ~= EXPECTED_PROGRAM_NO then
        Raise_Error(
            'PROGRAM_MISMATCH',
            string.format('程序号不一致：模板=%s，PLC=%s', EXPECTED_PROGRAM_NO, tostring(plc_program_no))
        )
    end
end

function Require_Production_Ready()
    if not TEMPLATE_PRODUCTION_ENABLED or not PRODUCTION_FLOW_IMPLEMENTED then
        Raise_Error('CONFIG_LOCK', '投产开关或真实流程未打开')
    end
end

function Grab_Reachable(point, opts)
    if not CHECK_REACHABLE or type(CheckMovL) ~= 'function' then
        return true
    end
    local code = CheckMovL(point, opts)
    if code == 0 then
        return true
    end
    Log('WARN', '抓取点不可达(CheckMovL code=%s)，跳过', tostring(code))
    Report_Fault(811, '抓取点不可达', 'process')
    return false
end

function Attain_Vacuum(di_addr)
    local desc = 0
    while true do
        Wait(CFG.vacuum_settle)
        if DI(di_addr) == 1 then
            return true
        end
        if desc >= CFG.vacuum_max_dz then
            Report_Fault(813, '真空不到位', 'process')
            return false
        end
        local step = CFG.vacuum_step_dz
        if desc + step > CFG.vacuum_max_dz then
            step = CFG.vacuum_max_dz - desc
        end
        if CHECK_REACHABLE and type(CheckMovL) == 'function' then
            local cur = GetPose(1, 0)
            local target = {
                pose = {cur.pose[1], cur.pose[2], cur.pose[3] - step, cur.pose[4], cur.pose[5], cur.pose[6]}
            }
            if CheckMovL(target, Move_Opts(1, 0)) ~= 0 then
                Log('WARN', '真空补偿下降目标不可达，停止下降')
                return false
            end
        end
        Safe_RelMovLUser({0, 0, -step, 0, 0, 0})
        desc = desc + step
    end
end

function Scan_Frame(photo)
    local tray, mat = false, false
    for _, item in ipairs(photo.items or {}) do
        if item.mat_type == 10 then
            tray = true
        elseif item.mat_type == 1 then
            mat = true
        end
    end
    return tray, mat
end

function Extract_Tray(photo)
    for _, item in ipairs(photo.items or {}) do
        if item.mat_type == 10 then
            return item
        end
    end
    return nil
end

function Signal_Grabbed_All()
    Set_Stage('通知R3抓完')
    Log('INFO', '%s 已抓完，置线圈 %s=1', ARM_NAME, tostring(COIL_DONE))
    Set_Coil(id_r3, COIL_DONE, 1)
end

function Grab_Items(photo)
    local got_any = false
    for _, item in ipairs(photo.items or {}) do
        if item.mat_type == 1 then
            if not Already_Grabbed(item) and Grab_One_And_Place(item) then
                Mark_Grabbed(item)
                got_any = true
            end
        end
    end
    if not got_any then
        Log('WARN', '一抓一: 本帧无可用物料，按本盘结束处理')
    end
end

function Finish_Tray(photo, empty)
    if empty then
        Set_Stage('空托盘')
        Set_Coil(id_r3, COIL_R3_SWITCH_FACE, 1)
    end
    Signal_Grabbed_All()
    local tray_item = nil
    if not empty then
        tray_item = Extract_Tray(photo)
    end
    After_Grabbed_All(tray_item)
    Clear_Grabbed()
end

function Production_Cycle()
    if not PRODUCTION_FLOW_IMPLEMENTED then
        Raise_Error('CONFIG_LOCK', 'Production_Cycle 禁止在真实流程未完成时运行')
    end
    Set_Coil(id_r3, COIL_DONE, 0)
    Set_Coil(id_r3, COIL_R2_DUMPED, 0)
    Wait_Coil(id_r3, COIL_JOIN_ACK, 0, CYCLE_ABORT)
    Go_Photo_Point()
    Wait_For_R3(COIL_R3_DETECT, 1, '等待R3拍照触发')
    local photo = Safe_Take_Photo()
    local code = photo.code
    if code == 310 then
        local tray, mat = Scan_Frame(photo)
        Grab_Items(photo)
        if tray and not mat then
            Log('WARN', '本帧已无物料且带空盘标记，本盘结束')
        end
        code = 120
    end
    if code == 120 then
        Finish_Tray(photo, false)
    elseif code == 130 then
        Finish_Tray(photo, true)
    else
        Log('ERROR', '相机报文无法识别: %s', tostring(code))
        Pause()
    end
end
