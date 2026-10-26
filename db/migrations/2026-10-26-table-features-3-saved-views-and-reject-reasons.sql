-- db/migrations/2026-10-26-table-features-3-saved-views-and-reject-reasons.sql
-- TABLE-FEATURES-3(v1.4.76,Tim 2026-10-25 Q2 · Q3 · Q11 与 2026-10-26 Q1–Q4):
--   ① saved_views —— 保存的视图(Q3):每人自己的、每人每张列表至多一个默认;RLS 锁在 user_id = auth.uid();anon 无权限;
--      不进变更记录(change_log_exclusions 第十张,屏幕偏好)。
--   ② decide_leave_request · decide_medical_claim —— 驳回要一句理由,按名拒(Q11):
--      LEAVE_REJECT_REASON_REQUIRED|<编号> · MEDICAL_CLAIM_REJECT_REASON_REQUIRED|<编号>。规矩在函数里,不在表上(线上一张旧驳回的理由为空)。
-- 批量动作(Q2)不动库:每一项走那一项的单项动作。镜像:下面每一段逐字是它标着的那个文件。
-- EXECUTE:apply_migration.sh 在本事务里重放 db/views/zzz_function_grants.sql。
BEGIN;

-- ── db/tables/saved_views.sql ──
-- db/tables/saved_views.sql
-- TABLE-FEATURES-3(Tim 2026-10-25 Q3 · 2026-10-26 Q1–Q3):一个人在一张列表上存下的视图 —— 筛选与排序,存成地址的查询串。
--
-- NOTE: introduced by db/migrations/2026-10-26-table-features-3-saved-views-and-reject-reasons.sql.
-- First-run script (plain CREATEs).
--
-- 【只属于一个人】Q3:per user only(分享以后再说)。RLS 四条策略都锁在 user_id = auth.uid() —— 与 notification_reads 同一个形状:
--   它记的是"我想这样看",那句话只有本人说得出,所以不装写闸(enforce_write_permission):那不是一个权限问题(fixture 198 点名豁免)。
-- 【一张表,不是 cookie】与 IA-BUILD-1 的 user_dock 同一条理由(Tim):视图要跟着人从手机走到桌面,cookie 是跟着设备的。
-- 【query】地址里 ? 之后那一段,去掉翻页与一次性参数(lib/savedViews.ts);存视图时日期正好是一个快捷区间,
--   存成 date_preset=<名>,打开时按那一天重新算(Tim 2026-10-26 Q2)。
-- 【is_default】每人每张列表至多一个(部分唯一索引);只在地址里什么都没有时才套用(Q3,lib/savedViews.ts applyDefaultView)。
-- 【list_key】列表的路由(/finance/expenses);只认路由的形状。
-- 【不进变更记录】每个读者自己的屏幕偏好,没有业务含义 —— change_log_exclusions 里第十张(与 notification_reads 同一类)。
-- 【anon 什么都没有】线上新表本就不给 anon(COD-2 的默认权限);这里照写,好让重建与线上一致(判词六)。

CREATE TABLE public.saved_views (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users (id) ON DELETE CASCADE,
    list_key    text NOT NULL CHECK (list_key ~ '^/[a-z0-9/_-]*$'),
    name        text NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 60),
    query       text NOT NULL CHECK (char_length(query) <= 2000),
    is_default  boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT saved_views_name_unique UNIQUE (user_id, list_key, name)
);

CREATE UNIQUE INDEX saved_views_one_default ON public.saved_views (user_id, list_key) WHERE is_default;

COMMENT ON TABLE public.saved_views IS
    'TABLE-FEATURES-3(Tim 2026-10-25 Q3 · 2026-10-26 Q1–Q3):一个人在一张列表上存下的视图(筛选与排序,存成查询串)。只属于本人:RLS 锁在 user_id = auth.uid();每人每张列表至多一个默认(部分唯一索引),只在地址为空时套用。日期正好是快捷区间时存 date_preset=<名>,打开时重算。不进变更记录(屏幕偏好)。';

CREATE TRIGGER trg_saved_views_updated_at
    BEFORE UPDATE ON public.saved_views
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.saved_views ENABLE ROW LEVEL SECURITY;

CREATE POLICY "saved_views select own"
    ON public.saved_views
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY "saved_views insert own"
    ON public.saved_views
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "saved_views update own"
    ON public.saved_views
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "saved_views delete own"
    ON public.saved_views
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (user_id = auth.uid());

REVOKE ALL ON public.saved_views FROM anon;
REVOKE ALL ON public.saved_views FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.saved_views TO authenticated;

-- ── db/functions/change_log_exclusions.sql ──
-- db/functions/change_log_exclusions.sql
-- HISTORY-1(Tim 的 Q5):不挂变更记录触发器的表 —— 【唯一】的一份名单,每一条带理由。
--
-- 三处读它,所以它只能有一份:
--   · change_log_coverage_gaps() —— gate 的 changelog 那一行(线上 + 重建)与 fixture 234;
--   · scripts/check-change-log-coverage.mjs —— 构建里的静态检查,从本文件的 VALUES 里读;
--   · db/scripts/gen_change_log_bindings.py —— 生成绑定清单时跳过这几张。
-- ★ 规矩(docs/change-log.md):新建的每一张 public 表,要么在 db/views/zzz_change_log_triggers.sql
--   里有两条绑定,要么在这里有一行带理由的豁免。两者都没有,构建与 gate 都会红。
-- ★ MES-1(2026-10-06,MES-0 Q14,Tim):第二种被接受的豁免 —— 【采集层的三份日志】(收件箱 · 传输日志 · 网关中断)。
--   它们本身就是只追加的日志(守卫按名拒改与删);再记一遍是把规格 §2.1 警告的量翻一倍,而不多一个事实。
--   状态的变化记在行上(收件箱的 attempts · last_attempt_* · discarded_*)。
-- ★ MES-9b(2026-10-19,MES-9 Step 0 Q22,Tim):第九张 —— 门户下载记录(portal_document_downloads)。同一类:它本身就是一份只追加的日志
--   (守卫按名拒改、删、清空),每一行就是一个事实;再记一遍是把量翻一倍而不多一个事实。豁免 8 → 9。
-- ★ TABLE-FEATURES-3(2026-10-26,Tim Q3):第十张 —— 保存的视图(saved_views)。与 notification_reads 同一类:每个读者自己的屏幕偏好,
--   没有业务含义。豁免 9 → 10。
CREATE OR REPLACE FUNCTION public.change_log_exclusions()
 RETURNS TABLE(table_name text, reason text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('change_log'::text, 'The change log itself; a trigger on it would record its own writes.'::text),
        ('festival_doodles', 'Home-screen holiday artwork; screen decoration with no business meaning.'),
        ('gateway_outages', 'Ingestion log (MES-1): itself an append-only record of gateway silences; logging it again doubles the volume and adds no fact.'),
        ('home_greetings', 'Home-screen greeting text; screen decoration with no business meaning.'),
        ('ingest_inbox', 'Ingestion log (MES-1): itself an append-only landing table; its status changes are recorded on the row (attempts, last attempt, discard).'),
        ('ingest_transmissions', 'Ingestion log (MES-1): itself an append-only log of every gateway call; logging it again doubles the volume and adds no fact.'),
        ('notification_reads', 'Per-viewer "seen" marks on notifications; screen state with no business meaning.'),
        ('saved_views', 'Per-user saved list views (TABLE-FEATURES-3, Tim Q3): a reader''s own screen preference with no business meaning.'),
        ('portal_document_downloads', 'Supplier portal download log (MES-9b, MES-9 Step 0 Q22): itself an append-only record of every issued document a portal user took; logging it again doubles the volume and adds no fact.'),
        ('scan_events', 'Scan log (MES-3b): itself an append-only record of every scan resolved on a page; logging it again doubles the volume and adds no fact.');
$function$;

-- ── db/functions/decide_leave_request.sql ──
CREATE OR REPLACE FUNCTION public.decide_leave_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_req    record;
    v_type   record;
    v_need   numeric;
    v_take   numeric;
    v_bal    jsonb;
    v_avail  numeric;
    v_accrual numeric;
    g        record;
    v_used   jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('action.decide_hr_requests');

    SELECT * INTO v_req FROM leave_requests WHERE id = p_request_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND'; END IF;
    IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'REQUEST_NOT_PENDING|%', v_req.status; END IF;

    -- ★ APR-2:四眼。此前这条链【一条自批判据都没有】——
    -- 一个持 module.hr.edit 的人批得了自己的假(APR-0 §1.5 实测)。
    -- 两条腿,判据只有一份定义(见 forbid_self_approval 的抬头):
    --   ① 提这张单的人;② 这张单【说的是谁】。
    -- ★ 第二条在这里是承重的:HR 可以【代人】提单,那时 created_by 是 HR、
    --   employee_id 是员工本人 —— 只判第一条的话,那位员工(若他持
    --   module.hr.edit)照样批得了自己的假。
    PERFORM forbid_self_approval(v_req.created_by, v_req.employee_id, 'leave_request');

    -- ★ LEAVE-BAL-1(Q13):锁住这名员工的行 —— 与 submit_leave_request 同一把锁,
    --   同一个人的两张单不会同时穿过余额检查。先锁单、再锁人,各条路径同一个次序。
    PERFORM 1 FROM employees WHERE id = v_req.employee_id FOR UPDATE;

    SELECT * INTO v_type FROM leave_types WHERE code = v_req.leave_type_code;

    IF NOT p_approve THEN
        -- ★ TABLE-FEATURES-3(Tim 2026-10-25 Q11):驳回要一句理由,由库按名拒 —— 与十二条审批链的
        --   <链>_REJECT_REASON_REQUIRED 同一个形状、同一条空白判据(decide_journal_request.sql)。
        --   规矩在函数里,不在表上:线上已有一张理由为空的旧驳回,表约束会拒它(TF-3 Step 0)。
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'LEAVE_REJECT_REASON_REQUIRED|%', v_req.code;
        END IF;
        UPDATE leave_requests SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid()
        WHERE id = p_request_id;

        -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
        -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
        PERFORM record_approval_decision('leave_request', p_request_id, 'rejected', NULL, p_notes);
        RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','rejected');
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- ★ LEAVE-BAL-1:审批时再查一次 —— 【每一个有额度的假别】,不只是年假。
    --   比的是 'available' = 额度 − 已批,【不扣别人还在等的单】(Tim Q10 Option A):
    --   待批不是承诺,而只按已批判,批准就不可能让已批超过额度;
    --   扣待批的话,两张各自够、合起来不够的旧单会互相卡死,谁都批不了。
    --   于是先批的那张过,后一张被拒并说出"可用 0 天"。
    -- ══════════════════════════════════════════════════════════════════════
    v_bal := leave_balance(v_req.employee_id, v_req.leave_type_code, v_req.start_date);
    IF (v_bal->>'balance_checked')::boolean THEN
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_req.days THEN
            IF v_type.is_accrued THEN
                RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                    trim_scale(GREATEST(v_avail, 0)), trim_scale(v_req.days);
            END IF;
            RAISE EXCEPTION 'INSUFFICIENT_BALANCE|%|%',
                trim_scale(GREATEST(v_avail, 0)), trim_scale(v_req.days);
        END IF;
    END IF;

    IF v_type.is_accrued THEN
        v_need := v_req.days;
        -- ══════════════════════════════════════════════════════════════════
        -- 【先用旧的】:按 expires_on 从早到晚扣。
        -- 结转来的行有失效日,当年累积没有 —— 所以结转天数天然排在前面被先吃掉,
        -- 反过来的话它们会先烂掉,对员工是净损失。
        -- ══════════════════════════════════════════════════════════════════
        FOR g IN
            SELECT gr.id, gr.days, gr.expires_on, gr.leave_year, gr.grant_type,
                   gr.days
                   - COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                               FROM leave_consumption c WHERE c.leave_grant_id = gr.id), 0)
                   - COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                               WHERE cf.source_grant_id = gr.id AND cf.grant_type = 'carry_forward'
                                 AND cf.deleted_at IS NULL), 0) AS remaining
            FROM leave_grants gr
            WHERE gr.employee_id = v_req.employee_id AND gr.leave_type_code = v_req.leave_type_code
              AND gr.deleted_at IS NULL AND gr.granted_on <= v_req.start_date
              AND (gr.expires_on IS NULL OR gr.expires_on >= v_req.start_date)
            ORDER BY gr.expires_on NULLS LAST, gr.granted_on
        LOOP
            EXIT WHEN v_need <= 0;
            IF g.remaining <= 0 THEN CONTINUE; END IF;
            v_take := LEAST(g.remaining, v_need);
            INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days)
            VALUES (p_request_id, g.id, 'draw', v_take);
            v_need := v_need - v_take;
            v_used := v_used || jsonb_build_object('source', 'grant', 'grant_id', g.id,
                                                   'leave_year', g.leave_year,
                                                   'grant_type', g.grant_type,
                                                   'expires_on', g.expires_on, 'days', v_take);
        END LOOP;

        -- 结转吃完了还不够 → 从当年度的派生累积里扣(记 accrual_year,不挂授予行)
        IF v_need > 0 AND v_type.is_accrued THEN
            v_accrual := available_annual_accrual(v_req.employee_id, v_req.start_date);
            v_take := LEAST(v_accrual, v_need);
            IF v_take > 0 THEN
                INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days, accrual_year)
                VALUES (p_request_id, NULL, 'draw', v_take,
                        EXTRACT(YEAR FROM v_req.start_date)::integer);
                v_need := v_need - v_take;
                v_used := v_used || jsonb_build_object('source', 'accrual',
                                                       'leave_year', EXTRACT(YEAR FROM v_req.start_date)::integer,
                                                       'grant_type', 'monthly_accrual',
                                                       'expires_on', NULL, 'days', v_take);
            END IF;
        END IF;

        IF v_need > 0 THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_req.days - v_need), trim_scale(v_req.days);
        END IF;
    END IF;

    UPDATE leave_requests SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid()
    WHERE id = p_request_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('leave_request', p_request_id, 'approved', NULL, p_notes);

    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','approved',
                              'days', v_req.days, 'consumed_from', v_used);
END;
$function$;

-- ── db/functions/decide_medical_claim.sql ──
CREATE OR REPLACE FUNCTION public.decide_medical_claim(p_claim_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_claim record; v_bal jsonb; v_remaining numeric;
BEGIN
    PERFORM require_permission('action.decide_hr_requests');

    SELECT * INTO v_claim FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;
    IF v_claim.status <> 'submitted' THEN RAISE EXCEPTION 'CLAIM_NOT_SUBMITTED|%', v_claim.status; END IF;

    -- ★ APR-2:四眼,与 decide_leave_request 逐字同一支判据、同样两条腿。
    -- 这条链此前也一条都没有 —— 而它【是真的在批钱】(amount_sgd)。
    PERFORM forbid_self_approval(v_claim.created_by, v_claim.employee_id, 'medical_claim');

    IF NOT p_approve THEN
        -- ★ TABLE-FEATURES-3(Tim 2026-10-25 Q11):驳回要一句理由,由库按名拒 —— 与十二条审批链的
        --   <链>_REJECT_REASON_REQUIRED 同一个形状、同一条空白判据(decide_journal_request.sql)。
        --   规矩在函数里,不在表上:线上已有一张理由为空的旧驳回,表约束会拒它(TF-3 Step 0)。
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'MEDICAL_CLAIM_REJECT_REASON_REQUIRED|%', v_claim.code;
        END IF;
        UPDATE medical_claims SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;

        -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
        -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
        PERFORM record_approval_decision('medical_claim', p_claim_id, 'rejected', NULL, p_notes);
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','rejected');
    END IF;

    v_bal := medical_claim_balance(v_claim.employee_id, v_claim.claim_year);
    v_remaining := (v_bal->>'remaining_sgd')::numeric;
    IF v_claim.amount_sgd > v_remaining THEN
        RAISE EXCEPTION 'CLAIM_EXCEEDS_LIMIT|%|%', v_remaining, v_claim.amount_sgd;
    END IF;

    UPDATE medical_claims SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('medical_claim', p_claim_id, 'approved', NULL, p_notes);

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','approved',
                              'amount_sgd', v_claim.amount_sgd,
                              'remaining_after', v_remaining - v_claim.amount_sgd,
                              -- 与补偿一样,把"没有入账"写进返回值,免得调用方以为记过账了
                              'expense_posted', false,
                              'note', 'No expense is posted. Reimbursement route (payroll vs separate payment) is an operational decision; link it via medical_claims.expense_id once chosen.');
END;
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;
