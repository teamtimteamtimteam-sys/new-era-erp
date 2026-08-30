-- db/migrations/2026-08-30-cmpl1-own-licence-limits-and-import-diligence.sql
-- CMPL-1:自家执照的【机器读得懂的那几格】+ 进口尽调
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【本刀【不】建的三样,以及为什么 —— 先说,免得读者去找】★★
--
-- ① **不建执照登记簿** —— `company_compliance`(CMP-1)【已经是】那张表:
--    cert_type_code → certificate_types(执照种类【本来就是字典行】)、cert_no、
--    issuing_body、valid_from/until、document_path。它的表注自己写着
--    「第一张真执照进来不需要任何 schema 变更」。**再建一张就是"我们的执照在哪"
--    的第二个答案。** 本刀只做【窄扩】。
--
-- ② **不建质量暂扣** —— 实测【已经在跑】:`hold_stock`(要理由,
--    STK_REASON_REQUIRED)/`release_stock`,而且**两条路都已经按名拒**:
--    加工 `IOD_CONSUME_EXCEEDS_AVAILABLE|已投|可用|暂扣`、销售同形。
--    剩下的只是 proc-reality 的 H 早就点名过的那一层:**【质量结论】不是【库存动作】**。
--    而线上产出批次**一份化验都没有**,没有东西可以据以下结论。
--    → 排队:**触发条件是产出批次上的第一份真化验**。**不加一个没人填得了的隔离状态。**
--
-- ③ **不建"在场危废吨数"的推导** —— 见下面第 3 节。它是本刀最要紧的一条【拒绝】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【样本的地位:只提供【字段】,一个【值】都没有进来】
--   Tim 给的两张 NEA 执照属于**另一家公司**,是【样本】不是【数据】。
--   本文件、镜像、界面、文档里**没有任何一个样本值** —— 不做默认值、不做示例行、
--   不做占位符、也不在注释里写「例如」。Evoltrya **至今没有任何执照**,
--   `company_compliance` 线上 **0 行**,而**空着就是正确状态**(那张表的表注早就写了)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1 · 窄扩 company_compliance —— 三格,外加一次【降级】
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.company_compliance
    ADD COLUMN issue_date date,
    ADD COLUMN status text
        CHECK (status IS NULL OR status IN ('active', 'suspended', 'revoked')),
    ADD COLUMN approved_storage_limit_tonnes numeric
        CHECK (approved_storage_limit_tonnes IS NULL OR approved_storage_limit_tonnes > 0);

COMMENT ON COLUMN public.company_compliance.issue_date IS
'CMPL-1:执照的【签发日】—— 与 valid_from 是两件事。样本上两者可以不同(签发在前、生效在后),所以分两列;把它们合成一列会让"什么时候发的"不可恢复。NULL = 没录。';

COMMENT ON COLUMN public.company_compliance.status IS
'CMPL-1:执照的【当下标准】。三个值,而且【故意不包含 expired】—— 是否过期由 valid_until 推得出来,再存一个 expired 就是同一个事实的第二份,而两份必然漂开(LOG-5a 那一课)。NULL = 没说。三值取的是【推导不出来】的那几种:active / suspended / revoked(监管方可以中止或吊销一张仍在有效期内的执照)。';

COMMENT ON COLUMN public.company_compliance.approved_storage_limit_tonnes IS
'CMPL-1:执照批准的【贮存上限】,吨。★这是本刀把一个数字从散文里挪出来的那一格★ —— 此前它只能写在自由文本 scope 里,而**一句话不是一个可以判的值**(与 LOG-5a 把 free_time_terms 换成 free_days 逐字同一件事)。**NULL 不表示"没有上限",表示"没有人录过上限"**,而按 R2,读到 NULL 的判据必须【拒绝作判断】,绝不能放行 —— 见 licence_storage_within_limit()。';

-- ── ★ 同一刀里把 scope【降级】,否则同一件事有两个来源 ★ ──
-- 【为什么降级而不是留着两处】此前 scope 的表注把"上限 60 吨"这类【数字】
-- 举成它的用法。现在数字有了自己的列,scope 若继续被读成数据,就会出现
-- "限额写在哪一处"的两个答案 —— 本仓库为"同一件事两份定义"反复付过账。
-- 处置:**保留 scope 作为散文,并在注释里写死【没有任何判据读它】**。
COMMENT ON COLUMN public.company_compliance.scope IS
'执照的适用范围与条件正文 —— **散文,给人读的**。★【没有任何判据读这一列】★(CMPL-1,2026-08-30):机器要判的那几格已经搬成了真列(目前是 approved_storage_limit_tonnes)。**不要把新的限额写进这句话里**,也不要写解析它的代码 —— 一句话不是一个可以判的值。执照正文里那些【机器判不了】的条件(车辆、人员培训、收运时段、记录保存)正是这一列该装的东西。';

-- ════════════════════════════════════════════════════════════════════════════
-- 2 · GWC —— 执照【种类】是一行数据,不是一列
-- ════════════════════════════════════════════════════════════════════════════
-- certificate_types 线上已经有 gwdf(block / 90 天)。样本显示还有一类 GWC
-- (一般废物收集商执照)。**加一类就是加一行** —— 这正是 certificate_types
-- 作为 RUNTIME CONFIG 的意义。到期提醒因此【自动继承】(见第 4 节)。
-- 【disposition 取 block,与 gwdf/basel/tfs/nea_import 一致】它们都是"过期了就
-- 不该再收货"的那一类;insurance/iso 那种是 warn。**这里不发明第三种处置。**
INSERT INTO public.certificate_types (code, name_en, name_zh, disposition, warn_lead_days)
VALUES ('gwc', 'GWC Licence', '一般废物收集商执照', 'block', 90)
ON CONFLICT (code) DO NOTHING;

-- ════════════════════════════════════════════════════════════════════════════
-- 3 · ★★【在场危废吨数:今天【算不出来】,而这一支就是用来说这句话的】★★
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么不建这个推导 —— 这是一条裁定,不是没做完】
--   要算"在场危废有多少吨",得先能说出【哪些料算危废】。今天说不出:
--     · `waste_classifications` 线上 **2 行**:focused / non_focused;
--     · 它的 `is_controlled` 列 **全库零个消费方**(views/functions 里一次都没被读过);
--     · 而这两行【对不上】NEA 的"批准废物类别"那套词汇。
--   把 is_controlled 硬映射成 NEA 的类别,那是**发明**,不是建模。
--   → 排队,触发条件:**分类字典能表达 NEA 的批准废物类别那天**。
--
-- 【所以它返回 NULL,而 NULL 的意思是"算不出来",不是"零吨"】
--   这条区别是本刀的全部要点:一个把"算不出来"读成 0 的实现,会让
--   任何上限检查都轻松通过 —— 那正是 R2 说的【制造出来的信心】。
CREATE OR REPLACE FUNCTION public.hazardous_qty_on_hand_tonnes()
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【今天无条件返回 NULL = 算不出来】理由在函数抬头,不在这一行。
    -- 分类字典能表达 NEA 的批准废物类别之后,这里换成真的推导,
    -- 而**上面那支判据一个字都不用改** —— 它读的是"是不是 NULL",不是别的。
    RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.hazardous_qty_on_hand_tonnes() IS
'CMPL-1:在场危废吨数 —— **今天返回 NULL,而 NULL 的意思是【算不出来】,不是【零吨】**。要算它得先说得出"哪些料算危废",而 waste_classifications 线上只有 focused / non_focused 两行、其 is_controlled 列**全库零个消费方**,两者都对不上 NEA 的批准废物类别词汇。把它们硬映射过去是发明不是建模,所以这条推导**排队而不是猜**:触发条件是【分类字典能表达 NEA 的批准废物类别】。★把 NULL 读成 0 的实现会让任何上限检查轻松通过,那正是 R2 点名的"制造出来的信心"★。';

-- ════════════════════════════════════════════════════════════════════════════
-- 4 · ★★【R2:读不到限额就【拒绝作判断】,而三种缺法给三条【不同】的拒绝】★★
-- ════════════════════════════════════════════════════════════════════════════
-- 【先例是 PDPA 的保留期】anonymise_employee 在 hr_settings.personal_data_retention_months
--   为 NULL 时 `RAISE EXCEPTION 'PDPA_RETENTION_PERIOD_NOT_SET'` —— **抛,不是返回一个
--   凑合的答案**。本支照抄那个形状:它是一支【下判断】的函数,判断不了就抛。
--
-- ★【三条码,不是一条】★ 「没有录过上限」与「危废吨数算不出来」是**两个不同的真相**,
--   而两者都缺是**第三个**。合成一句话就是 CHAIN-BUILD-1 刚修好的那个病:
--   两种不同的零在屏幕上长得一样,于是人去修错的那一件。
--   · LICENCE_STORAGE_LIMIT_NOT_SET      —— 吨数算得出来,但没有人录过上限
--   · HAZARDOUS_QTY_NOT_COMPUTABLE       —— 上限录了,但吨数算不出来
--   · LICENCE_STORAGE_INPUTS_BOTH_MISSING —— 两样都缺(**今天线上就是这一种**)
--
-- 【它今天只会走第三条】因为公司一张执照都没有(0 行),而吨数推导也还没建。
--   **一支今天只会拒绝的判据仍然值得上线**:TOLL-0 把这条标准写进了
--   dashboard-arm-inventory —— APR-2c 禁的是【一个无法被证明有判别力的屏幕元件】,
--   **不禁一条 fixture 建得出、触发得了、注入得动的【拒绝】**。fixture 152 三种都走。
CREATE OR REPLACE FUNCTION public.licence_storage_within_limit()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_limit numeric;
    v_qty   numeric;
BEGIN
    PERFORM require_permission('module.suppliers.view');

    -- 取【最宽松的那一张】在效执照上的上限:一家公司可能持多张执照,
    -- 而"有没有超"要对着真正管着它的那一张判。今天 0 行,所以必然是 NULL。
    SELECT max(approved_storage_limit_tonnes) INTO v_limit
      FROM company_compliance
     WHERE deleted_at IS NULL
       AND approved_storage_limit_tonnes IS NOT NULL
       AND (status IS NULL OR status = 'active')
       AND (valid_until IS NULL OR valid_until >= CURRENT_DATE);

    v_qty := hazardous_qty_on_hand_tonnes();

    -- ★ 三种缺法,三条码 —— 绝不合并 ★
    IF v_limit IS NULL AND v_qty IS NULL THEN
        RAISE EXCEPTION 'LICENCE_STORAGE_INPUTS_BOTH_MISSING';
    ELSIF v_limit IS NULL THEN
        RAISE EXCEPTION 'LICENCE_STORAGE_LIMIT_NOT_SET';
    ELSIF v_qty IS NULL THEN
        RAISE EXCEPTION 'HAZARDOUS_QTY_NOT_COMPUTABLE';
    END IF;

    -- 两样都在,才谈得上判断。
    RETURN v_qty <= v_limit;
END;
$function$;

COMMENT ON FUNCTION public.licence_storage_within_limit() IS
'CMPL-1(R2):在场危废有没有超出执照批准的贮存上限。★**读不到输入就抛,绝不放行**★ —— 一个"没录上限就一律通过"的实现比没有这道检查更坏,因为它**制造出信心**(与 PDPA 保留期未设时 anonymise_employee 按名拒是同一个形状,那也是 R2 引的先例)。★**三种缺法给三条不同的码**★:LICENCE_STORAGE_LIMIT_NOT_SET(吨数算得出、没录上限)/ HAZARDOUS_QTY_NOT_COMPUTABLE(录了上限、吨数算不出)/ LICENCE_STORAGE_INPUTS_BOTH_MISSING(两样都缺 —— **今天线上就是这一种**)。合成一句话就是 CHAIN-BUILD-1 刚修好的那个病:两种不同的零长得一样,人就会去修错的那一件。吨数为什么算不出来见 hazardous_qty_on_hand_tonnes()。';

-- ════════════════════════════════════════════════════════════════════════════
-- 5 · 进口尽调 —— **记录 + 告警,不加第二道拒绝**
-- ════════════════════════════════════════════════════════════════════════════
-- 【义务的出处是执照正文本身,不是谁的猜测】两张样本执照都写着:持证人不得接收
--   已进口至新加坡的有害或其他废物,除非交货方**在进口当时**持有《有害废物
--   (进出口及过境管制)法 1997》下的进口准证。
--
-- ★★【为什么是【告警】而不是【拒绝】—— 写在这里,因为下一个人一定会问】★★
--   本仓库的标准是:**当下判得了的可以拒;判不了的只能提醒。**
--   · **判得了的那一半【今天已经在拒】**:certificate_types 里 `nea_import`
--     (NEA Import Permit)的 disposition 是 `block`,过期的那张会经
--     supplier_receiving_blocked → trg_inbound_batches_po_receivable **拦在收货上**。
--     本刀**不重复它**,也不在它旁边加第二道。
--   · **本刀这一半判不了**:「交货方【在进口当时】持有准证吗」是一件关于**过去**、
--     关于**某一票具体货**的事实。系统手上没有那一刻的准证状态,只有一份
--     【人核对过】的断言。**对一件系统确立不了的事实设一道拒绝,是把判断伪装成机制。**
--
--   【两个方向的代价,都写出来】
--     · 错拒:一车货被拦在门口,而它其实合规 —— 代价不只是那一车,是**它会制造
--       绕过这道闸的压力**,而一道被绕过去的闸比没有闸更坏(本仓库记过这条)。
--     · 错放:收了一票没有准证的进口货,违反我们自己的执照条件 —— 但**判得了的
--       那一半已经拦着**,而这一半留下的是一条【谁核的、核的是哪张准证】的记录,
--       它既能被审计追,也能被监管方要。
-- 【三个状态由现有列的组合表达,不新建一个枚举类型】
--   imported IS NULL → 还没有人说;IS FALSE → 不是进口;
--   IS TRUE + verified_at IS NULL → 是进口、还没核;IS TRUE + verified_at → 已核。
--   建一个枚举会与这几列并存,成为同一个事实的第二份表示。
ALTER TABLE public.inbound_batches
    ADD COLUMN imported boolean,
    ADD COLUMN import_permit_ref text,
    ADD COLUMN import_permit_verified_by uuid REFERENCES auth.users (id),
    ADD COLUMN import_permit_verified_at timestamptz;

-- 【核验只有在"是进口货"时才说得通】不是进口货却填着核验人,那一行自相矛盾。
ALTER TABLE public.inbound_batches
    ADD CONSTRAINT inbound_import_verification_only_when_imported
    CHECK (
        imported IS TRUE
        OR (import_permit_ref IS NULL
            AND import_permit_verified_by IS NULL
            AND import_permit_verified_at IS NULL)
    );

-- 【核验人与核验时刻【同生同灭】】只有其中一个的记录说不出"什么时候核的"或"谁核的"。
ALTER TABLE public.inbound_batches
    ADD CONSTRAINT inbound_import_verified_pair
    CHECK ((import_permit_verified_by IS NULL) = (import_permit_verified_at IS NULL));

COMMENT ON COLUMN public.inbound_batches.imported IS
'CMPL-1:这批料是不是【进口进新加坡】的。★三个状态必须分得开,而 NULL 是第四个★:NULL = **还没有人说**(绝不等于"不是进口货" —— 一个空白读成"不是进口"正是本仓库反复付账的那种沉默);false = 明确不是进口;true = 是进口,于是执照条件要求交货方在【进口当时】持有进口准证,核验记录见同表另外三列。';

COMMENT ON COLUMN public.inbound_batches.import_permit_verified_at IS
'CMPL-1:【谁在什么时候核过】那张进口准证。★它记录的是一次【人的核对】,不是系统的判断★ —— 「交货方在进口当时是否持证」是关于过去、关于某一票货的事实,系统确立不了,所以本刀**只记录、只告警,不加拒绝**。判得了的那一半(交货方【当下】有没有一张在效的 nea_import 准证)**已经由 certificate_types 的 block 处置在收货上拦着了**,本刀不重复它。';

-- ════════════════════════════════════════════════════════════════════════════
-- 6 · 两支看板臂 —— **形状照抄既有的那两支,不另起一套**
-- ════════════════════════════════════════════════════════════════════════════
-- 【复用的是哪一个机制,写清楚】`qualification_expiring`(CMP-1):它读
--   certificate_types 自带的 warn_lead_days 与 disposition,到期前 lead days 上牌、
--   disposition='ignore' 的类型不上牌、过期后不落牌。**本刀的公司执照臂逐字同形**,
--   只是把 supplier_compliance 换成 company_compliance(没有供应商那一跳)。
--   于是 gwc 这一行加进字典的当天,它的到期提醒【自动就有了】。
-- 【复用的是 qualification_expiring 那一支的形状,逐字同形】
-- 它读 certificate_types 自带的 warn_lead_days 与 disposition:到期前 lead days 上牌、
-- disposition='ignore' 的类型不上牌、过期之后【不落牌】(证书过期两年而进场仍可能)。
-- 本刀的公司执照臂只是把 supplier_compliance 换成 company_compliance,少一跳供应商。
-- ★于是 gwc 那一行加进字典的当天,它的到期提醒【自动就有了】—— 不需要再写一支。★
--
-- 第二支 import_permit_unverified 是 A5 的【告警】那一半:是进口货、但还没有人核过
-- 那张准证。**它不拦任何东西** —— 拦的那一半由 nea_import 的 block 处置在收货上做,
-- 而这一支说的是"这一票还欠一次人工核对"。
-- 【为什么不用 CASCADE 删了重建】实测 operations_now 的数据库依赖方是 **0 个**
-- (app 经 PostgREST 读它),而列清单不变,所以 CREATE OR REPLACE 就够;
-- 而且它线上 reloptions 为空(默认属主权限),没有 WITH 子句会被丢掉。
CREATE OR REPLACE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
        UNION ALL
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text AND w.scheduled_date IS NOT NULL AND w.scheduled_date < CURRENT_DATE
        UNION ALL
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
                CASE
                    WHEN f.side = 'input'::text THEN (((('input overrun · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                    ELSE (((('output shortfall · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan AND f.planned_or_expected_qty > 0::numeric AND (f.side = 'input'::text AND (w2.status = ANY (ARRAY['released'::text, 'closed'::text])) AND f.actual_qty > (f.planned_or_expected_qty * (1::numeric + (( SELECT ps.wo_input_overrun_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)) OR f.side = 'output'::text AND w2.status = 'closed'::text AND f.actual_qty < (f.planned_or_expected_qty * (1::numeric - (( SELECT ps.wo_output_shortfall_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)))
        UNION ALL
         SELECT 'free_time_expiring'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((((q.free_days - (CURRENT_DATE - arr.event_date))::text) || ' left of '::text) || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id AND q.deleted_at IS NULL AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL AND q.free_days IS NOT NULL AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
         SELECT 'container_no_arrival'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL AND (CURRENT_DATE - dep.event_date) >= 14 AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m2
                  WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL AND c.expected_arrival_date IS NOT NULL AND c.expected_arrival_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m3
                  WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_documents_late'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL AND p.n > 0 AND (CURRENT_DATE - c.departure_date) >= 7
        UNION ALL
         SELECT 'equipment_service_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess.equipment_code AS item_code,
            (ess.service_kind || ' — '::text) || ess.equipment_description AS subject,
            ess.baseline_date AS item_date
           FROM equipment_service_status ess
          WHERE ess.monitored AND ess.disposition = 'warn'::text AND ess.equipment_status <> 'disposed'::text AND ess.is_due
        UNION ALL
         SELECT 'equipment_service_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess_1.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess_1.equipment_code AS item_code,
            (ess_1.service_kind || ' — '::text) || ess_1.equipment_description AS subject,
            ess_1.baseline_date AS item_date
           FROM equipment_service_status ess_1
          WHERE ess_1.monitored AND ess_1.disposition = 'warn'::text AND ess_1.equipment_status <> 'disposed'::text AND ess_1.is_approaching
        UNION ALL
         SELECT 'promise_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            ps.promise_id AS item_id,
            NULL::text AS doc_kind,
            ps.chase_code AS item_code,
            ps.customer_name AS subject,
            ps.promised_date AS item_date
           FROM collection_promise_status ps
          WHERE ps.is_overdue
        UNION ALL
         SELECT 'wht_due'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            to_char(w.period_month::timestamp without time zone, 'YYYY-MM'::text) AS item_code,
            (to_char(w.unremitted_base, 'FM999G999G990D00'::text) || ' '::text) || (( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base)) AS subject,
            w.due_date AS item_date
           FROM wht_liability_by_month w
          WHERE w.unremitted_base > 0::numeric AND (w.due_date - CURRENT_DATE) <= 7        UNION ALL
         SELECT 'company_licence_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(cc.cert_no, ct.code) AS item_code,
            ct.name_en AS subject,
            cc.valid_until AS item_date
           FROM company_compliance cc
             JOIN certificate_types ct ON ct.code = cc.cert_type_code
          WHERE cc.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND cc.valid_until IS NOT NULL AND cc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'import_permit_unverified'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            ib.code AS item_code,
            s.legal_name AS subject,
            ib.arrival_date AS item_date
           FROM inbound_batches ib
             JOIN suppliers s ON s.id = ib.supplier_id
          WHERE ib.deleted_at IS NULL AND ib.imported IS TRUE AND ib.import_permit_verified_at IS NULL
) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));;

COMMIT;
