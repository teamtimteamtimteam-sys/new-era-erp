-- db/migrations/2026-09-08-cod2-the-verification-page.sql
-- COD-2:核验页 —— 本系统第一扇【不用登录】就打得开的门。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【网页是原件,纸是副本】★★
-- ════════════════════════════════════════════════════════════════════════════
-- 改一张印出来的 PDF 毫无用处,因为它要对的那份东西在服务器上。COD-1 因此
-- 【两样都冻】:字节证明那张纸没被改过,而一行数据才渲染得出一个网页。
-- 本刀把那一行数据接到一条匿名可达的路上,并且【只接那一条】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 五件事,合成一刀,而合并是有理由的
-- ════════════════════════════════════════════════════════════════════════════
--   ① 核验页要的那一支函数(以及它自带的限流)
--   ② 两张【上了膛】的视图 + 默认权限          —— ①的前提
--   ③ 头像桶转私有                              —— ①正是 UI-1d 说的那扇"对外的门"
--   ④ 执照有效期闸                              —— 补上 COD-1 只查 active 没查日期
--   ⑤ db/check_grants.py(不在本文件里,它是脚本)
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★【这一刀最可能安静地失败的地方,写在最上面】★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 本文件里的
--     GRANT EXECUTE ON FUNCTION public.cod_verification(text) TO anon;
-- 【一个人跑不算数】。db/apply_migration.sh 会把 db/views/zzz_function_grants.sql
-- 拼在 COMMIT 【之前】、同一个事务里再跑一遍,而那个文件的第一句是
--     REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;
-- 于是一条只住在迁移里的 GRANT 会在提交之前【被自己的兜底冲掉】,而迁移
-- 报告成功。C-1 为反方向的同一件事记过一笔(real_role_grants 的 ⚠ 段)。
-- ★ 所以那句 GRANT 【也】写在 db/views/zzz_function_grants.sql 里,写在那句
--   REVOKE 的后面。本文件这一句是为了让迁移能被单独重放,不是真源。★
-- ★ 迁移落地之后必须【单独验一次】anon 到底有没有 EXECUTE —— 迁移成功不是证据。★
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- ① 默认权限:新建的关系不再自动授给 anon
-- ════════════════════════════════════════════════════════════════════════════
-- 【这一条才是不让问题复发的那一半】两张视图是今天的实例,默认权限是产地。
-- ANON-0 实测:anon 在 329 个关系上握着 2,272 条授权,【一条都不出行】——
-- 但那是 RLS 与函数锁定在挡,不是没人给。每一次 CREATE TABLE / CREATE VIEW
-- 都会因为下面这条默认权限自动再给一条,而给出去的那一刻没有任何东西会说话。
--
-- 【实测:public 里有【两条】默认权限记录,而只有一条是我们的】(2026-09-08)
--     defaclrole = postgres        ← 本仓库建的每一个关系都由它建,这一条是活的
--     defaclrole = supabase_admin  ← 平台自己的,postgres 不是它的成员,改不动
-- 所以下面【只改 postgres 那一条】,而 supabase_admin 那一条的存在原样报出去,
-- 不假装覆盖全了。一份声称覆盖全了的报告,比一份说明边界的报告危险。
--
-- 【为什么顺手把 SEQUENCES 与 FUNCTIONS 也收了】函数那一条正是
-- db/views/zzz_function_grants.sql 存在的全部理由(PostgreSQL 默认把 EXECUTE
-- 授给 PUBLIC,而默认权限又单独给 anon 记了一笔),也正是 apply_migration.sh
-- 每次都要重跑一遍那个文件的理由。同一类事故的三个对象类型,一起收。
--
-- 【它【不】影响遮蔽机制】db/platform-prelude.sql ③ 记着:22 张遮蔽表的
-- "REVOKE 整表 + GRANT 列清单" 依赖建表当下那条整表授权 —— 那一条是给
-- authenticated 的,本刀一个字没动。
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon;

-- ════════════════════════════════════════════════════════════════════════════
-- ② 两张【上了膛】的视图 —— 用 REVOKE 关,不是加判据
-- ════════════════════════════════════════════════════════════════════════════
-- ANON-0 的原话:它们不是在漏,它们是【上了膛】。两张都是属主权限视图
-- (security_invoker = off,于是基表的 RLS 根本不参与)、都授给了 anon、
-- body 里没有任何权限判据、也不调任何带门的函数。它们今天回空【只因为
-- collection_promises 与 expense_claims 还没有行】—— 而第一条催收记录、
-- 第一张报销单会同时把它们打开,没有任何东西会说一句话。
--
-- ★【为什么用 REVOKE,而不是给视图 body 加一句 has_permission】★
--   ANON-0 立过一条:四种关法【不能互换】。这里两条都指向 REVOKE:
--   ① collection_promise_status 自己的注释写着它【刻意只有纯 SQL、一个函数
--      都不调】,因为它要喂 operations_now —— 那是没有财务权限的人也在看的
--      首页仪表盘。给 body 加一句 has_permission 谓词,会让那些人的行
--      【静默消失】,而"少了一个逾期承诺"与"报错"完全不同。那正是
--      OPS-14 修法 (a) 要避免的东西,也正是这张视图当初写成属主权限的理由。
--   ② REVOKE 对 authenticated 【零代价】:应用一直以 authenticated 读它们,
--      anon 从来不是它们的合法读者。反悔只要一句 GRANT。
--
-- 【REVOKE 必须同时落进镜像】db/views/batch_lineage_all.sql 的抬头记着这个疤:
-- 一条 REVOKE 只住在迁移里,重建出来的库【是开着的】——"线上收着,重建出来的
-- 库开着"。所以两张视图的镜像文件在同一个提交里各加一行 REVOKE。
-- 而【谁来看着它别再漂回去】—— 本刀的 db/check_grants.py,那正是它存在的理由。
REVOKE ALL ON public.collection_promise_status FROM anon;
REVOKE ALL ON public.expense_claim_status      FROM anon;

-- ════════════════════════════════════════════════════════════════════════════
-- ③ 限流的状态表
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么它在库里,而不是在那条 Next 路由上】委托书原文写的是"给路由限流"。
-- 那是错的,而错在一件可量的事上:**anon key 是随浏览器包一起发出去的**,
-- 所以 POST /rest/v1/rpc/cod_verification 是【第二条门】,它根本不经过 Vercel。
-- 一个住在路由上的限流器会被它要拦的那个工具整个绕过去,同时在报告里印出
-- 一个数字 —— 那正是委托书自己说的"说不出依据的数字不是控制"。
-- 第二条理由:应用跑在 Vercel 上(serverless),进程内计数器每次冷启动清零、
-- 每个区域各算各的,它连自己的依据都说不出来。
-- 所以限流住在函数里,两条门一起管。
--
-- 【表本身对 anon 关着】写它的是 SECURITY DEFINER 函数,读它的没有人。
CREATE TABLE public.cod_verification_failures (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    failed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE public.cod_verification_failures IS
    'COD-2:核验查询的【失败预算】。每一次查不到的核验(令牌不存在或格式不对)在这里留一行,超过预算之后一律回 throttled。★【有效令牌永不被限流】★ —— 攻击者拿不出有效令牌,所以他限不掉任何一个真实持有人。滚动窗口 10 分钟、预算 30 次,依据写在 cod_verification() 的函数体里。表的规模因此封顶在 30 行上下:到了预算就不再插入,窗口自己滴干。';

ALTER TABLE public.cod_verification_failures ENABLE ROW LEVEL SECURITY;
-- 【没有任何策略,这是刻意的】它不是给人读的,写它的只有 cod_verification()。
REVOKE ALL ON public.cod_verification_failures FROM anon, authenticated;

CREATE INDEX idx_cod_verification_failures_at ON public.cod_verification_failures (failed_at);

-- ════════════════════════════════════════════════════════════════════════════
-- ④ 执照有效期闸 —— 一个判据,一份实现,六句具名拒绝
-- ════════════════════════════════════════════════════════════════════════════
-- 【COD-1 漏了什么】它的闸只问 "有没有一行 active 的 GWDF,号非空",
-- 【一个字都没问日期】。于是一行还标着 active、但去年就过期了的执照,
-- 照样能签发一张说"依据该执照合法处理"的对外法律文件。
--
-- 【裁定(Tim,2026-09-08)】这一票货的【加工完成日期】必须落在执照有效期
-- 【之内】,两端都查。而【多行时,在完成日当天在效的那一行说了算】——
-- 不是最新的那一行:一次续期不该回头把旧的那几票货重新盖上新的执照号。
--
-- ★【六句拒绝,而顺序本身是内容】★ 补救的办法各不相同,所以名字必须各不相同:
--   1 COD_LICENCE_NOT_RECORDED      压根没有 GWDF 行 → 去哪儿录(COD-1 已有)
--   2 COD_LICENCE_DATES_NOT_RECORDED  有 active 的行,但有效期缺一端
--   3 COD_LICENCE_NOT_ACTIVE        有一行盖住了这一天,但它不是 active
--   4 COD_LICENCE_EXPIRED           完成日在执照到期【之后】—— 真正会发生的那一种
--   5 COD_LICENCE_NOT_YET_IN_FORCE  完成日在执照生效【之前】—— 措辞是【数据对不上】
--   6 COD_LICENCE_PERIODS_OVERLAP   两行都盖住了这一天 —— 有一行录错了
--
-- 【2 为什么排在 3 前面】NULL 不是"永远有效",是【没有人录过】。这条法则本仓库
-- 反复付过账(approved_storage_limit_tonnes 的注释、issue_cod 对 status IS NULL
-- 的处理)。一个缺了一端的有效期【无法判断】它盖没盖住这一天,而"判断不出"
-- 必须自己有一个名字,不许悄悄退化成两个答案里的任何一个。
--
-- 【5 为什么留着,而且措辞不一样】Tim 的理由:执照没下来之前不会买料,所以这一头
-- 【一旦响,就说明有东西录错了】。它因此不说"业务规则不允许",它说
-- "去核对到货日期与执照日期" —— 一句把人指向【那两个日期】的话,而不是一条规则。
CREATE OR REPLACE FUNCTION public.cod_governing_licence(p_completed_on date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_any   integer;
    v_cover integer;
    v_lic   record;
    v_bad   record;
    v_txt   text;
BEGIN
    -- 【完成日期算不出来,不是执照的问题】—— cod_delivery_completion 已经按名拒过
    -- 一次(COMPLETION_DATE_UNKNOWN),这里只是不许自己拿今天顶上。
    IF p_completed_on IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_COMPLETION_DATE_UNKNOWN', 'detail', '');
    END IF;

    -- 候选:非软删、号非空的 GWDF 行。status 与日期【都还没判】—— 判在下面,
    -- 因为"有一行但它不合格"与"压根没有行"是两句不同的话。
    SELECT count(*) INTO v_any
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> '';
    IF v_any = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_NOT_RECORDED',
                                  'detail', '/purchasing/licences');
    END IF;

    -- 在效且盖住这一天的 active 行有几张?
    SELECT count(*) INTO v_cover
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status = 'active'
       AND cc.valid_from IS NOT NULL AND cc.valid_until IS NOT NULL
       AND p_completed_on BETWEEN cc.valid_from AND cc.valid_until;

    -- 6 · 两张都盖住 → 有一张录错了。【绝不挑一张】—— 挑就等于替录错的人做主。
    IF v_cover > 1 THEN
        SELECT string_agg(cc.cert_no || ' (' || cc.valid_from::text || ' … ' || cc.valid_until::text || ')',
                          ' / ' ORDER BY cc.valid_from)
          INTO v_txt
          FROM company_compliance cc
         WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
           AND cc.status = 'active'
           AND cc.valid_from IS NOT NULL AND cc.valid_until IS NOT NULL
           AND p_completed_on BETWEEN cc.valid_from AND cc.valid_until;
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_PERIODS_OVERLAP',
                                  'detail', p_completed_on::text || '|' || v_txt);
    END IF;

    -- 【正常那一条】在完成日当天在效的那一行说了算 —— 不是最新的那一行。
    IF v_cover = 1 THEN
        SELECT cc.cert_no, cc.issuing_body, cc.valid_from, cc.valid_until, cc.scope
          INTO v_lic
          FROM company_compliance cc
         WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
           AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
           AND cc.status = 'active'
           AND cc.valid_from IS NOT NULL AND cc.valid_until IS NOT NULL
           AND p_completed_on BETWEEN cc.valid_from AND cc.valid_until;
        RETURN jsonb_build_object('ok', true, 'licence', jsonb_build_object(
            'cert_no', v_lic.cert_no, 'issuing_body', v_lic.issuing_body,
            'valid_from', v_lic.valid_from, 'valid_until', v_lic.valid_until,
            'scope', v_lic.scope));
    END IF;

    -- 一张都没盖住。下面四句把【为什么】说清楚,顺序即内容。
    -- 2 · 有效期缺一端 —— 排在最前,因为"判断不出"不许退化成任何一个答案。
    SELECT cc.cert_no INTO v_bad
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status = 'active'
       AND (cc.valid_from IS NULL OR cc.valid_until IS NULL)
     LIMIT 1;
    IF FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_DATES_NOT_RECORDED',
                                  'detail', v_bad.cert_no || '|/purchasing/licences');
    END IF;

    -- 3 · 有一行盖住了这一天,但它不是 active(含 status IS NULL:没有人说过)
    SELECT cc.cert_no, cc.status INTO v_bad
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status IS DISTINCT FROM 'active'
       AND cc.valid_from IS NOT NULL AND cc.valid_until IS NOT NULL
       AND p_completed_on BETWEEN cc.valid_from AND cc.valid_until
     ORDER BY cc.valid_until DESC
     LIMIT 1;
    IF FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_NOT_ACTIVE',
                                  'detail', v_bad.cert_no || '|' || COALESCE(v_bad.status, 'not recorded'));
    END IF;

    -- 4 · 过期了 —— 真正会发生的那一种。两个日期都点名。
    SELECT cc.cert_no, cc.valid_until INTO v_bad
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status = 'active'
       AND cc.valid_until IS NOT NULL AND cc.valid_until < p_completed_on
     ORDER BY cc.valid_until DESC
     LIMIT 1;
    IF FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_EXPIRED',
                                  'detail', p_completed_on::text || '|' || v_bad.valid_until::text
                                            || '|' || v_bad.cert_no);
    END IF;

    -- 5 · 还没生效 —— 措辞是【数据对不上】,不是业务规则。
    SELECT cc.cert_no, cc.valid_from INTO v_bad
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status = 'active'
       AND cc.valid_from IS NOT NULL AND cc.valid_from > p_completed_on
     ORDER BY cc.valid_from ASC
     LIMIT 1;
    IF FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_NOT_YET_IN_FORCE',
                                  'detail', p_completed_on::text || '|' || v_bad.valid_from::text
                                            || '|' || v_bad.cert_no);
    END IF;

    -- 兜底:有行,但没有一行是 active 且日期齐全的。等同于"没录"。
    RETURN jsonb_build_object('ok', false, 'reason', 'COD_LICENCE_NOT_RECORDED',
                              'detail', '/purchasing/licences');
END;
$function$;

COMMENT ON FUNCTION public.cod_governing_licence(date) IS
    'COD-2:【在这一天在效的那一张 GWDF 执照】。判据只有这一份实现 —— issue_cod 与 cod_certificate_data 都调它,不各写一遍。★ 在完成日当天在效的那一行说了算,不是最新的那一行 ★:一次续期不该回头把旧的那几票货重新盖上新的执照号。六句具名拒绝,顺序即内容(NULL 有效期排最前:判断不出必须自己有名字,不许退化成两个答案里的任何一个)。';

-- ── ④b cod_certificate_data:执照那一格改读同一支判据 ────────────────────────
-- 【只改执照那一段】其余一个字没动。原来的那一句是
--     WHERE status = 'active' … ORDER BY valid_until DESC NULLS LAST LIMIT 1
-- —— 它挑的是【最新的】那一行,而不是【当天在效的】那一行,并且完全不看
-- 完成日期。那正是本刀要修的东西,而它此前有【两份实现】(这里一份、
-- issue_cod 里一份),两份还不一样:issue_cod 那份连 ORDER BY 都没有,
-- 是 LIMIT 1 随便挑一行。现在两边都调 cod_governing_licence()。
--
-- 【内部存档【仍然】不因缺执照被拒】这里拿不到执照只是把那一格记成 null
-- (纸上印"Not recorded"),按名拒绝是 issue_cod 的事。存档是内部的,签发才是对外的。
CREATE OR REPLACE FUNCTION public.cod_certificate_data(p_inbound_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ib   record;
    v_comp record;
    v_lic  jsonb;
    v_cod  record;
    v_done jsonb;
    v_runs jsonb;
BEGIN
    IF NOT has_permission('action.issue_cod') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    IF p_inbound_batch_id IS NULL THEN
        RAISE EXCEPTION 'BATCH_REQUIRED';
    END IF;

    SELECT ib.id, ib.code, ib.quantity, ib.unit, ib.arrival_date,
           m.code AS material_code, m.name AS material_name,
           s.legal_name AS supplier_name, s.code AS supplier_code,
           po.code AS purchase_order_code
      INTO v_ib
      FROM inbound_batches ib
      LEFT JOIN materials m       ON m.id  = ib.material_id
      LEFT JOIN suppliers s       ON s.id  = ib.supplier_id
      LEFT JOIN purchase_orders po ON po.id = ib.purchase_order_id
     WHERE ib.id = p_inbound_batch_id;

    -- 【三条拒绝是有序的,而顺序本身是内容】先分清"这个 id 根本不是批次"与
    -- "它是个批次、但是产出批"—— 后者是拿产出批的 id 来要销毁证书,一个可以
    -- 理解的错,它值得一句说得清的话。(与 traceability_report_data 同形,方向相反。)
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM output_batches ob WHERE ob.id = p_inbound_batch_id) THEN
            RAISE EXCEPTION 'NOT_AN_INBOUND_BATCH|%',
                (SELECT ob.code FROM output_batches ob WHERE ob.id = p_inbound_batch_id);
        END IF;
        RAISE EXCEPTION 'BATCH_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    -- 【第四个状态:组装不出来】判据不在这里重写一遍 —— 只有那一支说了算,
    -- 在这里再写一遍就是让同一件事有两处实现(而它们迟早各说各话)。
    v_done := cod_delivery_completion(p_inbound_batch_id);
    IF NOT (v_done->>'complete')::boolean THEN
        RAISE EXCEPTION 'CANNOT_CERTIFY|%|%', v_ib.code, v_done->>'reason';
    END IF;

    -- 公司抬头的【文字】部分。★ 印在纸上的抬头与 logo 仍然由
    -- loadDocumentCompany() 决定(裁定如此,八份对外单据都走它)★ ——
    -- 这里取的是要【冻进 snapshot】的那一份,核验页几年后靠它渲染。
    SELECT cp.legal_name, cp.registration_no, cp.address_lines, cp.city,
           cp.postal_code, cp.country, cp.phone, cp.email, cp.website
      INTO v_comp FROM company_profile cp LIMIT 1;

    -- 【执照:COD-2 起走 cod_governing_licence(完成日)】—— 一个判据一份实现。
    -- ★ 在完成日当天在效的那一行说了算,不是最新的那一行 ★:一次续期不该
    -- 回头把旧的那几票货重新盖上新的执照号。拿不到就是 null(内部存档照印
    -- "未记录"),按名拒绝由 issue_cod 做。
    v_lic := cod_governing_licence((v_done->>'completed_on')::date);

    SELECT c.id, c.code, c.status, c.issued_at, c.verification_token,
           c.void_reason, c.voided_at
      INTO v_cod
      FROM certificates_of_destruction c
     WHERE c.inbound_batch_id = p_inbound_batch_id AND c.status <> 'void';

    -- 【出处:只回答"这来自哪些行",不印在纸上、也不许被回查内容】
    SELECT COALESCE(jsonb_agg(DISTINCT r.id), '[]'::jsonb) INTO v_runs
      FROM processing_inputs pi JOIN processing_runs r ON r.id = pi.run_id
     WHERE pi.inbound_batch_id = p_inbound_batch_id AND r.deleted_at IS NULL;

    RETURN jsonb_build_object(
        'inbound_batch', jsonb_build_object(
            'id', v_ib.id, 'code', v_ib.code,
            'material_code', v_ib.material_code, 'material_name', v_ib.material_name,
            'quantity', v_ib.quantity, 'unit', v_ib.unit,
            'arrival_date', v_ib.arrival_date,
            'purchase_order_code', v_ib.purchase_order_code),
        -- 【只有名字与编号】—— 能力够得着的正好是证书需要的,不多一格。
        'supplier', jsonb_build_object(
            'name', v_ib.supplier_name, 'code', v_ib.supplier_code),
        'processing', jsonb_build_object(
            'completed_on', v_done->>'completed_on'),
        'company', jsonb_build_object(
            'legal_name', v_comp.legal_name, 'registration_no', v_comp.registration_no,
            'address_lines', v_comp.address_lines, 'city', v_comp.city,
            'postal_code', v_comp.postal_code, 'country', v_comp.country,
            'phone', v_comp.phone, 'email', v_comp.email, 'website', v_comp.website),
        -- 【执照缺席是一个具名状态,不是空白】内部存档照印这一格,标成"未记录";
        -- 签发则被 issue_cod() 按名拒。
        'licence', CASE WHEN (v_lic->>'ok')::boolean THEN v_lic->'licence' ELSE NULL END,
        'certificate', CASE WHEN v_cod.id IS NULL THEN NULL ELSE jsonb_build_object(
            'id', v_cod.id, 'code', v_cod.code, 'status', v_cod.status,
            'issued_at', v_cod.issued_at,
            'verification_token', v_cod.verification_token) END,
        'provenance', jsonb_build_object('run_ids', v_runs)
    );
END;
$function$;

-- ── ④c issue_cod:执照闸换成日期闸,并且【搬到完成判据之后】────────────────
-- 【为什么必须搬】新闸要的是【加工完成日期】,而那个日期由 cod_delivery_completion
-- 算出来 —— 闸不可能排在它前面。副作用照直写:一票【既没加工完、又没有执照】的货,
-- 从此先报 CANNOT_CERTIFY 而不是 COD_LICENCE_NOT_RECORDED。那也是对的顺序:
-- 先说"这票货还不成立",再说"而且执照也不对",比反过来有用。
CREATE OR REPLACE FUNCTION public.issue_cod(p_cod_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cod   record;
    v_lic   jsonb;
    v_done  jsonb;
    v_data  jsonb;
    v_code  text;
    v_token uuid;
    v_now   timestamptz;
BEGIN
    IF NOT has_permission('action.issue_cod') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    SELECT c.id, c.inbound_batch_id, c.status, c.completed_on INTO v_cod
      FROM certificates_of_destruction c WHERE c.id = p_cod_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(p_cod_id::text, '?');
    END IF;
    IF v_cod.status <> 'pending' THEN
        RAISE EXCEPTION 'COD_ALREADY_ISSUED|%', v_cod.status;
    END IF;

    -- 【签发那一刻再问一次判据】—— 不重写,问同一支函数。
    v_done := cod_delivery_completion(v_cod.inbound_batch_id);
    IF NOT (v_done->>'complete')::boolean THEN
        RAISE EXCEPTION 'CANNOT_CERTIFY|%|%', v_done->>'batch_code', v_done->>'reason';
    END IF;

    -- ── 执照闸(COD-2:两端日期都查)────────────────────────────────────────
    -- 【判据不在这里重写】cod_governing_licence() 是唯一那一份,六句具名拒绝
    -- 也住在那里。这里只负责把它抛出去 —— 而【抛出去的名字必须各不相同】,
    -- 因为补救的办法各不相同(去录一行 / 去补日期 / 去核对到货日期)。
    -- 【不发明任何占位执照号】—— 表今天是空的,所以今天什么都签发不了,而那是对的:
    -- NEA 发照之前 Tim 不会买料。
    v_lic := cod_governing_licence((v_done->>'completed_on')::date);
    IF NOT (v_lic->>'ok')::boolean THEN
        -- 【拒绝要说得出下一步去哪】与 loadDocumentCompany 的 COMPANY_MISSING_MESSAGE
        -- 同一条:一句报不出去处的拒绝,等于把人留在原地。
        RAISE EXCEPTION '%|%', v_lic->>'reason', v_lic->>'detail';
    END IF;

    v_code  := next_cod_code();
    v_token := gen_random_uuid();
    v_now   := clock_timestamp();

    -- 【快照由服务端自己组装,不收调用者递进来的一份】否则冻住的是调用者说的话。
    -- (record_traceability_report_issue 自己调 traceability_report_data,同一条。)
    v_data := cod_certificate_data(v_cod.inbound_batch_id);

    -- 【证书这一块用【真的】签发值覆盖】组装时它还是 pending。
    -- ★ issued_by 只存 uuid,【不解析成人名】★ —— 裁定:纸上没有人名,
    -- "谁处理的"是公司。签发人是一条记录,不是印在证书上的一行。
    v_data := (v_data - 'certificate') || jsonb_build_object(
        'certificate', jsonb_build_object(
            'id', v_cod.id, 'code', v_code, 'status', 'issued',
            'issued_at', v_now, 'issued_by', auth.uid(),
            'verification_token', v_token,
            'completed_on', v_cod.completed_on));

    -- 【任何一格缺了就按名拒,绝不回落去读活行、也绝不印一片空白】(S6 规则二)
    IF v_data->'company'->>'legal_name' IS NULL
       OR btrim(v_data->'company'->>'legal_name') = '' THEN
        RAISE EXCEPTION 'COMPANY_LEGAL_NAME_MISSING|/finance/company';
    END IF;
    IF v_data->'supplier'->>'name' IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_NAME_MISSING|%', v_data->'inbound_batch'->>'code';
    END IF;
    -- 【第二道,刻意留着】上面的闸已经过了,这一句问的是"组装出来的那一份里
    -- 到底有没有那一格" —— 两句问的不是同一件事,而快照是核验页几年后的唯一依据。
    IF v_data->'licence' = 'null'::jsonb OR v_data->'licence' IS NULL THEN
        RAISE EXCEPTION 'COD_LICENCE_NOT_RECORDED|/purchasing/licences';
    END IF;

    UPDATE certificates_of_destruction
       SET status = 'issued', code = v_code, verification_token = v_token,
           snapshot = v_data, issued_at = v_now, issued_by = auth.uid()
     WHERE id = p_cod_id;

    RETURN jsonb_build_object(
        'cod_id', v_cod.id, 'code', v_code, 'status', 'issued',
        'verification_token', v_token, 'issued_at', v_now,
        'batch_code', v_data->'inbound_batch'->>'code');
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- ⑤ 核验函数 —— 匿名请求够得着的【唯一】一样东西
-- ════════════════════════════════════════════════════════════════════════════
-- 【一支函数,一张证书,没有清单】它收一个令牌、回一份快照的【子集】。
-- 没有列表、没有翻页、没有索引 —— 一个"收一个令牌回一张证书"的接口
-- 【没有清单可以泄漏】,因为根本没有那个端点。
--
-- ★【返回的东西是【白名单】,不是把敏感字段减掉】★
--   第一版写的是 snapshot - 'provenance' - … 那种减法。减法有一个静默的失败模式:
--   将来往快照里多加一格,它【自动就出去了】,而没有任何东西会说一句话。
--   白名单反过来:多加一格默认【不】出去,要它出去得有人来这里写一行。
--   于是"漏"变成一件要动手做的事,而不是一件忘了做就会发生的事。
--
-- 【剥掉的,逐条点名】provenance.run_ids(内部加工单 uuid)、certificate.id、
--   inbound_batch.id(内部 uuid)、certificate.verification_token(回声)、
--   certificate.issued_by(签发人 uuid —— 纸上没有人名,页上也不该有)、
--   company 的电话/邮箱/网址(【纸上没有】,所以页上也没有)。
--   价格、成本、化验、品位、产出批:快照里【本来就没有】(COD-1 的裁定),
--   而白名单让这句话在将来也成立。
--
-- 【作废的证书【必须】仍然查得到】—— 一个 404 会把某人手里【拿着的】一份文件
--   变成一件从来不存在的东西。所以:
--     · void + 有替代品 → 说它作废了,并给出顶上来那一张的【号】;
--     · void + 没有替代品(加工被冲销)→ 照直说,并让持有人联系 Evoltrya。
--   ★【绝不显示作废原因】★ void_reason 是一个内部自由文本字段,
--     操作员可能往里面打了任何东西。
--
-- 【不认识的令牌与格式不对的令牌,回同一句话】两者的区别是探测工具的神谕。
--   所以参数是 text 而不是 uuid:收 uuid 的话,一个格式不对的令牌会在
--   PostgREST 那一层就撞成 400,而那本身就是一个可以分辨的答案。
CREATE OR REPLACE FUNCTION public.cod_verification(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- ★★【限流:滚动 10 分钟里 30 次【失败】,而有效令牌永不被限流】★★
    --
    -- 【依据,写在数字旁边而不只写在报告里】
    --   ① 真正挡住枚举的【不是这个数】,是令牌本身:它是 122 位随机的 UUID,
    --      猜中一次的概率是 2^-122。任何限流都只是在一个 5.3×10^36 的空间上
    --      少数几个数量级的差别 —— 说这个数字"防住了猜测"是不诚实的。
    --      它真正的差事有两件:控制成本与噪声;以及万一哪天令牌从别处漏成了
    --      可猜的形状,留一道纵深。
    --   ② 预算只算【失败】。一个拿着二维码扫进来的持有人产生【零次】失败;
    --      一个把网址敲错、抄漏一段的人产生一两次。6 个员工加少量供应商,
    --      合理的失败率远在个位数/10 分钟。30 次是它的约五十倍。
    --   ③ 而对探测方:30 次/10 分钟 ≈ 每年 158 万次,对着 5.3×10^36 的空间。
    --   ④ ★【有效令牌永不被限流】★ —— 这一条是这个设计能成立的关键:
    --      攻击者【拿不出】有效令牌,所以他【限不掉任何一个真实持有人】。
    --      一个"全局失败预算"若也拦有效令牌,就成了一个人人可用的拒绝服务开关。
    c_budget   constant integer  := 30;
    c_window   constant interval := interval '10 minutes';
    v_tok      uuid;
    v_found    boolean := false;
    v_status   text;
    v_snap     jsonb;
    v_repl     uuid;
    v_repl_code text;
    v_n        integer;
    v_retry    integer;
BEGIN
    -- 【格式判据自己做】—— 见抬头:收 uuid 会让"格式不对"在 PostgREST 那层
    -- 就变成一个不一样的答案。NULL 走同一条路(NULL ~* … 是 NULL,不是真)。
    IF p_token ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        v_tok := p_token::uuid;
        SELECT c.status, c.snapshot, c.replaced_by_cod_id
          INTO v_status, v_snap, v_repl
          FROM certificates_of_destruction c
         WHERE c.verification_token = v_tok;
        -- 【没有快照的行等于查不到】—— pending 行拿不到令牌(表上的 CHECK 钉着),
        -- 但这里不靠那条约束活着:渲染不出来的东西一律走同一句话。
        v_found := FOUND AND v_snap IS NOT NULL;
    END IF;

    IF NOT v_found THEN
        -- 【一把锁,免得并发探测把预算冲过去】与 next_cod_code 同一个习惯:
        -- 事务级顾问锁,便宜、自动释放,而且它让"30"真的是 30。
        PERFORM pg_advisory_xact_lock(hashtext('cod_verification_failures')::bigint);
        DELETE FROM cod_verification_failures WHERE failed_at < clock_timestamp() - c_window;
        SELECT count(*) INTO v_n FROM cod_verification_failures;
        IF v_n >= c_budget THEN
            -- 【超了预算就不再插入】—— 否则探测会把窗口无限往后推,
            -- 那是把限流变成永久封锁。窗口自己滴干。
            SELECT GREATEST(1, ceil(EXTRACT(EPOCH FROM
                       (min(f.failed_at) + c_window - clock_timestamp()))))::integer
              INTO v_retry FROM cod_verification_failures f;
            RETURN jsonb_build_object('result', 'throttled',
                                      'retry_after_seconds', COALESCE(v_retry, 60));
        END IF;
        INSERT INTO cod_verification_failures DEFAULT VALUES;
        -- ★【不认识 / 格式不对 —— 同一句话,不带任何区别】★
        RETURN jsonb_build_object('result', 'not_found');
    END IF;

    -- 【作废之后顶上来的那一张:只回它的【号】】—— 不回 id,也不回它的令牌。
    -- 没顶上来的(冲销那一种)是 NULL,页面照直说"没有替代品,请联系我们"。
    IF v_status = 'void' AND v_repl IS NOT NULL THEN
        SELECT c.code INTO v_repl_code
          FROM certificates_of_destruction c
         WHERE c.id = v_repl AND c.status = 'issued';
    END IF;

    RETURN jsonb_build_object(
        'result', 'ok',
        -- ★【状态读的是【活行】,不是快照】★ 快照冻在签发那一刻,而作废发生在
        -- 之后 —— 拿快照里的 status 渲染,一张已经作废的证书会永远显示"有效"。
        'status', v_status,
        'certificate', jsonb_build_object(
            'code',      v_snap->'certificate'->>'code',
            'issued_at', v_snap->'certificate'->>'issued_at'),
        'processing', jsonb_build_object(
            'completed_on', v_snap->'processing'->>'completed_on'),
        'inbound_batch', jsonb_build_object(
            'code',                v_snap->'inbound_batch'->>'code',
            'material_code',       v_snap->'inbound_batch'->>'material_code',
            'material_name',       v_snap->'inbound_batch'->>'material_name',
            'quantity',            v_snap->'inbound_batch'->'quantity',
            'unit',                v_snap->'inbound_batch'->>'unit',
            'arrival_date',        v_snap->'inbound_batch'->>'arrival_date',
            'purchase_order_code', v_snap->'inbound_batch'->>'purchase_order_code'),
        'supplier', jsonb_build_object(
            'name', v_snap->'supplier'->>'name',
            'code', v_snap->'supplier'->>'code'),
        -- 【公司:正好是纸上抬头印的那几格】电话/邮箱/网址【不在纸上】,
        -- 所以也不在这里 —— "页上显示纸上有的,不多一格"。
        'company', jsonb_build_object(
            'legal_name',      v_snap->'company'->>'legal_name',
            'registration_no', v_snap->'company'->>'registration_no',
            'address_lines',   v_snap->'company'->>'address_lines',
            'city',            v_snap->'company'->>'city',
            'postal_code',     v_snap->'company'->>'postal_code',
            'country',         v_snap->'company'->>'country'),
        'licence', CASE WHEN v_snap->'licence' IS NULL OR v_snap->'licence' = 'null'::jsonb
                        THEN NULL ELSE jsonb_build_object(
            'cert_no',      v_snap->'licence'->>'cert_no',
            'issuing_body', v_snap->'licence'->>'issuing_body',
            'valid_from',   v_snap->'licence'->>'valid_from',
            'valid_until',  v_snap->'licence'->>'valid_until') END,
        -- 【作废那一格:只有"顶上来的是哪一号",没有原因】
        'void', CASE WHEN v_status = 'void'
                     THEN jsonb_build_object('replaced_by_code', v_repl_code)
                     ELSE NULL END);
END;
$function$;

COMMENT ON FUNCTION public.cod_verification(text) IS
    'COD-2:核验页的取数 —— 本库【唯一】一支 anon 可执行的函数。收一个核验令牌,回一张证书快照的【白名单子集】(白名单不是减法:将来快照多一格,默认【不】出去)。剥掉:provenance.run_ids、所有内部 uuid、令牌回声、签发人、公司的电话/邮箱/网址。★ 状态读活行不读快照 ★(作废发生在冻结之后)。★ 作废的证书仍然解析得到 ★,给出替代证书的号,但【绝不给作废原因】——那是内部自由文本。不认识的令牌与格式不对的令牌回【同一句话】,所以参数是 text 不是 uuid。限流:滚动 10 分钟 30 次【失败】,有效令牌永不被限流(依据写在函数体里)。';

-- ════════════════════════════════════════════════════════════════════════════
-- ⑥ 授权 —— 本库【第一条】给 anon 的 EXECUTE
-- ════════════════════════════════════════════════════════════════════════════
-- ANON-0 实测:anon 在 492 支函数上握着【零】个 EXECUTE。这是第一个。
-- ★ 真源在 db/views/zzz_function_grants.sql ★(见本文件抬头那一大段:
--   apply_migration.sh 会在 COMMIT 之前重跑那个文件,它的第一句会把
--   只写在这里的 GRANT 冲掉)。这里写一份是为了本文件可以被单独重放。
REVOKE EXECUTE ON FUNCTION public.cod_governing_licence(date) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cod_verification(text)      FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.cod_verification(text)      TO anon, authenticated, service_role;

-- ════════════════════════════════════════════════════════════════════════════
-- ⑦ 头像桶转私有 —— UI-1d 自己写下的那条"到时候再改"
-- ════════════════════════════════════════════════════════════════════════════
-- db/migrations/2026-09-05-ui1d-avatar-bucket.sql 收下公开桶时,把后果与
-- 【重开这个决定的条件】一起写了下来:
--     "人一多、或者哪天有了对外的门户,就重开这一条,并照 (b) 改。"
-- ★ 核验页就是那扇对外的门。★ 所以照 (b) 改,而不是另设计一套。
--
-- 【(b) 原文:私有桶 + 一个 Next 路由把字节代理出来,地址里不出现 uid】
-- 实测(2026-09-08)全仓库【只有两处】画头像,而两处画的都是【当前登录者自己】:
--     app/components/TopNav.tsx:195   app/me/page.tsx:93
-- 没有任何一页画别人的头像。于是 (b) 落地得比它自己写的还干净:
-- 那条路由的地址里【连一个标识符都不需要】—— 它就叫 /me/avatar,
-- 服务谁由会话说了算。uid 不是换了个地方,是从地址里【消失了】。
--
-- 【两个既有对象:原样留着,一个字节都不动】对象名仍然是 <uid>.webp,
-- 四条策略一个字没改 —— 其中 "own avatar read" 那一条本来就允许本人读自己那一行,
-- 而它从今天起【真的开始干活】(此前公开读走 /object/public/… 不过 RLS)。
UPDATE storage.buckets SET public = false WHERE id = 'avatars';

COMMIT;
