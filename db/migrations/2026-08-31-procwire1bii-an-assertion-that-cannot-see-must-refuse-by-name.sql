-- PROC-WIRE-1B-ii(2026-08-31):看不见就【按名拒绝】;产出料也要被问同一个安全问题;
--                              在制品看得见;而"不适用"不再冒充"没测"
--
-- 四件事一刀,顺序不是随手排的:**第 2 步是安全项,写在最前面**,于是万一后面
-- 任何一步卡在一次拿不到的裁定上,它可以单独提交(Tim 的 A1 明写了这条退路)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【一、这一刀纠正了三条【我自己的 brief 里写错的】前提 —— 逐条记下来,
--       因为按错的那一条去修,会修出一个看起来绿的洞】★★
--
-- 【错 1:"返回 NULL 而不是 0" 这条药方,对一个 void 断言是【毒药】】
--   PROC-COST-1 fu2 与 PROC-COST-2 第 4 步都用过那条药方,而它们治的是
--   **返回数字**的读取器:无权时给 NULL,让「受限」与「没有」分得开。
--   **本刀这两支函数 RETURNS void。** 对一个 void 断言,"返回 NULL"这个动作
--   拼出来就是【不抛异常地返回】—— **那正是 SALE-BLIND 这个病本身。**
--   照抄那条已经成功两次的药方,会把这个 bug 重新发布一遍,而且带着两处先例背书。
--   ★ 正确的药方是把它【反过来】:属主权限 + 体内受众判据,而判据不成立时
--     **RAISE,不是 return**。
--   **下一个遇到这一族的人,脑子里会装着那两次成功的先例 —— 这段话是写给他的。**
--   判断标准一句话:**问这支函数"无权时它拿什么表示无权"。有返回值的用 NULL;
--   没有返回值的,只能用一次抛出 —— 因为它的"静默"与"通过"是同一个字节。**
--
-- 【错 2:SALE-BLIND 不是一处,是三处,而其中一处在另一支函数里】
--   实测 assert_output_batch_saleable 体内三个依赖各自的 RLS:
--     · output_batches      → module.output.view      读不到 → 第一句 SELECT
--                                                       NOT FOUND → RETURN
--                                                       → **四条拒绝全部跳过**
--     · materials           → module.materials.view   读不到 →
--                                                       assert_material_form_saleable
--                                                       查不到 → **法律那条拒绝
--                                                       SALE_FORM_NOT_SALEABLE
--                                                       永不触发**
--     · processing_outputs  → module.processing.view  读不到 → v_from_run 为假
--                                                       → SALE_FORM_NOT_SET 跳过
--   第二条住在 **assert_material_form_saleable**,它【不在】那六支待清理的
--   RLS 盲函数名单里 —— 它是本刀新发现的,而且它扛的是【法律】那条拒绝
--   (没有旁路的那一条)。
--   ★ 只修外面那一支,等于发布一道【下一层还漏着】的闸,同时发布一份
--     "断言绝不因为看不见而通过"的 fixture —— **那份 fixture 会制造信心,
--     而制造信心比不修更坏。** 所以两支一起修(Tim 的 A2)。
--
-- 【错 3:可达路径与钥匙,brief 都指错了】
--   record_output_sale 与 ship_order **都是 SECURITY DEFINER**。一个 INVOKER
--   触发器在 DEFINER 函数体内运行时,取的是【属主】的身份 —— 所以这两扇前门上
--   RLS 根本不生效,断言看得见一切。**它们不是那条洞。**
--   真正可达的是【另一条】:sales_records 有一条面向客户端的 INSERT 策略
--   (module.finance.edit),于是一次直连 PostgREST 的插入会让触发器**以调用者
--   自己的身份**跑起来。sales_order_reservations 没有 INSERT 策略,只有 DEFINER 门。
--   ★ 也就是说:**可达路径只有一条,而它的钥匙是 finance.edit,不是 sales.edit。**
--     结论(洞是真的、可达的)不变,但一个照着 brief 那条路去设的闸会【设错地方】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【二、第 2 步:两支断言都改成"看不见就按名拒绝"】★★
--
-- 【改之前实测到的那个不对称,逐字记下来】(线上,真角色,全部回滚)
--   拿 OUT-2026-0184 做题,两个场景:
--   ① 挂上工序投料指定(第四条拒绝该响):
--        admin(全权读者)          → SALE_BATCH_EARMARKED|OUT-2026-0184|下游工序投料|…
--        只有 processing.view 的读者 → **通过,一条拒绝都没有**
--   ② 把形态换成负极片(may_be_sold = false,法律那条该响):
--        admin(全权读者)          → SALE_FORM_NOT_SALEABLE|anode_sheet|负极片|Anode sheet
--        **warehouse(线上真角色,无 materials.view)** → **通过,一条拒绝都没有**
--        同一个读者直接调 assert_material_form_saleable → **通过**
--   **第二组用的是线上一个真实存在的角色,不是构造出来的。**
--
-- 【第五条拒绝:SALE_CANNOT_ESTABLISH_SALEABILITY】
--   **一个断言绝不许因为看不见而通过。** 看不见的时候它必须说【第五句话】,
--   而不是把四条里的任何一条借来用 —— 那四条各自对应一个明确的下一步动作:
--     SALE_FORM_NOT_SALEABLE = 这东西法律上不许卖(没有旁路)
--     SALE_FORM_NOT_SET      = 形态没设,所以判断不了(去设形态)
--     库存类                 = 数量不够
--     SALE_BATCH_EARMARKED   = 这一批许给了下游工序(释放指定)
--     ★ 本条                 = **调用者【没有资格判断】这件事**(去要权限)
--   五句话五种下一步。**并成一句,操作员就不知道该做什么。**
--   ★【一个码,两个帧,用载荷区分】第二个参数是 output_batch / material_form。
--     **不造第六个码**(五条拒绝,不许再涨),但两帧必须分得开 ——
--     否则将来把其中一帧重新捅漏的改动,可以躲在另一帧还绿的后面。
--     Tim 的 A2 明确要求两帧【分别】立 fixture。
--
-- 【白名单 = sales.edit OR finance.edit OR output.view,以及每一项在这里的理由】
--   · module.finance.edit —— **唯一那条可达路径的钥匙**(sales_records 直插)。
--   · module.sales.edit   —— quote_lines 的 INSERT 策略要它;而
--                            assert_material_form_saleable 还有两个入口
--                            (quote_lines / sales_order_lines,经
--                            guard_line_form_saleable)。少了它,一次合法的报价
--                            会被第五条拒绝挡住。
--   · module.output.view  —— 在批次页上合法看这一批的人,该拿到【真正的】那条
--                            拒绝,而不是"你没资格判断"。
--   ★【故意【不】收 processing.view】—— 持有它并不使人成为卖家,而且收了它
--     就会让上面实测到的那个盲读者【通过受众判据】,却依旧看不见 output_batches:
--     那等于把这道闸原样修回成一个哑闸。
--
-- 【这里的危险与 PROC-COST-2 的 Q7 【方向相反】,写下来免得被套错模板】
--   Q7 怕的是一个 NULL 顺着算式传下去,把一笔钱悄悄算小(**静默**)。
--   ★ 本条怕的是相反的一件事:**一个响在合法卖家头上的火警,把一条正常的线停掉**
--     (**喧哗**)。所以白名单的取舍标准不是"尽量窄",是
--     **"宽到任何一条合法写入路径的持钥人都不会被它挡住,而不再宽一格"** ——
--     上面三项恰好是三条写入路径各自的钥匙,一项不多。
--   而 Q7 那种毒 NULL 在这里【按构造不可能】:两支函数都 RETURNS void,
--   **没有任何调用者对它做加法或乘法,因为它根本没有值**。两个调用点都是
--   BEFORE INSERT 触发器里的 PERFORM。这一条不需要 fixture ——
--   **一个表达不出来的失败,写不出断言。**
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【三、第 3 步:产出料也要被问同一个安全问题(R1 / M4)】★★
--
-- 【那处不对称,与它被挡在哪一行】guard_processing_input 里 PROC-3 那一段
--   **只问 NEW.inbound_batch_id**,产出批那一路整个跳过。原注释自己写着理由:
--   不是"产出批不需要问",是【问不了】—— 安全状态过去只有进料批有。
--   于是 M4:买进来的极片要过火闸,自己产的极片【连问都问不到】。
--   ★ Tim 的 R1:**抬高产出这一侧,绝不放低进料那一侧。**
--
-- 【结构:平行表,共用同一本字典(A3)】
--   新 output_batch_safety_states,与 inbound_batch_safety_states 同形,
--   **共用 inbound_safety_states 这本字典,一个字不改**。
--   ★【必须不许分叉的是【字典】,不是那张联结表】—— 字典是"一个状态是什么意思"
--     以及"哪道工序受理它"的唯一定义;分叉它,同一个码就会有两种意思,
--     而 operation_type_safety_states 的表注已经明令受理只能有一个定义方式。
--   ★【为什么是平行表,不是把老表改成 XOR】处理输入腿走的是 XOR
--     (processing_inputs),但**更近的先例是 inbound_batch_metals /
--     output_batch_metals —— 一个逐批的实测事实,两种出处,两张平行表**。
--     改老表要动一个带主键、带触发器、有线上行的结构,买到的只是少一条分支;
--     加一张表只动新东西。**照抄先例之前先问那个先例成立的条件** —— 这次
--     成立的是金属那一对。
--   【字典改名?不改】只加一句表注说明它讲的是【物料状态】而不是"只属于进料",
--     改名会为了一件纯外观的事churn 掉每一份 fixture 与 operation_type_safety_states。
--
-- 【回填:一行都不写,而"缺席"必须【拦】(A4)】
--   ★【为什么不回填】线上 20 批产出全是测试残留,产线一天没开过。给它们写上
--     'discharged_verified' 等于**记下一次没有人做过的核验** —— 那是一条假记录,
--     与把 ZZ-PROCCOST1-DEMO 注销掉是同一种错(记一件没发生过的事)。
--   ★【为什么缺席必须拦】进料那一侧,"一行安全状态都没有"已经有名字、有拒绝:
--     INPUT_SAFETY_STATE_NOT_RECORDED —— **没有行 = 没有人看过,不是"安全"**。
--     产出这一侧若让同一种缺席变成通过,**同一个"空"在两张表里就有了相反的意思**,
--     而那正是本仓库反复付账的那一族(METAL-1 的 no_reference、SS-1 的阈值 NULL、
--     PROC-1 的 may_be_processed)。所以缺席 → PRODUCED_SAFETY_STATE_NOT_RECORDED。
--
-- ★★【与进料侧【刻意的分歧】:产出侧【不】看 has_condition_axes】★★
--   **这是一处有意的不同,不是照抄时漏掉的一行,所以写在这里。**
--   进料侧那道闸包在 `IF FOUND AND v_axes IS TRUE` 里:物料种类说"我没有状态轴"
--   就不问。产出侧【不能】照抄,理由是一次测量:
--     **线上 20 批产出,它们的物料 kind_code 全是 NULL** → has_condition_axes 全 NULL
--     → 照抄那一行,这道闸会对【零】批货生效,而那份证明它生效的 fixture
--     会对着空气变绿。
--   ★ 对产出料,"种类没人分过"的意思是**没有人分过类**,而那【不是许可】。
--     这是一道火闸:**未知的安全状态不是许可。**
--   (进料侧那一行的相反取舍是有记录的、刻意的,本刀不动它:那边的空意思是
--    "这条轴比这行料还年轻",拦掉它等于停掉线上每一笔收货。)
--
-- 【本刀因此新拦下什么 —— 线上量过,写在 docs/proc-operations-wired.md】
--   线上 14 批活着的产出批,**没有一批记过安全状态**,所以此后把它们中的任何
--   一批再投料,都会被 PRODUCED_SAFETY_STATE_NOT_RECORDED 拦下,直到有人去记。
--   历史上真实发生过的再加工腿有 **1** 条(FIN-25 那条路是活的,不是理论)。
--   ★【今天的代价是零,而它正是这道火闸存在的目的】产线没开,20 批全是测试残留;
--     而这条拒绝要的正是"投料之前有人看过这批料"这个动作。
--
-- 【收紧不变式一个字没动】没有工序类型 → may_be_fed;有 → 只受理明写的那些。
--   产出侧照同一条铺,fixture 159 F2/F3 仍然红。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【四、第 4 步:在制品看得见(R3)—— 而且【不建 WIP 表】】★★
--   PROC-WIRE-1A 已经立过:purpose_code = 'process_feed' 的产出批**就是**在制品。
--   ★ 再建一张 WIP 表就会【重复计数】,因为那一行已经在 output_batches 里了。
--   所以本刀只加**一个可空指针**:这一批在等哪一道工序。空 = 还没决定等哪道,
--   **不是**"不适用"——它仍然是在制品(purpose_code 才是那条轴)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【五、第 5 步:"不适用"不再冒充"没测"】★★
--   状态改变型工序**按定义没有产出腿**(operation_kinds.produces_outputs = false),
--   所以 recovery_blocked_by 说 'output_not_measured' 是**不精确**的:真相是
--   **不适用**。今天两者都导向"算不出回收率",所以它还不是假话;
--   ★ 但**产出测量真正要紧的那一天,两者会分道**:一个是"去把产出化验录进来",
--     另一个是"这道工序根本不产出,没有东西可录"。
--   没有工序类型的单**仍然报 output_not_measured** —— 说不出"不适用"的时候
--   不许猜它。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 第 2 步 · 安全项:两支断言都不许因为看不见而通过
-- ════════════════════════════════════════════════════════════════════════════

-- ── 2a · 内层那一帧(法律那条拒绝) ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assert_material_form_saleable(p_material_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_form text;
    v_zh   text;
    v_en   text;
    v_mat  text;
BEGIN
    -- 【属主权限:先让这支函数【看得见】】它 JOIN materials(module.materials.view),
    -- 而 INVOKER 会让一个没有那条权限的读者查不到行 —— 于是 FOUND 为假,
    -- 法律那条拒绝**静默地不发生**。线上真角色 warehouse 就是这种读者(实测)。
    SELECT m.code INTO v_mat FROM public.materials m WHERE m.id = p_material_id;

    -- ★【受众判据:看不见就按名拒绝,绝不静默通过】★
    -- 【它必须 RAISE,不能 return】—— 一支 void 函数的"返回 NULL"就是"通过",
    -- 见迁移抬头【错 1】。这是本刀最要紧的一句话。
    IF NOT (has_permission('module.sales.edit')
         OR has_permission('module.finance.edit')
         OR has_permission('module.output.view')) THEN
        RAISE EXCEPTION 'SALE_CANNOT_ESTABLISH_SALEABILITY|%|material_form',
            COALESCE(v_mat, p_material_id::text)
          USING HINT = '你的权限看不到这一种物料的形态,所以【判断不了】这一批可不可售 —— 而一个判断不了的断言【不许】放行。这不是说这个东西不许卖。要卖它,请让管理员给你销售或财务的编辑权限,或产出批次的查看权限。';
    END IF;

    SELECT f.code, f.name_zh, f.name_en INTO v_form, v_zh, v_en
      FROM public.materials m
      JOIN public.material_forms f ON f.code = m.form_code
     WHERE m.id = p_material_id
       AND f.may_be_sold IS FALSE;

    IF FOUND THEN
        RAISE EXCEPTION 'SALE_FORM_NOT_SALEABLE|%|%|%', v_form, v_zh, v_en
          USING HINT = '这个形态在法律上不允许出售(R5)。这【不是】库存问题,也【不是】审批问题 —— 没有例外路径。';
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.assert_material_form_saleable(uuid) IS
    'PROC-BUILD-1(R5):这一种物料的【形态】法律上许不许卖。PROC-WIRE-1B-ii 起【属主权限 + 体内受众判据】—— 此前它是 INVOKER,而一个没有 module.materials.view 的读者(线上真角色 warehouse 就是)会让那句 JOIN 查不到行,于是法律那条拒绝【静默地不发生】。它 RETURNS void,所以"无权返回 NULL"这条药方在这里是毒药:void 的"返回 NULL"拼出来就是"不抛异常地返回",那正是这个 bug 本身 —— 无权时必须 RAISE(第五条拒绝 SALE_CANNOT_ESTABLISH_SALEABILITY,载荷第二段 material_form 标出是哪一帧)。';

-- ── 2b · 外层那一帧(四条拒绝的入口) ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assert_output_batch_saleable(p_output_batch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
    -- 【属主权限:先看得见】三个依赖各自的 RLS 都会让一个部分权限的读者
    -- 静默地丢行(output_batches / materials / processing_outputs),见抬头【错 2】。
    SELECT ob.material_id, ob.code, m.form_code, ob.purpose_code
      INTO v_material, v_code, v_form, v_purpose
      FROM public.output_batches ob
      JOIN public.materials m ON m.id = ob.material_id
     WHERE ob.id = p_output_batch_id;

    IF NOT FOUND THEN
        RETURN;   -- 批次不存在不是本函数的题;既有的 OUTPUT_NOT_FOUND 管它。
    END IF;

    -- ★★【第五条拒绝:调用者【没有资格判断】这件事】★★
    -- 【一个断言绝不许因为看不见而通过】—— 改这一支之前实测:一个只有
    -- processing.view 的读者对着一批【已被指定为工序投料】的货,得到的是
    -- 【一条拒绝都没有】,而同一批货对 admin 抛 SALE_BATCH_EARMARKED。
    -- 【它是第五句话,不是前四句的变体】前四句各自对应一个明确的下一步;
    -- 本条对应的下一步是【去要权限】。并成一句,操作员就不知道该做什么。
    IF NOT (has_permission('module.sales.edit')
         OR has_permission('module.finance.edit')
         OR has_permission('module.output.view')) THEN
        RAISE EXCEPTION 'SALE_CANNOT_ESTABLISH_SALEABILITY|%|output_batch', v_code
          USING HINT = '你的权限看不到这一批产出货,所以【判断不了】它可不可售 —— 而一个判断不了的断言【不许】放行。这【不是】说这一批不许卖。请让管理员给你销售或财务的编辑权限,或产出批次的查看权限。';
    END IF;

    -- ① 形态已知且不可售 —— 与物料级同一条判据,同一个错误码。
    --   【它自己也是属主权限 + 同一条受众判据】见 2a:两帧分别设闸,
    --   于是将来把其中一帧重新捅漏的改动,躲不到另一帧还绿的后面。
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
    -- 【PROC-WIRE-1B-ii 之后是五句】第五句是"你没资格判断",见上面那一段。
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

COMMENT ON FUNCTION public.assert_output_batch_saleable(uuid) IS
    'PROC-BUILD-1 / PROC-WIRE-1A:一批产出货可不可售的四条拒绝入口。PROC-WIRE-1B-ii 起【属主权限 + 体内受众判据】,并新增第五条拒绝 SALE_CANNOT_ESTABLISH_SALEABILITY —— 此前它是 INVOKER,而它体内三个依赖(output_batches / materials / processing_outputs)各有各的 RLS,于是一个部分权限的读者会静默地丢行、四条拒绝一条都不响(实测:只有 processing.view 的读者对着一批已指定为工序投料的货,一条拒绝都没有)。可达路径是 sales_records 那条面向客户端的 INSERT(钥匙 module.finance.edit);两扇前门 record_output_sale / ship_order 是 DEFINER,不受影响。白名单 sales.edit / finance.edit / output.view 恰好是三条写入路径各自的钥匙 —— 这里的危险与 Q7 方向相反:不是毒 NULL 让数字变小,是一个响在合法卖家头上的火警把线停掉。';

-- ════════════════════════════════════════════════════════════════════════════
-- 第 3 步 · 产出料也要被问同一个安全问题(R1 / M4)
-- ════════════════════════════════════════════════════════════════════════════

-- ── 3a · 字典【共用】,只加一句说明它讲的是物料状态,不是"只属于进料" ──────
COMMENT ON TABLE public.inbound_safety_states IS
'PROC-2:这一【批】料的安全状态。**多值** —— 一批料可以同时是"进过水"与"破损"。
RUNTIME CONFIG,加一种是加一行。

★【PROC-WIRE-1B-ii:它讲的是【物料状态】,不是"只属于进料批"】★
**表名里的 inbound 是历史,不是范围。** 自本刀起它由三张表共用:
inbound_batch_safety_states(进料批)、**output_batch_safety_states(产出批)**、
以及 operation_type_safety_states(哪道工序受理哪个状态)。
【为什么不改名】改名要 churn 掉每一份 fixture 与 operation_type_safety_states 的
外键,买到的只是一个更好看的名字 —— 而这句话把范围说清楚了,代价是零。
★【为什么产出侧【不】另起一本字典】那会让同一个码有两种意思,
并且 operation_type_safety_states 的表注已经明令"受理"只能有一个定义方式。
**必须不许分叉的是这本字典;那张联结表分不分叉,是另一件事(答案是分,见下)。**

【它决定什么】**能不能投料(may_be_fed),以及怎么存放。**
存放那一半今天【没有落点】—— 系统里没有任何"存放要求"的机制。
所以本表只做前一半,后一半记成一条待办而不是一个没人读的列
(一个没人用的列教下一个人"这件事已经在管了")。

════════════════════════════════════════════════════════════════════════════
【热失控历史【被考虑过,并且 Tim 决定不要】—— 这是一个决定,不是一个遗漏】
它不在下面的取值里,**而这句话必须写在这里**:在这个仓库里,
一次考虑过的省略如果没有写下来,与一次疏忽长得一模一样,
于是下一个人会把它当成漏掉的补进来 —— 而那会推翻一个已经做过的决定。
**不要因为"看起来少了一个"就加它。** 要加,先去问 Tim。
════════════════════════════════════════════════════════════════════════════

【may_be_fed 与 inbound_chemistry_certainties.may_be_fed 是【两个理由,同一个后果】】
一个讲危险,一个讲认不认得出来。**PROC-3 那道闸要把它们【相与】,
任何一个单独都不充分。** 两处注释互相点名,免得有人以为读一个就够了。

【下面这些 may_be_fed 是【引导默认值】,不是决定】与 certificate_types.disposition
同一条:Tim 在界面上改一行,线上就与本文件不同,那是系统在正常工作。';

-- ── 3b · 平行表(A3):与 inbound_batch_safety_states 同形,共用同一本字典 ──
CREATE TABLE public.output_batch_safety_states (
    output_batch_id   uuid NOT NULL REFERENCES public.output_batches (id) ON DELETE CASCADE,
    safety_state_code text NOT NULL REFERENCES public.inbound_safety_states (code),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    -- 【一批料的同一个状态只记一次】与进料侧逐字同源:重复一行不是"更确定",
    -- 它只会让任何按状态计数的读法开始骗人。
    PRIMARY KEY (output_batch_id, safety_state_code)
);

COMMENT ON TABLE public.output_batch_safety_states IS
'PROC-WIRE-1B-ii(R1 / M4):一批【产出】料身上的安全状态,一行一个。多值。

★【它存在的理由:那处不对称是"问不了",不是"不需要问"】★
guard_processing_input 里 PROC-3 那一段过去只问 inbound_batch_id ——
于是【买进来的】极片要过火闸,而【自己产的】极片连问都问不到。
Tim 的 R1:**抬高产出这一侧,绝不放低进料那一侧。** 这张表就是那个抬高。

【为什么是平行表,而不是把 inbound_batch_safety_states 改成 XOR】
仓库里两个先例指向两个方向:processing_inputs 走 XOR,
inbound_batch_metals / output_batch_metals 走平行表。
**更近的是金属那一对** —— 一个逐批的实测事实,两种出处。
改老表要动一个带主键、带触发器、有线上行的结构,买到的只是少一条分支。
**照抄一个先例之前要问那个先例成立的条件在这里成不成立。**

★【没有安全状态行 = 没有人记过,【不是】"安全"】★ 与进料侧【同一个意思】——
**这正是它必须与那边一致的地方**:同一种"空"在两张表里若有相反的意思,
就是本仓库反复付账的那一族(METAL-1 的 no_reference、SS-1 的阈值 NULL、
PROC-1 的 may_be_processed)。缺席 → PRODUCED_SAFETY_STATE_NOT_RECORDED。

★【回填:一行都没有写,而这是一个【决定】】★ 线上 20 批产出全是测试残留,
产线一天没开过。给它们写上一个状态等于**记下一次没有人做过的核验** ——
一条假记录,与把 ZZ-PROCCOST1-DEMO 注销掉是同一种错。
所以:**不回填,而缺席拦人。** 代价量过:线上 14 批活着的产出批一批都没记过,
于是此后再投料它们中的任何一批都会被拦,直到有人去记 ——
**今天代价为零(产线没开),而那正是这道火闸要的那个动作。**';

CREATE INDEX idx_output_batch_safety_states_batch
    ON public.output_batch_safety_states (output_batch_id);

ALTER TABLE public.output_batch_safety_states ENABLE ROW LEVEL SECURITY;
-- 【跟着父单据判】与 inbound_batch_safety_states 逐字同源:哪个模块能读/写父,
-- 哪个就能读/写行。产出批的父模块是 output。
CREATE POLICY "output_batch_safety_states select by permission"
    ON public.output_batch_safety_states
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'::text));
CREATE POLICY "output_batch_safety_states insert by permission"
    ON public.output_batch_safety_states
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.output.edit'::text));
CREATE POLICY "output_batch_safety_states delete by permission"
    ON public.output_batch_safety_states
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.output.edit'::text));

GRANT SELECT, INSERT, DELETE ON public.output_batch_safety_states TO authenticated;

-- ── 3c · 那道闸:问的换成【这批料和它的状态】,不再是【这批料从哪来】 ──────
CREATE OR REPLACE FUNCTION public.guard_processing_input()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_material_id uuid;
    v_may  boolean;
    v_code text;
    v_axes       boolean;
    v_batch_code text;
    v_n          integer;
    v_bad_zh     text;
    v_bad_en     text;
    v_c_zh       text;
    v_c_en       text;
    -- PROC-WIRE-1B-i
    v_op         text;
    v_op_zh      text;
BEGIN
    IF current_setting('evoltrya.movement_ctx', true) NOT LIKE 'processing:%'
       AND current_setting('evoltrya.movement_ctx', true) NOT LIKE 'reversal:%' THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_DIRECT_INSERT';
    END IF;
    IF NEW.output_batch_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM processing_outputs po
        WHERE po.output_batch_id = NEW.output_batch_id AND po.run_id = NEW.run_id
    ) THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_SELF_CONSUME|%', NEW.run_id;
    END IF;
    -- ── PROC-1:只有【说了可以投料】的物料进得来 ────────────────────────────
    SELECT COALESCE(ib.material_id, ob.material_id) INTO v_material_id
      FROM (SELECT 1) x
      LEFT JOIN inbound_batches ib ON ib.id = NEW.inbound_batch_id
      LEFT JOIN output_batches  ob ON ob.id = NEW.output_batch_id;
    IF v_material_id IS NOT NULL THEN
        SELECT m.may_be_processed, m.code INTO v_may, v_code
          FROM materials m WHERE m.id = v_material_id;
        IF v_may IS NOT TRUE THEN
            RAISE EXCEPTION 'MATERIAL_NOT_PROCESSABLE|%|%', v_code,
                CASE WHEN v_may IS NULL THEN 'undecided' ELSE 'false' END
              USING HINT = '这一种物料没有被声明为可投料;第二个参数说的是【没人决定过】还是【决定了不投】。';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-3:这一【批】货现在是什么状态
    --
    -- ★【PROC-WIRE-1B-ii(R1 / M4):两侧都问了】★
    -- 此前这里只问进料批,而原注释写的理由是【问不了】—— 安全状态那时只有
    -- 进料批有。现在产出批也有(output_batch_safety_states),于是
    -- **这道闸的问题从"这批料从哪来"变成了"这批料和它的状态是什么"**。
    -- Tim 的 R1:抬高产出这一侧,绝不放低进料那一侧 —— 下面进料那一段一个字没动。
    -- ════════════════════════════════════════════════════════════════════════
    IF NEW.inbound_batch_id IS NOT NULL THEN
        SELECT mk.has_condition_axes INTO v_axes
          FROM inbound_batches ib
          JOIN materials       m  ON m.id   = ib.material_id
          JOIN material_kinds  mk ON mk.code = m.kind_code
         WHERE ib.id = NEW.inbound_batch_id;

        IF FOUND AND v_axes IS TRUE THEN
            SELECT ib.code INTO v_batch_code
              FROM inbound_batches ib WHERE ib.id = NEW.inbound_batch_id;

            -- 【D1:缺席仍然是自己那一条拒绝】"没有人记过"→ 去把它记下来。
            -- 这一条【与工序无关】:不管跑哪道工序,没人看过的料都不许进。
            SELECT count(*) INTO v_n
              FROM inbound_batch_safety_states s
             WHERE s.inbound_batch_id = NEW.inbound_batch_id;
            IF v_n = 0 THEN
                RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_RECORDED|%', v_batch_code
                  USING HINT = '一条安全状态都没有的意思是【没有人记过】,不是"这批货安全"。到【进料 → 打开这一批 → 到货状态】那一块把它记上。';
            END IF;

            -- ════════════════════════════════════════════════════════════════
            -- ★ PROC-WIRE-1B-i:受理由【这道工序】回答 ★
            --
            -- 【没有工序类型 → may_be_fed,今天的行为一个字不变】
            -- 【有工序类型 → 只受理明写的那些,没写的一律拒】
            --
            -- **方向只有一个:声明一道工序只会把闸收紧。** 任何放宽都必须是
            -- operation_type_safety_states 里一行明写的数据 —— 绝没有
            -- "状态改变型一律放行"那种按 kind 的旁路(那会让一块鼓包漏液的
            -- 电池进放电机,而放电机解决不了它)。
            --
            -- 【D2 合取仍然成立】一批料身上每一个状态都必须被受理;
            -- 有一条不被受理就拒,并且【一次点完】所有不被受理的。
            -- 【D4:仍然不读 is_active】—— 已经记下来的事实不因字典停用而改变。
            -- ════════════════════════════════════════════════════════════════
            SELECT pr.operation_type_code INTO v_op
              FROM processing_runs pr WHERE pr.id = NEW.run_id;

            IF v_op IS NULL THEN
                SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order)
                         FILTER (WHERE d.may_be_fed IS NOT TRUE),
                       string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                         FILTER (WHERE d.may_be_fed IS NOT TRUE)
                  INTO v_bad_zh, v_bad_en
                  FROM inbound_batch_safety_states s
                  JOIN inbound_safety_states d ON d.code = s.safety_state_code
                 WHERE s.inbound_batch_id = NEW.inbound_batch_id;

                IF v_bad_zh IS NOT NULL THEN
                    RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_FEEDABLE|%|%|%',
                        v_batch_code, v_bad_zh, v_bad_en
                      USING HINT = '这一批带着不可投料的安全状态(全部列在消息里,一次清完)。状态改了要到【进料 → 打开这一批 → 到货状态】那一块改。';
                END IF;
            ELSE
                SELECT ot.name_zh INTO v_op_zh FROM operation_types ot WHERE ot.code = v_op;

                SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order),
                       string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                  INTO v_bad_zh, v_bad_en
                  FROM inbound_batch_safety_states s
                  JOIN inbound_safety_states d ON d.code = s.safety_state_code
                 WHERE s.inbound_batch_id = NEW.inbound_batch_id
                   AND NOT EXISTS (
                       SELECT 1 FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op
                          AND a.safety_state_code = s.safety_state_code);

                IF v_bad_zh IS NOT NULL THEN
                    RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_ACCEPTED|%|%|%|%',
                        v_batch_code, COALESCE(v_op_zh, v_op), v_bad_zh, v_bad_en
                      USING HINT = '这道工序【不受理】这一批身上的某些安全状态(全部列在消息里)。这与"不可投料"是两句话:换一道受理它的工序也许就行 —— 比如没放电的料要先走【深度放电】。';
                END IF;
            END IF;

            -- 【D3:确定度【没记】仍然放行】不要"修"掉这处不对称 ——
            -- 安全状态防的是【起火】,确定度防的是【数字算错】,后者由化验回答,
            -- 不由停线回答。线上 23 批货一条确定度都没有。
            SELECT c.name_zh, c.name_en INTO v_c_zh, v_c_en
              FROM inbound_batches ib
              JOIN inbound_chemistry_certainties c ON c.code = ib.chemistry_certainty_code
             WHERE ib.id = NEW.inbound_batch_id
               AND c.may_be_fed IS NOT TRUE;
            IF FOUND THEN
                RAISE EXCEPTION 'INPUT_CHEMISTRY_NOT_FEEDABLE|%|%|%',
                    v_batch_code, v_c_zh, v_c_en
                  USING HINT = '这一批的化学体系确定度被记成了一个不可投料的值。到【进料 → 打开这一批 → 到货状态】那一块改。';
            END IF;
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★【产出批那一侧:M4 的修法】★★
    --
    -- ★【与进料侧【刻意的分歧】:这里【不】看 has_condition_axes】★
    -- **这是一处有意的不同,不是照抄时漏掉的一行。**
    -- 进料侧那道闸包在 `IF FOUND AND v_axes IS TRUE` 里;产出侧不能照抄,
    -- 理由是一次测量:**线上 20 批产出,它们的物料 kind_code 全是 NULL**,
    -- 于是 has_condition_axes 全是 NULL —— 照抄那一行,这道闸会对【零】批货
    -- 生效,而那份证明它生效的 fixture 会对着空气变绿。
    -- ★ 对产出料,"种类没人分过"的意思是**没有人分过类**,而那【不是许可】。
    --   **这是一道火闸:未知的安全状态不是许可。**
    -- (进料侧那个相反的取舍是刻意的、有记录的,本刀不动:那边的空意思是
    --  "这条轴比这行料还年轻",拦掉它等于停掉线上每一笔收货。)
    --
    -- 【三条拒绝与进料侧【同形但不同名】】下一步动作差在【去哪块屏幕记】:
    -- 进料侧是"进料 → 打开这一批 → 到货状态",产出侧是"产出批次页"。
    -- 同一句话配两个去处,操作员会走错门 —— 所以分名,不合并。
    -- ════════════════════════════════════════════════════════════════════════
    IF NEW.output_batch_id IS NOT NULL THEN
        SELECT ob.code INTO v_batch_code
          FROM output_batches ob WHERE ob.id = NEW.output_batch_id;

        -- 【缺席 = 没有人记过,不是"安全"】与进料侧 D1 同一个意思。
        SELECT count(*) INTO v_n
          FROM output_batch_safety_states s
         WHERE s.output_batch_id = NEW.output_batch_id;
        IF v_n = 0 THEN
            RAISE EXCEPTION 'PRODUCED_SAFETY_STATE_NOT_RECORDED|%', v_batch_code
              USING HINT = '这一批是【自己产出】的料,而它一条安全状态都没有 —— 那的意思是【没有人记过】,不是"它安全"。自产的料与买进来的料在这道火闸面前是同一个问题。到【产出 → 打开这一批 → 安全状态】那一块把它记上。';
        END IF;

        -- 【收紧不变式:与进料侧逐字同一条】没有工序类型 → may_be_fed;
        -- 有工序类型 → 只受理 operation_type_safety_states 里明写的那些。
        -- **声明一道工序只会把闸收紧**,产出侧不给任何按 kind 的旁路。
        SELECT pr.operation_type_code INTO v_op
          FROM processing_runs pr WHERE pr.id = NEW.run_id;

        IF v_op IS NULL THEN
            SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order)
                     FILTER (WHERE d.may_be_fed IS NOT TRUE),
                   string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                     FILTER (WHERE d.may_be_fed IS NOT TRUE)
              INTO v_bad_zh, v_bad_en
              FROM output_batch_safety_states s
              JOIN inbound_safety_states d ON d.code = s.safety_state_code
             WHERE s.output_batch_id = NEW.output_batch_id;

            IF v_bad_zh IS NOT NULL THEN
                RAISE EXCEPTION 'PRODUCED_SAFETY_STATE_NOT_FEEDABLE|%|%|%',
                    v_batch_code, v_bad_zh, v_bad_en
                  USING HINT = '这一批自产的料带着不可投料的安全状态(全部列在消息里,一次清完)。到【产出 → 打开这一批 → 安全状态】那一块改。';
            END IF;
        ELSE
            SELECT ot.name_zh INTO v_op_zh FROM operation_types ot WHERE ot.code = v_op;

            SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order),
                   string_agg(d.name_en, ', ' ORDER BY d.sort_order)
              INTO v_bad_zh, v_bad_en
              FROM output_batch_safety_states s
              JOIN inbound_safety_states d ON d.code = s.safety_state_code
             WHERE s.output_batch_id = NEW.output_batch_id
               AND NOT EXISTS (
                   SELECT 1 FROM operation_type_safety_states a
                    WHERE a.operation_type_code = v_op
                      AND a.safety_state_code = s.safety_state_code);

            IF v_bad_zh IS NOT NULL THEN
                RAISE EXCEPTION 'PRODUCED_SAFETY_STATE_NOT_ACCEPTED|%|%|%|%',
                    v_batch_code, COALESCE(v_op_zh, v_op), v_bad_zh, v_bad_en
                  USING HINT = '这道工序【不受理】这一批自产料身上的某些安全状态(全部列在消息里)。这与"不可投料"是两句话:换一道受理它的工序也许就行。';
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 第 4 步 · 在制品看得见(R3)—— **一个可空指针 + 一块屏,不建 WIP 表**
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★【为什么【不】建 WIP 表】★ PROC-WIRE-1A 已经立过:purpose_code =
--   'process_feed' 的产出批**就是**在制品那一行。再建一张表就会【重复计数】——
--   同一批料会同时出现在 output_batches 和那张新表里,而两处迟早各说各话。
--   R3 说得很清楚:在制品**不需要新对象**,只需要"它在等哪一道工序"+ 一块屏。

ALTER TABLE public.output_batches
    ADD COLUMN awaiting_operation_type_code text
        REFERENCES public.operation_types (code);

COMMENT ON COLUMN public.output_batches.awaiting_operation_type_code IS
'PROC-WIRE-1B-ii(R3):这一批在等【哪一道】工序。**可空。**

【空是什么意思:"还没决定等哪道",【不是】"不适用"】—— 一批已被指定为工序投料
(purpose_code 那条轴)但还没排到具体工序的料,仍然是在制品。
**是不是在制品由 purpose_code 回答,等哪一道由本列回答 —— 两个问题,不许合并。**

【它【不是】第三条轴,只是第二条轴的一个细节】purpose_code 说"这批是干什么用的",
本列说"那件事具体是哪一道"。所以守卫把话说死:**可售库存的批次上本列必须为空**
(guard_output_batch_awaiting_operation)—— 否则会长出一个"既是可售库存、
又在等粉料线"的自相矛盾行,而那正是 material_sources.implies_never_charged
那条列注说的"迟早会跟它的孪生兄弟打架的那一列"。';

-- 【守卫:让"空"与"非空"各自只有一个意思】与 guard_operation_type_shape 同一条:
-- 空是"不适用"还是"没人决定过",必须由数据回答,不能靠读的人猜。
CREATE OR REPLACE FUNCTION public.guard_output_batch_awaiting_operation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE v_saleable boolean;
BEGIN
    IF NEW.awaiting_operation_type_code IS NULL THEN
        RETURN NEW;   -- 【空永远合法】它的意思是"还没决定等哪道"。
    END IF;

    SELECT p.is_saleable_stock INTO v_saleable
      FROM public.output_batch_purposes p WHERE p.code = NEW.purpose_code;

    IF v_saleable IS NOT FALSE THEN
        RAISE EXCEPTION 'WIP_AWAITING_ON_SALEABLE_BATCH|%|%',
            NEW.code, NEW.purpose_code
          USING HINT = '一批【可售库存】不会在等任何工序 —— 要让它等一道工序,先把它的用途改成【下游工序投料】。留着这一列指向一道工序,会造出一个"既可售、又在排队"的自相矛盾行。';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_output_batches_awaiting_operation
    BEFORE INSERT OR UPDATE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_output_batch_awaiting_operation();

-- ── 4a · 那扇门同时管两件事:指定,以及在等哪一道 ──────────────────────────
-- 【为什么改这一扇门而不是新开一扇】"许给产线"与"许给产线的哪一台"是**同一个
-- 工序决定**,拆成两次调用会让中间那一刻既是投料、又不知道等谁 —— 而且两扇门
-- 就是两处权限判断,迟早漂开。
DROP FUNCTION IF EXISTS public.set_output_batch_purpose(uuid, text);

CREATE OR REPLACE FUNCTION public.set_output_batch_purpose(
    p_output_batch_id uuid,
    p_purpose_code text,
    p_awaiting_operation_type_code text DEFAULT NULL)
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
    v_saleable boolean;
    v_await   text;
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
    SELECT is_saleable_stock INTO v_saleable FROM public.output_batch_purposes
     WHERE code = p_purpose_code AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BATCH_PURPOSE_UNKNOWN|%', COALESCE(p_purpose_code, '(null)');
    END IF;

    -- 【释放指定就把"在等哪一道"一并清掉】留着它会造出一个自相矛盾行,
    -- 而守卫会把这次释放整个拒掉 —— 那等于让"释放"这个动作莫名其妙地失败。
    -- **清掉是这扇门的责任,不是调用者要记得的一步。**
    v_await := CASE WHEN v_saleable THEN NULL ELSE p_awaiting_operation_type_code END;

    IF v_await IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.operation_types
                        WHERE code = v_await AND is_active) THEN
        RAISE EXCEPTION 'WIP_OPERATION_UNKNOWN|%', v_await
          USING HINT = '没有这一道工序,或者它已经停用了。到【设置 → 工序】看一眼有哪些。';
    END IF;

    UPDATE public.output_batches
       SET purpose_code = p_purpose_code,
           awaiting_operation_type_code = v_await,
           updated_by   = v_user,
           updated_at   = now()
     WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'code', v_code,
        'purpose_from', v_old,
        'purpose_to', p_purpose_code,
        'awaiting_operation', v_await);
END;
$function$;

COMMENT ON FUNCTION public.set_output_batch_purpose(uuid, text, text) IS
'PROC-WIRE-1A / 1B-ii:设定或释放【下游工序投料】指定,并说出它在等哪一道工序。要 module.processing.edit —— 把一批货许给产线是一个【工序】决定,不是销售决定。释放指定时【自动清掉】那个指针:留着它会撞上 guard_output_batch_awaiting_operation,让"释放"这个动作莫名其妙地失败。';

-- ── 4b · 那块屏读的视图 ───────────────────────────────────────────────────
CREATE VIEW public.processing_wip WITH (security_invoker = off) AS
 SELECT ob.id AS output_batch_id,
    ob.code AS batch_code,
    ob.material_id,
    m.code AS material_code,
    m.name AS material_name,
    ob.remaining_qty,
    ob.unit,
    ob.purpose_code,
    ob.awaiting_operation_type_code,
    ot.name_zh AS awaiting_operation_zh,
    ot.name_en AS awaiting_operation_en,
    ob.output_date,
    -- 【安全状态记了没有】—— 这块屏要能回答"这批为什么投不进去"。
    -- 【0 的意思是"没有人记过",不是"安全"】与那道闸同一个意思。
    (SELECT count(*) FROM public.output_batch_safety_states s
      WHERE s.output_batch_id = ob.id) AS safety_states_recorded
   FROM public.output_batches ob
   JOIN public.materials m ON m.id = ob.material_id
   JOIN public.output_batch_purposes p ON p.code = ob.purpose_code
   LEFT JOIN public.operation_types ot ON ot.code = ob.awaiting_operation_type_code
  WHERE ob.deleted_at IS NULL
    AND p.is_saleable_stock IS FALSE      -- 【判据读的是那一列,不是写死的码】
    AND ob.remaining_qty > 0              -- 【吃光了就不在等了】
    AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_wip IS
'PROC-WIRE-1B-ii(R3):在制品 —— 已被指定为下游工序投料、且还有余量的产出批。

★【它是一个【投影】,不是一张表】★ 在制品那一行**就是** output_batches 里
那一行(PROC-WIRE-1A 立的)。建一张 WIP 表会让同一批料被数两遍,
而两处迟早各说各话。**本视图不存任何东西。**

【判据读的是 output_batch_purposes.is_saleable_stock 那一列,不是写死的码】
将来多一种不可售用途,这块屏自动跟着走。

【remaining_qty > 0】被工序吃光的投料不再"在等" —— 而它的 state 仍然不是"已售罄"
(那是另一条轴,合并会认下一笔从来没发生过的收入)。

【属主权限 + 体内谓词】(修法 (a))它跨 output(批次)与 processing(工序字典)
两个模块 —— invoker 会让一个只有 processing.view 的读者把每一行都丢掉,
而**一块"在等什么"的屏幕空着,与"没有东西在等"长得一模一样**。';

GRANT SELECT ON public.processing_wip TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 第 5 步 · "不适用"不再冒充"没测"
-- ════════════════════════════════════════════════════════════════════════════
-- 【今天它还不是假话,但它【不精确】,而两者会分道】状态改变型工序按定义
-- 没有产出腿(operation_kinds.produces_outputs = false)—— 说它"产出没测过"
-- 会教人去补一份**根本不存在**的化验。
-- 【没有工序类型的单仍然报 output_not_measured】说不出"不适用"的时候不许猜它;
-- 线上 13 张单没有工序类型,它们的答案一个字不变。
-- 【列名、类型、顺序一个没动】所以外层 processing_metal_recovery 不必重建。
CREATE OR REPLACE VIEW public.processing_metal_recovery_all AS
 WITH ins AS (
         SELECT pi.run_id,
            m.metal,
            sum(pi.quantity_consumed * m.content_pct / 100.0) AS input_metal_kg,
                CASE
                    WHEN min(COALESCE(m.content_source, 'unknown'::text)) = max(COALESCE(m.content_source, 'unknown'::text)) THEN min(COALESCE(m.content_source, 'unknown'::text))
                    ELSE 'mixed'::text
                END AS input_source
           FROM processing_inputs pi
             JOIN LATERAL ( SELECT ibm.metal,
                    ibm.content_pct,
                    ibm.content_source
                   FROM inbound_batch_metals ibm
                  WHERE ibm.inbound_batch_id = pi.inbound_batch_id
                UNION ALL
                 SELECT obm.metal,
                    obm.content_pct,
                    obm.content_source
                   FROM output_batch_metals obm
                  WHERE obm.output_batch_id = pi.output_batch_id) m ON true
          GROUP BY pi.run_id, m.metal
        ), outs AS (
         SELECT po.run_id,
            obm.metal,
            sum(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg,
                CASE
                    WHEN min(obm.content_source) = max(obm.content_source) THEN min(obm.content_source)
                    ELSE 'mixed'::text
                END AS output_source
           FROM processing_outputs po
             JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
          GROUP BY po.run_id, obm.metal
        )
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    COALESCE(i.metal, o.metal) AS metal,
    i.input_metal_kg,
    o.output_metal_kg,
    i.metal IS NOT NULL AS input_measured,
    o.metal IS NOT NULL AS output_measured,
        CASE
            WHEN i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric THEN round(o.output_metal_kg / i.input_metal_kg * 100::numeric, 2)
            ELSE NULL::numeric
        END AS recovery_pct,
        CASE
            WHEN i.metal IS NULL THEN 'input_not_measured'::text
            -- ★ PROC-WIRE-1B-ii:【不适用】与【没测】是两句话,两种下一步动作。
            --   状态改变型工序没有产出腿 —— 没有东西可测,不是"忘了测"。
            WHEN o.metal IS NULL AND k.produces_outputs IS FALSE THEN 'output_not_applicable'::text
            WHEN o.metal IS NULL THEN 'output_not_measured'::text
            WHEN i.input_metal_kg = 0::numeric THEN 'input_measured_zero'::text
            ELSE NULL::text
        END AS recovery_blocked_by,
    i.metal IS NOT NULL AND o.metal IS NOT NULL AND o.output_metal_kg > i.input_metal_kg AS conservation_warning,
    bool_or(i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric) OVER (PARTITION BY r.id) AS run_recovery_computable,
    i.input_source,
    o.output_source
   FROM ins i
     FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
     JOIN processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
     -- 【两条都 LEFT JOIN】没有工序类型的单(线上 13 张)必须原样走到
     -- output_not_measured —— 说不出"不适用"的时候不许猜它。
     LEFT JOIN operation_types ot ON ot.code = r.operation_type_code
     LEFT JOIN operation_kinds k ON k.code = ot.kind_code
  WHERE r.status = 'committed'::text AND r.deleted_at IS NULL;

COMMENT ON VIEW public.processing_metal_recovery_all IS
    'AUD-1:processing_metal_recovery 的【无判据基视图】,理由与 batch_lineage_all 逐字相同。【不授权给任何人】;对外读 processing_metal_recovery。PROC-WIRE-1B-ii:recovery_blocked_by 多一个取值 output_not_applicable —— 状态改变型工序按定义没有产出腿,说它"产出没测过"会教人去补一份根本不存在的化验。没有工序类型的单仍然报 output_not_measured(说不出"不适用"的时候不许猜它)。';

COMMIT;
