-- src0.lua  上料臂 R2（192.168.5.80）
-- 只保留运动和 Main。参数和运动选项在 global.lua。

local function Safe_Return_Home()
    Set_Stage('安全回原')
    Log('INFO', '开始安全回原')
    local cur = GetPose(0, 0)
    local x, y, z = cur.pose[1], cur.pose[2], cur.pose[3]
    local opts = Home_Opts()
    if y < HOME_Y_LIMIT then
        Log('INFO', 'y=%s < %s，垂直抬升到 P6.z(%s) 再回 Home', tostring(y), tostring(HOME_Y_LIMIT), tostring(P6.pose[3]))
        Safe_MovL(Keep_Pose(cur, x, y, P6.pose[3]), opts)
        Safe_MovL(P1, opts)
    elseif x < HOME_X_LIMIT then
        Log('INFO', '经抛盘过渡点 P10 回 Home')
        Safe_MovL(Keep_Pose(cur, x, y, P1.pose[3]), opts)
        Safe_MovJ(P10, opts)
        Safe_MovL(P1, opts)
    else
        if z < P1.pose[3] then
            Safe_MovL(Keep_Pose(cur, x, y, P1.pose[3]), opts)
        end
        Safe_MovJ(P1, opts)
    end
    Log('INFO', '已回到 P1/Home')
end

-- 下降吸取并抬升。lock_pt 用相机点的 x/y 做互锁。失败时已松锁，返回 false。
local function Pick_Up(lock_pt, point, descend_opts)
    Grab_Lock_Acquire('R2', lock_pt)
    Safe_MovL(Pose_With_Z(point, CFG.grab_above_dz), Move_Opts(1, 0))
    Safe_MovL(point, descend_opts)
    Set_Suck(true)
    Set_Blow(false)
    Wait(CFG.wait_pick_settle)
    if not Attain_Vacuum(CFG.di_vacuum_1) then
        Set_Suck(false)
        Grab_Lock_Release('R2')
        return false
    end
    Safe_Slow_Lift(CFG.lift_dz)
    Grab_Lock_Release('R2')
    return true
end

local function Release_And_Lift(settle_ms)
    Set_Suck(false)
    Set_Blow(true)
    Wait(settle_ms)
    Safe_RelMovLUser({0, 0, CFG.lift_dz, 0, 0, 0})
    Set_Blow(false)
end

function Grab_One_And_Place(item)
    Set_Stage('抓取物料')
    Overwrite_Pose(P5, item)
    if not Grab_Reachable(P5, Move_Opts(1, 0)) then
        return false
    end
    if not Pick_Up(item, P5, Pick_Opts()) then
        Log('WARN', '吸盘1 未吸到(真空不到位，下降%gmm仍无)，跳过该物料', CFG.vacuum_max_dz)
        return false
    end
    Request_Rotate_Single((item.rot or 0) + CFG.cup1_place_rot_comp, 1)
    Safe_MovL(P4, Run_Opts())
    Safe_MovL(P6, Run_Opts())
    Wait_Mover_OK('动子质量=%s(期望10)，NG：不放料，停在放料上方等待下一组动子')
    Safe_MovL(P14, Place_Opts())
    Release_And_Lift(CFG.place_release_settle)
    Safe_MovL(P4, Run_Opts())
    Seg_Close()
    Log('INFO', '物料抓取/放置完成')
    return true
end

local function Throw_Tray()
    local slow = {a = TRAY_LIFT_ACCEL, v = TRAY_LIFT_SPEED, cp = TRAY_LIFT_CP}
    local back = {a = TRAY_BACK_ACCEL, v = TRAY_BACK_SPEED, cp = RUN_CP}
    local cur = GetPose(0, 0)
    Safe_MovL(Keep_Pose(cur, cur.pose[1], cur.pose[2], P10.pose[3]), Move_Opts(0, 0, slow.a, slow.v, slow.cp))
    Grab_Lock_Release('R2')
    Safe_MovL(P10, Run_Opts(), slow)
    Safe_MovJ(P11, Run_Opts(), slow)
    Safe_MovL(P12, Run_Opts(), slow)
    Set_Suck(false)
    Set_Blow(true)
    Wait(CFG.tray_release_settle)
    Set_Blow(false)
    Safe_MovL(P11, Run_Opts(), back)
    Safe_MovJ(P10, Run_Opts(), back)
    Safe_MovL(P3, Move_Opts(1, 0, RUN_ACCEL, RUN_SPEED, 0))
end

local function Grab_And_Dump_Tray(tray_item)
    Set_Stage('取放托盘')
    Overwrite_Pose(P9, tray_item)
    Grab_Lock_Acquire('R2', tray_item)
    Safe_MovL(Pose_With_Z(P9, CFG.grab_above_dz), Move_Opts(1, 0))
    Safe_MovL(P9, Move_Opts(1, 0))
    Set_Suck(true)
    Set_Blow(false)
    Wait(CFG.wait_pick_settle)
    if not Attain_Vacuum(CFG.di_vacuum_1) then
        Set_Suck(false)
        Grab_Lock_Release('R2')
        Log('WARN', '料盘未吸到，跳过本次抛盘，仍上报抛空以免堵住 R3')
        return false
    end
    Throw_Tray()
    Log('INFO', '托盘取放/抛空完成')
    return true
end

function After_Grabbed_All(tray_item)
    Set_Stage('抛空托盘')
    Safe_MovL(P8, Run_Opts())
    Wait_For_R3(COIL_R3_CONTINUE, 1, '等待R3继续')
    if tray_item then
        Grab_And_Dump_Tray(tray_item)
    end
    Set_Coil(id_r3, COIL_R2_DUMPED, 1)
    Wait_For_R3(COIL_R3_READY, 1, '等待R3就绪')
end

local function Startup()
    Set_Stage('启动')
    Log('INFO', '加载上料臂R2，版本=%s', TEMPLATE_VERSION)
    Validate_Config()
    Set_Stage('PLC连接')
    Call_Or_Error('PLC_Connet', PLC_Connet)
    Call_Or_Error('Restart_Peer_If_Needed', Restart_Peer_If_Needed)
    Call_Or_Error('Connect_R3', Connect_R3)
    Call_Or_Error('Open_Camera', Open_Camera)
    Require_Connection_Id()
    Safe_Set_Speed(HOME_SPEED)
    Safe_Return_Home()
    Init_IO('R2', id_r3)
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
    Join_As_Arm('R2')
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
            Log('WARN', '三臂回卷，重新入组: %s', tostring(cycle_error))
            Join_As_Arm('R2')
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
        pcall(Pause)
    end
end
