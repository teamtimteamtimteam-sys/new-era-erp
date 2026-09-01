-- TIDY-1(2026-09-01):**三道工序的【英文名】不是行业里的叫法。**
--
-- Tim 在 /processing/new 上看见的:
--     Automatic electrode line  →  Automatic foil separating line
--     Electrode powder line     →  Foil processing line
--     Battery powder line       →  Battery processing line
--
-- 【只改英文,中文一直是对的】自动极片线 / 极片粉料线 / 整电池粉料线 三个中文名
-- 未动一个字 —— 错的从来只有那一次翻译。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本迁移是 DML,不是 DDL】没有 CREATE / ALTER / DROP,只有三条 UPDATE。
-- operation_types 是 RUNTIME CONFIG:它的行是【数据】,不是结构。db/tables/ 下的
-- 那份镜像因此是"全新安装的默认值",与线上各写各的 —— 两边都要改,而且
-- **没有任何自动检查会在它们分家时报红**(下一段)。
--
-- ★★【这一刀最要紧的一句:gate 对这三行是【瞎的】】★★
-- db/check_mirrors.py:243 把 operation_types 归进 RUNTIME CONFIG,而 RUNTIME CONFIG
-- 表【不逐行比对线上】—— 同一个文件 268-272 行只断言"重放之后行数 > 0"。
-- 于是:镜像改了、线上没改(或者反过来),gate 照样是绿的。
-- **所以这一刀的证据不是"gate 绿",是应用之后对线上的一次 SELECT 重读。**
-- 这不是这三行的毛病,是一整类盲区(runtime-config 表的【内容】无人校验,
-- 只有"空不空"有人看),已按 TIDY-1 记进 docs/known-issues.md,与货币字面量、
-- 嵌入式查询、吞异常那几条盲区并列。**本刀不去扩检查器** —— 它是两处改名加一次普查。
--
-- 【形状守卫会在 UPDATE 上开火,而它会放行】trg_operation_types_shape 是
-- BEFORE INSERT OR UPDATE。这三行都是 transforming + resulting_safety_state_code IS NULL,
-- 本迁移不动 kind_code 也不动那一列,所以守卫读到的还是它一直放行的那个形状。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【code 一个字都不改 —— 这是一条裁定,不是一件没做完的事】
-- 改 code 会波及每一处引用(operation_type_input_forms / _output_forms /
-- _safety_states、processing_runs.operation_type_code、两张视图、
-- commit_processing_run 的四道闸);改一个显示标签【不该】波及任何东西。
-- 代价是 code 与英文名从此对不上(electrode_line 的名字里不再有 electrode)。
-- 那个错位写进了这三行自己的 notes —— 下一个人是在【库里】遇见这个 code 的,
-- 不是在一份他没打开的文档里。

BEGIN;

-- electrode_line:Automatic electrode line → Automatic foil separating line
UPDATE public.operation_types
   SET name_en = 'Automatic foil separating line'
 WHERE code = 'electrode_line';

-- 【幂等:注解只追加一次】重跑本迁移不会把这段话叠两遍。
UPDATE public.operation_types
   SET notes = notes || E'\n【TIDY-1(2026-09-01):code 与英文名【故意】对不上】英文名按行业叫法从 “Automatic electrode line” 改成 “Automatic foil separating line”,而 code 仍是 electrode_line。**Tim 的裁定:改 code 会波及每一处引用,改一个显示标签不该波及任何东西。**所以这个错位是一次【决定】,不是没人来得及改。中文名(自动极片线)一直是对的,未动。'
 WHERE code = 'electrode_line'
   AND notes NOT LIKE '%TIDY-1%';

-- electrode_powder_line:Electrode powder line → Foil processing line
UPDATE public.operation_types
   SET name_en = 'Foil processing line'
 WHERE code = 'electrode_powder_line';

-- 【幂等:注解只追加一次】重跑本迁移不会把这段话叠两遍。
UPDATE public.operation_types
   SET notes = notes || E'\n【TIDY-1(2026-09-01):code 与英文名【故意】对不上】英文名按行业叫法从 “Electrode powder line” 改成 “Foil processing line”,而 code 仍是 electrode_powder_line。**Tim 的裁定:改 code 会波及每一处引用,改一个显示标签不该波及任何东西。**所以这个错位是一次【决定】,不是没人来得及改。中文名(极片粉料线)一直是对的,未动。'
 WHERE code = 'electrode_powder_line'
   AND notes NOT LIKE '%TIDY-1%';

-- battery_powder_line:Battery powder line → Battery processing line
UPDATE public.operation_types
   SET name_en = 'Battery processing line'
 WHERE code = 'battery_powder_line';

-- 【幂等:注解只追加一次】重跑本迁移不会把这段话叠两遍。
UPDATE public.operation_types
   SET notes = notes || E'\n【TIDY-1(2026-09-01):code 与英文名【故意】对不上】英文名按行业叫法从 “Battery powder line” 改成 “Battery processing line”,而 code 仍是 battery_powder_line。**Tim 的裁定:改 code 会波及每一处引用,改一个显示标签不该波及任何东西。**所以这个错位是一次【决定】,不是没人来得及改。中文名(整电池粉料线)一直是对的,未动。'
 WHERE code = 'battery_powder_line'
   AND notes NOT LIKE '%TIDY-1%';

-- 【三条都必须命中一行】写错一个 code 会让 UPDATE 静默地改零行,
-- 而 gate 对这张表是瞎的,于是那次静默会一路活到 Tim 再看一次那个下拉框。
DO $$
DECLARE v_wrong int;
BEGIN
    SELECT count(*) INTO v_wrong
      FROM (VALUES
              ('electrode_line',        'Automatic foil separating line'),
              ('electrode_powder_line', 'Foil processing line'),
              ('battery_powder_line',   'Battery processing line')
           ) AS want (code, name_en)
      LEFT JOIN public.operation_types ot ON ot.code = want.code
     WHERE ot.code IS NULL OR ot.name_en IS DISTINCT FROM want.name_en;

    IF v_wrong > 0 THEN
        RAISE EXCEPTION 'TIDY1_LABELS_NOT_APPLIED|%', v_wrong
          USING HINT = '三条 UPDATE 里有没落到实处的 —— 本迁移整支回滚。gate 不会替你发现这件事。';
    END IF;
END $$;

COMMIT;
