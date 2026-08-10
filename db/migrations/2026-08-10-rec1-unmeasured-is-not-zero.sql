-- REC-1:回收率表里的 0 有两种,现在分得开 —— 【测出来是零】与【根本没测】
--
-- 走查:Cobalt 投入 0 kg、产出 40 kg。查明 PROC-2026-0164 消耗的 IN-2026-0001
-- 只做过一次化验、只测了 cu —— 钴【从未在投入侧被测过】。这不是守恒被破坏,
-- 是测量缺口(Tim 的判定):没测的金属出现在产出侧是家常便饭,拿它去拦收货/投产
-- 会把一次正当作业挡在门外。
--
-- 【真正的缺陷是那个 0】视图此前写着 COALESCE(i.input_metal_kg, 0):FULL JOIN 给出
-- 的 NULL(= 这一侧没有这个金属的任何测量)被就地压成数字 0(= 测了,含量为零)。
-- 两者导向【相反】的结论:前者说"回收率无从谈起",后者说"无中生有,真有异常"。
-- 页面那句 `r.input_metal_kg ?? '—'` 因此是一条永远走不到的死分支。
-- 与 ASY-2 的应付比例列同一个病:数据里分得开,输出行把它丢了。
-- 【线上此刻没有任何一行 content_pct = 0】—— 所以屏幕上每一个"投入 0"都是"没测",
-- 而视图把它们全说成了"测出来是零"。
--
-- 修法:NULL 一路活到界面,并把"为什么算不出回收率"变成【一个可枚举的原因】,
-- 而不是让页面从数字反推(反推正是当初把两件事混在一起的原因)。
--   input_measured / output_measured  —— 这一侧到底有没有这个金属的测量
--   recovery_blocked_by               —— 'input_not_measured' / 'output_not_measured'
--                                        / 'input_measured_zero'(界面据此说人话)
--   conservation_warning              —— 【两侧都测了】且产出 > 投入:真信号
--                                        (投错批、产出录错、污染),但【永远只是提示】
--   run_recovery_computable           —— 本单有没有【任何一个】金属算得出回收率;
--                                        全靠投入侧从未化验的单子据此明说"本单回收率
--                                        无从计算",而不是摆一桌 0 和横杠。
--
-- 【为什么守恒不能是硬闸】两条结构性理由,都不是口味问题:
--   ① 没测过的投入【没有可守恒的对象】—— 拿 0 当基准就是拿"没测"当"没有";
--   ② 产出的金属含量是【提交之后】才由人在产出批上录的,提交那一刻通常还不存在,
--      所以它天然不是 commit_processing_run 能把的关(重量守恒能把,是因为两边的
--      重量都是提交载荷里的必填项 —— 见该函数的 OUTPUT_EXCEEDS_INPUT)。
-- 元素守恒因此是【数据完整性问题穿着校验问题的衣服】,这一刀只让它可见。
--
-- 【预防那一半在别处,已经存在】看板的 awaiting_assay 支(assay_count = 0)负责
-- "收了货还没化验"——【那是能救的时刻】。投产之后再报无从补救,所以本刀
-- 不加任何看板支(Tim 的答复:后果要看得见,但不是加一盏没人能关掉的灯)。
-- 那支自身的两处缺口在 docs/dashboard-arm-inventory.md 里记了,不在本刀动它。
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

-- 【先 DROP 后 CREATE】新列要插在中间(input_measured 紧挨着 input_metal_kg 才读得懂),
-- 而 CREATE OR REPLACE VIEW 只能在末尾追加。已核对:库内没有任何视图/函数依赖它,
-- 唯一的读者是加工单详情页 —— 所以这里 DROP 是安全的(与 INV-1b 那次相反,
-- 那张视图底下挂着 ar_open_items 与 invoice_status,只能追加)。
DROP VIEW public.processing_metal_recovery;

CREATE VIEW public.processing_metal_recovery WITH (security_invoker = off) AS
WITH ins AS (
    SELECT pi.run_id, m.metal,
           SUM(pi.quantity_consumed * m.content_pct / 100.0) AS input_metal_kg
    FROM public.processing_inputs pi
    JOIN LATERAL (
        SELECT ibm.metal, ibm.content_pct
        FROM public.inbound_batch_metals ibm
        WHERE ibm.inbound_batch_id = pi.inbound_batch_id
        UNION ALL
        SELECT obm.metal, obm.content_pct
        FROM public.output_batch_metals obm
        WHERE obm.output_batch_id = pi.output_batch_id
    ) m ON true
    GROUP BY pi.run_id, m.metal
),
outs AS (
    SELECT po.run_id, obm.metal,
           SUM(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg
    FROM public.processing_outputs po
    JOIN public.output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
    GROUP BY po.run_id, obm.metal
)
SELECT r.id            AS run_id,
       r.code          AS run_code,
       r.process_date,
       COALESCE(i.metal, o.metal) AS metal,
       -- 【不再 COALESCE 成 0】NULL = 这一侧从未测过这个金属;0 = 测了,含量为零
       i.input_metal_kg,
       o.output_metal_kg,
       (i.metal IS NOT NULL) AS input_measured,
       (o.metal IS NOT NULL) AS output_measured,
       CASE WHEN i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0
            THEN round(o.output_metal_kg / i.input_metal_kg * 100, 2)
       END AS recovery_pct,
       -- 算不出的【原因】由这里说定,不让界面从数字反推
       CASE WHEN i.metal IS NULL           THEN 'input_not_measured'::text
            WHEN o.metal IS NULL           THEN 'output_not_measured'::text
            WHEN i.input_metal_kg = 0      THEN 'input_measured_zero'::text
       END AS recovery_blocked_by,
       -- 【两侧都测了】才谈得上守恒。产出 > 投入是真信号:投错批 / 产出录错 /
       -- 污染。投入测出来是零而产出有量,同样落在这里 —— 那正是"无中生有"。
       (i.metal IS NOT NULL AND o.metal IS NOT NULL
        AND o.output_metal_kg > i.input_metal_kg) AS conservation_warning,
       -- 本单是否【至少有一个】金属算得出回收率(界面据此对整单说人话)
       bool_or(i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0)
           OVER (PARTITION BY r.id) AS run_recovery_computable
FROM ins i
FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
JOIN public.processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
WHERE r.status = 'committed' AND r.deleted_at IS NULL
  AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_metal_recovery IS
    '每个已提交加工单 × 金属的回收率(REC-1 起区分【测出来是零】与【根本没测】)。input_metal_kg / output_metal_kg 为 NULL 表示那一侧从未测过这个金属 —— 不再压成 0,因为两者导向相反的结论。recovery_blocked_by 说明算不出的原因;conservation_warning 只在两侧都测过、且产出大于投入时为真,它【永远只是提示】:没测过的投入没有可守恒的对象,而产出含量往往在提交之后才录入,所以元素守恒天然不是提交时能把的闸(重量守恒能把,因为两边都是提交载荷的必填项)。';

COMMIT;
