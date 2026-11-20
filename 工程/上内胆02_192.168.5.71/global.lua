-- global.lua  上料臂 R2 (192.168.5.71)
-- 通信、互锁、相机、IO、配置，以及 src0 以外的流程工具。
-- 本文件只定义变量和函数，顶层不运动、不写现场 IO。

-- ============================================================================
-- 网络（三臂仅 IP / 相机端口不同）
-- ============================================================================
local g_self_ip = '192.168.5.71'
local g_self_port = 502
local g_slave_id = 1
local g_r3_ip = '192.168.5.92'
local g_peer_ip = '192.168.5.73' -- 对臂 R1
local g_cam_ip = '192.168.5.9'
local g_cam_port = 1004
local g_rot_ip = '192.168.5.17' -- 旋转机构

local SEG_REG_OUT = 3811 -- 机械臂 -> EAP
local SEG_REG_IN = 3911 -- EAP -> 机械臂

-- ============================================================================
-- 现场配置
-- ============================================================================
CFG = {
    cfg_version = 'v18-2026-11-17', -- 与本文件 EXPECTED_CFG_VERSION 比对；两边都在 global.lua，只改 src0 发现不了旧配置
    do_suck_1 = 1, -- 吸盘1吸气 DO
    do_blow_1 = 2, -- 吸盘1吹气 DO
    do_suck_2 = 3, -- 吸盘2吸气 DO
    do_blow_2 = 4, -- 吸盘2吹气 DO
    do_suck = 1, -- 单盘吸气，与吸盘1同一路
    do_blow = 2, -- 单盘吹气，与吹气1同一路
    do_varpitch = 6, -- 变距 DO
    varpitch_close = 0, -- 窄距电平，起机时写入
    di_vacuum_1 = 5, -- 吸盘1真空反馈 DI，1=吸住
    vacuum_step_dz = 2.0, -- 真空不到位时每次再下降(mm)
    vacuum_max_dz = 6.1, -- 真空补偿最多再下降(mm)
    vacuum_settle = 100, -- 读真空 DI 前的等待(ms)
    cup1_place_rot_comp = 0.0, -- 吸盘1放料角补偿(度)，加在相机角上再写入 5678
    interlock_enabled = true, -- true 时目标越出安全区才和另一臂互锁
    interlock_axis = 'xy', -- 参与判定的轴：x / y / xy
    interlock_x_min = -999, -- X 安全下限(mm)，落在区间内不申请互锁
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
    wait_coil_poll = 20, -- 线圈轮询间隔(ms)，src1 也按这个间隔看 5666
    wait_rot_poll = 200, -- 旋转机构写后间隔/状态轮询(ms)
    wait_seg_poll = 40, -- EAP Seg 轮询间隔(ms)
    wait_conn_retry = 500, -- Modbus 或相机连接失败后的重试间隔(ms)
    wait_grab_lock = 20, -- 抓取互锁轮询间隔(ms)
    wait_pick_settle = 200, -- 开吸气后、判真空前的等待(ms)
    place_release_settle = 300, -- 放料开吹气后、抬起前的等待(ms)
    tray_release_settle = 100, -- 抛盘开吹气后、抬起前的等待(ms)
    quality_check_enabled = false, -- true 时保持寄存器 3703==10 才下降放料
    xshift_enabled = false, -- true 时不可达料走 R3 平移闭环
    rot_holdreg_type = 'F32' -- 角度寄存器 5678 的类型，F32 占用 5678 和 5679
}

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
    local ints = {
        {'CFG.do_blow', CFG.do_blow, 0, 255},
        {'CFG.do_suck', CFG.do_suck, 0, 255},
        {'CFG.do_suck_1', CFG.do_suck_1, 0, 255},
        {'CFG.do_blow_1', CFG.do_blow_1, 0, 255},
        {'CFG.do_suck_2', CFG.do_suck_2, 0, 255},
        {'CFG.do_blow_2', CFG.do_blow_2, 0, 255},
        {'CFG.do_varpitch', CFG.do_varpitch, 0, 255},
        {'CFG.di_vacuum_1', CFG.di_vacuum_1, 0, 255}
    }
    local nums = {
        {'CFG.grab_above_dz', CFG.grab_above_dz, 0, 200},
        {'CFG.lift_dz', CFG.lift_dz, 0, 500},
        {'CFG.grab_approach_speed', CFG.grab_approach_speed, 1, 100},
        {'CFG.grab_approach_accel', CFG.grab_approach_accel, 1, 100},
        {'CFG.grab_lift_speed', CFG.grab_lift_speed, 1, 100},
        {'CFG.grab_lift_accel', CFG.grab_lift_accel, 1, 100},
        {'CFG.place_approach_speed', CFG.place_approach_speed, 1, 100},
        {'CFG.place_approach_accel', CFG.place_approach_accel, 1, 100},
        {'CFG.grab_cp', CFG.grab_cp, 0, 100},
        {'CFG.place_cp', CFG.place_cp, 0, 100},
        {'CFG.cam_timeout', CFG.cam_timeout, 0.1, 60},
        {'CFG.cam_retry_wait', CFG.cam_retry_wait, 0, 60000},
        {'CFG.photo_settle', CFG.photo_settle, 0, 5000},
        {'CFG.cam_response_wait', CFG.cam_response_wait, 0, 60000},
        {'CFG.wait_io_settle', CFG.wait_io_settle, 10, 5000},
        {'CFG.wait_coil_poll', CFG.wait_coil_poll, 10, 5000},
        {'CFG.wait_rot_poll', CFG.wait_rot_poll, 50, 5000},
        {'CFG.wait_seg_poll', CFG.wait_seg_poll, 10, 5000},
        {'CFG.wait_conn_retry', CFG.wait_conn_retry, 100, 30000},
        {'CFG.wait_grab_lock', CFG.wait_grab_lock, 10, 5000},
        {'CFG.wait_pick_settle', CFG.wait_pick_settle, 10, 5000},
        {'CFG.place_release_settle', CFG.place_release_settle, 10, 5000},
        {'CFG.tray_release_settle', CFG.tray_release_settle, 10, 5000},
        {'CFG.varpitch_close', CFG.varpitch_close, 0, 1},
        {'CFG.cup1_place_rot_comp', CFG.cup1_place_rot_comp, -180, 180},
        {'CFG.vacuum_step_dz', CFG.vacuum_step_dz, 0.1, 100},
        {'CFG.vacuum_max_dz', CFG.vacuum_max_dz, 0.1, 200},
        {'CFG.interlock_x_min', CFG.interlock_x_min, -100000, 100000},
        {'CFG.interlock_x_max', CFG.interlock_x_max, -100000, 100000},
        {'CFG.interlock_y_min', CFG.interlock_y_min, -100000, 100000},
        {'CFG.interlock_y_max', CFG.interlock_y_max, -100000, 100000}
    }
    for _, it in ipairs(ints) do
        chk_int(it[1], it[2], it[3], it[4])
    end
    for _, it in ipairs(nums) do
        chk_num(it[1], it[2], it[3], it[4])
    end
    if type(CFG.cam_start_cmd) ~= 'string' or CFG.cam_start_cmd == '' then
        error('[CONFIG_ERROR] CFG.cam_start_cmd 不能为空', 0)
    end
    if type(CFG.quality_check_enabled) ~= 'boolean' then
        error('[CONFIG_ERROR] CFG.quality_check_enabled 必须是布尔值', 0)
    end
    if
        type(CFG.rot_holdreg_type) ~= 'string' or
            not (CFG.rot_holdreg_type == 'U16' or CFG.rot_holdreg_type == 'U32' or CFG.rot_holdreg_type == 'F32' or
                CFG.rot_holdreg_type == 'F64')
     then
        error('[CONFIG_ERROR] CFG.rot_holdreg_type 无效=' .. tostring(CFG.rot_holdreg_type), 0)
    end
    if type(CFG.interlock_enabled) ~= 'boolean' then
        error('[CONFIG_ERROR] CFG.interlock_enabled 必须是布尔值', 0)
    end
    if type(CFG.xshift_enabled) ~= 'boolean' then
        error('[CONFIG_ERROR] CFG.xshift_enabled 必须是布尔值', 0)
    end
    if
        type(CFG.interlock_axis) ~= 'string' or
            not (CFG.interlock_axis == 'x' or CFG.interlock_axis == 'y' or CFG.interlock_axis == 'xy')
     then
        error('[CONFIG_ERROR] CFG.interlock_axis 无效=' .. tostring(CFG.interlock_axis) .. ' (应为 x / y / xy)', 0)
    end
    if CFG.interlock_x_min > CFG.interlock_x_max then
        error('[CONFIG_ERROR] CFG.interlock_x_min 不能大于 interlock_x_max', 0)
    end
    if CFG.interlock_y_min > CFG.interlock_y_max then
        error('[CONFIG_ERROR] CFG.interlock_y_min 不能大于 interlock_y_max', 0)
    end
    print('[校验] CFG 配置校验通过')
end

-- ============================================================================
-- 线圈 / 旋转寄存器（位于 R3，除旋转寄存器在本臂）
-- ============================================================================
COIL_R1_GRABBED = 2001 -- R1 已抓完
COIL_R2_GRABBED = 2010 -- R2 已抓完
COIL_R2_DUMPED = 2020 -- R2 抛空完成
COIL_R3_DETECT = 2100 -- R3 允许拍照
COIL_R3_CONTINUE = 2200 -- R3 通知继续
COIL_R3_READY = 2300 -- R3 二次抬升到位
COIL_R3_SWITCH_FACE = 2400 -- 请求 R3 换面
COIL_R3_XSHIFT_REQ = 2401 -- 请求托盘向 X 负方向平移
COIL_R3_XSHIFT_BACK = 2402 -- 请求托盘移回
COIL_GRAB_BUSY = 2030
COIL_GRAB_REQ_R1 = 2031
COIL_GRAB_REQ_R2 = 2032
COIL_GRAB_TURN = 2033 -- 0=优先 R1, 1=优先 R2
COIL_JOIN_REQ_R1 = 2040
COIL_JOIN_REQ_R2 = 2041
COIL_JOIN_ACK = 2042 -- 入组应答，兼周期作废

-- 每个线圈只有一个写者。重启只清本臂，避免抹掉另两臂在途信号。
OWN_COILS = {
    R1 = {COIL_R1_GRABBED, COIL_GRAB_REQ_R1, COIL_JOIN_REQ_R1},
    R2 = {COIL_R2_GRABBED, COIL_R2_DUMPED, COIL_GRAB_REQ_R2, COIL_JOIN_REQ_R2},
    R3 = {COIL_R3_DETECT, COIL_R3_CONTINUE, COIL_R3_READY, COIL_JOIN_ACK, COIL_GRAB_BUSY, COIL_GRAB_TURN}
}

HREG_ROT_ANGLE = 5678
COIL_ROT_DONE = 4444
COIL_ROT_REQ = 5666

-- ============================================================================
-- 本臂参数与运行时
-- ============================================================================
TEMPLATE_VERSION = '2026-08-05-3arm-r2-monitor'
STATION_NAME = '上料臂R2'
EXPECTED_PROGRAM_NO = 2
TEMPLATE_PRODUCTION_ENABLED = true
PRODUCTION_FLOW_IMPLEMENTED = true
LOG_LEVEL = 'INFO'
CHECK_REACHABLE = true -- 仅 CheckMovL==0 视为可达
EXPECTED_CFG_VERSION = 'v18-2026-11-17'

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
RUN_ACCEL = 50
RUN_SPEED = 100
RUN_CP = 100
HOME_Y_LIMIT = -250 -- y 小于此值：取放料区，先抬到 P6.z
HOME_X_LIMIT = 200 -- 其余区域 x 小于此值：经 P10 回原
TRAY_LIFT_ACCEL = 15
TRAY_LIFT_SPEED = 65
TRAY_LIFT_CP = 100
TRAY_BACK_ACCEL = 60
TRAY_BACK_SPEED = 100

PHOTO_POS_TOL = 1.0
PHOTO_POINT_STRICT = true -- false 时拍照点不到位只告警
PHOTO_DRAIN = true
GRAB_DEDUP_TOL = 5.0 -- mm，大于视觉抖动、小于料距

LOG_LEVEL_RANK = {DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40}
Runtime = {stage = '启动', cycle_no = 0, xshift_pending = false,
    action_code = nil,
    fault_code = 0,
    fault_source = nil
}
Grabbed = {}

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
            '[CFG版本不一致] global.lua 版本=%s，src0 期望=%s —— 现场调过的速度/互锁/真空值可能都没生效，请把新版 global.lua 一起上传到控制器！',
            tostring(CFG.cfg_version),
            EXPECTED_CFG_VERSION
        )
    else
        Log('INFO', 'CFG 版本一致(%s)', EXPECTED_CFG_VERSION)
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
        Raise_Error('CONFIG_ERROR', 'P1/Home 点位无效，请完成示教后重启程序')
    end
    for index = 1, 6 do
        if not Is_Finite_Number(P1.pose[index]) then
            Raise_Error(
                'CONFIG_ERROR',
                string.format('P1/Home pose[%d]必须是有限数值，当前值=%s', index, tostring(P1.pose[index]))
            )
        end
    end
end

function Validate_Config()
    Set_Stage('配置校验')
    Log('INFO', '开始校验基础配置')
    Validate_CFG()
    Check_CFG_Version()
    if type(TEMPLATE_VERSION) ~= 'string' or TEMPLATE_VERSION == '' then
        Raise_Error('CONFIG_ERROR', 'TEMPLATE_VERSION 不能为空')
    end
    if type(STATION_NAME) ~= 'string' or STATION_NAME == '' then
        Raise_Error('CONFIG_ERROR', 'STATION_NAME 不能为空')
    end
    if LOG_LEVEL_RANK[LOG_LEVEL] == nil then
        Raise_Error('CONFIG_ERROR', 'LOG_LEVEL 无效=' .. tostring(LOG_LEVEL))
    end
    if type(TEMPLATE_PRODUCTION_ENABLED) ~= 'boolean' then
        Raise_Error('CONFIG_ERROR', 'TEMPLATE_PRODUCTION_ENABLED 必须是 boolean')
    end
    if type(PRODUCTION_FLOW_IMPLEMENTED) ~= 'boolean' then
        Raise_Error('CONFIG_ERROR', 'PRODUCTION_FLOW_IMPLEMENTED 必须是 boolean')
    end
    Require_Integer_In_Range('EXPECTED_PROGRAM_NO', EXPECTED_PROGRAM_NO, 0, 9999)
    Require_Number_In_Range('HOME_ACCEL', HOME_ACCEL, 1, 100)
    Require_Number_In_Range('HOME_SPEED', HOME_SPEED, 1, 100)
    Require_Number_In_Range('HOME_CP', HOME_CP, 0, 100)
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
    Raise_Error(
        'PLC_READ_ERROR',
        string.format('%s返回格式无效: first=%s, second=%s', action_name, tostring(first_result), tostring(second_result))
    )
end

function Safe_Set_Speed(speed)
    Require_Number_In_Range('SpeedFactor', speed, 1, 100)
    Log('INFO', '设置全局速度倍率=%s', tostring(speed))
    Call_Or_Error('SpeedFactor', SpeedFactor, speed)
end

function Safe_Out_Seg(seg_value)
    Require_Seg_Value(seg_value)
    Set_Stage('Seg输出')
    Log('INFO', '机械臂->EAP，输出 Seg=%s', tostring(seg_value))
    Call_Or_Error('Out_Seg(' .. tostring(seg_value) .. ')', Out_Seg, seg_value)
end

function Safe_Wait_Seg(seg_value)
    Require_Seg_Value(seg_value)
    Set_Stage('Seg等待')
    Log('INFO', 'EAP->机械臂，等待 Seg=%s', tostring(seg_value))
    Call_Or_Error('Wait_Seg(' .. tostring(seg_value) .. ')', Wait_Seg, seg_value)
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
    return (tbl and tbl[1]) or nil
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
        Log('WARN', '触发相机前清掉缓冲区 %d 帧(过期帧)，已丢弃', dropped)
    end
end

function Wait_For_R3(addr, expect, label)
    Set_Stage(label)
    Log('INFO', '等待 R3 线圈 %s == %s', tostring(addr), tostring(expect))
    Wait_Coil(id_r3, addr, expect, {addr = COIL_JOIN_ACK, val = 1})
end

function Safe_Reset_Elapsed_Time()
    Call_Or_Error('ResetElapsedTime', ResetElapsedTime)
end

function Safe_Elapsed_Time()
    local elapsed = Call_Or_Error('ElapsedTime', ElapsedTime)
    if not Is_Finite_Number(elapsed) then
        Raise_Error('RUNTIME_ERROR', 'ElapsedTime 返回无效值=' .. tostring(elapsed))
    end
    return elapsed
end

function Check_Program_Number()
    Set_Stage('程序号校验')
    Log('INFO', '读取 PLC 程序号，寄存器=%s', HREG_PROG_NUM)
    local first, second = Call_Or_Error('GetHoldRegs', GetHoldRegs, id, HREG_PROG_NUM, 2, 'U32')
    local program_values = Extract_Register_Table('读取PLC程序号', first, second)
    local plc_program_no = program_values[1]
    if not Is_Finite_Number(plc_program_no) or math.floor(plc_program_no) ~= plc_program_no then
        Raise_Error('PLC_READ_ERROR', 'PLC 程序号必须是有限整数，当前值=' .. tostring(plc_program_no))
    end
    local write_result = Call_Or_Error('SetHoldRegs', SetHoldRegs, id, HREG_SET_PROG, 4, {EXPECTED_PROGRAM_NO}, 'F64')
    Validate_Write_Result('SetHoldRegs', write_result)
    Log('INFO', '模板程序号=%s，PLC 程序号=%s', EXPECTED_PROGRAM_NO, plc_program_no)
    if plc_program_no ~= EXPECTED_PROGRAM_NO then
        Raise_Error('PROGRAM_MISMATCH', string.format('程序号不一致：模板=%s，PLC=%s', EXPECTED_PROGRAM_NO, plc_program_no))
    end
    Log('INFO', '程序号校验通过')
end

function Require_Production_Ready()
    Set_Stage('投产条件校验')
    Log('INFO', '投产开关=%s，真实流程完成=%s', tostring(TEMPLATE_PRODUCTION_ENABLED), tostring(PRODUCTION_FLOW_IMPLEMENTED))
    if not TEMPLATE_PRODUCTION_ENABLED then
        Raise_Error('CONFIG_LOCK', '投产开关未启用，自动循环保持锁定')
    end
    if not PRODUCTION_FLOW_IMPLEMENTED then
        Raise_Error('CONFIG_LOCK', '真实生产流程尚未实现，自动循环保持锁定')
    end
end

function Grab_Reachable(point, opts)
    if not CHECK_REACHABLE then
        return true
    end
    if type(CheckMovL) ~= 'function' then
        Log('WARN', 'CheckMovL 不可用，跳过可达性检查')
        return true
    end
    local code = CheckMovL(point, opts)
    if code == 0 then
        return true
    end
    Log('WARN', '抓取点不可达(CheckMovL code=%s)，跳过该物料', tostring(code))
    Report_Fault(811, '抓取点不可达', 'process')
    return false
end

function Scan_Frame(photo)
    local tray, mat = false, false
    for _, item in ipairs(photo.items) do
        if item.mat_type == 10 then
            tray = true
        end
        if item.mat_type == 1 then
            mat = true
        end
    end
    return tray, mat
end

function Extract_Tray(photo)
    for _, item in ipairs(photo.items) do
        if item.mat_type == 10 then
            return item
        end
    end
    return nil
end

function Signal_Grabbed_All()
    Set_Stage('通知R3抓完')
    Log('INFO', 'R2 已抓完，置 R3 线圈 %s=1', tostring(COIL_R2_GRABBED))
    Set_Coil(id_r3, COIL_R2_GRABBED, 1)
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

-- ============================================================================
-- 运动封装
-- ============================================================================
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
    print(
        '[点位覆盖] ' ..
            tostring(base) ..
                ' 更新为相机坐标 x=' .. tostring(item.x) .. ' y=' .. tostring(item.y) .. ' z=' .. tostring(item.z)
    )
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

function Log_Target(tag, pt)
    local p = (type(pt) == 'table' and pt.pose) or nil
    if p and p[1] ~= nil then
        print(
            string.format(
                '[%s] 目标 x=%.3f y=%.3f z=%.3f rx=%.3f ry=%.3f rz=%.3f',
                tag,
                p[1],
                p[2],
                p[3],
                p[4],
                p[5],
                p[6]
            )
        )
    else
        print(string.format('[%s] 目标(无pose): %s', tag, tostring(pt)))
    end
end

function Safe_MovJ(point, opts, override)
    Set_Stage('MovJ')
    Log_Target('MovJ', point)
    local merged = Merge_Opts(opts, override)
    Call_Or_Error('MovJ', MovJ, point, merged or Move_Opts())
end

function Safe_MovL(point, opts, override)
    Set_Stage('MovL')
    Log_Target('MovL', point)
    local merged = Merge_Opts(opts, override)
    Call_Or_Error('MovL', MovL, point, merged or Move_Opts())
end

function Safe_RelMovLUser(vec)
    Set_Stage('相对移动')
    print(
        string.format(
            '[Rel] 相对量 dx=%.3f dy=%.3f dz=%.3f drx=%.3f dry=%.3f drz=%.3f',
            vec[1],
            vec[2],
            vec[3],
            vec[4],
            vec[5],
            vec[6] or 0
        )
    )
    Call_Or_Error('RelMovLUser', RelMovLUser, vec)
end

function Safe_Slow_Lift(dz)
    local cur = GetPose(1, 0)
    Safe_MovL(
        {pose = {cur.pose[1], cur.pose[2], cur.pose[3] + dz, cur.pose[4], cur.pose[5], cur.pose[6]}},
        Move_Opts(1, 0, CFG.grab_lift_accel, CFG.grab_lift_speed)
    )
end

function Ensure_At_Photo_Point()
    for attempt = 1, 2 do
        local ok, dev, cur = At_Photo_Point()
        if ok then
            if attempt > 1 then
                Log('WARN', '已走到拍照点(偏差=%.2fmm)', dev)
            end
            return true
        end
        Log(
            PHOTO_POINT_STRICT and 'ERROR' or 'WARN',
            '不在拍照点 P3(偏差=%.2fmm，当前 x=%.2f y=%.2f z=%.2f)，第%d次走 P2->P3',
            dev,
            cur.pose[1],
            cur.pose[2],
            cur.pose[3],
            attempt
        )
        Set_Stage('去拍照点')
        Safe_MovJ(P2, Move_Opts(0, 0))
        Safe_MovL(P3, Move_Opts(1, 0, RUN_ACCEL, RUN_SPEED, 0))
    end
    return false
end

function Safe_Take_Photo()
    if not Ensure_At_Photo_Point() then
        local cur = GetPose(1, 0)
        if PHOTO_POINT_STRICT then
            Raise_Error(
                'PHOTO_POINT_ERROR',
                string.format(
                    '两次走位后仍未到拍照点 P3，拒绝在此位置触发相机(当前 x=%.2f y=%.2f z=%.2f)',
                    cur.pose[1],
                    cur.pose[2],
                    cur.pose[3]
                )
            )
        end
        Log(
            'ERROR',
            '仍未到拍照点 P3(x=%.2f y=%.2f z=%.2f)！按调试模式继续，正式投产请置 PHOTO_POINT_STRICT=true',
            cur.pose[1],
            cur.pose[2],
            cur.pose[3]
        )
    end
    Set_Stage('拍照')
    Drain_Camera_Buffer()
    Wait(CFG.photo_settle)
    return Call_Or_Error('Take_Photo_Checked', Take_Photo_Checked)
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
            local code = CheckMovL(target, Move_Opts(1, 0))
            if code ~= 0 then
                Log('WARN', '真空补偿下降目标点不可达/奇异(CheckMovL code=%s)，停止下降', tostring(code))
                return false
            end
        end
        Safe_RelMovLUser({0, 0, -step, 0, 0, 0})
        desc = desc + step
    end
end

function Handle_Empty()
    Set_Stage('空托盘')
    Set_Coil(id_r3, COIL_R3_SWITCH_FACE, 1)
    Signal_Grabbed_All()
    After_Grabbed_All(nil)
end

function Grab_Items(photo)
    local tray, mat = Scan_Frame(photo)
    local got_any = false
    for _, item in ipairs(photo.items) do
        if item.mat_type == 1 and not Already_Grabbed(item) then
            if Grab_One_And_Place(item) then
                Mark_Grabbed(item)
                got_any = true
            else
                Runtime.xshift_pending = true
            end
        end
    end
    if not got_any then
        Log('WARN', '一抓一: 本帧无可用物料(空位/已抓完/不可达)，本盘结束')
    end
    if tray and not mat then
        Log('WARN', '310 帧已无物料且含空料盘标记(10)，判定本盘结束')
    end
end

function XShift_Regrab()
    Wait_Coil(id_r3, COIL_R3_XSHIFT_REQ, 0)
    local photo = Safe_Take_Photo()
    if photo.code == 310 then
        Grab_Items(photo)
    end
    Set_Coil(id_r3, COIL_R3_XSHIFT_BACK, 1)
    Wait_Coil(id_r3, COIL_R3_XSHIFT_BACK, 0)
    Runtime.xshift_pending = false
end

function Production_Cycle()
    if not PRODUCTION_FLOW_IMPLEMENTED then
        Raise_Error('CONFIG_LOCK', 'Production_Cycle 禁止在真实流程未完成时运行')
    end
    Set_Coil(id_r3, COIL_R2_GRABBED, 0)
    Set_Coil(id_r3, COIL_R2_DUMPED, 0)
    Runtime.xshift_pending = false
    Wait_Coil(id_r3, COIL_JOIN_ACK, 0)
    Safe_MovJ(P2, Move_Opts(0, 0))
    Safe_MovL(P3, Move_Opts(1, 0, RUN_ACCEL, RUN_SPEED, 0))
    Wait_For_R3(COIL_R3_DETECT, 1, '等待R3拍照触发')
    local photo = Safe_Take_Photo()
    local code = photo.code
    if code == 310 then
        Grab_Items(photo)
        code = 120
    end
    if code == 120 then
        if CFG.xshift_enabled and Runtime.xshift_pending then
            Set_Coil(id_r3, COIL_R3_XSHIFT_REQ, 1)
        end
        Signal_Grabbed_All()
        if CFG.xshift_enabled and Runtime.xshift_pending then
            XShift_Regrab()
        end
        After_Grabbed_All(Extract_Tray(photo))
        Clear_Grabbed()
    elseif code == 130 then
        if CFG.xshift_enabled and Runtime.xshift_pending then
            Set_Coil(id_r3, COIL_R3_XSHIFT_REQ, 1)
            Signal_Grabbed_All()
            XShift_Regrab()
        end
        Handle_Empty()
        Clear_Grabbed()
    elseif code ~= 310 then
        Log('ERROR', '相机报文无法识别(防御分支): %s', tostring(code))
        Pause()
    end
end

-- ============================================================================
-- 连接
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

-- 控制线圈：5清报警 1停止 4下使能 3上使能 0开始。脉冲：0 → 100ms → 1 → 100ms → 0
local RESTART_COILS = {5, 1, 4, 3, 0}
local RESTART_PULSE_MS = 100
local COIL_RESTART_BY_PEER = 4600 -- 本臂线圈。1=这次是对臂拉起的，不再回发重启

function Connect_Peer()
    id_peer = Connect_Modbus('对臂连接', g_peer_ip)
end

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
-- 相机。报文: 310 有料 / 120 有料盘 / 130 空托盘。物料类型 1=物料 10=料盘
-- ============================================================================
function Send_Camera(cmd)
    local rc = TCPWrite(cam_socket, cmd, 0)
    if rc ~= 0 then
        print('[相机] 发送失败 cmd=' .. tostring(cmd) .. ' rc=' .. tostring(rc))
    end
    return rc
end

function Receive_Camera()
    local recv_err, recv = TCPRead(cam_socket, CFG.cam_timeout, 'string')
    if recv_err ~= 0 then
        print('[相机] 接收失败 err=' .. tostring(recv_err))
        return nil
    end
    return recv
end

function Parse_Camera_Data(recv)
    if type(recv) ~= 'string' or recv == '' then
        print('[相机] 报文为空或类型异常: ' .. tostring(recv))
        return {code = nil, items = {}}
    end
    local result = {code = nil, items = {}}
    local s = recv:gsub('%s+', '')
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
        return result
    end
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

function Take_Photo()
    print('[相机] 触发拍照: ' .. tostring(CFG.cam_start_cmd))
    local rc = Send_Camera(CFG.cam_start_cmd)
    if rc ~= 0 then
        return {code = nil, items = {}, recv_fail = true}
    end
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

-- 无效结果一直重试，避免 code=nil 被当成空托盘
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
-- 线圈。abort 命中时抛 [RESTART_CYCLE]，由 Main 作废本周期
-- ============================================================================
function Read_Coil(conn_id, addr)
    local coils = GetCoils(conn_id, addr, 1)
    if coils == nil then
        return nil
    end
    return coils[1]
end

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

function Wait_Coil(conn_id, addr, expect, abort)
    local c
    repeat
        if abort ~= nil and Read_Coil(conn_id, abort.addr) == abort.val then
            error(
                '[RESTART_CYCLE] 等待 addr=' ..
                    tostring(addr) ..
                        '==' ..
                            tostring(expect) ..
                                ' 期间检测到周期作废(addr=' ..
                                    tostring(abort.addr) .. '==' .. tostring(abort.val) .. ')，本臂从周期起点重入',
                0
            )
        end
        c = GetCoils(conn_id, addr, 1)
        if c == nil or c[1] ~= expect then
            Wait(CFG.wait_coil_poll)
        end
    until c ~= nil and c[1] == expect
    print('[线圈] 等待 addr=' .. tostring(addr) .. ' == ' .. tostring(expect) .. ' 完成')
end

-- ============================================================================
-- 旋转机构（IP 见 g_rot_ip）。68=脉冲(6000脉冲/360°)，70=0复位 / 1反向 / 2正向。
-- 角度是相对转角。机构无到位线圈，下发后不等 4444。
-- src0 抬升后只写 5678 并置请求线圈 5666，然后继续走。src1 看到 5666 后调用 RotatingMachineControl。
-- ============================================================================
local ROT_MACHINE_PORT = 502
local HOLDREG_TYPE_COUNT = {U16 = 1, U32 = 2, F32 = 2, F64 = 4}

local function HoldReg_Count(dtype)
    local n = HOLDREG_TYPE_COUNT[dtype]
    if n == nil then
        error('[CONFIG_ERROR] 不支持的数据类型: ' .. tostring(dtype), 0)
    end
    return n
end

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
            Write_Rot_Reg(rot_id, 70, dir) -- 启动电机
            Wait(CFG.wait_rot_poll)
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

function Request_Rotate_Single(angle, cup)
    local total = angle or 0
    print('[旋转] 吸盘' .. tostring(cup or 1) .. ' 请求角度=' .. tostring(total) .. '，交给 src1，轨迹继续')
    local last = nil
    for i = 1, ROT_REQ_TRIES do
        local ang_ok, ang_rc = Try_Write_Rotate_Angle(HREG_ROT_ANGLE, total)
        if ang_ok then
            local req_ok, req_rc = Try_Set_Coil(id, COIL_ROT_REQ, 1)
            if req_ok then
                return
            end
            last = '置请求 rc=' .. tostring(req_rc)
        else
            last = '写角度 rc=' .. tostring(ang_rc)
        end
        print('[旋转] 第 ' .. tostring(i) .. ' 次请求写入失败(' .. tostring(last) .. ')，轨迹不停止')
        if i < ROT_REQ_TRIES then
            Wait(CFG.wait_coil_poll)
        end
    end
    print('[旋转] 请求写入仍失败，继续走轨迹，本件可能不旋转 角度=' .. tostring(total))
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

function Rotate_Thread_Step()
    if not Ensure_Rotate_Thread() then
        Wait(CFG.wait_conn_retry)
        return false
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
        print('[旋转] src1 下发仍失败，不停止 src0，本件可能不旋转 角度=' .. tostring(angle) .. ' 原因=' .. tostring(last_err))
        return true
    end
    local done_ok, done_rc = Try_Set_Coil(id_rot_thread, COIL_ROT_DONE, 1)
    if not done_ok then
        print('[旋转] src1 写完成线圈失败 rc=' .. tostring(done_rc) .. '，脉冲已下发，不重复旋转')
    else
        print('[旋转] src1 下发完成')
    end
    return true
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

function Reset_Rotate_Registers()
    Write_Rotate_Angle(HREG_ROT_ANGLE, 0)
    Set_Coil(id, COIL_ROT_DONE, 0)
    Set_Coil(id, COIL_ROT_REQ, 0)
end

-- ============================================================================
-- 抓取互斥：目标点越出安全区才上锁（Peterson）
-- ============================================================================
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
        return false
    end
    local need_lock = false
    for _, pt in ipairs({...}) do
        if pt and Point_Outside_Safe_Zone(pt.x, pt.y) then
            need_lock = true
            break
        end
    end
    if not need_lock then
        return false
    end
    local flag_me = (arm == 'R1') and COIL_GRAB_REQ_R1 or COIL_GRAB_REQ_R2
    local flag_other = (arm == 'R1') and COIL_GRAB_REQ_R2 or COIL_GRAB_REQ_R1
    local other_idx = (arm == 'R1') and 1 or 0
    Set_Coil(id_r3, flag_me, 1)
    Set_Coil(id_r3, COIL_GRAB_BUSY, 1)
    Set_Coil(id_r3, COIL_GRAB_TURN, other_idx)
    while Read_Coil(id_r3, flag_other) == 1 and Read_Coil(id_r3, COIL_GRAB_TURN) == other_idx do
        Wait(CFG.wait_grab_lock)
    end
    return true
end

function Grab_Lock_Release(arm)
    local flag_me = (arm == 'R1') and COIL_GRAB_REQ_R1 or COIL_GRAB_REQ_R2
    local flag_other = (arm == 'R1') and COIL_GRAB_REQ_R2 or COIL_GRAB_REQ_R1
    Set_Coil(id_r3, flag_me, 0)
    if Read_Coil(id_r3, flag_other) ~= 1 then
        Set_Coil(id_r3, COIL_GRAB_BUSY, 0)
    end
end

-- ============================================================================
-- IO
-- ============================================================================
function Set_Blow(on)
    DO(CFG.do_blow, on and ON or OFF)
end

function Set_Suck(on)
    DO(CFG.do_suck, on and ON or OFF)
end

function Close_All_DO()
    DO(CFG.do_blow, OFF)
    DO(CFG.do_suck, OFF)
    DO(CFG.do_suck_1, OFF)
    DO(CFG.do_blow_1, OFF)
    DO(CFG.do_suck_2, OFF)
    DO(CFG.do_blow_2, OFF)
    DO(CFG.do_varpitch, CFG.varpitch_close)
    print('[DO] 已关闭全部 DO')
end

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

function Join_As_Arm(arm)
    local req = (arm == 'R1') and COIL_JOIN_REQ_R1 or COIL_JOIN_REQ_R2
    print(
        '[入组] ' ..
            tostring(arm) .. ' 请求入组: 置 addr=' .. tostring(req) .. '=1，等待 R3 应答 addr=' .. tostring(COIL_JOIN_ACK) .. '=1'
    )
    Set_Coil(id_r3, req, 1)
    Wait_Coil(id_r3, COIL_JOIN_ACK, 1)
    Set_Coil(id_r3, req, 0)
    Wait_Coil(id_r3, COIL_JOIN_ACK, 0)
    print('[入组] ' .. tostring(arm) .. ' 入组完成，按周期起点重入（会重拍照重建物料状态）')
end

-- 会关吸盘。起机前确认末端无料。
function Init_IO(arm, conn)
    print('[IO初始化] 复位本臂(' .. tostring(arm) .. ')拥有的信号并关闭所有 DO')
    Reset_Own_Signals(arm, conn)
    Reset_Rotate_Registers()
    Close_All_DO()
    Set_Blow(true)
    Set_Suck(false)
    Wait(CFG.wait_io_settle)
    Close_All_DO()
    print('[IO初始化] 完成')
end

-- ============================================================================
-- Seg
-- ============================================================================
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

-- id: 本臂 Modbus；id_r3: R3 Modbus；cam_socket: 相机
