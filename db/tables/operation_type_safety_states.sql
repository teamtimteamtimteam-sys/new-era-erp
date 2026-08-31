-- db/tables/operation_type_safety_states.sql
-- PROC-WIRE-1B-i:这道工序【受理】哪些安全状态 —— **那个死锁的解**。
-- NOTE: introduced by db/migrations/2026-08-31-procwire1bi-operations-wired-and-the-discharge-deadlock.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.operation_type_safety_states (
    operation_type_code text NOT NULL REFERENCES public.operation_types (code) ON DELETE CASCADE,
    safety_state_code   text NOT NULL REFERENCES public.inbound_safety_states (code),
    -- 【这道工序把这个状态【解决掉】没有】深度放电解决 charged_not_discharged;
    -- 它受理 discharged_verified 但那个状态不需要被解决。
    -- 提交一张状态改变型加工单时,被解决的那些状态从批次上【删掉】,
    -- 再写上 resulting_safety_state_code —— 否则那批货会永远带着"未放电"。
    resolves            boolean NOT NULL DEFAULT false,
    notes               text,
    PRIMARY KEY (operation_type_code, safety_state_code)
);

COMMENT ON TABLE public.operation_type_safety_states IS
'PROC-WIRE-1B-i:这道工序【受理】哪些安全状态。**这张表是那个死锁的解。**

【它与 may_be_fed 的关系,一句话说清】may_be_fed 是【没有工序类型时】的答案,
也就是今天的行为;一旦加工单说出了自己是哪道工序,答案就换成这张表。

【不变式:只许收紧,不许默认放宽】
  * 没有工序类型 → may_be_fed,行为一个字不变;
  * 有工序类型 → **只有这张表里明写的才受理,没写的一律拒**,
    哪怕它 may_be_fed = true。
声明一道工序只会把闸收紧;任何放宽都必须是这里的一行【明写的数据】。
**"设了工序就放行"的实现,在 fixture 里是红的。**

【PROC-COST-1(R4):鼓包漏液已经有路线了】此前这里写着"swollen_leaking 一道工序
都没有受理……它等 Tim 的一句裁定"。裁定到了:**鼓包与漏液同一处置,走整电池粉料线**,
与 damaged_deformed 同形(resolves = false —— 料被粉碎掉,不是被治好)。
**深度放电仍然不受理它**:放电机解决不了起火风险。
加这一行是【逐工序的、明写的放宽】,那正是不变式允许的唯一放宽方式;
"按 kind 放行"的实现在 fixture 159 F2/F3 里仍然是红的。

【今天仍然一道工序都不受理的是 water_exposed(进过水)】那不是遗漏,是同一条
处置:它可能在干燥后可投,而那是一个判断,等一次裁定,不等一个猜测。';

-- 投料形态(R1:每道工序自己声明)

INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes) VALUES
    -- 【深度放电】唯一受理"未放电"的工序,而且它【解决】这个状态。
    ('deep_discharge', 'charged_not_discharged', true,
     '★ 这一行就是死锁的解:唯一受理"未放电"的地方,而且放完之后这个状态被【删掉】。'),
    ('deep_discharge', 'discharged_verified', false,
     '已经放过电的料再进一次放电机,无害 —— 受理,但没有什么要解决的。'),
    -- 【深度放电【不】受理任何损坏状态】Tim 的硬要求:放电机解决不了起火风险。
    -- 于是这里【故意】没有 damaged_deformed / water_exposed / swollen_leaking 三行。

    ('manual_disassembly', 'discharged_verified', false, NULL),
    ('electrode_line', 'discharged_verified', false, NULL),
    ('electrode_powder_line', 'discharged_verified', false, NULL),

    -- 【整电池粉料线】R2 明写它收"放不了电的整包/模组/3C/损坏电池" ——
    -- 所以它受理"未放电"与"变形损坏",而那正是它与极片粉料线是【两台设备】的理由。
    ('battery_powder_line', 'discharged_verified', false, NULL),
    ('battery_powder_line', 'charged_not_discharged', false,
     '【R2】它专收【放不了电】的料 —— 那种料按定义就是没放过电的。它不【解决】这个状态:料在这里被粉碎掉了,不是被放电了。'),
    ('battery_powder_line', 'damaged_deformed', false,
     '【R2】"损坏电池"。同上,不解决 —— 料被粉碎掉了。'),
    -- 【PROC-COST-1 / R4】这一行就是上面那段表注在等的裁定。
    ('battery_powder_line', 'swollen_leaking', false,
     '【R4,PROC-COST-1】Tim 裁定:鼓包与漏液同一处置,走整电池粉料线,与 damaged_deformed 同形。不解决 —— 料被粉碎掉了,不是被治好了。【深度放电仍然不受理它】:放电机解决不了起火风险(fixture 159 F3 钉着那一条)。');

ALTER TABLE public.operation_type_safety_states ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_safety_states select all" ON public.operation_type_safety_states
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "operation_type_safety_states write by permission" ON public.operation_type_safety_states
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_type_safety_states TO authenticated;
