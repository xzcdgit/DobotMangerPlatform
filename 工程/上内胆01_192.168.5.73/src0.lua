-- src0.lua  上料臂 R1（192.168.5.73）
-- 只保留运动和 Main。参数和运动选项在 global.lua。P7 只取 z，不作为运动目标。

local function Safe_Return_Home()
    Set_Stage('安全回原')
    Log('INFO', '开始安全回原')
    local cur = GetPose(0, 0)
    local x, y = cur.pose[1], cur.pose[2]
    local opts = Home_Opts()
    if y < HOME_Y_LIMIT then
        local lift_z = P7.pose[3] + HOME_LIFT_EXTRA
        Log('INFO', 'y=%s < %s，抬到 %s 后平移到 x=%s 再回 Home', tostring(y), tostring(HOME_Y_LIMIT), tostring(lift_z), tostring(HOME_SHIFT_X))
        Safe_MovL(Keep_Pose(cur, x, y, lift_z), opts)
        Safe_MovL(Keep_Pose(cur, HOME_SHIFT_X, y, lift_z), opts)
        Safe_MovL(P1, opts)
    else
        Log('INFO', '常规区 y=%s，直接回 Home', tostring(y))
        Safe_MovL(P1, opts)
    end
    Log('INFO', '已回到 P1/Home')
end

-- 下降吸取并抬升。item 的 x/y 用于互锁。失败时已松锁，返回 false。
local function Pick_Up(item)
    Grab_Lock_Acquire('R1', item)
    Safe_MovL(Pose_With_Z(P5, CFG.grab_above_dz), Pick_Opts())
    Safe_MovL(P5, Pick_Opts())
    Set_Suck(true)
    Set_Blow(false)
    Wait(CFG.wait_pick_settle)
    if not Attain_Vacuum(CFG.di_vacuum_1) then
        Set_Suck(false)
        Grab_Lock_Release('R1')
        return false
    end
    Safe_Slow_Lift(CFG.lift_dz)
    Grab_Lock_Release('R1')
    return true
end

local function Place_Part()
    Safe_MovL(P4, Run_Opts(), {a = P4_ACCEL})
    Safe_MovL(P6, Run_Opts())
    Wait_Mover_OK('动子质量=%s(期望10)，NG：不放料，停在放料上方等待位，等下一组动子')
    Safe_MovL(P10, Place_Opts())
    Set_Suck(false)
    Set_Blow(true)
    Wait(CFG.place_release_settle)
    Safe_RelMovLUser({0, 0, CFG.lift_dz, 0, 0, 0})
    Set_Blow(false)
    Safe_MovL(P4, Run_Opts())
    Seg_Close()
end

function Grab_One_And_Place(item)
    Set_Stage('抓取物料')
    Overwrite_Pose(P5, item)
    if not Grab_Reachable(P5, Move_Opts(1, 0)) then
        return false
    end
    if not Pick_Up(item) then
        Log('WARN', '吸盘1 未吸到(真空不到位，下降%gmm仍无)，跳过该物料', tostring(CFG.vacuum_max_dz))
        return false
    end
    Request_Rotate_Single((item.rot or 0) + CFG.cup1_place_rot_comp + 0, 1)
    Place_Part()
    Log('INFO', '物料抓取/放置完成')
    return true
end

function After_Grabbed_All()
    Set_Stage('等待继续')
    Safe_MovL(P8, Run_Opts())
    Wait_For_R3(COIL_R3_CONTINUE, 1, '等待R3继续')
    Wait_For_R3(COIL_R2_DUMPED, 1, '等待R2抛空')
    Wait_For_R3(COIL_R3_READY, 1, '等待R3就绪')
    Safe_MovL(P3, Move_Opts(1, 0, RUN_ACCEL, RUN_SPEED, 0))
end

local function Startup()
    Set_Stage('启动')
    Log(
        'INFO',
        '加载上料臂R1，版本=%s，投产开关=%s，真实流程完成=%s',
        TEMPLATE_VERSION,
        tostring(TEMPLATE_PRODUCTION_ENABLED),
        tostring(PRODUCTION_FLOW_IMPLEMENTED)
    )
    Validate_Config()
    Set_Stage('PLC连接')
    Call_Or_Error('PLC_Connet', PLC_Connet)
    Call_Or_Error('Restart_Peer_If_Needed', Restart_Peer_If_Needed)
    Call_Or_Error('Connect_R3', Connect_R3)
    Call_Or_Error('Open_Camera', Open_Camera)
    Require_Connection_Id()
    Safe_Set_Speed(HOME_SPEED)
    Safe_Return_Home()
    Init_IO('R1', id_r3)
    Check_Program_Number()
    Set_Stage('初始化握手')
    Safe_Out_Seg(SEG_PROGRAM_CONFIRMED)
    Safe_Wait_Seg(SEG_PROGRAM_CONFIRMED)
    Safe_Out_Seg(SEG_READY)
    Safe_Wait_Seg(SEG_INITIALIZED)
    Safe_Out_Seg(SEG_INITIALIZED)
    Safe_Wait_Seg(SEG_CYCLE_START)
    Log('INFO', '初始化完成')
    Require_Production_Ready()
    Safe_Set_Speed(RUN_SPEED)
    Set_Stage('入组同步')
    Join_As_Arm('R1')
end

local function Run_Cycles()
    while true do
        Runtime.cycle_no = Runtime.cycle_no + 1
        Set_Stage('等待周期启动')
        Safe_Reset_Elapsed_Time()
        local cycle_ok, cycle_error = xpcall(Production_Cycle, Traceback_Handler)
        if cycle_ok then
            Set_Stage('周期完成')
            Log('INFO', '周期结束，耗时=%s ms', tostring(Safe_Elapsed_Time()))
        elseif tostring(cycle_error):find('RESTART_CYCLE', 1, true) then
            Set_Stage('周期作废')
            Log('WARN', '三臂入组回卷，本周期作废并立即重入: %s', tostring(cycle_error))
        else
            error(cycle_error, 0)
        end
    end
end

local run_ok, fatal_error = xpcall(function()
    Startup()
    Run_Cycles()
end, Traceback_Handler)
if not run_ok then
    Set_Stage('故障停机')
    Log('ERROR', '程序异常，自动流程已停止: %s', tostring(fatal_error))
    if type(Pause) == 'function' then
        local pause_ok, pause_error = pcall(Pause)
        if not pause_ok then
            Log('ERROR', 'Pause 调用失败: %s', tostring(pause_error))
        end
    else
        Log('ERROR', 'Pause 函数不可用，脚本直接结束')
    end
end
