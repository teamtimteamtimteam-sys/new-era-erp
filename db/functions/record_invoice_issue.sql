CREATE OR REPLACE FUNCTION public.record_invoice_issue(p_invoice_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv   invoices%ROWTYPE;
    v_name  text;
    v_lines integer;
    v_next  integer;
BEGIN
    -- 【第一道门:记档案这个动作】另一道(data.view_banking)在渲染那条路上 ——
    -- 见本刀迁移抬头:两道门是【合取】,而且都不是顺带继承来的。
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;

    -- 【作废了的发票不再签发,但既有的版本仍然读得到、取得回】
    -- 作废不删任何东西(status/void_reason/voided_at/voided_by 留在行上,明细行
    -- 由 trg_invoices_propagate_void 打上标记但一行不少)。所以"已经发出去过的
    -- 那几版"仍然是真实发生过的事;被拒的只是【再发一版】——
    -- 那两个状态的意思是"这张单据结束了"(与 record_qt_issue 拒 declined/converted
    -- 同一条)。作废后的 PDF 仍然打得开,而且会印上 VOID 水印,那正是它的用途:
    -- 让手里拿着旧件的人认得出来。
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'INV_VOIDED_NOT_ISSUABLE|%|%', v_inv.code, v_inv.status;
    END IF;

    -- 【没有行的发票不给签发】那是一张白纸,而客户要照着上面的数付款。
    -- 渲染那条路也拦得住(它拿不到 totals 就 409),但那道拦截报的是
    -- "金额取不到",既可能是没有行、也可能是没有权限 —— 两件事该分开说。
    SELECT count(*) INTO v_lines FROM invoice_lines WHERE invoice_id = p_invoice_id;
    IF v_lines = 0 THEN
        RAISE EXCEPTION 'INV_NO_LINES|%', v_inv.code;
    END IF;

    -- 【公司抬头没填就不给签发】一张没有公司名的发票寄出去是真实事故,而这条
    -- 判断在渲染那条路上已经有了(它 409 并指去 /finance/company)。这里【也】
    -- 有一份,不是重复:那一份挡的是"渲染出一份残缺的 PDF",这一份挡的是
    -- "把一份残缺的东西记进档案"。档案说"某年某月发出去过第 1 版",而那一版
    -- 没有抬头 —— 记录本身就成了一句假话。
    SELECT btrim(COALESCE(legal_name, '')) INTO v_name FROM company_profile LIMIT 1;
    IF v_name IS NULL OR v_name = '' THEN
        RAISE EXCEPTION 'INV_PROFILE_INCOMPLETE';
    END IF;

    -- 【版本由数据库裁决】对象键不含版本号,并发安全靠这把每单据一把的咨询锁
    -- (与其余五个族逐字同一套)。
    PERFORM pg_advisory_xact_lock(hashtext('invoice_issue_' || p_invoice_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next
      FROM invoice_issues WHERE invoice_id = p_invoice_id;

    INSERT INTO invoice_issues (invoice_id, version, file_path, sha256, issued_by)
    VALUES (p_invoice_id, v_next, p_file_path, p_sha256, auth.uid());

    -- 【两种 kind 走同一个函数,而这不是偷懒】sale 与 order 的区别在【它们怎么
    -- 产生应收】(一个什么都不过账、一个开票即过账),而"这一版发出去了"这件事
    -- 与那个区别毫无关系:客户手里拿到的都是一张纸。分成两个函数会让同一件事
    -- 有两处实现,而它们迟早各说各话。
    RETURN jsonb_build_object(
        'invoice_id', p_invoice_id,
        'code', v_inv.code,
        'kind', v_inv.kind,
        'version', v_next);
END;
$function$

;
