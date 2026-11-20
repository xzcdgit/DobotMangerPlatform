-- 版本：Lua 5.3.5
-- 泡罩线 · 上纸板主程序。
-- 回原、抓放、避让和生产循环在本文件；通信与监控在 global.lua。
--
-- 工艺动作节点（写保持寄存器 4100）在下方各 Set_Stage 处上报。
-- 控制器运行/停止/报警由上位机读系统触点，本脚本不冒充写入。

-- 回原：第1步抬升，第2步横移，第3步下降，第4步落到 P1。
function Check_Home()
    -- 104：安全回原（抬升→横移→落到 Home/P1）
    Set_Stage('安全回原')
    local home_point = Require_Point(P_HOME, 'Home 点') -- P1。
    local current_pose = GetPose() -- 当前笛卡尔位姿。
    if current_pose == nil or current_pose.pose == nil or home_point.pose == nil then
        Stop_For_Configuration('无法读取当前位姿或 P1.pose，禁止执行回原运动')
    end

    local current_x = current_pose.pose[1] -- 当前 X，单位 mm。
    local current_y = current_pose.pose[2] -- 当前 Y，单位 mm。
    local current_z = current_pose.pose[3] -- 当前 Z，单位 mm。
    local home_x = home_point.pose[1] -- P1 的 X。
    local home_y = home_point.pose[2] -- P1 的 Y。
    local home_safe_z = home_point.pose[3] -- P1 的安全高度。
    local travel_z = math.max(current_z, home_safe_z) -- 横移时使用的高度，不低于 P1。
    local lift_distance = travel_z - current_z -- 第1步要抬升的距离。
    local move_x = home_x - current_x -- 第2步的 X 位移。
    local move_y = home_y - current_y -- 第2步的 Y 位移。
    local descend_distance = home_safe_z - travel_z -- 第3步要下降的距离，高于 P1 时为负数。

    print(string.format('[回原] 当前=(%.3f, %.3f, %.3f)，P1安全高度=%.3f', current_x, current_y, current_z, home_safe_z))

    -- 第1步：只在当前 XY 垂直抬到安全高度，不斜着抬。
    if lift_distance > HOME_POSITION_EPSILON then
        print(string.format('[回原] 第1步：当前位置垂直抬升 %.3f mm 至 P1 安全高度', lift_distance))
        RelMovLUser({0, 0, lift_distance, 0, 0, 0}, MOTION_HOME_LIFT)
    end

    -- 第2步：在安全高度平移到 P1 的 XY。
    if math.abs(move_x) > HOME_POSITION_EPSILON or math.abs(move_y) > HOME_POSITION_EPSILON then
        print(string.format('[回原] 第2步：安全高度横移 X=%.3f mm, Y=%.3f mm', move_x, move_y))
        RelMovLUser({move_x, move_y, 0, 0, 0, 0}, MOTION_HOME_TRAVEL)
    end

    -- 第3步：到了 P1 上方后，垂直降到 P1 的高度。
    if descend_distance < -HOME_POSITION_EPSILON then
        print(string.format('[回原] 第3步：P1 上方垂直下降 %.3f mm', -descend_distance))
        RelMovLUser({0, 0, descend_distance, 0, 0, 0}, MOTION_HOME_DESCEND)
    end

    -- 第4步：精确落到 P1，并关闭两侧吸气、吹气。
    MovL(home_point, MOTION_HOME_FINAL)
    Set_Grip_Outputs(false, false, false, false)
    print('[回原] 已安全到达 P1(Home)，双吸气/双吹气已关闭')
end

-- 人工补料避让：离开料仓和放料工位，到避让点 P7。
function Robot_Move_To_Avoid()
    -- 251：人工补料（去避让点 P7；等 Seg15 也在同一节点内）
    Set_Stage('人工补料')
    print('[运动] 前往人工补料避让点 P7')
    Service_Mover_Handshake()
    MovJ(Require_Point(P_AVOID, '人工补料避让点'), MOTION_AVOID)
    print('[避让] 机械臂已进入人工补料安全避让位置')
end

-- 抓取：P2 → P3 吸料 → 真空确认/下探 → 抬回 P2 → 吸住后到 P4。
-- 说明：料仓 DI 有料才进入本函数；真空到位才算抓取成功，未到位则返回空表由上层转人工补料。
function Robot_Pick_Materials(sides)
    if #sides == 0 then
        print('[抓取] 无可用侧，跳过抓取（料仓 DI 未到位）')
        return {}
    end

    -- 抓之前确认左右放料点都有，避免吸起来后才发现去不了放料位。
    for _, side in ipairs(sides) do
        Require_Point(side.place_top, side.place_top_name)
        Require_Point(side.place, side.place_name)
    end

    -- 200：去抓取上方 P2
    Set_Stage('去抓取上方')
    print('[抓取] 料仓有料侧=' .. Side_List_Name(sides) .. '，前往抓取上方 P2')
    Service_Mover_Handshake()
    MovJ(Require_Point(P_PICK_TOP, '抓取上方点(共用)'), MOTION_PICK_TOP)

    -- 204：下降到抓取点 P3 并开吸
    Set_Stage('下降抓取')
    print('[抓取] 低速下降到抓取点 P3，准备开吸')
    Service_Mover_Handshake()
    MovL(Require_Point(P_PICK, '抓取点(共用)'), MOTION_PICK_DOWN)

    print('[抓取] 同时激活吸盘：' .. Side_List_Name(sides))
    Set_Grip_State(sides, nil)

    -- 205：真空确认（不到位则下探，最多 GRIP_MAX_PROBE_MM）
    Set_Stage('真空确认')
    print('[抓取] 真空确认：到位则抓取成功；未到位则下探，仍无则本轮不抓')
    local picked_sides = {}
    for probe_depth = 0, GRIP_MAX_PROBE_MM do
        Wait(GRIP_CHECK_DELAY_MS)
        Service_Mover_Handshake()
        print('[抓取] 当前下探深度=' .. probe_depth .. ' mm，检查各侧真空 DI')
        picked_sides = Sides_With_Vacuum(sides)

        if #picked_sides == #sides then
            print('[抓取] 真空到位，抓取成功：' .. Side_List_Name(picked_sides))
            break
        end
        if probe_depth >= GRIP_MAX_PROBE_MM then
            print('[抓取] 已达最大下探 ' .. GRIP_MAX_PROBE_MM .. ' mm，真空仍未全部到位')
            break
        end

        print('[抓取] 尚有 ' .. (#sides - #picked_sides) .. ' 侧真空未到位，向下探 ' .. GRIP_PROBE_STEP_MM .. ' mm')
        RelMovLUser(OFF_GRIP_PROBE_DOWN, MOTION_PICK_PROBE)
    end

    Close_Missed_Suction(sides, picked_sides)

    -- 206：抬回抓取上方 P2
    Set_Stage('取料抬起')
    print('[抓取] 抬回抓取上方 P2')
    Service_Mover_Handshake()
    MovL(Require_Point(P_PICK_TOP, '抓取上方安全点'), MOTION_PICK_UP)

    -- 真空未到位：不抓取，停在 P2，返回空表
    if #picked_sides == 0 then
        print('[抓取] 真空未到位，不抓取；关闭气路，交上层转人工补料')
        Set_Grip_Outputs(false, false, false, false)
        return {}
    end

    -- 210：去过渡点 P4（取料区→放料区）
    Set_Stage('去过渡点')
    print('[抓取] 真空到位已抓取 ' .. #picked_sides .. ' 件：' .. Side_List_Name(picked_sides) .. '，前往过渡点 P4')
    Service_Mover_Handshake()
    MovJ(Require_Point(P_TRANS, '过渡点'), MOTION_PICK_TRANS)
    return picked_sides
end

-- 放一件：去放料上方 → 等动子 → 下降吹气 → 抬起 → 放行动子。
function Robot_Place_Material(side, held_sides)
    -- 252：去该侧放料上方（左 P5 / 右 P8），与 P4 过渡点分开报
    Set_Stage('去放料上方')
    print('[放料] 前往' .. side.place_top_name .. '（放料上方，尚未下降）')
    Service_Mover_Handshake()
    MovJ(Require_Point(side.place_top, side.place_top_name), MOTION_PLACE_TOP)

    -- 181：已在放料上方，发 Seg2，等 EAP Seg3=动子到位
    Finish_Mover_Handshake() -- 上一件的 Seg4/5/0/2 握手必须走完，才能发新的 Seg2
    Set_Stage('放料上方等动子')
    print('[放料] ' .. side.name .. '已在放料上方，输出 Seg2，等待动子到位 Seg3')
    Out_Seg(SEG_WAIT_MOVER, false)
    Wait_Seg(SEG_MOVER_READY)
    print('[放料] ' .. side.name .. '动子已到位(Seg3)，开始下降放料')

    -- 212：下降到放料点（左 P6 / 右 P9）
    Set_Stage('下降放料')
    print('[放料] 直线下降到' .. side.place_name)
    Service_Mover_Handshake()
    MovL(Require_Point(side.place, side.place_name), MOTION_PLACE_DOWN)

    -- 213：关吸开吹松开
    Set_Stage('松开')
    print('[放料] ' .. side.name .. '吸气关闭，吹气打开（松开）')
    Set_Grip_State(held_sides, side)

    Wait_And_Close_Blow_Channel(side)

    print('[放料] 直线抬回' .. side.place_top_name)
    MovL(Require_Point(side.place_top, side.place_top_name), MOTION_PLACE_UP)

    -- 184：发 Seg4 请求动子放行
    Set_Stage('放行动子')
    print('[放料] ' .. side.name .. '放料完成，输出 Seg4 请求动子放行')
    Out_Seg(SEG_NOTIFY_MOVER_LEAVE, false)
    if OVERLAP_MOVER_HANDSHAKE then
        -- 不原地等：Seg5 → Seg0 → Seg2 在后续动作间隙推进，下一次发 Seg2/10/14 前再兜底。
        mover_handshake_state = HANDSHAKE_WAIT_GONE
        return
    end
    Wait_Seg(SEG_MOVER_GONE)
    print('[放料] ' .. side.name .. '动子放行完成(Seg5)')

    print('[放料] ' .. side.name .. '输出 Seg0 复位，等待 EAP 回 Seg2')
    Out_Seg(SEG_CYCLE_DONE, false)
    Wait_Seg(SEG_WAIT_MOVER)
end

-- 人工补料：关气 → P7 避让 → Seg14，等到 Seg15。
function Manual_Refill_Flow(reason)
    -- 251：人工补料整段（避让+等待补料完成）
    Set_Stage('人工补料')
    print('[人工补料] 原因=' .. reason .. '，关气并移至避让位 P7，再等 EAP Seg15')
    Set_Grip_Outputs(false, false, false, false)

    Robot_Move_To_Avoid()

    Finish_Mover_Handshake() -- 放料握手未完成时不能发 Seg14
    print('[人工补料] 输出 Seg14，持续等待 EAP Seg15=补料完成')
    Out_Seg(SEG_WAIT_REFILL, false)
    Wait_Seg(SEG_REFILL_OK)
    print('[人工补料] 收到 Seg15，补料完成，将重新检查料仓 DI')
end

-- 左右料仓均无料：发 Seg10 请求 EAP 托举料仓；到顶则转人工补料。
function Bin_Rise_Flow()
    Finish_Mover_Handshake() -- 放料握手未完成时不能发 Seg10
    -- 250：料仓托举（与人工补料 251 分开）
    Set_Stage('料仓托举')
    print('[料仓] 左右料仓 DI 均无料，输出 Seg10 请求托举（非人工补料）')
    ::bin_rise_retry::
    Out_Seg(SEG_BIN_RISE, false)
    print('[料仓] 等待 EAP：Seg11=托举成功，Seg13=已到最高位需人工补料')

    local eap_seg
    repeat
        eap_seg = GetHoldRegs(id, REG_SEG_IN, SEG_REG_COUNT, 'F64')
        Wait(SEG_POLL_MS)
    until math.abs(eap_seg[1] - SEG_BIN_RISE_OK) < SEG_MATCH_EPSILON or
        math.abs(eap_seg[1] - SEG_BIN_OVER) < SEG_MATCH_EPSILON
    print('[料仓] 收到 EAP 回传 Seg=' .. eap_seg[1])

    if math.abs(eap_seg[1] - SEG_BIN_OVER) < SEG_MATCH_EPSILON then
        print('[料仓] 已到最高位，转入人工补料流程')
        Manual_Refill_Flow('料仓已到最高位')
        return
    end

    local sides = Select_Available_Sides()
    if #sides > 0 then
        print('[料仓] 托举成功，检测到有料：' .. Side_List_Name(sides) .. '，回到循环准备抓取')
        return
    end

    print(
        '[料仓] 托举后仍无料，输出 Seg(' ..
            SEG_BIN_RISE_RETRY .. ')，等待 Seg(' .. SEG_BIN_RISE_RETRY_ACK .. ') 后重新请求 Seg10'
    )
    Out_Seg(SEG_BIN_RISE_RETRY, false)
    Wait_Seg(SEG_BIN_RISE_RETRY_ACK)
    goto bin_rise_retry
end

-- 一轮生产：查料仓 DI → 有料则抓放；无料则托举。
-- 料仓检测不单独报动作码：有料→进入抓取（真空到位才算抓到）；无料→料仓托举。
function Production_Cycle()
    print('[生产循环] === 新一轮：读料仓 DI，决定抓取或托举 ===')
    local sides = Select_Available_Sides()
    if #sides == 0 then
        print('[生产循环] 料仓 DI 未到位(左右皆无料) → 不抓取，走料仓托举')
        Bin_Rise_Flow()
        return
    end

    print('[生产循环] 料仓 DI 有料：' .. Side_List_Name(sides) .. ' → 进入抓取；真空到位才抓取成功，未到位则人工补料')
    local picked_sides = Robot_Pick_Materials(sides)
    if #picked_sides == 0 then
        print('[生产循环] 真空未到位，不抓取 → 人工补料')
        Manual_Refill_Flow('所有选中吸盘下探 ' .. GRIP_MAX_PROBE_MM .. ' mm 后真空仍未建立')
        return
    end

    local held_sides = {}
    for _, side in ipairs(picked_sides) do
        table.insert(held_sides, side)
    end
    for i, side in ipairs(picked_sides) do
        print('[生产循环] 第 ' .. i .. '/' .. #picked_sides .. ' 件放料：' .. side.name)
        Robot_Place_Material(side, held_sides)
        Remove_Side(held_sides, side)
    end
    -- 187：本轮抓放完成
    Set_Stage('周期完成')
    print('[生产循环] 本轮抓放完成')
end

-- 第1步：连接 PLC。
PLC_Connet()

-- 第2步：降速回 Home。
SpeedFactor(SPEED_RETURN)
print('[初始化] 已连接 PLC，加载示教点并以低速回 Home')
Map_Teach_Points()
Check_Home()

-- 第3步：恢复生产速度。
SpeedFactor(SPEED_FACTOR_RUN)
print('[初始化] 已回 Home，生产速度倍率=' .. SPEED_FACTOR_RUN)

-- 第4步：程序号 + Seg 初始化，等到 Seg2。
Prepare_Production()

-- 第5步：循环生产。
while true do
    local ok, err = pcall(Production_Cycle)
    if not ok then
        local err_text = tostring(err)
        if err_text:find('Dobot_Lua_Script_Normal_Exit', 1, true) then
            -- 硬停/停止键通常来不及写寄存器；停机态由上位机读触点「运行状态」
            print('[提示] 脚本被停止或正常退出: ' .. err_text)
            Set_Grip_Outputs(false, false, false, false)
            break
        end
        Report_Process_Fault(919, err_text)
        print('[严重错误] 生产循环异常: ' .. err_text)
        Set_Grip_Outputs(false, false, false, false)
        Wait(CYCLE_ERROR_WAIT_MS)
    end
end
