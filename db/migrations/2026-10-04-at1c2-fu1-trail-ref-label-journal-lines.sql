-- db/migrations/2026-10-04-at1c2-fu1-trail-ref-label-journal-lines.sql
-- AUDIT-TRAIL-1c-2 · fu1 —— trail_ref_label 的分录行名字("JE-… · 科目"),同一刀里漏进主迁移的那一句(v1.4.33 的一部分,未发布)。
--
-- 【为什么有这一份】主迁移(2026-10-04-at1c2-trails-documents-and-contracts.sql)是从镜像拼出来的 —— 而 db/functions/trail_ref_label.sql
--   在拼完之后又加了一支(journal_lines → "JE-… · 科目":对账单的一行匹配到的那一行分录的名字)。试跑与应用用的都是那一份拼好的旧文件,
--   于是线上少了这一支,镜像多了这一支;整门的判词【镜像 vs 线上】当场红在这一支函数上(GATE_EXIT=1,结构差异只有这一处)。
--   修法是把线上补成镜像(镜像是真源),不是把镜像改回线上。
-- 【做什么】trail_ref_label 原地替换(同一签名,镜像原样)。不改任何表、策略、授权、触发器;不写任何业务行。
-- 【破窗】与主迁移同一个窗口(起点 01:18:22 CST):这一支只给审计记录里"匹配到的那一行分录"一个名字;它不在的这几分钟里那一行说成
--   "Matched to"(没有名字)—— 而旧应用根本不读对账单的审计记录。什么都不坏。
-- 【备份】主迁移之前那一份(evoltrya-backup-2026-10-04-0058.dump,BACKUP_EXIT=0,01:15:48)早于本文件;两者之间线上只换了几支审计记录的
--   读法函数,没有一行业务数据动过。
BEGIN;

DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'AT1C2FU1_PRE|approvals are expected ON'; END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 44 THEN
        RAISE EXCEPTION 'AT1C2FU1_PRE|expected the 44 subjects of 1c-2 (the main migration first), got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF position('journal_lines' in pg_get_functiondef('public.trail_ref_label(text, text, text)'::regprocedure)) > 0 THEN
        RAISE EXCEPTION 'AT1C2FU1_PRE|trail_ref_label already names journal lines';
    END IF;
END;
$pre$;

CREATE TEMP TABLE at1c2fu1_log_before ON COMMIT DROP AS SELECT count(*) AS n, max(seq) AS mx FROM change_log;

-- db/functions/trail_ref_label.sql
-- AUDIT-TRAIL-1a(Tim 的 Q12 · Q13 · Q40):一个被引用的值 → 屏幕上认得出的名字。数据库解析,界面只负责造句。
--   返回 {"label": …, "gone": bool, "person": {…}}(person 只在 p_table = 'auth.users' 时有):
--   · 单据(document_types 登记的表)→ 单据编号(PO-2026-0010);客户 / 供应商 → 法定名;物料 → 名称;
--     员工 → 称呼名,没有就法定名;批次 → 编号 · 物料名(外加 unit);采购单明细行 → 采购单编号 line N;
--     字典(有 name_en 的表)→ name_en;币种 → 代码;其余依次试 name / legal_name / title / label。
--   · 一个都没有 → label 为 NULL,界面说 "a <thing>"。【绝不回落到 uuid 或内部代码】。
--   · 那一行已经被硬删 → 取 change_log 里它最后一份完整影像,gone = true(界面加 "(since deleted)");
--     连影像都没有(早于变更记录,或从未存在)→ label NULL + gone = true(界面说 "a … that has since been deleted")。
--   · 'auth.users':一个登录账号 → 那个人(trail_actor 同一套答法)。
-- AUDIT-TRAIL-1b-1:
--   · 加工单多带一个 ended(它已经回滚了)—— 批次页上"用在加工 PROC-…"那一条据此加一句灰字
--     "This processing was later rolled back"(旧批次记录的 run_voided,Q5)。
--   · 交接班 → "DD/MM/YYYY · 班次";停机 → "机器编号 · DD/MM/YYYY HH:MM"(新加坡时间)—— 两张表都没有编号或名字,
--     以前只能说 "a handover" / "a downtime"。
-- AUDIT-TRAIL-1b-2:订单 / 报价明细行 → "SO-… line N";港口 → "代码 名称";航段 → "起运港 → 目的港";
--   执照与合规证书 → "种类 · 编号";附件 → 文件名;集装箱单据 → 单据种类 —— 这几张表都没有编号或 name 一类的列。
--   物料多带一个 unit(与批次同一个做法):订单 / 报价明细行的数量据此说成 "10 kg"。
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 的 Q12 · Q33):
--   · 员工 → 走 trail_actor(与"谁做的"同一份答法):不持 module.hr.view 的读者只认得出他自己,别人一律 Restricted ——
--     与 ActorName、与每一页的人名同一条规矩(§9.7 早就说"每一个指着人的值都走同一个函数",而此前这一支直接把名字交了出去)。
--     付款、费用、报销单、付款申请上的 employee_id 都是这一种。匿名化了的人说 "A former employee"(以前是一个空名字)。
--   · 单据(document_types 里 link_mode = 'detail' 的)多带一个 href(详情页的路径)—— 审计记录里"被 JE-… 冲销"那一行
--     是一个链接(Q33),路径来自登记表,界面不拼路由。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §g · Q14):这几张表没有编号或名字,以前只能说 "a …":
--   · 销售 → "OUT-2026-0186 sale 01/08/2026"(卖的那一批 + 售出日;与 "PO-… line N" 同一种说法),外加 href 指向它的应收页
--     (Q14:销售没有 code 列,所以【不】进 document_types —— 进了,全站搜索会对它拼一句 SELECT code,当场报错;
--      Record 一栏的名字与链接由这里与 trail_row_record 给,与单据同一个形状);
--   · 汇率 → "USD · TT selling rate · 01/08/2026";对账单行 → "BS-… line N";分录行 → "JE-… · 科目";申报格 → "Box 1";
--     对账记录 → "BS-… reconciliation DD/MM/YYYY";折旧 → "FA-… · period ending DD/MM/YYYY"。
-- 【属主身份】按表名动态读;EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.trail_ref_label(p_table text, p_column text, p_value text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_img   jsonb;
    v_gone  boolean := false;
    v_label text;
    v_doc   boolean;
    v_extra text;
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'auth.users' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        RETURN jsonb_build_object('person', trail_actor('prelog', p_value::uuid, NULL));
    END IF;
    IF to_regclass(format('public.%I', p_table)) IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_table = 'employees' AND p_column = 'id' THEN
        IF p_value !~ '^[0-9a-fA-F-]{36}$' THEN
            RETURN NULL;
        END IF;
        -- label 一并带回(只在认得出名字时):/settings/change-history 的 Record 一栏读 label,不读 person
        v_img := trail_actor('prelog', NULL, p_value::uuid);
        RETURN jsonb_build_object('person', v_img, 'gone', false,
                                  'label', CASE WHEN v_img ->> 'state' = 'person' THEN v_img ->> 'name' END);
    END IF;
    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.%I::text = $1 LIMIT 1', p_table, p_column)
       INTO v_img USING p_value;
    IF v_img IS NULL THEN
        v_gone := true;
        SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO v_img
          FROM change_log c
         WHERE c.table_name = p_table AND c.row_key = jsonb_build_object(p_column, p_value)
           AND c.op IN ('INSERT', 'DELETE')
         ORDER BY c.seq DESC LIMIT 1;
        IF v_img IS NULL THEN
            RETURN jsonb_build_object('label', NULL, 'gone', true);
        END IF;
    END IF;
    v_doc := EXISTS (SELECT 1 FROM document_types d WHERE d.table_name = p_table);
    v_label := CASE
        WHEN p_table = 'employees' THEN
            CASE WHEN v_img ->> 'anonymised_at' IS NULL
                 THEN COALESCE(NULLIF(v_img ->> 'preferred_name', ''), v_img ->> 'legal_name') END
        WHEN p_table IN ('suppliers', 'customers') THEN v_img ->> 'legal_name'
        WHEN p_table = 'materials' THEN v_img ->> 'name'
        WHEN p_table = 'currencies' THEN v_img ->> 'code'
        WHEN p_table = 'purchase_order_lines' THEN
            (SELECT po.code FROM purchase_orders po WHERE po.id::text = v_img ->> 'purchase_order_id')
            || ' line ' || (v_img ->> 'line_no')
        WHEN v_doc AND v_img ? 'code' THEN v_img ->> 'code'
        WHEN v_img ? 'name_en' THEN v_img ->> 'name_en'
        WHEN v_img ? 'name' THEN v_img ->> 'name'
        WHEN v_img ? 'legal_name' THEN v_img ->> 'legal_name'
        WHEN v_img ? 'title' THEN v_img ->> 'title'
        WHEN v_img ? 'label' THEN v_img ->> 'label'
    END;
    IF p_table = 'shift_handovers' THEN
        v_label := to_char((v_img ->> 'handover_date')::date, 'DD/MM/YYYY')
                   || COALESCE(' · ' || (SELECT s.name_en FROM shifts s WHERE s.code = v_img ->> 'shift_code'), '');
    ELSIF p_table = 'equipment_downtime' THEN
        v_label := COALESCE((SELECT fa.code FROM fixed_assets fa WHERE fa.id::text = v_img ->> 'equipment_id') || ' · ', '')
                   || to_char(((v_img ->> 'started_at')::timestamptz) AT TIME ZONE 'Asia/Singapore', 'DD/MM/YYYY HH24:MI');
    ELSIF p_table IN ('sales_order_lines', 'quote_lines', 'invoice_lines') THEN
        -- AUDIT-TRAIL-1b-2:订单 / 报价的明细行 → "SO-2026-0001 line 1"(与采购单明细同一种说法)
        -- AUDIT-TRAIL-1c-1:发票明细行同一种说法(贷项通知的每一行冲的是发票的哪一行)
        v_label := CASE p_table
            WHEN 'sales_order_lines' THEN (SELECT so.code FROM sales_orders so WHERE so.id::text = v_img ->> 'sales_order_id')
            WHEN 'invoice_lines' THEN (SELECT i.code FROM invoices i WHERE i.id::text = v_img ->> 'invoice_id')
            ELSE (SELECT q.code FROM quotes q WHERE q.id::text = v_img ->> 'quote_id') END
            || ' line ' || (v_img ->> 'line_no');
    ELSIF p_table = 'ports' THEN
        -- 港口 → "SGSIN Singapore"(航段页、货代页上的同一种写法)
        v_label := concat_ws(' ', v_img ->> 'code', v_img ->> 'name');
    ELSIF p_table = 'lanes' THEN
        -- 航段没有名字 → "起运港 → 目的港"(两头各按港口那一句说)
        v_label := COALESCE((SELECT concat_ws(' ', pt.code, pt.name) FROM ports pt WHERE pt.id::text = v_img ->> 'origin_port_id'), '?')
                   || ' → ' ||
                   COALESCE((SELECT concat_ws(' ', pt.code, pt.name) FROM ports pt WHERE pt.id::text = v_img ->> 'destination_port_id'), '?');
    ELSIF p_table IN ('company_compliance', 'supplier_compliance') THEN
        -- 执照 / 证书 → "证书种类 · 编号"
        v_label := concat_ws(' · ', (SELECT ct.name_en FROM certificate_types ct WHERE ct.code = v_img ->> 'cert_type_code'),
                             NULLIF(v_img ->> 'cert_no', ''));
    ELSIF p_table IN ('customer_attachments', 'supplier_attachments') THEN
        v_label := v_img ->> 'file_name';
    ELSIF p_table = 'container_documents' THEN
        v_label := v_img ->> 'document_type';
    ELSIF p_table = 'sales_records' THEN
        v_label := COALESCE((SELECT ob.code FROM output_batches ob WHERE ob.id::text = v_img ->> 'output_batch_id') || ' sale ', 'Sale ')
                   || to_char((v_img ->> 'sale_date')::date, 'DD/MM/YYYY');
        RETURN jsonb_build_object('label', v_label, 'gone', v_gone)
               || CASE WHEN p_column = 'id' AND NOT v_gone
                       THEN jsonb_build_object('href', '/finance/receivables/' || p_value) ELSE '{}'::jsonb END;
    ELSIF p_table = 'fx_rates' THEN
        v_label := concat_ws(' · ', v_img ->> 'currency',
                             CASE v_img ->> 'rate_type' WHEN 'tt_buy' THEN 'TT buying rate' WHEN 'tt_sell' THEN 'TT selling rate'
                                                        WHEN 'mid' THEN 'Mid rate' END,
                             to_char((v_img ->> 'rate_date')::date, 'DD/MM/YYYY'));
    ELSIF p_table = 'journal_lines' THEN
        -- 对账单的一行匹配到的那一行分录 → "JE-2026-0001 · Cash at Bank – SGD"(分录号 · 科目)
        v_label := concat_ws(' · ', (SELECT je.code FROM journal_entries je WHERE je.id::text = v_img ->> 'entry_id'),
                             (SELECT a.name_en FROM accounts a WHERE a.id::text = v_img ->> 'account_id'));
    ELSIF p_table = 'bank_statement_lines' THEN
        v_label := (SELECT bs.code FROM bank_statements bs WHERE bs.id::text = v_img ->> 'statement_id') || ' line ' || (v_img ->> 'line_no');
    ELSIF p_table = 'gst_return_boxes' THEN
        v_label := 'Box ' || regexp_replace(v_img ->> 'box', '^box', '');
    ELSIF p_table = 'bank_reconciliations' THEN
        v_label := (SELECT bs.code FROM bank_statements bs WHERE bs.id::text = v_img ->> 'statement_id')
                   || ' reconciliation ' || to_char(((v_img ->> 'reconciled_at')::timestamptz) AT TIME ZONE 'Asia/Singapore', 'DD/MM/YYYY');
    ELSIF p_table = 'fixed_asset_depreciation' THEN
        v_label := (SELECT fa.code FROM fixed_assets fa WHERE fa.id::text = v_img ->> 'asset_id')
                   || ' · period ending ' || to_char((v_img ->> 'period_end')::date, 'DD/MM/YYYY');
    ELSIF p_table = 'processing_runs' THEN
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'ended', v_img ->> 'deleted_at' IS NOT NULL);
    END IF;
    IF p_table = 'materials' THEN
        -- AUDIT-TRAIL-1b-2:物料带回它的单位 —— 订单 / 报价的明细行没有单位列,"10"要说成"10 kg"
        --   只在影像里真有单位时才带(一份早于变更记录、只剩名字的影像不说单位 —— 与"名字 + gone"那一形状逐字相同)
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
               || CASE WHEN v_img ->> 'unit' IS NOT NULL THEN jsonb_build_object('unit', v_img ->> 'unit') ELSE '{}'::jsonb END;
    END IF;
    IF p_table IN ('inbound_batches', 'output_batches') THEN
        IF v_img ->> 'material_id' IS NOT NULL THEN
            SELECT m.name INTO v_extra FROM materials m WHERE m.id::text = v_img ->> 'material_id';
            IF v_extra IS NOT NULL THEN
                v_label := v_label || ' · ' || v_extra;
            END IF;
        END IF;
        -- 批次的数量单位随名字一起带回 —— 加工单的"用了 300"要说成"300 kg",而投入 / 产出行自己没有单位列
        RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone, 'unit', v_img ->> 'unit');
    END IF;
    RETURN jsonb_build_object('label', NULLIF(v_label, ''), 'gone', v_gone)
           || COALESCE((SELECT jsonb_build_object('href', d.route || '/' || p_value) FROM document_types d
                         WHERE d.table_name = p_table AND d.link_mode = 'detail' AND p_column = 'id' AND NOT v_gone
                         ORDER BY d.key LIMIT 1), '{}'::jsonb);
END;
$function$;

DO $proof$
DECLARE v jsonb; jl uuid;
BEGIN
    IF position('journal_lines' in pg_get_functiondef('public.trail_ref_label(text, text, text)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'AT1C2FU1_PROOF|trail_ref_label still does not name journal lines';
    END IF;
    SELECT l.id INTO jl FROM journal_lines l ORDER BY l.created_at LIMIT 1;
    IF jl IS NOT NULL THEN
        v := trail_ref_label('journal_lines', 'id', jl::text);
        IF COALESCE(v ->> 'label', '') !~ '^JE-' THEN
            RAISE EXCEPTION 'AT1C2FU1_PROOF|a journal line should be named "JE-… · account", got %', v;
        END IF;
        RAISE NOTICE 'AT1C2FU1 journal line % is named «%»', jl, v ->> 'label';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1c2fu1_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1C2FU1_PROOF|change_log moved';
    END IF;
END;
$proof$;

NOTIFY pgrst, 'reload schema';

COMMIT;
