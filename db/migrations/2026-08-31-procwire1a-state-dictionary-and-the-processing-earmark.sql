-- PROC-WIRE-1A:销售状态变字典(R5 的结构那一半)+ 工序投料指定(新的一条轴)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本刀最要紧的一条:它们是【两条轴】,不是一条】
--
-- 原 brief(R5)写的是"output_batches.state 变字典,并在里面加一个 INTERMEDIATE
-- 取值"。**盘问把它删掉了一半,而删掉的那一半是错的**:
--
--   `output_batches.state` 【不是】一条生命周期轴,它是一条【销售消耗】轴 ——
--   库存中 / 部分售出 / 已售罄,而且它由每一条销售路【机器写入】:
--   `CASE WHEN remaining_qty = 0 THEN '已售罄' ELSE '部分售出' END`
--   (record_output_sale · ship_order,两处逐字相同)。
--   docs/proc-reality.md 第 823 行早就写着:**三个全是销售状态,没有一个是质量结论。**
--
-- **把"这批货是干什么用的"压到那一列上,第一次被下游工序吃掉就会撞墙:**
-- 一批 100 kg 的正极片被极片粉料线吃光,`remaining_qty` 归零 ——
-- 它是【被用掉了】,不是【卖光了】。而那一列表示"没有了"的取值只有「已售罄」,
-- 那句话会凭空认下一笔从来没发生过的收入。要躲开它就得再造一个「已消耗」
-- 销售取值 —— **一个为了容纳非销售事实而被撑大的销售轴,就是这条设计的败笔。**
--
-- 【实测证据,不是推演】commit_processing_run 第 229 行的原话:
--   「FIN-25:产出批投料。state 是【销售状态】(表注),消耗不碰它 ——
--     只扣 remaining_qty」
-- 也就是说**今天线上就已经**存在"remaining_qty 归零而 state 仍是「库存中」"
-- 这个行形。两条轴分开之后它读得通;合成一条就读不通。
--
-- 所以本刀做两件事,而不是一件:
--   ① `state` 【原样】变字典 —— 结构变更,语义一个字不动(R5 活下来的那一半);
--   ② 「指定为下游工序投料」落在**它自己的**那条轴上(purpose_code)。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【为什么这条轴的活儿比 brief 想的窄 —— 而这是本刀最值钱的一条发现】
-- PROC-BUILD-1 已经把可售性挂在【形态】上(material_forms.may_be_sold),并且
-- 已经把电芯 / 已开壳电芯 / 负极片设成 false。**对这三种,本刀这条轴一点用都没有**
-- —— 它们今天就已经按名被拒了。
--
-- 真正剩下的那件事,是【形态可售、却又要往下走】的那些:`cathode_sheet`
-- 的种子注释自己写着「**它可以进极片粉料线,也可以卖**」。同一个形态,两种角色。
-- 于是这条轴的定义是:**这【一批】货被指定成下游工序的投料,所以它不是可售库存**
-- —— 一条【批次级】的指定,不是一句关于"这东西是什么"的断言。
--
-- **拒绝的措辞因此【不许】说"这个东西不许卖"** —— 对正极片那是假话,
-- 而 PROC-BUILD-1 为同一个区别已经付过一次账(SALE_FORM_NOT_SET 的表注)。
--
-- 【G29 的另一半仍然开着,不要读成关了】proc-reality.md 把 G29 记的是
-- 【质量暂扣 / 不合格状态】,本刀只用掉了它的"state 变字典"那句实现注解。
-- **质量暂扣与工序投料指定是【两条轴】,可以同时为真,永远不许并进一列。**
-- 依赖 G29 的两处:docs/known-issues.md:3547 与 docs/contract1-handover.md:186。
--
-- 幂等性:本迁移是一次性 DDL,不可重入(建表 + 换约束 + 加列)。
BEGIN;

-- ═══ 1 · 销售状态字典(R5 的结构那一半)═══════════════════════════════════
--
-- 【为什么码是中文】这一列今天存的【就是】这三个中文串,而且它们已经流到
-- 界面下拉、CSV 导出(机器可读的规范值)、outputQuery 的过滤白名单、
-- 以及两处销售函数的 CASE WHEN 里。**换码是一次语义/数据变更,而本刀被明令
-- 只做结构变更** —— 所以字典的主键【就是】既有的存储值,行为一个字不变。
CREATE TABLE public.output_batch_states (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.output_batch_states IS
'PROC-WIRE-1A:产出批次的【销售消耗】状态。RUNTIME CONFIG,加一种是加一行。

【它【只】回答一个问题:这一批卖掉了多少】不回答"这批货是干什么用的"
(那是 output_batches.purpose_code),也不回答"它合不合格"(G29 的另一半,仍然开着)。

【它由机器写,不由人写】record_output_sale 与 ship_order 两处逐字相同:
`CASE WHEN remaining_qty = 0 THEN 已售罄 ELSE 部分售出 END`。
建批次的界面上那个下拉是唯一的人工入口,而它只在建批次那一刻起作用。

【码是中文,这是刻意的】既有存储值就是这三个串,而它们已经流到界面、
CSV 导出、过滤白名单与两处销售函数里。本刀是结构变更,不是数据变更 ——
换码要动的是那六个地方,那是另一刀的事。

【本表【故意】没有规则列】loss_categories 有 metal_fate/is_true_loss,是因为
那两列【就是那张字典存在的理由】。这里不同:今天关于 state 的每一条行为
都是销售函数从 remaining_qty 【算】出来的,没有一条规则读这张表。
**凭空加一列规则等于替一个没有人裁定过的问题作答** —— 那正是 W2/F4 记过账的
那种污染。要加规则列,等到有一条真的读它的行为出现那天。';

INSERT INTO public.output_batch_states (code, name_en, name_zh, sort_order, notes) VALUES
    ('库存中',   'In stock',      '库存中',   1,
     '一克都还没卖出去。**注意它【不】意味着"这批货可以卖"** —— 可售性由形态(material_forms.may_be_sold)与用途(purpose_code)两条轴回答,不由这一列。'),
    ('部分售出', 'Partially sold', '部分售出', 2,
     '卖掉了一部分,还有余量。由销售函数写入。'),
    ('已售罄',   'Sold out',      '已售罄',   3,
     '**"卖光了",【不是】"没有了"。** 一批被下游工序吃光的投料,remaining_qty 同样归零,但它【不是】这个状态 —— 消耗不碰这一列(commit_processing_run)。这条区别正是本刀不把"工序投料"塞进这条轴的理由:塞进来就得再造一个「已消耗」取值,而那等于用一条销售轴去装一件非销售的事实。');

-- 换约束:CHECK → 外键。**取值集合一个字不变**,变的是"它由谁定义"。
ALTER TABLE public.output_batches DROP CONSTRAINT output_batches_state_check;
ALTER TABLE public.output_batches
    ADD CONSTRAINT output_batches_state_fkey
    FOREIGN KEY (state) REFERENCES public.output_batch_states (code);

-- ═══ 2 · 用途字典 —— 新的那条轴 ═══════════════════════════════════════════
CREATE TABLE public.output_batch_purposes (
    code              text PRIMARY KEY,
    name_en           text NOT NULL,
    name_zh           text NOT NULL,
    -- 【规则列】这个用途下的批次算不算【可售库存】。**这一列就是这张字典存在的理由**,
    -- 而且它是四条拒绝里第四条唯一读的东西 —— 加一个不可售的新用途是加一行,不是改代码。
    is_saleable_stock boolean NOT NULL,
    is_active         boolean NOT NULL DEFAULT true,
    sort_order        integer NOT NULL DEFAULT 0,
    notes             text
);

COMMENT ON TABLE public.output_batch_purposes IS
'PROC-WIRE-1A:这一【批】货是干什么用的。RUNTIME CONFIG,加一种是加一行。

【为什么它必须是【批次级】,而不是挂在形态上】可售性里"这东西本身许不许卖"
那一半,PROC-BUILD-1 已经挂在形态上了(material_forms.may_be_sold,法律说的是
这个东西物理上是什么)。**剩下的那一半挂不上去**:cathode_sheet 的种子注释
自己写着「它可以进极片粉料线,也可以卖」——【同一个形态,两种角色】,
而角色是这一批的事,不是这个物质的事。

【它与 state 是两条轴,不许合并】state 答"卖掉了多少",本列答"这批是干什么的"。
一批被工序吃光的投料 remaining_qty 归零而【不是】已售罄 —— 合成一条轴就必须
凭空造一个「已消耗」销售取值,那会认下一笔从来没发生过的收入。

【G29 的质量暂扣是【第三】条轴,同样不许并进来】一批货可以既是可售库存、
又在质量暂扣上;也可以既是工序投料、又不合格。三条轴可以同时为真。
G29 仍然开着,依赖它的两处:known-issues.md:3547、contract1-handover.md:186。';

COMMENT ON COLUMN public.output_batch_purposes.is_saleable_stock IS
'PROC-WIRE-1A:这个用途下的批次算不算可售库存。**false 的那些不是"不许卖的东西",
是"这一批已经许给下游工序了"** —— 区别在于前者没有旁路,后者【释放指定即可】。
第四条拒绝(SALE_BATCH_EARMARKED)只读这一列,所以将来多一种不可售用途是加一行。';

INSERT INTO public.output_batch_purposes (code, name_en, name_zh, is_saleable_stock, sort_order, notes) VALUES
    ('saleable_stock', 'Saleable stock', '可售库存', true, 1,
     '默认。今天线上每一批都是这一种,而这正是本列敢给默认值的理由 —— 它是【现状】,不是一个猜测。'),
    ('process_feed',   'Feed for a downstream operation', '下游工序投料', false, 2,
     '【本刀的那一行】这一批被指定成下游工序的投料,所以它不是可售库存。**它【不】说这个东西不许卖** —— 正极片就是可售的(may_be_sold = true),它只是这一批已经许给了粉料线。要卖它,把指定释放掉即可,这正是它与 SALE_FORM_NOT_SALEABLE 的分界:那一条没有旁路,这一条有。');

-- 【为什么这一列【给】默认值,而 PROC-BUILD-1 的 may_be_sold 【不给】】
-- 两者的空意思不同。may_be_sold 不给默认,是因为"加一个形态"是一次【裁定时刻】:
-- 法律许不许卖,必须当场回答,给了默认就等于替法律作答。
-- 而这一列的默认是【现状】:线上每一批今天都是可售库存,既有的每一条建批次路
-- (create_output_batch · commit_processing_run)也都在建可售库存。
-- 不给默认会当场拆掉那两扇门与每一份 fixture,而且拆完之后答案还是 saleable_stock。
-- **默认值合不合理,看的是"它是不是现状",不是"给不给默认"本身。**
ALTER TABLE public.output_batches
    ADD COLUMN purpose_code text NOT NULL DEFAULT 'saleable_stock'
    REFERENCES public.output_batch_purposes (code);

COMMENT ON COLUMN public.output_batches.purpose_code IS
'PROC-WIRE-1A:这一批是干什么用的 —— 可售库存,还是下游工序的投料。
**与 state 是两条轴**:state 答"卖掉了多少",本列答"这批是干什么的"。
**线上既有行全部落在 saleable_stock**,那不是一次数据迁移,那就是它们今天的样子
(Tim 裁定线上 20 批产出全是测试残留,本刀不动它们中的任何一批)。
"这批投料用完了没有"【不需要】本轴表示 —— remaining_qty = 0 已经把它说清楚了,
而且消耗路(commit_processing_run)本来就只扣 remaining_qty。';

-- ═══ 3 · 第四条拒绝 ═══════════════════════════════════════════════════════
--
-- 【判据的先后是刻意的:形态在前,指定在后】两条都成立时(比如一批被指定成
-- 投料的负极片),报【形态】那一条。理由:形态那条是法律,**没有旁路**;
-- 指定这条【释放即可】。先报可释放的那一条,等于教操作员去做一件
-- 做完了还是卖不掉的事 —— 一句真话放错顺序就成了一条假指引。
CREATE OR REPLACE FUNCTION public.assert_output_batch_saleable(p_output_batch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_material uuid;
    v_code     text;
    v_form     text;
    v_from_run boolean;
    v_axes     boolean;
    v_purpose  text;
    v_p_zh     text;
    v_p_en     text;
BEGIN
    SELECT ob.material_id, ob.code, m.form_code, ob.purpose_code
      INTO v_material, v_code, v_form, v_purpose
      FROM public.output_batches ob
      JOIN public.materials m ON m.id = ob.material_id
     WHERE ob.id = p_output_batch_id;

    IF NOT FOUND THEN
        RETURN;   -- 批次不存在不是本函数的题;既有的 OUTPUT_NOT_FOUND 管它。
    END IF;

    -- ① 形态已知且不可售 —— 与物料级同一条判据,同一个错误码。
    PERFORM public.assert_material_form_saleable(v_material);

    IF v_form IS NULL THEN
        -- ════════════════════════════════════════════════════════════════════
        -- 【空的意思由【种类】回答,不由人猜】—— 见文件头。
        -- 【JOIN 查不到 = 没有人记过种类,那【不是】"不适用"】—— 与 PROC-3 的
        -- guard_processing_input 立的那条同源:两边都让数据回答,而这一边的
        -- 默认方向相反(那边放行,这边拒),因为后果不同:那边防的是【停线】,
        -- 这边防的是【卖掉一件不许卖的东西】。
        -- ════════════════════════════════════════════════════════════════════
        SELECT mk.has_condition_axes INTO v_axes
          FROM public.materials m
          JOIN public.material_kinds mk ON mk.code = m.kind_code
         WHERE m.id = v_material;

        IF NOT FOUND OR v_axes IS TRUE THEN
            SELECT EXISTS (SELECT 1 FROM public.processing_outputs po
                            WHERE po.output_batch_id = p_output_batch_id)
              INTO v_from_run;

            -- 【这条不对称是刻意的,不要"修"平它】
            --   * 买进来的、以及这条轴之前就存在的料:照旧可售。空的意思是
            --     "这条轴比这行料还年轻"。拦掉它等于停掉线上每一笔销售,
            --     并且会教操作员随便填一个值去解锁 —— 那会毁掉这条轴本身。
            --   * 加工产出的料:拦。产线跑起来那天,一个从来没有人设过形态的
            --     产出批会悄悄变成可售,而且没有任何信号,**后果是法律上的**。
            --
            -- 【这条拒绝【不】说"这个东西不许卖"】—— 那是另一句话,而且会是假的。
            IF v_from_run THEN
                RAISE EXCEPTION 'SALE_FORM_NOT_SET|%', v_code
                  USING HINT = '这一批是加工产出的,而它的物料没有设形态,所以【判断不了】它可不可售。这【不是】说它不许卖。到【物料 → 打开这一种物料】把形态设上。';
            END IF;
        END IF;
    END IF;

    -- ② PROC-WIRE-1A:这一批已被指定为下游工序的投料 —— 于是它不是可售库存。
    --
    -- 【它必须是【第四句】,而不是前三句里任何一句的变体】
    --   SALE_FORM_NOT_SALEABLE = 这个东西法律上不许卖(没有旁路);
    --   SALE_FORM_NOT_SET      = 形态没设,所以【判断不了】(去把形态设上);
    --   库存类               = 数量不够(少卖点或换一批);
    --   本条                 = 这一批【许给了下游工序】(释放指定,或换一批)。
    -- 四句话四种下一步动作。**并成一句,操作员就不知道该做什么。**
    --
    -- 【措辞的红线】它【不许】说"这个东西不许卖" —— 对正极片那是假话
    -- (may_be_sold = true),而说假话的拒绝会教人去改一个根本没错的地方。
    SELECT p.name_zh, p.name_en INTO v_p_zh, v_p_en
      FROM public.output_batch_purposes p
     WHERE p.code = v_purpose
       AND p.is_saleable_stock IS FALSE;

    IF FOUND THEN
        RAISE EXCEPTION 'SALE_BATCH_EARMARKED|%|%|%', v_code, v_p_zh, v_p_en
          USING HINT = '这一批已被指定为下游工序的投料,所以它不算可售库存。这【不是】说这个东西不许卖 —— 要卖它,先到产出批次页把这个指定释放掉,或者改用另一批。';
    END IF;
END;
$function$;

-- ═══ 4 · 设定与释放的那扇门 ═══════════════════════════════════════════════
--
-- 【为什么是一扇 DEFINER 的门,而不是直接 UPDATE 那一列】
-- output_batches 的 UPDATE 策略要的是 module.output.edit(销售/库存侧的权限),
-- 而**把一批货许给产线是一个【工序】决定**。直接改列会让这件事落在错的权限上。
-- 门里要 module.processing.edit,与 loss_categories 同一条(那也是工序侧的配置)。
CREATE OR REPLACE FUNCTION public.set_output_batch_purpose(
    p_output_batch_id uuid,
    p_purpose_code    text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_code    text;
    v_deleted timestamptz;
    v_old     text;
BEGIN
    PERFORM public.require_permission('module.processing.edit');

    SELECT code, deleted_at, purpose_code INTO v_code, v_deleted, v_old
      FROM public.output_batches WHERE id = p_output_batch_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED|%', v_code;
    END IF;

    -- 【停用的用途不许再被指派上去,但既有的行不动】—— 与 is_active 在别处
    -- 的意思一致:停用是"以后别再选它",不是"把历史改掉"。
    IF NOT EXISTS (SELECT 1 FROM public.output_batch_purposes
                    WHERE code = p_purpose_code AND is_active) THEN
        RAISE EXCEPTION 'BATCH_PURPOSE_UNKNOWN|%', COALESCE(p_purpose_code, '(null)');
    END IF;

    UPDATE public.output_batches
       SET purpose_code = p_purpose_code,
           updated_by   = v_user,
           updated_at   = now()
     WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'code', v_code,
        'purpose_from', v_old,
        'purpose_to', p_purpose_code);
END;
$function$;

-- ═══ 5 · RLS 与授权 ═══════════════════════════════════════════════════════
-- 两张字典与既有字典同形:人人读得到(下拉要用),改要工序编辑权。
-- 【两张字典【分类不同】,而这不是随手放的】判据是 KPI-1 那条:
--   操作员在界面上改不改得动它?改不动 → INSTALL SEED(逐行比对);
--   改得动、而且改了系统照样正确工作 → RUNTIME CONFIG(只查引导非空)。
--
-- output_batch_states 是 INSTALL SEED:**加一个销售状态没有意义,因为没有东西会写它**
-- —— 那三个取值是 record_output_sale / ship_order 里的 CASE WHEN 算出来的,
-- 多一行只会得到一个永远为零行的状态。所以它【没有】写策略(写入只经迁移),
-- 并且进 check_mirrors 的 SEED_TABLES 逐行比对:线上多出一行就是真漂移。
ALTER TABLE public.output_batch_states ENABLE ROW LEVEL SECURITY;
CREATE POLICY "output_batch_states select all" ON public.output_batch_states
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.output_batch_states TO authenticated;

-- output_batch_purposes 是 RUNTIME CONFIG:**多一种不可售用途,加一行就够了** ——
-- 第四条拒绝读的是 is_saleable_stock 这一列,不是某个写死的码。改得动,而且
-- 改了系统照样正确工作,所以它有写策略,并进 RUNTIME_CONFIG_TABLES(只查引导非空)。
ALTER TABLE public.output_batch_purposes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "output_batch_purposes select all" ON public.output_batch_purposes
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "output_batch_purposes write by permission" ON public.output_batch_purposes
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.output_batch_purposes TO authenticated;

COMMIT;
