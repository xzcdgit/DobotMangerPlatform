-- src1.lua  旋转线程
-- 与 src0 并行。只下发旋转机构脉冲，不调用运动指令，不改 src0 轨迹。
-- 取料抬升后 src0 写角度寄存器 5678 并置线圈 5666，本线程看到后执行 RotatingMachineControl。

print('[旋转] src1 线程启动')
Rotate_Thread_Main()
