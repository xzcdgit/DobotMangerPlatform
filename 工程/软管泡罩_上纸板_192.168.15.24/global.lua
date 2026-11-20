-- 版本：Lua 5.3.5
-- 泡罩线三站：配置、吸盘、料仓检测与 EAP 通信。
-- 回原、抓放、避让和生产循环在 src0.lua，由主程序调用后才运动。

-- ============================================================================
-- 通信与寄存器
-- ============================================================================
g_server_ip = '192.168.15.24' -- PLC 的 Modbus TCP 地址。
PLC_PORT = 502 -- Modbus TCP 端口。
PLC_STATION = 1 -- Modbus 站号。
PLC_RETRY_MS = 1000 -- 连接失败后的重试间隔。
id = nil -- 本臂 Modbus 会话号，PLC_Connet 成功后赋值（先声明，避免编辑器报未声明）。

REG_SEG_OUT = 3811 -- 机器人写给 EAP 的 Seg 寄存器。
REG_SEG_IN = 3911 -- EAP 回给机器人的 Seg 寄存器。
SEG_REG_COUNT = 4 -- F64 占 4 个保持寄存器。
REG_PROGRAM_IN = 3095 -- PLC 下发的程序号，类型 U32。
REG_PROGRAM_OUT = 3751 -- 机器人上报的程序号，类型 F64。
PROGRAM_REG_COUNT = 2 -- U32 占 2 个保持寄存器。
PROGRAM_NUMBER = 1 -- 本站程序号，气垫类。
COIL_PROGRAM_ALARM = 8 -- 程序号不一致时置位的报警线圈。
COIL_ERROR = 3155 -- 配置错误时置位的报警线圈。

SEG_MATCH_EPSILON = 0.01 -- F64 回读容差，用于 11 和 13 的判断。
CONFIG_ERROR_WAIT_MS = 1000 -- 配置错误后空转等待，避免脚本退出。
CYCLE_ERROR_WAIT_MS = 3000 -- 生产循环异常后的重试等待。
SEG_POLL_MS = 50 -- 读取 EAP Seg 的轮询间隔。
OVERLAP_MOVER_HANDSHAKE = true -- true：Seg4 后不原地等 Seg5/Seg2，握手在后续动作间隙完成；false：恢复逐步阻塞等待。

-- ============================================================================
-- Seg：机器人写 3811，EAP 回 3911。
-- ============================================================================
SEG_INIT_REQUEST = 1000 -- 初始化请求，EAP 以相同值确认。
SEG_CYCLE_DONE = 0 -- 单件完成，状态复位。
SEG_READY = 1 -- 初始化完成，机器人就绪。
SEG_WAIT_MOVER = 2 -- 已在放料上方，等待动子到位。
SEG_MOVER_READY = 3 -- EAP 确认动子已到放料工位。
SEG_NOTIFY_MOVER_LEAVE = 4 -- 放料完成，请求放行动子。
SEG_MOVER_GONE = 5 -- EAP 确认动子已放行。
SEG_BIN_RISE = 10 -- 左右料仓都无料，请求托举。
SEG_BIN_RISE_OK = 11 -- EAP 确认本次托举完成。
SEG_BIN_RISE_RETRY = -1 -- 托举后仍无料，请求再次顶升。
SEG_BIN_RISE_RETRY_ACK = 1 -- EAP 确认后，允许再次发送 Seg10。
SEG_BIN_OVER = 13 -- 料仓已到最高位，需要人工补料。
SEG_WAIT_REFILL = 14 -- 机器人已避让，等待人工补料。
SEG_REFILL_OK = 15 -- EAP 确认人工补料完成。

-- ============================================================================
-- IO、节拍与运动参数
-- ============================================================================
DI_MATERIAL_LEFT = 6 -- 左料仓有料，1 表示有料。
DI_MATERIAL_RIGHT = 7 -- 右料仓有料，1 表示有料。
DI_VACUUM_LEFT = 2 -- 左吸盘真空，1 表示吸住，0 表示已释放。
DI_VACUUM_RIGHT = 1 -- 右吸盘真空，1 表示吸住，0 表示已释放。
DO_SUCTION_LEFT = 1 -- 左吸气输出。
DO_BLOW_LEFT = 2 -- 左吹气输出。
DO_SUCTION_RIGHT = 3 -- 右吸气输出。
DO_BLOW_RIGHT = 4 -- 右吹气输出。

GRIP_CHECK_DELAY_MS = 100 -- 每个抓取高度等待真空建立的时间。
GRIP_PROBE_STEP_MM = 1 -- 真空未建立时，每次向下试探的距离。
GRIP_MAX_PROBE_MM = 5 -- 相对抓取点允许下探的最大距离。
RELEASE_POLL_MS = 20 -- 放料后查询真空是否归零的间隔。
RELEASE_TIMEOUT_MS = 2000 -- 真空未归零时强制关吹气并继续放行动子。

SPEED_RETURN = 70 -- 回原前的全局速度倍率。
SPEED_FACTOR_RUN = 100 -- 回原结束后恢复的生产速度倍率。
HOME_POSITION_EPSILON = 0.05 -- 回原位移小于该值时不再补一次微小运动，单位 mm。

-- 每步运动参数：user 用户坐标，tool 工具坐标，a 加速度，v 速度，cp 到位。
-- 回原沿 Z+ 抬升。下探不写 user/tool，沿当前用户坐标 Z-。
MOTION_HOME_LIFT = {user = 0, tool = 0, a = 25, v = 70, cp = 1} -- 回原第1步：当前位置垂直抬升。
MOTION_HOME_TRAVEL = {user = 0, tool = 0, a = 25, v = 70, cp = 1} -- 回原第2步：安全高度横移。
MOTION_HOME_DESCEND = {user = 0, tool = 0, a = 25, v = 70, cp = 1} -- 回原第3步：P1 上方垂直下降。
MOTION_HOME_FINAL = {user = 0, tool = 0, a = 25, v = 70, cp = 1} -- 回原第4步：精确落到 P1。
MOTION_AVOID = {user = 0, tool = 0, a = 100, v = 100, cp = 1} -- 关节运动到避让点 P7。
MOTION_PICK_TOP = {user = 0, tool = 0, a = 100, v = 100, cp = 1} -- 关节运动到抓取上方 P2。
MOTION_PICK_DOWN = {user = 0, tool = 0, a = 50, v = 50, cp = 1} -- 低速直线下降到抓取点 P3。
MOTION_PICK_PROBE = {a = 50, v = 100, cp = 1} -- 真空未建立时下探 1 mm。
MOTION_PICK_UP = {user = 0, tool = 0, a = 100, v = 100, cp = 1} -- 直线抬回抓取上方 P2。
MOTION_PICK_TRANS = {user = 0, tool = 0, a = 100, v = 100, cp = 1} -- 关节运动到过渡点 P4。
MOTION_PLACE_TOP = {user = 0, tool = 0, a = 100, v = 100, cp = 1} -- 关节运动到放料上方，左 P5、右 P8。
MOTION_PLACE_DOWN = {user = 0, tool = 0, a = 100, v = 100, cp = 1} -- 直线下降到放料点，左 P6、右 P9。
MOTION_PLACE_UP = {user = 0, tool = 0, a = 100, v = 100, cp = 1} -- 直线抬回放料上方。
OFF_GRIP_PROBE_DOWN = {0, 0, -GRIP_PROBE_STEP_MM, 0, 0, 0} -- 每次下探的相对位移。

-- 示教点在 Map_Teach_Points() 中赋值。
-- P1 Home，P2 抓取上方，P3 抓取点，P4 过渡点，P7 避让点，P5/P6 左放料，P8/P9 右放料。
SIDE_LEFT = {
    name = '左侧',
    material_di = DI_MATERIAL_LEFT, -- 左料仓检测。
    vacuum_di = DI_VACUUM_LEFT, -- 左吸盘真空检测。
    suction_do = DO_SUCTION_LEFT, -- 左吸气。
    blow_do = DO_BLOW_LEFT, -- 左吹气。
    place_top_name = '左放料上方点(P5)',
    place_name = '左放料点(P6)'
}
SIDE_RIGHT = {
    name = '右侧',
    material_di = DI_MATERIAL_RIGHT, -- 右料仓检测。
    vacuum_di = DI_VACUUM_RIGHT, -- 右吸盘真空检测。
    suction_do = DO_SUCTION_RIGHT, -- 右吸气。
    blow_do = DO_BLOW_RIGHT, -- 右吹气。
    place_top_name = '右放料上方点(P8)',
    place_name = '右放料点(P9)'
}
SIDES = {SIDE_LEFT, SIDE_RIGHT} -- 固定先左后右，双件放料也按这个顺序。

-- ============================================================================
-- 吸盘与点位检查
-- ============================================================================
-- 一次写完四路输出，顺序固定为左吸气、右吸气、左吹气、右吹气。
function Set_Grip_Outputs(suction_left, suction_right, blow_left, blow_right)
    -- 用 1/0，避免部分控制器把 ON/OFF 判成类型不兼容
    DO(DO_SUCTION_LEFT, suction_left and 1 or 0)
    DO(DO_SUCTION_RIGHT, suction_right and 1 or 0)
    DO(DO_BLOW_LEFT, blow_left and 1 or 0)
    DO(DO_BLOW_RIGHT, blow_right and 1 or 0)
end

function Contains_Side(sides, target_side)
    for _, side in ipairs(sides) do
        if side == target_side then
            return true
        end
    end
    return false
end

function Remove_Side(sides, target_side)
    for i, side in ipairs(sides) do
        if side == target_side then
            table.remove(sides, i)
            return
        end
    end
end

-- release_side 为空：列表中的吸盘吸气，吹气全部关闭。
-- release_side 有值：该侧关闭吸气并打开吹气，另一侧若仍在列表中则继续吸气。
function Set_Grip_State(held_sides, release_side)
    Set_Grip_Outputs(
        Contains_Side(held_sides, SIDE_LEFT) and release_side ~= SIDE_LEFT,
        Contains_Side(held_sides, SIDE_RIGHT) and release_side ~= SIDE_RIGHT,
        release_side == SIDE_LEFT,
        release_side == SIDE_RIGHT
    )
end

function Side_List_Name(sides)
    local names = {}
    for _, side in ipairs(sides) do
        table.insert(names, side.name)
    end
    return table.concat(names, '、')
end

-- 点位或位姿缺失时关闭气路、置报警线圈，并停在循环里等待人工处理。
function Stop_For_Configuration(message)
    Set_Grip_Outputs(false, false, false, false)
    Report_Process_Fault(905, message) -- 配置类过程异常；控制器是否在跑由上位机读触点
    print('[配置错误] ' .. message .. '；已关闭双吸气/双吹气并保持当前安全状态等待人工处理')
    SetCoils(id, COIL_ERROR, 1, {1})
    while true do
        Wait(CONFIG_ERROR_WAIT_MS)
    end
end

function Require_Point(point, point_name)
    if point == nil then
        Stop_For_Configuration(point_name .. '尚未映射到实际示教点，禁止执行运动')
    end
    return point
end

-- ============================================================================
-- 物料检测与放料气路
-- ============================================================================
function Select_Available_Sides()
    local readings = {} -- 左右料仓 DI 的日志。
    local sides = {} -- 当前有料、需要抓取的工位。
    for _, side in ipairs(SIDES) do
        local material = DI(side.material_di) -- 1 表示该仓有料。
        table.insert(readings, 'DI(' .. side.material_di .. ')=' .. tostring(material))
        if material == 1 then
            table.insert(sides, side)
        end
    end
    print('[物料 DI] ' .. table.concat(readings, ', '))

    if #sides > 0 then
        print('[物料检测] 有料侧：' .. Side_List_Name(sides) .. '，共 ' .. #sides .. ' 件')
    else
        print('[物料检测] 左右料仓均无料')
    end
    return sides
end

function Sides_With_Vacuum(sides)
    local picked_sides = {} -- 真空 DI 已经为 1 的工位。
    for _, side in ipairs(sides) do
        local vacuum = DI(side.vacuum_di)
        print('[真空 DI] ' .. side.name .. ' DI(' .. side.vacuum_di .. ')=' .. tostring(vacuum))
        if vacuum == 1 then
            table.insert(picked_sides, side)
        end
    end
    return picked_sides
end

function Close_Missed_Suction(sides, picked_sides)
    for _, side in ipairs(sides) do
        if not Contains_Side(picked_sides, side) then
            print('[抓取] ' .. side.name .. '真空未建立，关闭其吸气')
            DO(side.suction_do, OFF)
        end
    end
end

function Wait_And_Close_Blow_Channel(side)
    print('[放料] ' .. side.name .. '吹气已打开，等待真空 DI' .. side.vacuum_di .. ' 变为 0 后关闭吹气')
    local elapsed = 0 -- 本侧吹气已经等待的时间。
    while elapsed < RELEASE_TIMEOUT_MS do
        if DI(side.vacuum_di) == 0 then
            DO(side.blow_do, OFF)
            print('[放料] ' .. side.name .. '真空 DI' .. side.vacuum_di .. '=0，关闭吹气 DO' .. side.blow_do)
            return
        end
        Wait(RELEASE_POLL_MS)
        elapsed = elapsed + RELEASE_POLL_MS
    end

    -- 超时仍关闭吹气，后面的 Seg4 继续发送，避免动子停在放料工位。
    DO(side.blow_do, OFF)
    print(
        string.format(
            '[放料] %s真空 DI%d 在 %d ms 内未归零，强制关闭吹气 DO%d 并继续放行动子',
            side.name,
            side.vacuum_di,
            RELEASE_TIMEOUT_MS,
            side.blow_do
        )
    )
end

function Map_Teach_Points()
    P_HOME = P1 -- Home，回原安全点。
    P_PICK_TOP = P2 -- 左右料仓共用的抓取上方点。
    P_PICK = P3 -- 左右料仓共用的抓取点。
    P_TRANS = P4 -- 抓取区到放料区的过渡点。
    P_AVOID = P7 -- 人工补料避让点。
    SIDE_LEFT.place_top = P5 -- 左放料上方点。
    SIDE_LEFT.place = P6 -- 左放料点。
    SIDE_RIGHT.place_top = P8 -- 右放料上方点。
    SIDE_RIGHT.place = P9 -- 右放料点。
end

function Prepare_Production()
    -- 读取 PLC 程序号并回写本站程序号。不一致只报警，不中断初始化。
    Set_Stage('程序号校验')
    local program_num = GetHoldRegs(id, REG_PROGRAM_IN, PROGRAM_REG_COUNT, 'U32')
    print('PLC给的程序号', program_num[1])
    SetHoldRegs(id, REG_PROGRAM_OUT, SEG_REG_COUNT, {PROGRAM_NUMBER}, 'F64')
    if program_num[1] ~= PROGRAM_NUMBER then
        SetCoils(id, COIL_PROGRAM_ALARM, 1, {1})
        print('程序号不一致，当前程序号为 ' .. PROGRAM_NUMBER .. '，PLC给的程序号为：', program_num[1])
    end

    -- 初始化握手：1000 确认，0 等待就绪，1 等待 EAP 下发 2 后才允许生产。
    Set_Stage('初始化握手')
    print('[初始化] 输出 Seg1000，请求 EAP 确认')
    Out_Seg(SEG_INIT_REQUEST, true)
    Wait_Seg(SEG_INIT_REQUEST)

    print('[初始化] EAP 已确认，输出 Seg0 并等待 Seg1')
    Out_Seg(SEG_CYCLE_DONE, true)
    Wait_Seg(SEG_READY)

    Set_Grip_Outputs(false, false, false, false)
    Set_Stage('等待周期启动')
    print('[初始化] IO 初始化完成，输出 Seg1，等待 EAP 下发 Seg2 启动生产')
    Out_Seg(SEG_READY, true)
    Wait_Seg(SEG_WAIT_MOVER)
end

-- ============================================================================
-- PLC / Seg
-- ============================================================================
function PLC_Connet()
    ::create_PLC_Connet::
    Set_Stage('PLC连接')
    print('[PLC连接] 正在创建 Modbus TCP 连接，目标=' .. g_server_ip .. ':' .. PLC_PORT .. '，站号=' .. PLC_STATION)
    local connect_err -- ModbusCreate 的错误码，0 表示成功。
    connect_err, id = ModbusCreate(g_server_ip, PLC_PORT, PLC_STATION) -- id 供后续寄存器读写使用。
    if connect_err ~= 0 then
        print('[PLC连接] 失败，err=' .. tostring(connect_err) .. '，id=' .. tostring(id) .. '，1 秒后重试')
        Wait(PLC_RETRY_MS)
        goto create_PLC_Connet
    end
    print('[PLC连接] 连接成功，连接标识 id=' .. tostring(id))
    -- 连上后立刻写一次监控寄存器，清掉上次残留的异常码
    g_action_code = nil
    g_fault_code = nil
    Clear_Fault()
    Set_Stage('PLC连接')
end

-- verify 为 true 时写后读回（启动握手用）；生产循环不读回，省一次 Modbus 往返。
function Out_Seg(num, verify)
    SetHoldRegs(id, REG_SEG_OUT, SEG_REG_COUNT, {num}, 'F64') -- 写入机器人请求。
    if verify == true then
        local num_req = GetHoldRegs(id, REG_SEG_OUT, SEG_REG_COUNT, 'F64') -- 读回确认写入成功。
        print('[Seg输出] 机械臂->EAP，寄存器=' .. REG_SEG_OUT .. '，请求=' .. num .. '，读回=' .. num_req[1])
        return
    end
    print('[Seg输出] 机械臂->EAP，寄存器=' .. REG_SEG_OUT .. '，请求=' .. num)
end

-- 先读后判断，已经到位就立即返回，不再白等一个轮询周期；只在数值变化时打印。
function Wait_Seg(num)
    local last = nil -- 上一次打印的 EAP 数值。
    local logged_waiting = false
    while true do
        local seg = GetHoldRegs(id, REG_SEG_IN, SEG_REG_COUNT, 'F64') -- 第 1 项是 EAP 当前 Seg。
        local cur = seg and seg[1]
        if cur == nil then
            Wait(SEG_POLL_MS)
        else
            -- F64 用容差比较，避免 2.0000001 之类反复刷屏
            if last == nil or math.abs(cur - last) >= SEG_MATCH_EPSILON then
                print(string.format('[Seg等待] EAP->机械臂，寄存器=%d，期望=%s，当前=%g', REG_SEG_IN, tostring(num), cur))
                last = cur
                logged_waiting = false
            elseif not logged_waiting and math.abs(cur - num) >= SEG_MATCH_EPSILON then
                print(string.format('[Seg等待] 继续等待期望=%s（当前仍为 %g）…', tostring(num), cur))
                logged_waiting = true
            end
            if math.abs(cur - num) < SEG_MATCH_EPSILON then
                return
            end
            Wait(SEG_POLL_MS)
        end
    end
end

-- 放料后动子放行握手：Seg4 → 等 Seg5 → 写 Seg0 → 等 Seg2。
-- 重叠模式下机械臂发 Seg4 后直接继续动作，由 Service_Mover_Handshake 在动作间隙推进；
-- 下一次发 Seg2/Seg10/Seg14 之前，Finish_Mover_Handshake 保证握手已完整走完。
HANDSHAKE_IDLE = 0 -- 没有待完成的握手。
HANDSHAKE_WAIT_GONE = 1 -- 已发 Seg4，等 EAP 回 Seg5。
HANDSHAKE_WAIT_NEXT = 2 -- 已发 Seg0，等 EAP 回 Seg2。
mover_handshake_state = HANDSHAKE_IDLE

function Service_Mover_Handshake()
    if mover_handshake_state == HANDSHAKE_IDLE then
        return
    end
    local seg = GetHoldRegs(id, REG_SEG_IN, SEG_REG_COUNT, 'F64')
    if mover_handshake_state == HANDSHAKE_WAIT_GONE and seg[1] == SEG_MOVER_GONE then
        print('[生产循环] 动子已放行(Seg' .. SEG_MOVER_GONE .. ')，输出 Seg0 复位')
        Out_Seg(SEG_CYCLE_DONE, false)
        mover_handshake_state = HANDSHAKE_WAIT_NEXT
    elseif mover_handshake_state == HANDSHAKE_WAIT_NEXT and seg[1] == SEG_WAIT_MOVER then
        print('[生产循环] EAP 已回 Seg' .. SEG_WAIT_MOVER .. '，上一件握手完成')
        mover_handshake_state = HANDSHAKE_IDLE
    end
end

function Finish_Mover_Handshake()
    if mover_handshake_state == HANDSHAKE_IDLE then
        return
    end
    print('[生产循环] 新的 Seg 请求前上一件握手未完成，阻塞等待')
    if mover_handshake_state == HANDSHAKE_WAIT_GONE then
        Wait_Seg(SEG_MOVER_GONE)
        Out_Seg(SEG_CYCLE_DONE, false)
    end
    Wait_Seg(SEG_WAIT_MOVER)
    mover_handshake_state = HANDSHAKE_IDLE
end

-- ============================================================================
-- 可视化监控（两层，勿混用）
-- A. 控制器状态：运行/暂停/报警/硬停 —— 脚本写不了，由上位机读 map1 触点(2/3/4)
-- B. 工艺状态：本脚本可写
--    4100=当前动作节点  4101=自定义过程异常(旋转通讯失败等；0=无)
-- ============================================================================
HREG_ACTION = 4100
HREG_FAULT = 4101
g_action_code = nil
g_fault_code = nil

-- 工艺动作节点 → 4100。名称供现场对照；上位机显示名以 codes.json 为准（可随时改上位机）。
-- 250 料仓托举 / 251 人工补料 / 252 去放料上方 为本站专用码。
STAGE_ACTION = {
    ['PLC连接'] = 101, -- Modbus 连本臂
    ['安全回原'] = 104, -- 抬升→横移→落到 P1
    ['程序号校验'] = 110, -- 读 3095 / 写 3751
    ['初始化握手'] = 112, -- Seg1000 / 0 / 1
    ['等待周期启动'] = 113, -- 等 EAP 首次 Seg2
    ['料仓托举'] = 250, -- 左右无料，Seg10 等托举（与人工补料分开）
    ['人工补料'] = 251, -- 避让 P7 + Seg14 等 Seg15
    ['去抓取上方'] = 200, -- 去 P2（料仓 DI 有料才进入抓取）
    ['下降抓取'] = 204, -- 降 P3 开吸
    ['真空确认'] = 205, -- 真空到位=抓取成功；未到位=下探/不抓取
    ['取料抬起'] = 206, -- 抬回 P2
    ['去过渡点'] = 210, -- 去 P4（取料区→放料区）
    ['去放料上方'] = 252, -- 去 P5/P8（与 P4 分开）
    ['放料上方等动子'] = 181, -- 已在放料上方，Seg2 等 Seg3
    ['下降放料'] = 212, -- 降 P6/P9
    ['松开'] = 213, -- 关吸开吹
    ['放行动子'] = 184, -- Seg4
    ['周期完成'] = 187 -- 本轮抓放结束
}

local function Write_Monitor(addr, code)
    if id == nil or type(code) ~= 'number' then
        return false
    end
    local ok, rc = pcall(SetHoldRegs, id, addr, 1, {math.floor(code)}, 'U16')
    if not ok then
        print(string.format('[监控] 写寄存器失败 addr=%s code=%s err=%s', tostring(addr), tostring(code), tostring(rc)))
        return false
    end
    if rc ~= nil and rc ~= 0 and rc ~= true then
        print(string.format('[监控] 写寄存器返回异常 addr=%s code=%s rc=%s', tostring(addr), tostring(code), tostring(rc)))
        return false
    end
    return true
end

function Report_Action(code)
    if type(code) ~= 'number' or g_action_code == code then
        return
    end
    if Write_Monitor(HREG_ACTION, code) then
        g_action_code = code
        print(string.format('[监控] 动作码=%s', tostring(code)))
    end
end

function Report_Fault(code)
    if type(code) ~= 'number' or g_fault_code == code then
        return
    end
    if Write_Monitor(HREG_FAULT, code) then
        g_fault_code = code
    end
end

function Clear_Fault()
    Report_Fault(0)
end

-- 工艺动作节点：只写 4100，不冒充控制器「运行/停机」
function Set_Stage(stage)
    local code = STAGE_ACTION[stage]
    if code ~= nil then
        Report_Action(code)
    end
    if stage == 'PLC连接' or stage == '初始化握手' or stage == '等待周期启动' or stage == '周期完成' then
        Clear_Fault()
    end
end

-- 脚本还能跑时上报的自定义过程异常（写 4101）。硬停/碰撞停不要走这里。
function Report_Process_Fault(code, message)
    Report_Fault(code or 919)
    if message then
        print('[过程异常] ' .. tostring(message))
    end
end
