-- PROC-6:什么基准,谁的结果 —— 两件"事后再也重建不出来"的事实
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【S1 先答,因为它决定了本刀能用什么机制】
--
-- PROC-5 实测:**一条 NOT VALID 约束在【任何一次 UPDATE】上都重算整行**,
-- 于是 materials 的八行被冻住了。所以本刀开工前先问同一个问题:
-- **assay_results 的行写完之后会不会被 UPDATE?**
--
-- **会,而且是例行操作。** 逐条查过:
--   apply_assay_result   : `UPDATE assay_results SET superseded_by = …
--                           WHERE id = v_prior`  ← 改的是【上一份历史化验】
--   apply_output_assay   : 同形
--   unapply_assay_result : `UPDATE … WHERE superseded_by = p_assay_result_id`
--                           ← 同样是历史行
-- 也就是说:**只要有人对同一批货再化验一次,历史行就会被改。**
--
-- 【结论:NOT VALID 在这里是个陷阱,不能用】
-- 一条 NOT VALID 的 CHECK 会让"第一次复检"把所有旧化验单冻死。
-- 所以基准的必填【由一条 BEFORE INSERT 触发器执行】—— 它只看新行,
-- 对 UPDATE 一个字都不说,历史行因此既留空、又照样改得动。
--
-- 【而 result_party 用的是 NOT NULL,不是触发器 —— 这个不对称是刻意的(D3)】
-- 两者的区别不在机制,在【我们知不知道答案】:
--   * 基准:历史化验单是按湿基还是干基报的,**没有人知道**,也无从考证。
--     编一个值就是伪造一个可以被拿去算钱的事实 → 留空,新行必填。
--   * 出具方:历史化验单【全部是我们自己出的】,因为对手方那条路
--     **从来就不存在**。写 'ours' 是在陈述一个【已知事实】,不是编造。
-- **把这句话写在这里,是因为下一个读的人会看见两种做法,并以为其中一种做错了。**
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 一 · 重量基准 ───────────────────────────────────────────────────────────
ALTER TABLE public.assay_results ADD COLUMN weight_basis text;

ALTER TABLE public.assay_results
    ADD CONSTRAINT assay_results_weight_basis_check
    CHECK (weight_basis IS NULL OR weight_basis IN ('as_received', 'dry'));

COMMENT ON COLUMN public.assay_results.weight_basis IS
'PROC-6:这一份化验的含量数字是按【哪种重量】报的。

  as_received  收到时的重量(湿基)—— 含水一起称
  dry          烘干后的重量(干基)

【为什么这件事非记不可】同一批货,干基 30% 与湿基 30% 是【两个不同的数】,
差多少取决于水分。而一份没有说明基准的化验单,**事后没有任何办法把它还原** ——
出具它的人当时知道,三个月后没有人知道。PROC-0b 把这一条归为
"EXPENSIVE 正在变成 IMPOSSIBLE",说的就是这件事。

【为什么是 CHECK 而不是一张字典 —— 与前三刀【故意】不同】
PROC-1/2/4/5 把好几处清单做成了字典,而那些清单的共同点是:
**要么是自由文本(F7 的病),要么同一份清单被复制在好几张表上。**
这一条两样都不是:它是一个封闭的小集合,只出现在【一张表的一列】上。
更要紧的是 —— **加一种重量基准【不该】便宜。** 加一种金属是加一行,
因为那只是"我们又开始测一种元素";而加一种重量基准是【改变我们报数字的口径】,
它应当值一支迁移和一次对话。把它做成字典,等于把一个业务口径的变更
降格成一次随手的数据录入。

【第三种基准?本刀不发,理由说清楚】实验室行当里还有 air-dried(风干基)一类口径,
但**本仓库里没有任何证据说明我们这一行在用它**:线上零条基准数据,合同也还没有。
D5 的规矩是只发实际存在的 —— 编一个没人用的取值,会教下一个读它的人"这个在用"。
**返回条件:第一份写明按风干基结算的合同。** 那时它是一支两行的迁移。

【必填由触发器执行,不是 NOT VALID】理由在迁移抬头:
assay_results 的历史行会被 apply/unapply 改动,而 NOT VALID 会把它们冻死
(PROC-5 为这件事付过账,八行物料至今改不动)。
**触发器只看 INSERT** —— 新行必须说出基准,旧行留空且照样改得动。
**留空的意思是"没有人说过",不是"湿基"** —— 绝不要给它一个默认值。';

-- ── 二 · 水分 ───────────────────────────────────────────────────────────────
ALTER TABLE public.assay_results ADD COLUMN moisture_pct numeric;

ALTER TABLE public.assay_results
    ADD CONSTRAINT assay_results_moisture_pct_range
    CHECK (moisture_pct IS NULL OR (moisture_pct >= 0 AND moisture_pct <= 100));

COMMENT ON COLUMN public.assay_results.moisture_pct IS
'PROC-6:这一批货的水分(百分比)。**可空,而空【永远不是零】。**

【为什么这一条要单独写死在这里】一个乘数的单位元是【看不见的】:
把没测过的水分读成 0,`1 − 0` 会安安静静地算出一个**看起来完全合理的数**,
没有任何东西会报错。这个仓库已经为一模一样的形状付过账 ——
inbound_batch_metals 的含量:线上没有一行是真的零,而把 NULL 读成 0
会让"这批货一点镍都没有"成为一句系统亲口说的话。

**所以:任何一处读它的地方都不许 COALESCE 到 0。**
没测过就要在屏幕上、在报表里、在任何派生量里显示成【没测过】——
而不是显示成一个数字。干重推导在这一条上更危险:
没有水分就【推不出干重】,那时正确的行为是说"推不出来",不是当成湿的等于干的。

【它挂在哪一侧】今天只有进料化验用得上它(采购按到货湿重结算,PROC-0b 已定)。
不为它加"只能挂进料"的约束 —— 那是一条没有人要求过的规则,
而产出侧将来要不要报水分,是它自己的问题。';

-- ── 三 · 出具方 ─────────────────────────────────────────────────────────────
ALTER TABLE public.assay_results ADD COLUMN result_party text;

-- 【回填 'ours' —— 而这【不是】编造,与基准那一列的处置正好相反】
-- 对手方化验、仲裁化验这两条路【从来没有存在过】:界面里没有入口,
-- 函数里没有参数,线上零条记录。所以既有的每一份化验单都是我们自己出的,
-- 这是一个【可以被指出来的事实】,不是一个"没人决定过"的空白。
-- 对照 PROC-1:那里的 kind_code 留空,是因为"这一种物料是什么"从来没有人决定过,
-- 回填它就是替人做判断。两件事看起来都是"给旧行填值",本质相反。
UPDATE public.assay_results SET result_party = 'ours' WHERE result_party IS NULL;

ALTER TABLE public.assay_results
    ADD CONSTRAINT assay_results_result_party_check
    CHECK (result_party IN ('ours', 'counterparty', 'umpire'));
ALTER TABLE public.assay_results ALTER COLUMN result_party SET NOT NULL;

COMMENT ON COLUMN public.assay_results.result_party IS
'PROC-6:这一份化验结果是【谁出的】。

  ours          我们自己(或我们委托的实验室)
  counterparty  对手方(供应商或客户)出的
  umpire        仲裁实验室出的

【为什么它能 NOT NULL,而基准不能】既有的每一份化验单都是我们出的 ——
对手方与仲裁那两条路从来没有存在过(零入口、零记录),所以回填 ''ours''
是在陈述一个已知事实。而"历史化验单是按什么基准报的",**没有人知道**。
两列的处置不同,是因为我们对它们的知情程度不同,不是因为标准不一。

【没有默认值,这是刻意的】新行必须明说是谁出的。给它一个 ''ours'' 的默认,
等于让"忘了改"静静变成"这是我们测的"——而 D4 那条正是在防这件事。

【本刀【不】决定谁的结果算数】那是逐笔合同的条款(PROC-0b 的 U12),
要跟着已承诺条款那套机制走。这一列只记录【是谁出的】,不裁决【谁说了算】。';

COMMENT ON COLUMN public.assay_results.superseded_by IS
'指向【取代了本份结果的那一份】。含义是:"我们重新化验了,以那一份为准。"

【D4:对手方的结果【不是】对我们结果的取代 —— 不要用这一列去记它】
这个诱惑很明显:对手方报来一个不同的数字,顺手把我们的那份标成 superseded。
**那会静静地把我们自己测到的东西盖掉**,而两份结果本该【并存】:
一份是我们的,一份是对手方的,分歧本身就是要拿去谈的东西。
要记对手方的结果,就【新记一份化验单】并把 result_party 设成 ''counterparty'';
两份都留着、都读得出来。
**谁说了算是一个合同条款(PROC-0b 的 U12),不是一次 UPDATE。**';

-- ── 四 · 必填的那道闸:只看 INSERT ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_assay_basis_stated()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 【只在 INSERT 上说话】这一条是整个设计的关键,不是实现细节:
    -- assay_results 的历史行会被 apply/unapply 例行改动(改的是【别人】那一行:
    -- `WHERE id = v_prior`),而历史行【没有】基准也永远补不出来。
    -- 若这道判断也管 UPDATE,第一次复检就会把所有旧化验单冻死 ——
    -- 那正是 PROC-5 在 materials 上实测到的那一幕(八行至今改不动)。
    IF NEW.weight_basis IS NULL THEN
        RAISE EXCEPTION 'ASSAY_BASIS_REQUIRED|%', COALESCE(NEW.code, '(未编号)')
          USING HINT = '一份没有说明重量基准的化验单,事后没有任何办法还原它按的是湿基还是干基。在录入界面上选「收到时(湿基)」或「烘干后(干基)」。';
    END IF;
    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_assay_basis_stated() FROM PUBLIC, anon;

CREATE TRIGGER trg_assay_results_basis_stated
    BEFORE INSERT ON public.assay_results
    FOR EACH ROW EXECUTE FUNCTION public.guard_assay_basis_stated();

-- ── 五 · 唯一的写入口:三个新参数 ──────────────────────────────────────────
-- 【DROP + CREATE,不是 CREATE OR REPLACE】preflight 会拒绝签名变了的
-- CREATE OR REPLACE(那是重载,不是替换),而重载会留下一个镜像看不见的旧签名。
-- 【DROP + CREATE,不是 CREATE OR REPLACE】preflight 会拒绝签名变了的
-- CREATE OR REPLACE(那是重载,不是替换),而重载会留下一个镜像看不见的旧签名。
DROP FUNCTION public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid);

CREATE OR REPLACE FUNCTION public.record_assay_result(
    p_assay_date date,
    p_metals jsonb,
    p_lab_name text DEFAULT NULL::text,
    p_certificate_ref text DEFAULT NULL::text,
    p_sample_ref text DEFAULT NULL::text,
    p_is_final boolean DEFAULT true,
    p_notes text DEFAULT NULL::text,
    p_inbound_batch_id uuid DEFAULT NULL::uuid,
    p_output_batch_id uuid DEFAULT NULL::uuid,
    -- ── PROC-6 追加(尾部,带默认,与 PROC-2c 的做法一致)────────────────────
    -- 【两个都默认 NULL,而"必填"由别处执行】
    --   weight_basis  → 触发器(旧行补不出来,所以只管新行)
    --   result_party  → 本函数里具名拒绝 + 列上 NOT NULL 兜底
    -- 这里【不】给业务默认值:默认会让"忘了填"静静变成一个可以拿去算钱的答案。
    p_weight_basis text DEFAULT NULL::text,
    p_moisture_pct numeric DEFAULT NULL::numeric,
    p_result_party text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_el    jsonb;
    v_metal text;
    v_pct   numeric;
    v_seen  text[] := ARRAY[]::text[];
    v_count integer := 0;
BEGIN
    -- PROC-1:两个父【二选一】。记录、编号、取代共享一张表一条序列;
    -- 权限跟着父走 —— 进料化验挂 inbound 模块,产出化验挂 output 模块。
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'ASSAY_ONE_PARENT';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        PERFORM require_permission('module.inbound.edit');
        IF NOT EXISTS (
            SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
        END IF;
    ELSE
        PERFORM require_permission('module.output.edit');
        IF NOT EXISTS (
            SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
        END IF;
    END IF;
    IF p_assay_date IS NULL OR p_assay_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSAY_DATE_INVALID|%', COALESCE(p_assay_date::text, '?');
    END IF;
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    -- PROC-6:出具方必须明说。**在这里具名拒绝,而不是等列上的 NOT NULL 抛机器话** ——
    -- 一个具名码翻得成人话,一个 null-value violation 翻不成。
    IF p_result_party IS NULL THEN
        RAISE EXCEPTION 'ASSAY_RESULT_PARTY_REQUIRED'
          USING HINT = '这一份结果是我们出的、对手方出的、还是仲裁实验室出的?没有默认值 —— 默认会让"忘了改"变成"这是我们测的"。';
    END IF;

    v_code := next_assay_code(p_assay_date);
    INSERT INTO assay_results (id, code, inbound_batch_id, output_batch_id, assay_date, lab_name,
                               certificate_ref, sample_ref, is_final, notes,
                               weight_basis, moisture_pct, result_party,
                               created_by, updated_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_assay_date, p_lab_name,
            p_certificate_ref, p_sample_ref, p_is_final, p_notes,
            p_weight_basis, p_moisture_pct, p_result_party,
            v_user, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        -- 【PROC-6 顺手修的一处 PROC-4 漏网】这里原本写着
        --     v_metal NOT IN ('ni','co','li','mn','cu','al','fe')
        -- —— **那是那份金属清单的第九个副本**,而 PROC-4 声称已经清干净了。
        -- 它没有:PROC-4 的 S1 只查了 pg_constraint,【没有查函数体】。
        -- 线上实测函数体里还有四份(见 docs/known-issues.md),本刀只修它正在
        -- 重建的这一支 —— 另外三支按名排期,不在这一刀里顺手动。
        -- 现在它读字典,于是"加一种物质"真的只要一行。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;
        v_pct := (v_el->>'content_pct')::numeric;
        IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;
        INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
        VALUES (v_id, v_metal, v_pct);
        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'assay_result_id', v_id,
        'code', v_code,
        'metal_count', v_count
    );
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text) TO authenticated;

COMMIT;
