-- db/tables/assay_results.sql
-- 化验单据:一行 = 一份实验室结果(或初检读数)对【一个批次】的含量断言。
--
-- 业务现实:货到在先,真实含量在后 —— 先按估计含量暂定计价,证书回来再按实际
-- 含量重算(apply_assay_result)。所以【记录与执行分开】:record_assay_result 只
-- 落这张表,不动批次;执行是显式动作,先能被人审阅。
--
-- PROC-1(2026-08-12):化验有两种父 —— 进料批或产出批,恰好一个
-- (num_nonnulls XOR,processing_inputs 的形状)。记录、编号、取代链共享;
-- 【应用拆开】:进料化验走 apply_assay_result(抄含量 + 重算应付),产出化验走
-- apply_output_assay(只抄含量 —— 产出批没有一张应付可以重述)。RLS 跟着父走:
-- 进料化验挂 module.inbound.*,产出化验挂 module.output.*。
--
--   * is_final 区分正式证书与初检/部分读数 —— 只有 is_final 的化验被执行后,
--     批次的 pricing_status 才升 'final'(仅进料侧;产出批没有定价状态);
--   * superseded_by 记录复验取代早先结果(链条保持可读;unapply 只许撤最新一环;
--     链按【父】各自成链 —— 进料链与产出链互不相扰);
--   * applied_at/by 是"已执行"标记 —— 执行时批次的含量表被替换为本化验的含量
--     (批次含量永远是当前最可信的真相),本行留作历史。
-- 无缝编号 'ASY-YYYY-NNNN':next_assay_code(),咨询锁串行化取号(同 JE/收付款);
-- 进料与产出化验共用一条序列 —— 化验单号是实验室视角的,不分进出。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut5a-assay-repricing.sql;
-- output parent by db/migrations/2026-08-12-proc1-output-assays.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.assay_results (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code             text NOT NULL UNIQUE,  -- gapless 'ASY-YYYY-NNNN'
    inbound_batch_id uuid REFERENCES public.inbound_batches (id),
    assay_date       date NOT NULL,
    lab_name         text REFERENCES public.laboratories (code),
    certificate_ref  text,
    sample_ref       text,
    is_final         boolean NOT NULL DEFAULT true,
    notes            text,
    applied_at       timestamptz,
    applied_by       uuid,
    superseded_by    uuid REFERENCES public.assay_results (id),
    deleted_at       timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid DEFAULT auth.uid(),
    -- PROC-1(ALTER 加列,留在末尾)
    output_batch_id  uuid REFERENCES public.output_batches (id),
    -- ── PROC-6 追加(ALTER 加的列排在末尾,与 attnum 顺序一致)────────────────
    weight_basis     text,
    moisture_pct     numeric,
    result_party     text NOT NULL,
    CONSTRAINT assay_results_one_parent
        CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1)
);

CREATE INDEX idx_assay_results_batch ON public.assay_results (inbound_batch_id);
CREATE INDEX idx_assay_results_output_batch ON public.assay_results (output_batch_id);

COMMENT ON COLUMN public.assay_results.output_batch_id IS
    'PROC-1:产出批父(与 inbound_batch_id 二选一,num_nonnulls = 1 —— processing_inputs 的形状)。挂产出批的化验由 apply_output_assay 应用:只抄含量、不动定价 —— 产出批没有一张应付可以重述。';

ALTER TABLE public.assay_results
    ADD CONSTRAINT assay_results_weight_basis_check
    CHECK (weight_basis IS NULL OR weight_basis IN ('as_received', 'dry'));
ALTER TABLE public.assay_results
    ADD CONSTRAINT assay_results_moisture_pct_range
    CHECK (moisture_pct IS NULL OR (moisture_pct >= 0 AND moisture_pct <= 100));
ALTER TABLE public.assay_results
    ADD CONSTRAINT assay_results_result_party_check
    CHECK (result_party IN ('ours', 'counterparty', 'umpire'));

-- PROC-6:基准必填,**只看 INSERT**(历史行会被 apply/unapply 例行改动,
-- 而 NOT VALID 会把它们冻死 —— PROC-5 为这件事付过账)。
CREATE TRIGGER trg_assay_results_basis_stated
    BEFORE INSERT ON public.assay_results
    FOR EACH ROW EXECUTE FUNCTION public.guard_assay_basis_stated();

CREATE TRIGGER trg_assay_results_updated_at
    BEFORE UPDATE ON public.assay_results
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.assay_results ENABLE ROW LEVEL SECURITY;
-- PROC-1:RLS 跟着父走 —— 守卫跟着数据自己的归属,不跟着功能建在哪个目录(OPS-15)
CREATE POLICY "assay_results select by permission"
    ON public.assay_results
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)));

CREATE POLICY "assay_results insert by permission"
    ON public.assay_results
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
             OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)));

CREATE POLICY "assay_results update by permission"
    ON public.assay_results
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)))
    WITH CHECK ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
             OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)));

CREATE POLICY "assay_results delete by permission"
    ON public.assay_results
    AS PERMISSIVE FOR DELETE TO authenticated
    USING ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)));

COMMENT ON COLUMN public.assay_results.lab_name IS
'PROC-5:指向 laboratories 那张字典(外键 assay_results_lab_name_fkey)。

【留空 = 没有人记过是哪家出的】那不是"我们自己做的" —— 若将来"自检"要成为一个
可记录的事实,它是字典里的一行,不是一个空值的含义。

【列名仍然叫 lab_name,而它现在存的是 code】与 PROC-4 留下的 metal → substance_code
同一族的名不副实。改名的代价见 docs/known-issues.md;它不挡路,所以不在本刀里付。';

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
