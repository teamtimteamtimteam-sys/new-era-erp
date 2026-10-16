-- db/migrations/2026-10-16-mes7a2-spare-parts.sql
-- MES-7a-2 —— 备件:按批收货,出给一条保养记录(借 6800 Repairs & Maintenance / 贷 1200,按落地单价),带理由退回
--   (MES 组的第十七刀,v1.4.53;发布那一行在 docs/handbacks/MES-7a-2.md 的抬头)。由 db/scripts/build_mes7a2_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-16:MES-7a Step 0 的 Q2 · Q10–Q17 · Q20–Q23 照推荐裁定;Q11:费用科目 6800 Repairs & Maintenance,系统科目)
--   ① 科目表多一行 6800 Repairs & Maintenance(expense,is_system —— issue_spare_parts / return_spare_parts / reprice_inbound_batch 按 code 点名)。
--   ② 分录来源多一种 maintenance_part(出给保养 / 退回;journal_entry_reversal_route 认它作 source_path —— 更正是一行退回,不是冲掉分录)。
--   ③ 库存流水多两种类型 maintenance_issue(为负,进料一侧,可用桶)与 maintenance_return(为正);只由那两支函数写
--      (trg_inventory_movements_maintenance_ctx 按名拒别的写法 MAINTENANCE_MOVEMENT_THROUGH_FUNCTION_ONLY)。
--   ④ maintenance_part_issues(一行一次出库或一次退回;只可追加;只经函数写;不带钱 —— 钱在分录上)进变更记录(豁免仍是 8;没有遮蔽的列)。
--   ⑤ issue_spare_parts · return_spare_parts(码 module.inventory.edit,没有审批 —— Q10):只出 spare_part 的批;只出给没有资本化的保养记录;
--      数量 ≤ 可用;没定价的批按名拒 SPARE_PART_UNPRICED(暂定价是价);质量暂扣挡出库不挡退回(guard_quality_hold 多认一种);
--      一条还挂着件的保养记录不能再资本化(trg_equipment_maintenance_parts_capitalise,MAINTENANCE_HAS_PARTS)。
--   ⑥ 改价:reprice_split 多一个入参(出给保养的净数量),已出给保养那一份的价差进 6800、不进 5000 —— 一份算术照旧两个调用者
--      (reprice_inbound_batch · preview_reprice_inbound_batch);签名换了,旧的那一支 DROP。
--   ⑦ 存货控制科目勾稽把 maintenance_part 的 1200 行归回批次,M3 / M4 的"已被消耗"只算加工消耗(inventory_control_reconciliation)。
--   ⑧ 库存月度滚动多一列 issued_to_maintenance(DROP + CREATE 两张视图:新列排在 voided 之后、moved 之前);质量树多一条去向 maintenance;
--      待定值多一支 V21(备件的最低库存);备件库存的读视图 spare_part_stock(可用 · 有没有价 · 在不在暂扣 —— 与函数同一组判据,不带钱)。
--   ⑨ 审计:不加新主语;出库记录在 equipment 下(家)与 inbound_batch 下(连同那张分录)。
--   material_kinds 那一行备件的说明在镜像里改写(Q2:按批收货、挂保养记录出库、不逐件追溯)—— 它是 RUNTIME CONFIG,本迁移【不】改线上那一行。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权一行不动;不写、不改任何一行既有的批次、流水、分录、物料、保养记录、证书;
--   不建任何备件物料、批次、出库、退回或最低库存;不回填。require_calibrated_since 保持空。线上由本迁移造出的只有:6800 那一个科目、
--   两种流水类型(与一种分录来源)、一张空表、两支函数与它们的守卫、一张读视图、V21 那一支(线上没有备件物料,它读出 0 行)。
--
-- 【破窗】(Q21:这一窗什么都不坏)旧应用不写这两种新类型、不读新表;库存滚动两张视图换成 DROP + CREATE 的那一瞬在同一笔事务里,
--   旧应用读的列一列不少(只多一列)。旧应用的改价预览不读多出来的那个返回键。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动,admin 持目录里每一个码(79);在途单据一张不少、一张不多,每一张仍有
--   一个不是它当事人的决定人;七个账号一个都没被停;既有的批次、流水、分录、物料、物料种类、保养、停机、间隔、资产、不合格报告、证书、字节档案、
--   申请、费用、付款、审批留痕、加工单、盘点、科目(减去 6800)逐字未变;科目恰好多一行 6800(系统、启用);流水 14 种类型;出库表 0 行、两种新流水
--   0 行;旧的 reprice_split 不在了;守卫都在;本事务往变更记录只写了科目那一行;三支对外的函数员工调得到、四支内层与触发器调不到;anon 能执行的
--   【恰好】两支;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);提醒 66 支、待定值 24 支;299 张表。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES7A2_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM accounts WHERE code = '6800') THEN
        RAISE EXCEPTION 'MES7A2_PRE|account 6800 already exists: %', (SELECT name_en FROM accounts WHERE code = '6800');
    END IF;
    IF to_regclass('public.maintenance_part_issues') IS NOT NULL OR to_regclass('public.spare_part_stock') IS NOT NULL
       OR to_regprocedure('public.issue_spare_parts(uuid, date, jsonb)') IS NOT NULL
       OR to_regprocedure('public.reprice_split(numeric, numeric, numeric, numeric, numeric)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A2_PRE|MES-7a-2 objects already exist';
    END IF;
    IF to_regprocedure('public.reprice_split(numeric, numeric, numeric, numeric)') IS NULL THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected the four-argument reprice_split';
    END IF;
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'inventory_movements_movement_type_check')) LIKE '%maintenance%'
       OR pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'journal_entries_source_type_check')) LIKE '%maintenance%' THEN
        RAISE EXCEPTION 'MES7A2_PRE|the movement / source type checks already know maintenance';
    END IF;
    IF EXISTS (SELECT 1 FROM materials WHERE kind_code = 'spare_part') THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected no spare-part material on live (opening reading)';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected a catalogue of 79 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66 THEN
        RAISE EXCEPTION 'MES7A2_PRE|operations_now should have 66 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES7A2_PRE|pending_values should have 23 arms';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 298 THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected 298 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A2_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes7a2_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
CREATE TEMP TABLE mes7a2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes7a2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes7a2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes7a2_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t ) AS inventory_movements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM price_history t ) AS price_history,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t ) AS materials,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM material_kinds t ) AS material_kinds,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_maintenance t ) AS equipment_maintenance,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_downtime t ) AS equipment_downtime,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_service_intervals t ) AS equipment_service_intervals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_assets t ) AS fixed_assets,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM nonconformance_reports t ) AS nonconformance_reports,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) AS certificates_of_destruction,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_analysis t ) AS certificates_of_analysis,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM coa_issues t ) AS coa_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM warehouse_requests t ) AS warehouse_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_price_requests t ) AS receipt_price_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t ) AS processing_runs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_inputs t ) AS processing_inputs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM stocktakes t ) AS stocktakes,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM stocktake_lines t ) AS stocktake_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t WHERE code <> '6800') AS accounts;

-- ── 1 · 新函数(镜像原样),先于新表:两种保养流水只经函数 · 出库记录只可追加只经函数 · 挂着件不能资本化(三支触发器函数)──

-- db/functions/guard_maintenance_movement.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12,Tim):【备件的出与退只经那两支函数】—— inventory_movements BEFORE INSERT(行级),
--   只对 maintenance_issue / maintenance_return 两种类型触发(触发器上的 WHEN)。issue_spare_parts / return_spare_parts 在事务里设
--   evoltrya.part_issue_ctx(写完即清);没有它 = 别的写法(另一支属主函数、一张盘点、一次转移、一句手写的 INSERT)想写这两种类型,
--   按名拒 MAINTENANCE_MOVEMENT_THROUGH_FUNCTION_ONLY|<类型>。于是每一行这种流水都恰好对应 maintenance_part_issues 的一行,
--   而那一行带着保养记录、理由与分录 —— 流水自己不带这些指针。
--   【为什么是 INVOKER】它只读一个会话设置,不读任何表(guard_movement_direct_insert 同形)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.guard_maintenance_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF COALESCE(current_setting('evoltrya.part_issue_ctx', true), '') = '' THEN
        RAISE EXCEPTION 'MAINTENANCE_MOVEMENT_THROUGH_FUNCTION_ONLY|%', NEW.movement_type;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_part_issue_write.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12,Tim):maintenance_part_issues 的两道守卫,一支函数 ——
--   UPDATE / DELETE(语句级):对谁都按名拒 PART_ISSUE_IMMUTABLE|<动作> —— 只可追加,一次出错的出库靠一行退回更正。
--   INSERT(行级):会话里直连插入(row_security_active = 真)按名拒 PART_ISSUES_THROUGH_FUNCTION_ONLY;那两支 DEFINER 函数(属主路径)放行。
--   【为什么是 INVOKER】row_security_active 必须反映【调用者】的视角(guard_equipment_direct_write 同一个理由)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.guard_part_issue_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        RAISE EXCEPTION 'PART_ISSUE_IMMUTABLE|%', lower(TG_OP);
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'PART_ISSUES_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_maintenance_capitalise_parts.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q14,Tim):【一条已经出过备件的保养记录,不能再资本化】—— equipment_maintenance BEFORE UPDATE OF
--   capitalised, capitalised_expense_id。从库里出给它的件已经照维修费(6800)记掉了,而资本化走的是费用单(record_expense 回填
--   capitalised_expense_id)—— 那些件没有一条路进资产成本,于是一条"资本化的大修"会少计资产。按名拒
--   MAINTENANCE_HAS_PARTS|<机器>|<日期>|<还挂着的件的条数>。另一个方向(往一条资本化了的记录上出件)由 issue_spare_parts 拒。
--   判据是【还挂着的】件:出库数量 − 已退的 > 0 的那几行。全部退回之后,这条记录上就没有件了,可以资本化。
--   "备件进资本化大修"登记在 docs/known-issues.md,等第一次真的大修再定那条路。
--   DEFINER:它要读全部出库记录(读策略认码),不能因为按按钮的人读不到就放过去(guard_quality_hold 同一个理由)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.guard_maintenance_capitalise_parts()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n    int;
    v_code text;
BEGIN
    IF NOT ((NEW.capitalised AND NOT OLD.capitalised)
            OR (NEW.capitalised_expense_id IS NOT NULL AND OLD.capitalised_expense_id IS NULL)) THEN
        RETURN NEW;
    END IF;
    SELECT count(*) INTO v_n
      FROM maintenance_part_issues i
     WHERE i.maintenance_id = NEW.id AND i.kind = 'issue'
       AND i.quantity > COALESCE((SELECT sum(r.quantity) FROM maintenance_part_issues r WHERE r.returns_issue_id = i.id), 0);
    IF v_n > 0 THEN
        SELECT code INTO v_code FROM fixed_assets WHERE id = NEW.equipment_id;
        RAISE EXCEPTION 'MAINTENANCE_HAS_PARTS|%|%|%', v_code, NEW.performed_on, v_n;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 2 · 科目表多一行 6800(与 db/tables/accounts.sql 系统段那一行逐字同一份)───────────────────────────
INSERT INTO public.accounts (code, name_en, name_zh, account_type, is_system, is_monetary) VALUES
    ('6800', 'Repairs & Maintenance', '维修保养费', 'expense', true, false);

-- ── 3 · 分录来源多一种 maintenance_part(镜像 db/tables/journal_entries.sql 的列内 CHECK;约束名是线上那一个)────────
ALTER TABLE public.journal_entries DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries ADD CONSTRAINT journal_entries_source_type_check
    CHECK (source_type IN ('manual','purchase','sale','processing_cost','allocation','stocktake','writeoff','payment','fx','expense','prepayment','payroll','transfer','revaluation','depreciation','asset_disposal','year_close','freight','invoice','shipment','credit_note','wht_remittance','maintenance_part'));

-- ── 4 · 库存流水:两种新类型与它们的符号、侧面(镜像 db/tables/inventory_movements.sql);只经函数的守卫 ──────────────
ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_movement_type_check;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_movement_type_check
    CHECK (movement_type IN ('receipt','processing_consume','processing_produce','reversal_restore','reversal_void','sale','writeoff','adjustment','status_change_out','status_change_in','transfer_out','transfer_in','maintenance_issue','maintenance_return'));
ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_sign;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_sign CHECK (CASE movement_type
        WHEN 'receipt' THEN qty_delta > 0
        WHEN 'processing_produce' THEN qty_delta > 0
        WHEN 'reversal_restore' THEN qty_delta > 0
        WHEN 'processing_consume' THEN qty_delta < 0
        WHEN 'reversal_void' THEN qty_delta < 0
        WHEN 'sale' THEN qty_delta < 0
        WHEN 'writeoff' THEN qty_delta < 0
        WHEN 'status_change_out' THEN qty_delta < 0
        WHEN 'status_change_in' THEN qty_delta > 0
        WHEN 'transfer_out' THEN qty_delta < 0
        WHEN 'transfer_in' THEN qty_delta > 0
        WHEN 'maintenance_issue' THEN qty_delta < 0
        WHEN 'maintenance_return' THEN qty_delta > 0
        ELSE true END);
ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_side;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_side CHECK (CASE movement_type
        WHEN 'processing_produce' THEN output_batch_id IS NOT NULL
        WHEN 'reversal_void' THEN output_batch_id IS NOT NULL
        WHEN 'sale' THEN output_batch_id IS NOT NULL
        WHEN 'maintenance_issue' THEN inbound_batch_id IS NOT NULL AND stock_status = 'available'
        WHEN 'maintenance_return' THEN inbound_batch_id IS NOT NULL AND stock_status = 'available'
        ELSE true END);
CREATE TRIGGER trg_inventory_movements_maintenance_ctx
    BEFORE INSERT ON public.inventory_movements
    FOR EACH ROW
    WHEN (NEW.movement_type IN ('maintenance_issue', 'maintenance_return'))
    EXECUTE FUNCTION public.guard_maintenance_movement();

-- ── 5 · 新表(镜像原样):备件出给保养与退回 ─────────────────────────────────────────────

-- db/tables/maintenance_part_issues.sql
-- MES-7a-2(2026-10-16,MES-0 Q70 · Q89;MES-7a Step 0 Q2 · Q10–Q15 · Q20,Tim):【一件备件出给了哪一条保养记录 —— 以及退回来多少】。
--   一行 = 一次出库的一条明细(kind = issue:哪一条保养记录、哪一批备件、多少),或一次退回(kind = return:引用它退的那一行出库,带理由)。
--   ★ 只可追加(Q12):没有改、没有删(trg_maintenance_part_issues_immutable 按名拒 PART_ISSUE_IMMUTABLE);一次出错的出库靠一行退回更正。
--   ★ 只经两支函数写(issue_spare_parts / return_spare_parts,码 module.inventory.edit);会话里直连插入按名拒 PART_ISSUES_THROUGH_FUNCTION_ONLY。
--   ★ 备件是【按批收货】的(Q2):一批备件就是一张进料批,有数量、库位与成本,但没有逐件追溯 —— 这里记的是"从哪一批出的",不是"哪一件"。
--   ★ 【这张表不带钱】(Q20):价值在那一张分录上(借 6800 / 贷 1200,按那一批的落地单价 × 数量;退回反过来),journal_entry_id 指着它;
--     读得到总账的人读得到金额(AGENTS.md 常设决定 1),保养页面上只给持 data.view_prices 的人照落地单价现算。于是没有遮蔽的列。
--   ★ movement_ids:这一行写下的那几条库存流水(drain_stock 可能跨几个库位桶,于是一次出库可以是几条流水);退回恰好一条。
--     流水自己不带指针 —— 是这一行指着它们,而 trg_inventory_movements_maintenance_ctx 保证那两种流水只由这两支函数写。
--   读:module.processing.view(保养记录在加工那边)或 module.inventory.view(批次的库存那一侧)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.maintenance_part_issues (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    maintenance_id   uuid NOT NULL REFERENCES public.equipment_maintenance (id),
    inbound_batch_id uuid NOT NULL REFERENCES public.inbound_batches (id),
    kind             text NOT NULL CHECK (kind IN ('issue', 'return')),
    -- 一行退回引用它退的那一行出库(同一条保养记录、同一批 —— 函数照抄那一行的两个外键)
    returns_issue_id uuid REFERENCES public.maintenance_part_issues (id),
    quantity         numeric NOT NULL CHECK (quantity > 0),
    -- 【世界侧的日期,必填、不默认】件是哪天出 / 退的;它也是那张分录的记账日(期间锁按它判)。
    business_date    date NOT NULL,
    reason           text,
    movement_ids     uuid[] NOT NULL CHECK (cardinality(movement_ids) >= 1),
    -- 一批落地单价为零的件出库没有分录(金额为 0 不过账,注销的先例)—— 于是可以为空
    journal_entry_id uuid REFERENCES public.journal_entries (id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    -- 出库不带理由、不引用别的行;退回必须引用一行出库,并且说出理由(Q12)
    CONSTRAINT maintenance_part_issues_shape CHECK (
        (kind = 'issue' AND returns_issue_id IS NULL AND reason IS NULL)
        OR (kind = 'return' AND returns_issue_id IS NOT NULL AND reason IS NOT NULL AND btrim(reason) <> ''))
);

CREATE INDEX idx_maintenance_part_issues_maintenance ON public.maintenance_part_issues (maintenance_id);
CREATE INDEX idx_maintenance_part_issues_batch ON public.maintenance_part_issues (inbound_batch_id);
CREATE INDEX idx_maintenance_part_issues_returns ON public.maintenance_part_issues (returns_issue_id);

COMMENT ON TABLE public.maintenance_part_issues IS
    'MES-7a-2:备件出给一条保养记录(kind = issue)与它的退回(kind = return,引用那一行出库、带理由)。只可追加;只经 issue_spare_parts / return_spare_parts 写(module.inventory.edit)。不带钱:价值在 journal_entry_id 那张分录上(借 6800 / 贷 1200,退回反过来)。movement_ids 是这一行写下的库存流水(maintenance_issue / maintenance_return)。';

COMMENT ON COLUMN public.maintenance_part_issues.business_date IS
    'MES-7a-2:件是哪天出 / 退的 —— 必填,不默认(AGENTS.md「决定期间的日期必填、永不默认」);那张分录按它记账,流水的 business_date 也是它。';

ALTER TABLE public.maintenance_part_issues ENABLE ROW LEVEL SECURITY;
CREATE POLICY "maintenance_part_issues select by permission" ON public.maintenance_part_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text) OR has_permission('module.inventory.view'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.maintenance_part_issues TO authenticated;
REVOKE ALL ON public.maintenance_part_issues FROM anon;

-- 会话里直连插入按名拒(行级 BEFORE INSERT 先于 RLS 的 WITH CHECK);属主路径(那两支函数)放行。
CREATE TRIGGER trg_maintenance_part_issues_direct
    BEFORE INSERT ON public.maintenance_part_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_part_issue_write();
-- 只可追加:改与删对谁都按名拒 —— 语句级,所以 RLS 让一句 UPDATE 碰不到任何一行时它照样抛,不是一次"成功的空操作"(ALERT-1)。
CREATE TRIGGER trg_maintenance_part_issues_immutable
    BEFORE UPDATE OR DELETE ON public.maintenance_part_issues
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_part_issue_write();

-- ── 6 · 保养记录:一条还挂着件的记录不能再资本化(与 db/tables/equipment_maintenance.sql 那一支逐字同一份)────────
CREATE TRIGGER trg_equipment_maintenance_parts_capitalise
    BEFORE UPDATE OF capitalised, capitalised_expense_id ON public.equipment_maintenance
    FOR EACH ROW EXECUTE FUNCTION public.guard_maintenance_capitalise_parts();

-- ── 7 · 新函数(镜像原样),新表之后:出给保养的净数量 · 出库 · 退回 ──────────────────────────

-- db/functions/inbound_batch_maintenance_net_qty.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q13,Tim):【一批里有多少已经出给了保养(减去退回的)】—— maintenance_issue 与 maintenance_return
--   两种流水之和的相反数。reprice_inbound_batch 与 preview_reprice_inbound_batch 把它递给 reprice_split,于是改价时已出给保养那一份的
--   价差进 6800、不进 5000(一份算术,两个调用者);inventory_control_reconciliation 用它把 M3 / M4 两条机制项里的"已被消耗"限在加工消耗上
--   (出给保养的那一份在出库那一刻就按落地单价解除了 1200,不是一份搁浅的资本化)。
--   不授给 authenticated —— 只在那几支 DEFINER 里被调用(它不问码,只回一个数量)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.inbound_batch_maintenance_net_qty(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(- sum(m.qty_delta), 0)
      FROM inventory_movements m
     WHERE m.inbound_batch_id = p_inbound_batch_id
       AND m.movement_type IN ('maintenance_issue', 'maintenance_return');
$function$;

-- db/functions/issue_spare_parts.sql
-- MES-7a-2(2026-10-16,MES-0 Q70 · Q89;MES-7a Step 0 Q10–Q15,Tim):【把备件出给一条保养记录】。
--   p_lines = [{inbound_batch_id, quantity}, …];每一条明细写一行 maintenance_part_issues(kind = issue)、一到几条 maintenance_issue 流水
--   (drain_stock 从可用桶里取,可能跨几个库位桶)、一张分录(借 6800 Repairs & Maintenance / 贷 1200,按那一批的落地单价)。
--   ★ 码 module.inventory.edit(Q12,不加新码);没有审批(Q10 · MES-0 §4.1:一次出库是一条库存流水,与加工投料同一类)。
--   ★ 只出 spare_part 那一种物料的批(Q12):PART_NOT_SPARE_PART|<批号>|<种类>。
--   ★ 只出给没有资本化的保养记录(Q14):PART_ISSUE_CAPITALISED|<机器>|<日期> —— 一条资本化了的大修,它的钱经费用单进资产成本;
--     从库里出的件没有一条路进资产成本,照费用记掉会少计资产("备件进资本化大修"登记在 docs/known-issues.md)。
--     ★ 保养记录【没有作废】这件事(没有作废列、没有作废函数、删除被拒)—— 委托书说的"未作废"在今天没有主语;fixture 266 的 VOID 臂
--       断言这一点,谁给保养记录加一个作废,那一臂就红,逼他回来这里加一道拒绝。
--   ★ 数量 ≤ 可用(Q12):PART_ISSUE_EXCEEDS_AVAILABLE|<批号>|<可用>|<要出的>(同一批分几条明细时按合计判)。
--   ★ 没定价的批不出(Q13):SPARE_PART_UNPRICED|<批号> —— 一次照 0 过账的维修费会少计这次修理;暂定价(provisional)是价,照出。
--   ★ 质量暂扣挡出库(Q15):一批有开着的不合格报告的备件,流水上的 guard_quality_hold 按名拒 QUALITY_HOLD_OPEN|<批号>|<报告>。
--   ★ 日期必填、不默认,不许在未来(AGENTS.md「决定期间的日期」):PART_ISSUE_DATE_REQUIRED · PART_ISSUE_DATE_IN_FUTURE。分录按它记账,
--     期间锁由 post_journal_entry → assert_posting_allowed 判。
--   ★ 【金额 = 出库前后两次计值之差】round(出库前剩余 × 落地单价, 2) − round(出库后剩余 × 落地单价, 2),而不是 round(数量 × 单价, 2):
--     存货的明细侧(inventory_control_reconciliation 的 batch_side)就是 round(剩余 × 落地单价, 2),这样记 1200 才逐分跟着它走 ——
--     两种取整在一个三位小数的单价上会差一分钱,而那一分钱会落进"未解释"。落地单价读 inbound_batch_landed_unit_cost_all(无判据的过账原语:
--     账上的金额不许取决于按按钮的人看不看得见价格)。
--   DEFINER:写流水、批次与分录都只能经属主路径;它自己 require_permission。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.issue_spare_parts(p_maintenance_id uuid, p_issued_on date, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_today    date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_maint    record;
    v_line     jsonb;
    v_batch    uuid;
    v_qty      numeric;
    v_b        record;
    v_avail    numeric;
    v_id       uuid;
    v_cost     numeric;
    v_before   numeric;
    v_after    numeric;
    v_amt      numeric;
    v_mv       uuid[];
    v_je       jsonb;
    v_out      jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.inventory.edit');
    IF p_issued_on IS NULL THEN
        RAISE EXCEPTION 'PART_ISSUE_DATE_REQUIRED';
    END IF;
    IF p_issued_on > v_today THEN
        RAISE EXCEPTION 'PART_ISSUE_DATE_IN_FUTURE|%', p_issued_on;
    END IF;

    SELECT m.id, m.performed_on, m.capitalised, m.capitalised_expense_id, fa.code AS asset_code
      INTO v_maint
      FROM equipment_maintenance m JOIN fixed_assets fa ON fa.id = m.equipment_id
     WHERE m.id = p_maintenance_id
       FOR UPDATE OF m;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MAINTENANCE_NOT_FOUND|%', COALESCE(p_maintenance_id::text, '?');
    END IF;
    IF v_maint.capitalised OR v_maint.capitalised_expense_id IS NOT NULL THEN
        RAISE EXCEPTION 'PART_ISSUE_CAPITALISED|%|%', v_maint.asset_code, v_maint.performed_on;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'PART_ISSUE_NO_LINES';
    END IF;

    -- ① 先把每一条明细判完(按批合计),一行都不写 —— 一张单要么整张出,要么一件都不出
    FOR v_batch, v_qty IN
        SELECT (l ->> 'inbound_batch_id')::uuid, sum((l ->> 'quantity')::numeric)
          FROM jsonb_array_elements(p_lines) l
         GROUP BY 1
    LOOP
        IF v_batch IS NULL THEN
            RAISE EXCEPTION 'PART_ISSUE_NO_BATCH';
        END IF;
        SELECT b.id, b.code, b.unit_price, b.deleted_at, m.kind_code
          INTO v_b
          FROM inbound_batches b JOIN materials m ON m.id = b.material_id
         WHERE b.id = v_batch
           FOR UPDATE OF b;
        IF NOT FOUND OR v_b.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_batch;
        END IF;
        IF v_b.kind_code IS DISTINCT FROM 'spare_part' THEN
            RAISE EXCEPTION 'PART_NOT_SPARE_PART|%|%', v_b.code, COALESCE(v_b.kind_code, '-');
        END IF;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'PART_QTY_INVALID|%|%', v_b.code, COALESCE(v_qty::text, '?');
        END IF;
        IF v_b.unit_price IS NULL THEN
            RAISE EXCEPTION 'SPARE_PART_UNPRICED|%', v_b.code;
        END IF;
        SELECT COALESCE(sum(qty_delta), 0) INTO v_avail
          FROM inventory_movements WHERE inbound_batch_id = v_batch AND stock_status = 'available';
        IF v_qty > v_avail THEN
            RAISE EXCEPTION 'PART_ISSUE_EXCEEDS_AVAILABLE|%|%|%', v_b.code, v_avail, v_qty;
        END IF;
    END LOOP;
    -- 每一条明细自己的数量也要 > 0(合计 > 0 不等于每一条 > 0)
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) l
                WHERE (l ->> 'quantity') IS NULL OR (l ->> 'quantity')::numeric <= 0) THEN
        RAISE EXCEPTION 'PART_QTY_INVALID|-|%',
            (SELECT COALESCE(l ->> 'quantity', '?') FROM jsonb_array_elements(p_lines) l
              WHERE (l ->> 'quantity') IS NULL OR (l ->> 'quantity')::numeric <= 0 LIMIT 1);
    END IF;

    -- ② 逐条写:批次的剩余量 · 流水 · 分录 · 一行出库记录
    PERFORM set_config('evoltrya.part_issue_ctx', 'issue', true);
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_batch := (v_line ->> 'inbound_batch_id')::uuid;
        v_qty   := (v_line ->> 'quantity')::numeric;
        v_id    := gen_random_uuid();
        SELECT code, remaining_qty INTO v_b FROM inbound_batches WHERE id = v_batch;
        v_before := v_b.remaining_qty;
        v_after  := v_before - v_qty;
        v_cost   := inbound_batch_landed_unit_cost_all(v_batch);

        UPDATE inbound_batches
           SET remaining_qty = v_after, updated_by = v_user, updated_at = now()
         WHERE id = v_batch;
        v_mv := drain_stock(
            p_qty => v_qty, p_movement_type => 'maintenance_issue', p_business_date => p_issued_on,
            p_inbound_batch_id => v_batch, p_statuses => ARRAY['available'],
            p_notes => 'Spare parts to ' || v_maint.asset_code || ' maintenance of ' || v_maint.performed_on,
            p_created_by => v_user);

        v_je := NULL;
        v_amt := round(v_before * COALESCE(v_cost, 0), 2) - round(v_after * COALESCE(v_cost, 0), 2);
        IF v_amt <> 0 THEN
            v_je := post_journal_entry(
                p_issued_on,
                'Spare parts ' || v_b.code || ' to ' || v_maint.asset_code || ' maintenance of ' || v_maint.performed_on,
                'maintenance_part', v_id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '6800', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt),
                    jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt)));
        END IF;

        INSERT INTO maintenance_part_issues (id, maintenance_id, inbound_batch_id, kind, quantity, business_date,
                                             movement_ids, journal_entry_id, created_by)
        VALUES (v_id, p_maintenance_id, v_batch, 'issue', v_qty, p_issued_on, v_mv, (v_je ->> 'entry_id')::uuid, v_user);

        v_out := v_out || jsonb_build_object('issue_id', v_id, 'batch_code', v_b.code, 'quantity', v_qty,
                                             'journal_code', v_je ->> 'code');
    END LOOP;
    PERFORM set_config('evoltrya.part_issue_ctx', '', true);

    RETURN jsonb_build_object('maintenance_id', p_maintenance_id, 'lines', v_out);
END;
$function$;

-- db/functions/return_spare_parts.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12 · Q15,Tim):【把出给保养的备件退回库里】—— 一次出库的更正,也是拆下来没用上的件回库。
--   一行 maintenance_part_issues(kind = return,引用它退的那一行出库,带理由)、一条 maintenance_return 流水(可用桶,为正)、
--   一张分录(借 1200 / 贷 6800 —— 出库那一张反过来)。码 module.inventory.edit;没有审批(Q10)。
--   ★ 必须说理由(Q12):PART_RETURN_REASON_REQUIRED。必须引用一行出库:PART_ISSUE_NOT_FOUND|<id>(找不到,或那一行本身是一次退回)。
--   ★ 退的不能多于那一行还没退的(出库数量 − 已退的):PART_RETURN_EXCEEDS_ISSUED|<批号>|<还可退>|<要退的>。
--   ★ 日期必填、不在未来、不早于那一次出库:PART_RETURN_DATE_REQUIRED · PART_RETURN_DATE_IN_FUTURE · PART_RETURN_BEFORE_ISSUE|<出库日>。
--   ★ 那一批已经注销了 → PART_RETURN_BATCH_WRITTEN_OFF|<批号>:一批注销掉的货不再收回东西(它的剩余量已归零、价值已进 5200)。
--   ★ 质量暂扣【不挡】退回(Q15):退回不在 guard_quality_hold 的名单上;那一批在不在暂扣里,下一次出库时再问。
--   ★ 退回落在"未指定库位"(location_id 为空,可用桶)—— 从机器上拆回来的件还没放上任何货架,上架是一次转移(加工产出同一条规矩);
--     出库当时从哪几个库位取的,不替人猜回去。
--   ★ 金额 = 退回前后两次计值之差(issue_spare_parts 抬头那一条,方向相反),落地单价照【今天的】读 —— 一次改价已经把出给保养那一份的价差
--     记进了 6800(reprice_split),所以照今天的单价退,1200 才与 round(剩余 × 落地单价, 2) 逐分对得上。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.return_spare_parts(p_issue_id uuid, p_quantity numeric, p_returned_on date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_today    date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_iss      record;
    v_b        record;
    v_left     numeric;
    v_id       uuid := gen_random_uuid();
    v_cost     numeric;
    v_before   numeric;
    v_after    numeric;
    v_amt      numeric;
    v_mv       uuid;
    v_je       jsonb;
BEGIN
    PERFORM require_permission('module.inventory.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PART_RETURN_REASON_REQUIRED';
    END IF;
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'PART_RETURN_DATE_REQUIRED';
    END IF;
    IF p_returned_on > v_today THEN
        RAISE EXCEPTION 'PART_RETURN_DATE_IN_FUTURE|%', p_returned_on;
    END IF;

    SELECT i.id, i.maintenance_id, i.inbound_batch_id, i.quantity, i.business_date, fa.code AS asset_code, m.performed_on
      INTO v_iss
      FROM maintenance_part_issues i
      JOIN equipment_maintenance m ON m.id = i.maintenance_id
      JOIN fixed_assets fa ON fa.id = m.equipment_id
     WHERE i.id = p_issue_id AND i.kind = 'issue'
       FOR UPDATE OF i;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PART_ISSUE_NOT_FOUND|%', COALESCE(p_issue_id::text, '?');
    END IF;
    IF p_returned_on < v_iss.business_date THEN
        RAISE EXCEPTION 'PART_RETURN_BEFORE_ISSUE|%', v_iss.business_date;
    END IF;

    SELECT b.code, b.remaining_qty, b.deleted_at INTO v_b FROM inbound_batches b WHERE b.id = v_iss.inbound_batch_id FOR UPDATE;
    IF v_b.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'PART_RETURN_BATCH_WRITTEN_OFF|%', v_b.code;
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'PART_QTY_INVALID|%|%', v_b.code, COALESCE(p_quantity::text, '?');
    END IF;
    SELECT v_iss.quantity - COALESCE(sum(r.quantity), 0) INTO v_left
      FROM maintenance_part_issues r WHERE r.returns_issue_id = p_issue_id;
    IF p_quantity > v_left THEN
        RAISE EXCEPTION 'PART_RETURN_EXCEEDS_ISSUED|%|%|%', v_b.code, v_left, p_quantity;
    END IF;

    v_before := v_b.remaining_qty;
    v_after  := v_before + p_quantity;
    v_cost   := inbound_batch_landed_unit_cost_all(v_iss.inbound_batch_id);

    PERFORM set_config('evoltrya.part_issue_ctx', 'return', true);
    UPDATE inbound_batches
       SET remaining_qty = v_after, updated_by = v_user, updated_at = now()
     WHERE id = v_iss.inbound_batch_id;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, stock_status, location_id, business_date, notes, created_by)
    VALUES (v_iss.inbound_batch_id, 'maintenance_return', p_quantity, 'available', NULL, p_returned_on,
            'Returned from ' || v_iss.asset_code || ' maintenance of ' || v_iss.performed_on || ': ' || btrim(p_reason), v_user)
    RETURNING id INTO v_mv;
    PERFORM set_config('evoltrya.part_issue_ctx', '', true);

    v_amt := round(v_after * COALESCE(v_cost, 0), 2) - round(v_before * COALESCE(v_cost, 0), 2);
    IF v_amt <> 0 THEN
        v_je := post_journal_entry(
            p_returned_on,
            'Spare parts ' || v_b.code || ' returned from ' || v_iss.asset_code || ' maintenance of ' || v_iss.performed_on,
            'maintenance_part', v_id,
            jsonb_build_array(
                jsonb_build_object('account_code', '1200', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt),
                jsonb_build_object('account_code', '6800', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt)));
    END IF;

    INSERT INTO maintenance_part_issues (id, maintenance_id, inbound_batch_id, kind, returns_issue_id, quantity, business_date,
                                         reason, movement_ids, journal_entry_id, created_by)
    VALUES (v_id, v_iss.maintenance_id, v_iss.inbound_batch_id, 'return', p_issue_id, p_quantity, p_returned_on,
            btrim(p_reason), ARRAY[v_mv], (v_je ->> 'entry_id')::uuid, v_user);

    RETURN jsonb_build_object('return_id', v_id, 'issue_id', p_issue_id, 'batch_code', v_b.code, 'quantity', p_quantity,
                              'journal_code', v_je ->> 'code');
END;
$function$;

-- ── 8 · reprice_split 换签名(四个入参 → 五个):DROP 旧的,CREATE 新的 —— 两支并存是一次镜像看不见的重载 ─────
DROP FUNCTION public.reprice_split(numeric, numeric, numeric, numeric);

-- db/functions/reprice_split.sql
-- 改价的拆账算术 —— reprice_inbound_batch 与 preview_reprice_inbound_batch 共用这一份(AGENTS.md「一份实现,两个调用者」)。
-- 价差 delta = round(整批数量 × (新价 − 旧价), 2);在库份额按 剩余 ÷ 数量 进 1200,其余是已离开库存的份额。
-- ★ MES-7a-2(2026-10-16,MES-7a Step 0 Q13,Tim):【它认得出给保养的那一份】—— 多一个入参 p_maintenance_qty(这一批出给保养、减去退回的
--   数量:inbound_batch_maintenance_net_qty 读 maintenance_issue / maintenance_return 两种流水)。已离开库存的份额于是拆成两块:
--   出给保养的那一份进 6800 Repairs & Maintenance(maintenance_share_usd),其余(加工消耗、销售、注销……)照旧进 5000(cost_share_usd)。
--   签名换了(四个入参 → 五个),旧的那一支在迁移里 DROP —— 两支并存就是一次镜像看不见的重载(FIN-21)。
--   ★ 取整:在库份额与保养份额各自 round 到分;当这两块已经占满整批(没有别的消耗)时,保养份额取 delta − 在库份额,
--     于是 cost_share 恰好是 0,不会因为两次取整变成 −0.01。
-- 不带 SET search_path:纯算术,IMMUTABLE(journal_activity_lines 的注释提到它同样不带)。

CREATE FUNCTION public.reprice_split(p_quantity numeric, p_remaining numeric, p_old_price numeric, p_new_price numeric, p_maintenance_qty numeric)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- ratio 用未取整的值参与乘法(与历来的入账口径一致),仅在输出时取到 4 位
    SELECT jsonb_build_object(
        'delta_usd', d.delta,
        'in_stock_ratio', round(d.ratio, 4),
        'inventory_share_usd', d.inv,
        'maintenance_ratio', round(d.mratio, 4),
        'maintenance_share_usd', d.mnt,
        'cost_share_usd', round(d.delta - d.inv - d.mnt, 2)
    )
    FROM (
        SELECT delta, ratio, mratio, round(delta * ratio, 2) AS inv,
               CASE WHEN mratio = 0 THEN 0
                    WHEN ratio + mratio >= 1 THEN delta - round(delta * ratio, 2)
                    ELSE round(delta * mratio, 2) END AS mnt
        FROM (
            SELECT delta, ratio, LEAST(1 - ratio, mr) AS mratio
            FROM (
                SELECT round(p_quantity * (p_new_price - COALESCE(p_old_price, 0)), 2) AS delta,
                       CASE WHEN p_quantity = 0 THEN 1
                            ELSE LEAST(1, GREATEST(0, p_remaining / p_quantity)) END AS ratio,
                       CASE WHEN p_quantity = 0 THEN 0
                            ELSE LEAST(1, GREATEST(0, COALESCE(p_maintenance_qty, 0) / p_quantity)) END AS mr
            ) x0
        ) x
    ) d;
$function$;

-- ── 9 · 换掉的函数(镜像原样,同签名):改价两支认得保养份额 · 质量暂扣挡出库 · 存货勾稽归因 · 冲销路由 · 审计成员 ─


-- MES-7a-2(2026-10-16,MES-7a Step 0 Q13):改价时,已出给保养那一份的价差进 6800 Repairs & Maintenance,不进 5000 —— reprice_split 多了一个入参
-- (inbound_batch_maintenance_net_qty),一份实现照旧两个调用者;返回值多一个 maintenance_share_usd。
-- MES-2(2026-10-06,MES-2 Step 0 Q27):校准闸在这里 —— 每一条收货定价路径都落进本引擎,所以只问一次
-- (assert_receipt_reading_calibrated;试算 preview_reprice_inbound_batch 问同一支)。
-- FIN-21(2026-08-06):改问 fx_rate_asof —— 同一条解析规则,多拿一个【取自哪一天】,
-- 与所用侧(恒 tt_sell)一起记进 price_history.rate_as_of / rate_type。
-- 缺牌价仍拒:再调一次 fx_rate_for 抛唯一的 FX_RATE_MISSING(重估写入侧同一模式)。

CREATE OR REPLACE FUNCTION public.reprice_inbound_batch(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_old       numeric;
    v_deleted   timestamptz;
    v_qty       numeric;
    v_remaining numeric;
    v_code      text;
    v_fx        numeric;
    v_fx_asof date;   -- FIN-21:牌价取自哪一天(fx_rate_asof 的 as_of)
    v_usd       numeric;
    v_split     jsonb;
    v_delta     numeric;
    v_ratio     numeric;
    v_inv       numeric := 0;
    v_cost      numeric := 0;
    v_mnt       numeric := 0;   -- MES-7a-2:已出给保养那一份(进 6800)
    v_lines     jsonb;
    v_je        jsonb := NULL;
BEGIN
    -- ★ ROLE-1 Batch 4a(Tim 2026-09-24:看不见价格的人不能定价,【在库里】挡):这是每一条定价路径
    --   (建单带价、定价面板、按已承诺条款改价、应用化验)都落进来的那一支引擎,所以
    --   "看得见采购价"在这里问【按按钮的那个人】(DEFINER 不改 auth.uid())。它原来那道嵌套的
    --   module.inbound.edit 拆掉(ROLE-1 Batch 2 grilling 第 4 条登记给 Batch 4 的那一处):
    --   谁能定价由各自的门说 —— 手工定价 action.price_receipts,应用化验 action.apply_assay。
    --   本支的 EXECUTE 已从 authenticated 收回(侧门 (c)),只经那几扇门进来。
    PERFORM require_permission('data.view_purchase_prices');
    SELECT unit_price, deleted_at, quantity, remaining_qty, code
    INTO v_old, v_deleted, v_qty, v_remaining, v_code
    FROM inbound_batches WHERE id = p_inbound_batch_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    -- MES-2(Q26 · Q27)/ MES-3a(Tim 的裁定 1):校准闸 —— 不在校准期内的读数永远拒;开关只管两种缺席。判据只在那一支函数里。
    PERFORM assert_receipt_reading_calibrated(p_inbound_batch_id);
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【定价日】的行方卖出价(tt_sell)估值 ——
    -- 这批货将来要向银行买外币去付。当日无牌价即拒(FX_RATE_MISSING);
    -- 汇率不再由调用方递入(p_fx_rate 必须为空),原币与所用汇率仍进 price_history。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    -- FIN-21:问 fx_rate_asof —— 同一条解析规则,多拿一个【取自哪一天】。
    -- 缺牌价时它返回空行;再调一次 fx_rate_for 让它抛出唯一的那份
    -- FX_RATE_MISSING|币种|日期|侧(重估写入侧同一模式,错误文案不写第二遍)。
    SELECT a.rate, a.as_of INTO v_fx, v_fx_asof
    FROM fx_rate_asof(p_currency, CURRENT_DATE, 'tt_sell') a;
    IF v_fx IS NULL THEN
        PERFORM fx_rate_for(p_currency, CURRENT_DATE, 'tt_sell');
    END IF;

    v_usd := round(p_unit_price * v_fx, 4);  -- 单价 4 位小数(FIN-0 起为 SGD 本位价;列名沿用 _usd,重命名与生产重建同批)

    -- GUC 放行本函数内的 unit_price 更新(guard_inbound_price_change),用毕即清,
    -- 免得同事务内后续的直改被误放行(同 movement_ctx 模式)。
    PERFORM set_config('evoltrya.price_ctx', 'set_inbound_unit_price', true);
    UPDATE inbound_batches
    SET unit_price = v_usd, updated_by = v_user, updated_at = now()
    WHERE id = p_inbound_batch_id;
    PERFORM set_config('evoltrya.price_ctx', '', true);

    INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate,
                               rate_as_of, rate_type, notes, created_by)
    VALUES (p_inbound_batch_id, v_old, v_usd, p_currency, p_unit_price, v_fx,
            v_fx_asof, 'tt_sell', p_notes, v_user);

    -- cut 2a:计价即入账 —— 整批数量 × 价差(负债在收货整批上成立,非剩余量)。
    -- 记于定价日 CURRENT_DATE(到货日尚无金额,刻意如此);USD 口径(原币在 price_history)。
    -- 拆分算术来自 reprice_split —— 与 preview_reprice_inbound_batch 共用同一份。
    -- MES-7a-2(Q13):reprice_split 认得出给保养的那一份 —— 它的价差进 6800,不进 5000
    v_split := reprice_split(v_qty, v_remaining, v_old, v_usd, inbound_batch_maintenance_net_qty(p_inbound_batch_id));
    v_delta := (v_split->>'delta_usd')::numeric;
    v_ratio := (v_split->>'in_stock_ratio')::numeric;

    IF v_delta <> 0 THEN
        -- 拆账:在库份额进 1200,出给保养的份额进 6800(MES-7a-2),其余已消耗份额进 5000;贷方(负差时借方)恒 2000
        v_inv  := (v_split->>'inventory_share_usd')::numeric;
        v_mnt  := (v_split->>'maintenance_share_usd')::numeric;
        v_cost := (v_split->>'cost_share_usd')::numeric;

        v_lines := '[]'::jsonb;
        IF abs(v_inv) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_inv),
                'line_memo', 'in-stock share');
        END IF;
        IF abs(v_mnt) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '6800',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_mnt),
                'line_memo', 'issued-to-maintenance share');
        END IF;
        IF abs(v_cost) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '5000',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_cost),
                'line_memo', 'consumed share');
        END IF;
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2000',
            'side', CASE WHEN v_delta > 0 THEN 'credit' ELSE 'debit' END,
            'currency', base_currency_code(), 'amount_ccy', abs(v_delta));

        v_je := post_journal_entry(
            CURRENT_DATE,
            'Pricing ' || v_code,
            'purchase',
            p_inbound_batch_id,
            v_lines
        );
    END IF;

    RETURN jsonb_build_object(
        -- 旧返回键原样保留(既有调用方靠它们)
        'batch_id', p_inbound_batch_id,
        'unit_price_usd', v_usd,
        -- cut 5a 起的完整分解(界面与对账都要能逐项交代)
        'batch_code', v_code,
        'old_unit_price', v_old,
        'new_unit_price', v_usd,
        'price_delta_usd', v_delta,
        'in_stock_ratio', v_ratio,
        'inventory_share_usd', v_inv,
        'cost_share_usd', v_cost,
        'maintenance_share_usd', v_mnt,
        'journal_code', v_je->>'code'
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.preview_reprice_inbound_batch(p_inbound_batch_id uuid, p_new_unit_price numeric, p_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old       numeric;
    v_qty       numeric;
    v_remaining numeric;
    v_fx        numeric;
    v_fx_asof   date;
    v_base      numeric;
    v_split     jsonb;
    v_delta     numeric;
BEGIN
    PERFORM require_permission('data.view_purchase_prices');
    SELECT unit_price, quantity, remaining_qty
    INTO v_old, v_qty, v_remaining
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    -- MES-2(Q27):与 reprice_inbound_batch 同一道校准闸 —— 提交会被拒的,试算也不许说"可以"
    PERFORM assert_receipt_reading_calibrated(p_inbound_batch_id);
    IF p_new_unit_price IS NULL OR p_new_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    -- 【与 reprice_inbound_batch 逐行同构】本位币免换算;外币按【定价日】(即
    -- 提交时的 CURRENT_DATE)的 tt_sell 折算,缺牌价时用同一个 fx_rate_for 抛出
    -- 同一份 FX_RATE_MISSING|币种|日期|侧。少乘这一次就是 ASY-1 之前那个 56% 的差。
    SELECT a.rate, a.as_of INTO v_fx, v_fx_asof
    FROM fx_rate_asof(p_currency, CURRENT_DATE, 'tt_sell') a;
    IF v_fx IS NULL THEN
        PERFORM fx_rate_for(p_currency, CURRENT_DATE, 'tt_sell');
    END IF;

    v_base  := round(p_new_unit_price * v_fx, 4);
    -- MES-7a-2(Q13):与 reprice_inbound_batch 同一份拆账 —— 已出给保养那一份另列(进 6800)
    v_split := reprice_split(v_qty, v_remaining, v_old, v_base, inbound_batch_maintenance_net_qty(p_inbound_batch_id));
    v_delta := (v_split->>'delta_usd')::numeric;

    -- 价差不为零时提交要过账 —— 过账过不去的日子,试算也不许说"可以"
    IF v_delta <> 0 THEN
        PERFORM assert_posting_allowed(CURRENT_DATE, 'purchase');
    END IF;

    RETURN jsonb_build_object(
        'old_unit_price', v_old,
        'new_unit_price', v_base,
        'delta_usd', v_delta,
        'in_stock_ratio', (v_split->>'in_stock_ratio')::numeric,
        'inventory_share_usd', (v_split->>'inventory_share_usd')::numeric,
        'cost_share_usd', (v_split->>'cost_share_usd')::numeric,
        'maintenance_share_usd', (v_split->>'maintenance_share_usd')::numeric,
        -- 折算用的牌价与它取自哪天:屏幕上的数是怎么来的,要指得出来(FIN-21)
        'fx_rate', v_fx,
        'rate_as_of', v_fx_asof,
        'currency', p_currency
    );
END;
$function$;

-- db/functions/guard_quality_hold.sql
-- MES-6b-1(2026-10-15,MES-0 Q66 · G29;MES-6b Step 0 Q3 · Q21 · Q23 · Q24,Tim):【质量暂扣守在流水上】——
--   inventory_movements BEFORE INSERT(行级),与 APR-7 的注销 / 回滚冻结(guard_warehouse_request_freeze)并排:动库存的函数有几十支,
--   流水只有一张表,挂在这里就没有侧门(DEFINER 的调用者 —— 加工提交、发货、直接销售、预留 —— 一样被拒)。
--
--   一批在暂扣里(batch_quality_hold)时,写向它的这几种流水按名拒 QUALITY_HOLD_OPEN|<批号>|<不合格报告编号>:
--     processing_consume                  投料(含配料计划的执行 —— 它是一张 blending 加工单)
--     sale                                直接销售,以及发货那一条腿(ship_order 从 committed 桶里出)
--     status_change_in 进 committed        预留(available → committed 那一对的"进"腿;另一条腿与它同一句 INSERT,一起回滚)
--     writeoff,却不在一张仓库申请的执行里  注销只经 CFO 批的那张申请(warehouse_request_execute_internal 设 evoltrya.warehouse_request_ctx)
--     maintenance_issue                   备件出给一条保养记录(MES-7a-2,MES-7a Step 0 Q15:一件开着不合格报告的备件不装上机器)
--   放行(Q3 · Q21 · Q23):收货、加工产出、转移(两条腿 —— 想把它搬进隔离库位就搬)、盘点调整、available ↔ on_hold、committed → available
--   (释放一个预留 —— 已有的预留照留,只是发不出去)、CFO 批过的注销、回滚的冲销两腿(reversal_restore / reversal_void)、
--   备件退回(maintenance_return —— 从机器上拆回来的件回到库里;它在不在暂扣里,下一次出库时再问,MES-7a Step 0 Q15)。
--   ★ 守卫只认【流水的种类与桶】,不认是谁写的:一张已经预留了的货,暂扣落下之后预留照旧在(Q23),发货那一条 sale 腿在这里被拒。
--   SECURITY DEFINER:暂扣的判据要读全部不合格报告(读策略认码),守卫不能因为写流水的人读不到那一张报告就放过去。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.guard_quality_hold()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hold record;
BEGIN
    IF NOT (NEW.movement_type IN ('processing_consume', 'sale', 'maintenance_issue')
            OR (NEW.movement_type = 'status_change_in' AND NEW.stock_status = 'committed')
            OR (NEW.movement_type = 'writeoff'
                AND COALESCE(current_setting('evoltrya.warehouse_request_ctx', true), '') = '')) THEN
        RETURN NEW;
    END IF;
    SELECT h.ncr_code, h.batch_code INTO v_hold
      FROM batch_quality_hold(NEW.inbound_batch_id, NEW.output_batch_id) h;
    IF FOUND THEN
        RAISE EXCEPTION 'QUALITY_HOLD_OPEN|%|%', v_hold.batch_code, v_hold.ncr_code
          USING HINT = '这一批在质量暂扣里(一张开着的不合格报告,或一张决定为拒收而货还在的)—— 先让另一个人在报告上做出放行的处置;拒收的货走 CFO 注销申请。';
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/inventory_control_reconciliation.sql
-- INV-VAL-1:存货明细账 ↔ 控制科目的两条腿(1200 原料 / 1220 产成品),
-- 供 gl_control_reconciliation 拼接。四条具名成因 + 两条机制项,【没有兜底桶】。
--
-- ★【归因必须【原分录优先】走回批次】★ 1200 上的冲销分录,它的 source_id
--   指向【原分录】,不是批次。写成 COALESCE(je.source_id, orig.source_id)
--   会让 4 行归因失败 —— 原分录算进了批次、它的冲销没有,净额错成 +原分录,
--   unexplained 当场不为零。正确顺序是 COALESCE(orig.source_id, je.source_id)。
--   实测(2026-08-31):18 行全部归因,归因合计 = 74,687.92 = 1200 的余额本身。
--
-- 【它【不】授给 authenticated】只被 gl_control_reconciliation(属主权限)
--   在体内调用。但它自己仍然 require_permission —— **授权不是控制**。
--
-- NOTE: introduced by db/migrations/2026-08-31-invval1-the-valuation-report-the-close-gate-and-the-fields-already-mandatory.sql.
-- CLEANUP-A fu1:落地成本改读 inbound_batch_landed_unit_cost_all(无判据的过账原语)——
-- 计值不许取决于谁按的按钮。

CREATE OR REPLACE FUNCTION public.inventory_control_reconciliation(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_sides      jsonb := '[]'::jsonb;
    v_live       boolean;
    v_refuse     text;
    -- raw
    v_led_raw    numeric;
    v_sub_raw    numeric;
    v_c1 numeric; v_c2 numeric; v_c3 numeric; v_c6 numeric;
    v_m3 numeric; v_m4 numeric;
    v_diff_raw   numeric;
    v_unexp_raw  numeric;
    -- fg
    v_led_fg     numeric;
    v_sub_fg     numeric;
    v_fg_pre     numeric;
    v_diff_fg    numeric;
    v_unexp_fg   numeric;
    v_null_bd    integer;
    v_late_cap   integer;
BEGIN
    -- 【定义者函数必须自己问】见抬头第五节:授权不是控制。
    PERFORM require_permission('module.finance.view');
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'AS_OF_REQUIRED';
    END IF;

    v_live := (p_as_of >= CURRENT_DATE);

    -- ── 明细侧能不能重建 ────────────────────────────────────────────────
    IF NOT v_live THEN
        SELECT count(*) INTO v_null_bd
          FROM inventory_movements m
         WHERE m.business_date IS NULL;
        SELECT count(*) INTO v_late_cap
          FROM (
            SELECT fa.created_at FROM freight_allocations fa
            UNION ALL
            SELECT bpca.created_at FROM batch_processing_cost_allocations bpca
          ) c
         WHERE c.created_at::date > p_as_of;

        IF v_null_bd > 0 THEN
            v_refuse := 'BUSINESS_DATES_INCOMPLETE|' || v_null_bd
                     || '|' || COALESCE((SELECT min(business_date)::text
                                           FROM inventory_movements
                                          WHERE business_date IS NOT NULL), '?');
        ELSIF v_late_cap > 0 THEN
            v_refuse := 'CAPITALISATION_AFTER_AS_OF|' || v_late_cap;
        END IF;
    END IF;

    -- ── 账面侧:两个科目,as-at 精确(分录带日期,不需要重建) ──────────
    SELECT COALESCE(SUM(l.debit - l.credit), 0) INTO v_led_raw
      FROM journal_activity_lines(NULL, p_as_of, true) l
     WHERE l.account_code = '1200';
    SELECT COALESCE(SUM(l.debit - l.credit), 0) INTO v_led_fg
      FROM journal_activity_lines(NULL, p_as_of, true) l
     WHERE l.account_code = '1220';

    IF v_refuse IS NOT NULL THEN
        -- 【拒绝也要把账面侧报出来】它是算得准的;拒的是明细侧。
        -- reconciled 为 NULL:「答不上来」不是「对不上」。
        v_sides := jsonb_build_array(
            jsonb_build_object(
                'side','inventory_raw','control_account','1200',
                'ledger_base', round(v_led_raw,2),
                'subledger_base', NULL, 'difference_base', NULL,
                'subledger_basis','refused','refusal', v_refuse,
                'variances','[]'::jsonb,
                'unexplained_base', NULL, 'reconciled', NULL),
            jsonb_build_object(
                'side','inventory_fg','control_account','1220',
                'ledger_base', round(v_led_fg,2),
                'subledger_base', NULL, 'difference_base', NULL,
                'subledger_basis','refused','refusal', v_refuse,
                'variances','[]'::jsonb,
                'unexplained_base', NULL, 'reconciled', NULL));
        RETURN v_sides;
    END IF;

    -- ── 明细侧 + 逐批归因 ───────────────────────────────────────────────
    WITH eff AS (
        SELECT COALESCE(o.source_type, je.source_type) AS st,
               COALESCE(o.source_id,   je.source_id)   AS sid,
               (l.debit - l.credit)                    AS amt
          FROM journal_activity_lines(NULL, p_as_of, true) l
          JOIN journal_entries je ON je.id = l.entry_id
          -- 【原分录优先】见抬头:冲销分录的 source_id 指向原分录,不是批次。
          LEFT JOIN journal_entries o ON o.reversed_by = je.id
         WHERE l.account_code = '1200'
    ),
    attr AS (
        SELECT e.sid AS batch_id, e.amt, e.st FROM eff e
         WHERE e.st IN ('purchase','writeoff')
           AND EXISTS (SELECT 1 FROM inbound_batches b WHERE b.id = e.sid)
        UNION ALL
        SELECT pi.inbound_batch_id,
               e.amt * (pi.quantity_consumed * COALESCE(inbound_batch_landed_unit_cost_all(pi.inbound_batch_id),0))
                     / NULLIF(w.tot,0), e.st
          FROM eff e
          JOIN processing_inputs pi ON pi.run_id = e.sid
          JOIN LATERAL (SELECT SUM(p2.quantity_consumed * COALESCE(inbound_batch_landed_unit_cost_all(p2.inbound_batch_id),0)) AS tot
                          FROM processing_inputs p2
                         WHERE p2.run_id = e.sid AND p2.inbound_batch_id IS NOT NULL) w ON true
         WHERE e.st = 'allocation' AND pi.inbound_batch_id IS NOT NULL
        UNION ALL
        SELECT sl.inbound_batch_id,
               e.amt * (sl.counted_qty - sl.book_qty) / NULLIF(w.tot,0), e.st
          FROM eff e
          JOIN stocktake_lines sl ON sl.stocktake_id = e.sid
          JOIN LATERAL (SELECT SUM(s2.counted_qty - s2.book_qty) AS tot
                          FROM stocktake_lines s2
                         WHERE s2.stocktake_id = e.sid AND s2.inbound_batch_id IS NOT NULL) w ON true
         WHERE e.st = 'stocktake' AND sl.inbound_batch_id IS NOT NULL
        UNION ALL
        SELECT fa.inbound_batch_id, e.amt * fa.amount_base / NULLIF(w.tot,0), e.st
          FROM eff e
          JOIN freight_allocations fa ON fa.freight_document_id = e.sid
          JOIN LATERAL (SELECT SUM(f2.amount_base) AS tot FROM freight_allocations f2
                         WHERE f2.freight_document_id = e.sid) w ON true
         WHERE e.st = 'freight'
        -- MES-7a-2:备件出给保养 / 退回 —— source_id 是 maintenance_part_issues 的那一行,它指着批次(没有这一支,出库解除的 1200 归不回批次,
        -- 而批次一侧的剩余量已经少了,未解释当场不为零 —— 这正是没有兜底桶换来的东西)
        UNION ALL
        SELECT pi.inbound_batch_id, e.amt, e.st
          FROM eff e
          JOIN maintenance_part_issues pi ON pi.id = e.sid
         WHERE e.st = 'maintenance_part'
    ),
    b AS (
        SELECT ib.id,
               round(COALESCE(ib.remaining_qty * inbound_batch_landed_unit_cost_all(ib.id),0),2) AS batch_side,
               round(COALESCE((SELECT SUM(a.amt) FROM attr a WHERE a.batch_id = ib.id),0),2) AS ledger_net,
               COALESCE((SELECT count(*) FROM attr a WHERE a.batch_id = ib.id AND a.st='purchase'),0) AS purch_n,
               round(COALESCE((SELECT SUM(a.amt) FROM attr a WHERE a.batch_id = ib.id AND a.st='purchase'),0),2) AS purch_net,
               EXISTS (SELECT 1 FROM processing_inputs pi
                         JOIN processing_runs r ON r.id = pi.run_id
                        WHERE pi.inbound_batch_id = ib.id AND r.deleted_at IS NULL
                          AND r.status = 'committed' AND r.allocated_at IS NULL) AS unalloc
          FROM inbound_batches ib
    )
    SELECT round(SUM(batch_side),2),
           -- C1:从来没有过计价分录,而批次身上有价 —— 计价早于过账通路。
           round(SUM(CASE WHEN batch_side > 0 AND purch_n = 0 AND ledger_net <= 0
                          THEN batch_side ELSE 0 END),2),
           -- C2:计价分录有过,但净额为零(冲销之后没有按新价补过)。
           round(SUM(CASE WHEN batch_side > 0 AND purch_n > 0 AND purch_net = 0
                          THEN batch_side ELSE 0 END),2),
           -- C3/C5:账面被解除到了【贷方】—— 放出去的钱从来没有进来过。
           round(SUM(CASE WHEN ledger_net < 0 THEN -ledger_net ELSE 0 END),2),
           -- C6/M1:货已消耗,而 1200 还挂着它的成本(已提交、未分摊)。
           round(SUM(CASE WHEN ledger_net > batch_side AND unalloc
                          THEN -(ledger_net - batch_side) ELSE 0 END),2)
      INTO v_sub_raw, v_c1, v_c2, v_c3, v_c6
      FROM b;

    -- ★ MES-7a-2:M3 与 M4 里的"已被消耗"只算【加工消耗那一类】—— 出给保养的件在出库那一刻就按落地单价(含运费与加工资本化的那一份)
    --   解除了 1200,所以把 inbound_batch_maintenance_net_qty 加回剩余量:否则同一份解除会被这里再报一次,未解释反而不为零。
    -- M3 LANDED-DENOM:资本化落在【已被部分消耗】的批次上,分母是 quantity,
    -- 于是解除不足,残值搁浅在 1200。今天为零 —— 唯一一笔资本化已回滚。
    SELECT round(COALESCE(SUM(
             bpca.amount_base * (1 - LEAST((ib.remaining_qty + inbound_batch_maintenance_net_qty(ib.id)) / NULLIF(ib.quantity,0), 1))
           ),0),2) INTO v_m3
      FROM batch_processing_cost_allocations bpca
      JOIN inbound_batches ib ON ib.id = bpca.inbound_batch_id
      JOIN processing_runs r ON r.id = bpca.run_id
     WHERE r.deleted_at IS NULL AND r.status <> 'reversed'
       AND ib.remaining_qty + inbound_batch_maintenance_net_qty(ib.id) < ib.quantity;

    -- M4:运费按过账当刻的 in_stock_ratio 劈分,之后不再重算。
    -- 残差 = 冻结的比例与今天的比例之差。今天为零 —— 唯一一张运费单已冲销。
    SELECT round(COALESCE(SUM(
             fa.amount_base * (fa.in_stock_ratio
               - LEAST((COALESCE(ib.remaining_qty,0) + inbound_batch_maintenance_net_qty(ib.id)) / NULLIF(ib.quantity,0), 1))
           ),0),2) INTO v_m4
      FROM freight_allocations fa
      JOIN inbound_batches ib ON ib.id = fa.inbound_batch_id
      JOIN freight_documents fd ON fd.id = fa.freight_document_id
     WHERE fd.status <> 'reversed' AND fd.deleted_at IS NULL;

    v_diff_raw  := round(v_sub_raw - v_led_raw, 2);
    -- ★ 没有兜底桶:只扣这六项,任何没被分类的来源原样留在 unexplained 里。
    v_unexp_raw := round(v_diff_raw - (v_c1 + v_c2 + v_c3 + v_c6 + v_m3 + v_m4), 2);

    -- ── 产成品侧 ────────────────────────────────────────────────────────
    -- 【三种状态不许长得一样】(R6):有数 / 0.00(卖光了) / NULL(从未分摊)。
    -- 这里只加【有数】的那些;从未分摊的批次不是 0,它们不参与合计,
    -- 由报表侧渲染成 '—' 并单独报量。
    SELECT round(COALESCE(SUM(ob.remaining_qty * po.unit_cost_base),0),2) INTO v_sub_fg
      FROM output_batches ob
      JOIN processing_outputs po ON po.output_batch_id = ob.id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0
       AND po.unit_cost_base IS NOT NULL;

    -- M10:成本在 1220 通路存在【之前】就分摊掉了 —— 明细里有,总账里一张分录都没有。
    SELECT round(COALESCE(SUM(ob.remaining_qty * po.unit_cost_base),0),2) INTO v_fg_pre
      FROM output_batches ob
      JOIN processing_outputs po ON po.output_batch_id = ob.id
      JOIN processing_runs r ON r.id = po.run_id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0
       AND po.unit_cost_base IS NOT NULL
       AND NOT EXISTS (
             SELECT 1 FROM journal_activity_lines(NULL, p_as_of, true) l
              JOIN journal_entries je ON je.id = l.entry_id
             WHERE l.account_code = '1220'
               AND je.source_type = 'allocation' AND je.source_id = r.id);

    v_diff_fg  := round(v_sub_fg - v_led_fg, 2);
    v_unexp_fg := round(v_diff_fg - v_fg_pre, 2);

    v_sides := jsonb_build_array(
        jsonb_build_object(
            'side','inventory_raw','control_account','1200',
            'ledger_base',     round(v_led_raw,2),
            'subledger_base',  v_sub_raw,
            'difference_base', v_diff_raw,
            'subledger_basis', CASE WHEN v_live THEN 'live_position' ELSE 'reconstructed' END,
            'refusal', NULL,
            'variances', jsonb_build_array(
                jsonb_build_object('code','never_capitalised','amount_base',v_c1),
                jsonb_build_object('code','orphaned_reprice_delta','amount_base',v_c2),
                jsonb_build_object('code','relief_without_capitalisation','amount_base',v_c3),
                jsonb_build_object('code','unallocated_consumption','amount_base',v_c6),
                jsonb_build_object('code','stranded_capitalisation','amount_base',v_m3),
                jsonb_build_object('code','freight_split_residue','amount_base',v_m4)),
            'unexplained_base', v_unexp_raw,
            'reconciled', (v_unexp_raw = 0)),
        jsonb_build_object(
            'side','inventory_fg','control_account','1220',
            'ledger_base',     round(v_led_fg,2),
            'subledger_base',  v_sub_fg,
            'difference_base', v_diff_fg,
            'subledger_basis', CASE WHEN v_live THEN 'live_position' ELSE 'reconstructed' END,
            'refusal', NULL,
            'variances', jsonb_build_array(
                jsonb_build_object('code','costed_before_1220_path','amount_base',v_fg_pre)),
            'unexplained_base', v_unexp_fg,
            'reconciled', (v_unexp_fg = 0)));

    RETURN v_sides;
END;
$function$;

COMMENT ON FUNCTION public.inventory_control_reconciliation(p_as_of date) IS
    'INV-VAL-1:存货明细账 ↔ 控制科目(1200 原料 / 1220 产成品)的两条腿,供 gl_control_reconciliation 拼接。四条具名成因 + 两条机制项,【没有兜底桶】,判据是 unexplained = 0。归因必须【原分录优先】走回批次 —— 冲销分录的 source_id 指向原分录,取错顺序会让 4 行归因失败、unexplained 当场不为零。as-at 早于今天时先证明重建算得出来(business_date 无空缺、无迟到的资本化),证不出来就【具名拒绝】,数字为 NULL、reconciled 为 NULL —— 答不上来不是对不上。';

-- db/functions/journal_entry_reversal_route.sql
-- APR-6(2026-09-25,grilling Q6):一张分录【从凭证页】怎么冲 —— 一份判据,三个读它的人
-- (reverse_journal_entry 那扇只会拒的门 · 冲销申请的提交与过账 · 凭证页上那颗钮灰不灰、说什么)。
--
--   'reversed'     已经冲过(status <> posted 或 reversed_by 已挂上)—— 不能再冲。
--   'source_path'  有自己冲销路径的:付款 · 转账 · 代扣税缴纳(各自的冲销申请)、purchase(改价申请)、
--                  invoice / credit_note(作废 / 贷项申请)、expense(reverse_expense)、freight
--                  (reverse_freight_document)、allocation / processing_cost(重分摊 / 加工回滚)、year_close
--                  (reopen_financial_year)、工资期的【过账】分录与它的冲销(撤销申请)。凭证页按名拒
--                  JE_REVERSE_USE_SOURCE_PATH —— 从这里冲掉,总账回来了,那张单据却不知道。
--   'request'      其余一切:手工凭证,以及没有自己路径的系统分录(sale · stocktake · writeoff · prepayment ·
--                  revaluation · depreciation · shipment · fx · 工资的【付款】分录)。
--   ★ APR-9(grilling Q9):asset_disposal 从 'request' 挪进 'source_path'。处置从此经 CFO 批的申请过账,
--     而冲掉它的分录只会把总账拿回来、资产卡照旧是 disposed(APR4-DISPOSAL-REVERSAL-LEAVES-ASSET-DISPOSED)——
--     总账与卡不许说两句话。处置【还没有】自己的撤销路径(known-issues:APR9-NO-DISPOSAL-REVERSAL-YET);
--     在它之前,这张分录从凭证页冲不掉。
--                  从凭证页冲它们是一个人的裁量,走同一张 CFO 冲销申请(Q6 (i)(iii))。
--   ★ MES-7a-2(2026-10-16,MES-7a Step 0 Q12):maintenance_part(备件出给保养 / 退回)进 'source_path'。更正一次出库是一行退回
--     (return_spare_parts),冲掉那张分录只会把总账拿回来、流水与那一行出库照旧 —— 1200 与库存当场对不上。
--   NULL           没有这张分录。
--
-- 【冲销分录抄原分录的 source_type】所以一张冲销分录落在与原分录同一格 —— 冲掉一张作废留下的冲销,
-- 同样是 source_path(否则 = 不经批准地复活发票),与 reverse_journal_entry 一直以来的判法一致。
-- 工资那一段原样搬自 reverse_journal_entry(PAYROLL-APR-1 Q5):只有被 payroll_lines.paid_journal_entry_id /
-- payroll_periods.cpf_journal_entry_id / deductions_journal_entry_id 指着的【付款】分录(以及它们的冲销)不算
-- source_path —— 它们没有正经的冲销路径(PAYROLL-PAYMENT-NO-REVERSAL-PATH),APR-6 起走冲销申请。
--
-- DEFINER:它读工资表(一个持 finance.view 却读不到 payroll_lines 的人,INVOKER 下会把一张工资过账分录
-- 错读成 'request' —— xmodule 那一族)。本体【不问码】:它也在批准与试跑的内层被调用(那里的主语未必持
-- 凭证页的码,以 postgres 跑的 fixture 根本没有主语);而它只回一个词,不回任何金额、任何行
-- (db/check_mirrors.py DEFINER_NO_CHECK_ALLOWED 记着这条理由)。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.journal_entry_reversal_route(p_entry_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_je journal_entries%ROWTYPE;
BEGIN
    SELECT * INTO v_je FROM journal_entries WHERE id = p_entry_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    IF v_je.status <> 'posted' OR v_je.reversed_by IS NOT NULL THEN
        RETURN 'reversed';
    END IF;
    IF v_je.source_type IN ('payment', 'transfer', 'wht_remittance', 'purchase', 'invoice', 'credit_note',
                            'expense', 'freight', 'allocation', 'processing_cost', 'year_close',
                            'asset_disposal', 'maintenance_part') THEN
        RETURN 'source_path';
    END IF;
    IF v_je.source_type = 'payroll' AND NOT (
           EXISTS (SELECT 1 FROM payroll_lines pl
                    WHERE pl.paid_journal_entry_id IN (v_je.id, v_je.source_id))
           OR EXISTS (SELECT 1 FROM payroll_periods pp
                       WHERE pp.cpf_journal_entry_id IN (v_je.id, v_je.source_id)
                          OR pp.deductions_journal_entry_id IN (v_je.id, v_je.source_id))) THEN
        RETURN 'source_path';
    END IF;
    RETURN 'request';
END;
$function$;

-- db/functions/trail_subject_members.sql
-- AUDIT-TRAIL-1a(Tim 的 Q3 · Q6):一个主语的审计记录【由哪些行组成】—— 根行之外的子行与相关行。
--   每一行说:这张表里 fk_column 等于 parent_table 某一行的 id 的那些行,属于这条记录;match 是额外的固定条件
--   (多态的 approval_log 靠 subject_type 认主)。parent_table 可以是另一张子表(孙行:付款保留金挂在明细行上)。
--   按 ord 依次展开,所以孙行排在它的父行之后。
-- 【子行是在读的时候找出来的】(Q6)—— 不在记录上写父键。找法见 record_trail:今天还在的行按外键查,
--   已经删掉或改过父键的行从 change_log 的影像里查(GIN 索引 idx_change_log_image / idx_change_log_update_old)。
-- 【每一行子行都要再过一次它自己那张表的读规则】(Q4)—— 由 record_trail 调 trail_row_visible 做,不在这里。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M4 与 Q4)多了三列:
--   hop    'down'(默认):table.fk_column = parent 那一行的 id(往下走)。
--          'up'(M4):table.id = parent 那一行的 fk_column(往上走一跳 —— 批次 → 消耗它的加工单、它收货的采购单)。
--   shown  true:这张表的行是这条记录的一部分,它们的每一次改动都进审计记录。
--          false:【垫脚石】—— 只用来够到它下面的行,它自己的改动不进来(Q4:"只限碰到这个批次的那些事")。
--          批次的审计记录经由加工单够到那张单的成本修改、分录与工单的审批,但加工单本身的编辑不在批次上。
--   home   true:这张表的行【住在】这个主语下 —— /settings/change-history 的"Record"一栏沿 home 的那一条往上走
--          (trail_row_record)。同一张表挂在两个主语下时(加工投入既属于加工单、也出现在批次上),只有一处是家。
--   原来旧批次审计记录那 20 支(db/views/batch_audit_trail_all.sql)的每一支都在下面有它的来处 ——
--   fixture 238 逐行对照两边,少一行就红。
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb, 'down', true, true),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗;1b-1 加:回滚申请及其审批(Q12)
        ('processing_run', 1, 'processing_inputs',                 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 2, 'processing_outputs',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 7, 'warehouse_requests',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, false),
        ('processing_run', 8, 'approval_log',                      'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        -- 角色:授权(加上 / 拿掉);AUDIT-TRAIL-1d-1 加:授给了谁(Q22 —— 家在账号那一边:授出去的是那个账号)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),
        ('role', 2, 'user_roles',       'roles', 'role_id', '{}'::jsonb, 'down', true, false),

        -- ── 进料批次(1b-1)────────────────────────────────────────────────────────────────────────────
        -- 批次自己的:金属含量 · 化验与化验的金属 · 安全状态 · 价格 · 收货定价申请与它的审批 · 预付款核销 · 条款承诺 ·
        --   库存流水 · 盘点行与盘点的每一次清点 · 加工投入 · 成本分摊 · 销毁证书与签发 · 仓库申请(注销、证书作废)与它的审批 ·
        --   运费分摊 · 付款核销 · 财务附件
        ('inbound_batch',  1, 'inbound_batch_metals',              'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  3, 'assay_result_metals',               'assay_results',               'assay_result_id',  '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  4, 'inbound_batch_safety_states',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  5, 'price_history',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  6, 'receipt_price_requests',            'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  7, 'approval_log',                      'receipt_price_requests',      'subject_id',       '{"subject_type": "receipt_price_request"}'::jsonb, 'down', true, true),
        ('inbound_batch',  8, 'prepayment_applications',           'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  9, 'pricing_term_commitments',          'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 10, 'pricing_term_commitment_metals',    'pricing_term_commitments',    'commitment_id',    '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 11, 'inventory_movements',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 12, 'stocktake_lines',                   'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 13, 'stocktake_counts',                  'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 14, 'processing_inputs',                 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 15, 'batch_processing_cost_allocations', 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 16, 'certificates_of_destruction',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 17, 'cod_issues',                        'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 18, 'warehouse_requests',                'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 19, 'warehouse_requests',                'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 20, 'approval_log',                      'warehouse_requests',          'subject_id',       '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch', 21, 'freight_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 22, 'payment_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 23, 'finance_attachments',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4),只取碰到这个批次的那些事:
        --   它收货的采购单 → 那张单的审批与修改史(旧 approval / po_change 两支)
        ('inbound_batch', 24, 'purchase_orders',                   'inbound_batches',             'purchase_order_id', '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 25, 'approval_log',                      'purchase_orders',             'subject_id',        '{"subject_type": "purchase_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 26, 'purchase_order_history',            'purchase_orders',             'purchase_order_id', '{}'::jsonb, 'down', true,  false),
        --   消耗它的加工单 → 那张单的成本修改史、成本条目(垫脚石)、工单(垫脚石)→ 工单的审批与修改史
        ('inbound_batch', 27, 'processing_runs',                   'processing_inputs',           'run_id',            '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 28, 'processing_cost_entry_history',     'processing_runs',             'run_id',            '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 29, 'processing_cost_entries',           'processing_runs',             'run_id',            '{}'::jsonb, 'down', false, false),
        ('inbound_batch', 30, 'work_orders',                       'processing_runs',             'work_order_id',     '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 31, 'approval_log',                      'work_orders',                 'subject_id',        '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 32, 'work_order_history',                'work_orders',                 'work_order_id',     '{}'::jsonb, 'down', true,  false),
        --   盘点过它的那一次盘点(垫脚石)→ 那次盘点过账的分录
        ('inbound_batch', 33, 'stocktakes',                        'stocktake_lines',             'stocktake_id',      '{}'::jsonb, 'up',  false, false),
        --   分录:直接挂在批次上的(计价、注销)· 预付款核销的 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('inbound_batch', 34, 'journal_entries',                   'inbound_batches',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 35, 'journal_entries',                   'prepayment_applications',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 36, 'journal_entries',                   'processing_cost_entries',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 37, 'journal_entries',                   'processing_runs',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 38, 'journal_entries',                   'stocktakes',                  'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false),

        -- ── 产出批次(1b-1)────────────────────────────────────────────────────────────────────────────
        ('output_batch',  1, 'output_batch_metals',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  2, 'assay_results',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  3, 'assay_result_metals',               'assay_results',      'assay_result_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  4, 'output_batch_safety_states',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  5, 'inventory_movements',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  6, 'processing_outputs',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  7, 'processing_inputs',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  8, 'stocktake_lines',                   'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 10, 'warehouse_requests',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 11, 'approval_log',                      'warehouse_requests', 'subject_id',      '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 13, 'sales_record_movements',            'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 14, 'sales_attribution_log',             'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 15, 'invoice_lines',                     'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 16, 'payment_allocations',               'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 17, 'sales_order_reservations',          'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 18, 'shipment_lines',                    'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 19, 'traceability_report_issues',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 20, 'sales_settlements',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4):产出它 / 消耗它的加工单 → 成本修改史、成本条目(垫脚石)、工单 → 审批与修改史;
        --   盘点过它的盘点(垫脚石);它的销售对应的订单行(垫脚石)→ 那一行的订单修改史(旧 so_change 一支)
        ('output_batch', 21, 'processing_runs',                   'processing_outputs', 'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 22, 'processing_runs',                   'processing_inputs',  'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 23, 'processing_cost_entry_history',     'processing_runs',    'run_id',              '{}'::jsonb, 'down', true,  false),
        ('output_batch', 24, 'processing_cost_entries',           'processing_runs',    'run_id',              '{}'::jsonb, 'down', false, false),
        ('output_batch', 25, 'work_orders',                       'processing_runs',    'work_order_id',       '{}'::jsonb, 'up',  false, false),
        ('output_batch', 26, 'approval_log',                      'work_orders',        'subject_id',          '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('output_batch', 27, 'work_order_history',                'work_orders',        'work_order_id',       '{}'::jsonb, 'down', true,  false),
        ('output_batch', 28, 'stocktakes',                        'stocktake_lines',    'stocktake_id',        '{}'::jsonb, 'up',  false, false),
        ('output_batch', 29, 'sales_order_lines',                 'sales_records',      'sales_order_line_id', '{}'::jsonb, 'up',  false, false),
        ('output_batch', 30, 'sales_order_history',               'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true,  false),
        --   分录:注销(直接挂在批次上)· 销售与发货的成本 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('output_batch', 31, 'journal_entries',                   'output_batches',     'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 32, 'journal_entries',                   'sales_records',      'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 33, 'journal_entries',                   'processing_cost_entries', 'source_id',      '{}'::jsonb, 'down', true,  false),
        ('output_batch', 34, 'journal_entries',                   'processing_runs',    'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 35, 'journal_entries',                   'stocktakes',         'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 36, 'journal_entries',                   'journal_entries',    'reversed_by',         '{}'::jsonb, 'up',  true,  false),

        -- ── 工单(1b-1):明细 · 预期产出 · 修改史 · 放行审批 ─────────────────────────────────────────────
        ('work_order', 1, 'work_order_lines',            'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 2, 'work_order_expected_outputs', 'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 3, 'work_order_history',          'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 4, 'approval_log',                'work_orders', 'subject_id',    '{"subject_type": "work_order"}'::jsonb, 'down', true, true),

        -- ── 盘点(1b-1):盘点行 · 每一次清点 · 过账审批 · 过账分录(财务读)─────────────────────────────────
        ('stocktake', 1, 'stocktake_lines',  'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 2, 'stocktake_counts', 'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 3, 'approval_log',     'stocktakes', 'subject_id',   '{"subject_type": "stocktake"}'::jsonb, 'down', true, true),
        ('stocktake', 4, 'journal_entries',  'stocktakes', 'source_id',    '{"source_type": "stocktake"}'::jsonb, 'down', true, false),

        -- ── 设备(1b-1,Q22):保养维修 · 停机 · 保养周期 · 交接班里提到的那次停机 ────────────────────────────
        ('equipment', 1, 'equipment_maintenance',         'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 2, 'equipment_downtime',            'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 3, 'equipment_service_intervals',   'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 4, 'shift_handover_equipment_refs', 'equipment_downtime', 'downtime_id',  '{}'::jsonb, 'down', true, false),

        -- ── 交接班(1b-1,Q23):交接事项 · 提到的停机 ───────────────────────────────────────────────────
        ('shift_handover', 1, 'shift_handover_items',          'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),
        ('shift_handover', 2, 'shift_handover_equipment_refs', 'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),

        -- ── 仓库申请(1b-1,Q12):/inventory 那一块 —— 申请本身与它的审批 ─────────────────────────────────
        ('warehouse_request', 1, 'approval_log', 'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a)· 商务:报价、订单、发货、客户、佣金、供应商、物流 ══
        -- ── 报价:明细(硬删的行从影像里找)· 签发档 · 事件史 ─────────────────────────────────────────
        ('quote', 1, 'quote_lines',  'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 2, 'qt_issues',    'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        -- ── 销售订单:明细 · 明细的预留 · 发货放行与它的明细、审批 · 签发档 · 事件史 · 合同条款 ──────────────
        --   ★ 预留、发货单明细、订单事件史以前挂在产出批次下面(home = false);它们的【家】是这张订单 / 这张发货单,
        --     所以 /settings/change-history 的 Record 一栏从此指向订单 / 发货单(trail_row_record 只沿 home 走)。
        ('sales_order', 1, 'sales_order_lines',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 2, 'sales_order_reservations', 'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true, true),
        ('sales_order', 3, 'shipping_releases',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 4, 'shipping_release_lines',   'shipping_releases',  'release_id',          '{}'::jsonb, 'down', true, true),
        ('sales_order', 5, 'approval_log',             'shipping_releases',  'subject_id',          '{"subject_type": "shipping_release"}'::jsonb, 'down', true, true),
        ('sales_order', 6, 'so_issues',                'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 8, 'contract_document_terms',  'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        -- ── 发货单(M1:销售或发货的人都读得到):明细 · 送货单签发档 ─────────────────────────────────────
        ('shipment', 1, 'shipment_lines',  'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        ('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        -- ── 客户:联系人 · 附件 · 信用史 · 对账单与它的签发档 · 催收与它挂的单据、承诺
        --   (后四张只给财务读 —— 读不了的人那几行是 Restricted,Q4)────────────────────────────────────
        ('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 2, 'customer_attachments',       'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 3, 'customer_credit_history',    'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 4, 'customer_statements',        'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 5, 'statement_issues',           'customer_statements', 'statement_id', '{}'::jsonb, 'down', true, true),
        ('customer', 6, 'collection_chases',          'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 7, 'collection_chase_documents', 'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        ('customer', 8, 'collection_promises',        'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        -- ── 供应商:合规证书 · 附件 · 联系人 · 状态变动史 · 审批(送审、批准、驳回)────────────────────────
        ('supplier', 1, 'supplier_compliance',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 2, 'supplier_attachments',    'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 3, 'counterparty_contacts',   'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 4, 'supplier_status_history', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{"subject_type": "supplier"}'::jsonb, 'down', true, true),
        -- ── 集装箱:里程碑 · 单据清单 ────────────────────────────────────────────────────────────────
        ('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        ('container', 2, 'container_documents',  'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        -- ── 货代(M3):物流属性(一家一行,主键就是 supplier_id)· 按航段的报价 ──────────────────────────────
        ('forwarder', 1, 'forwarder_details',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        -- ── 航段:它的单据清单;港口:从它出发、到它为止的航段(两个外键,两行)──────────────────────────────
        ('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true),
        ('port', 1, 'lanes',                      'ports', 'origin_port_id',      '{}'::jsonb, 'down', true, false),
        ('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a)· 主数据与工具:物料、库位、金属价格、公式、任务 ══
        -- ── 物料:附件 · 必须化验的金属(复合主键,叶子)───────────────────────────────────────────────
        ('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        ('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        -- ── 库位:允许存放的废物分类(Q13:保存只改变动的那几条,一次调用 —— save_storage_location)──────────
        ('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true),
        -- ── 公式:应付金属(叶子)· 修改史 · 条款申请(只给持价格码的人读,别人那一行是 Restricted,Q4)· 申请的审批 ────
        ('pricing_formula', 1, 'pricing_formula_metals',  'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 2, 'pricing_formula_history', 'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 4, 'approval_log',            'terms_requests',   'subject_id', '{"subject_type": "terms_request"}'::jsonb, 'down', true, true),
        -- ── 任务(Q3:私人任务也是):步骤 · 参与者 · 修改史(三张表的人都是员工 id,M2)─────────────────────
        ('task', 1, 'task_nodes',        'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a)· 账上的单据 ══════════════════════════════════
        -- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),不是原单据 —— 所以一张单据够到它的冲销,
        --   只走原分录的 reversed_by(往上一跳,M4;批次 ord 39 的同一个做法),绝不按 source_id = 单据 id 去找。
        -- 一张冲销分录的行【不】挂在原分录上(Q33):行(ord 1)排在冲销(ord 2)之前展开,所以只取到根分录自己的行。
        -- ── 分录:行 · 它的冲销(往上)· 它冲的那一张(往下,在冲销分录的页上)· 申请(人工分录 / 冲销)与申请的审批 ──
        ('journal_entry', 1, 'journal_lines',    'journal_entries',  'entry_id',                '{}'::jsonb, 'down', true, true),
        ('journal_entry', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('journal_entry', 3, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'down', true, false),
        ('journal_entry', 4, 'journal_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('journal_entry', 5, 'journal_requests', 'journal_entries',  'target_entry_id',         '{}'::jsonb, 'down', true, false),
        ('journal_entry', 6, 'approval_log',     'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, false),
        -- AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(/finance/assets 的折旧批次一块读这张分录;
        --   家仍是资产那一页 —— 每一张资产卡自己也有它那一行,Step 0 §a)
        ('journal_entry', 7, 'fixed_asset_depreciation', 'journal_entries', 'journal_entry_id', '{}'::jsonb, 'down', true, false),
        -- ── 发票:行 · 签发档 · 作废 / 贷项申请与它的审批 · 由它开出的贷项通知 · 核销它的收款 · 它的分录与冲销 ──────
        ('invoice', 1, 'invoice_lines',    'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 2, 'invoice_issues',   'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 3, 'invoice_requests', 'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 4, 'approval_log',     'invoice_requests', 'subject_id',              '{"subject_type": "invoice_request"}'::jsonb, 'down', true, true),
        ('invoice', 5, 'credit_notes',     'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 6, 'payment_allocations', 'invoices',      'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 7, 'journal_entries',  'invoices',         'entry_id',                '{}'::jsonb, 'up',   true, false),
        ('invoice', 8, 'journal_entries',  'invoice_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        ('invoice', 9, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        -- ── 贷项通知:行 · 签发档 · 开出它的那张申请与审批 · 它的分录 ──────────────────────────────────────────
        ('credit_note', 1, 'credit_note_lines', 'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 2, 'cn_issues',         'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 3, 'invoice_requests',  'credit_notes',     'result_credit_note_id', '{}'::jsonb, 'down', true, false),
        ('credit_note', 4, 'approval_log',      'invoice_requests', 'subject_id',            '{"subject_type": "invoice_request"}'::jsonb, 'down', true, false),
        ('credit_note', 5, 'journal_entries',   'credit_notes',     'entry_id',              '{}'::jsonb, 'up',   true, false),
        -- ── 收付款:核销行 · 附件 · 冲销它的那一笔(往上)/ 它冲的那一笔(往下,在镜像单上)· 付出它的申请 · 冲它的申请 ·
        --    申请的审批 · 它的分录与冲销 ────────────────────────────────────────────────────────────────────────
        ('payment', 1, 'payment_allocations', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, true),
        ('payment', 2, 'finance_attachments', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 3, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'up',   true, false),
        ('payment', 4, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'down', true, false),
        ('payment', 5, 'payment_requests',    'payments',         'result_payment_id',   '{}'::jsonb, 'down', true, false),
        ('payment', 6, 'payment_requests',    'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 7, 'approval_log',        'payment_requests', 'subject_id',          '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        ('payment', 8, 'journal_entries',     'payments',         'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('payment', 9, 'journal_entries',     'journal_entries',  'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 付款申请(六种:付款 · 付款冲销 · 行内转账 · 转账冲销 · 代扣税缴纳 · 缴纳冲销):审批 · 付出的那一笔 ·
        --    被冲的那一笔(垫脚石:它自己的事不是这张申请的)· 转账 · 缴纳 · 过账的分录与冲销 ──────────────────
        --    ★ 一张"代扣税缴纳"申请没有指向它造出的那一笔缴纳的外键(形状检查让 wht_remittance_id 在这一种上恒为空)——
        --      唯一的路是 申请 → result_journal_entry_id → wht_remittances.journal_entry_id(ord 8)。
        ('payment_request',  1, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, true),
        ('payment_request',  2, 'payments',         'payment_requests', 'result_payment_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  3, 'payments',         'payment_requests', 'payment_id',              '{}'::jsonb, 'up',   false, false),
        ('payment_request',  4, 'bank_transfers',   'payment_requests', 'result_transfer_id',      '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  5, 'bank_transfers',   'payment_requests', 'transfer_id',             '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  6, 'wht_remittances',  'payment_requests', 'wht_remittance_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  7, 'journal_entries',  'payment_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  8, 'wht_remittances',  'journal_entries',  'journal_entry_id',        '{}'::jsonb, 'down', true,  false),
        ('payment_request',  9, 'journal_entries',  'bank_transfers',   'reversal_entry_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request', 10, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true,  false),
        -- ── 费用 / 供应商账单:核销行 · 附件 · 定金冲抵 · 冲销它的那一张(往上)/ 它冲的那一张(往下)· 报销单与它的审批 ·
        --    资本化进资产的那一笔成本 · 它的分录 · 定金冲抵的分录 · 冲销 ────────────────────────────────────────
        ('expense',  1, 'payment_allocations',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  2, 'finance_attachments',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  3, 'prepayment_applications',  'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        ('expense',  4, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('expense',  5, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'down', true, false),
        ('expense',  6, 'expense_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  7, 'approval_log',             'expense_claims',          'subject_id',          '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('expense',  8, 'fixed_asset_cost_entries', 'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  9, 'journal_entries',          'expenses',                'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('expense', 10, 'journal_entries',          'prepayment_applications', 'source_id',           '{}'::jsonb, 'down', true, false),
        ('expense', 11, 'journal_entries',          'journal_entries',         'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- AUDIT-TRAIL-1d-2(Q37):医疗报销付款时建的那张费用单 —— 费用页够得到是哪一张报销单让它生出来的(家仍在报销单那一页)
        ('expense', 12, 'medical_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        -- ── 应付(Q5,M3 · M6):只有钱的那几样 —— 核销 · 运费分摊 · 定金冲抵 · 财务附件 · 价格 · 计价 / 注销 / 定金的分录与冲销 ──
        ('payable', 1, 'payment_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 2, 'freight_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 3, 'prepayment_applications', 'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 4, 'finance_attachments',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 5, 'price_history',           'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 6, 'journal_entries',         'inbound_batches',         'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 7, 'journal_entries',         'prepayment_applications', 'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 8, 'journal_entries',         'journal_entries',         'reversed_by',      '{}'::jsonb, 'up',   true, false),

        -- ══ AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a)· 其余的单据与合同 ══════════════════════════════════
        -- ── 销售(Q14):出库 · 归属客户 · 开票的那一行 · 收款核销 · 附件 · 收入 / 成本分录与它们的冲销 ─────────────────
        --    ★ 销售自己是一个主语的根了 —— /settings/change-history 的 Record 一栏把销售那一行与它的子行归到【这一笔销售】
        --      (以前归到产出批次:产出批次 ord 12 的 home 改成 false,于是从子行往上走到销售就停下)
        ('sale', 1, 'sales_record_movements', 'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 2, 'sales_attribution_log',  'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 3, 'invoice_lines',          'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 4, 'payment_allocations',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 5, 'finance_attachments',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, true),
        ('sale', 6, 'journal_entries',        'sales_records',   'source_id',       '{"source_type": "sale"}'::jsonb, 'down', true, false),
        ('sale', 7, 'journal_entries',        'sales_records',   'cogs_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('sale', 8, 'journal_entries',        'journal_entries', 'reversed_by',     '{}'::jsonb, 'up',   true, false),
        -- ── 运费单:分摊到的批次(家在这里 —— 它是这张单分出去的)· 付它的核销 · 过账分录 · 冲销分录 ───────────────────
        ('freight', 1, 'freight_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, true),
        ('freight', 2, 'payment_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, false),
        ('freight', 3, 'journal_entries',     'freight_documents', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('freight', 4, 'journal_entries',     'freight_documents', 'reversal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('freight', 5, 'journal_entries',     'journal_entries',   'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 资产(财务那一页,Q10):资产卡的修改史 · 成本 · 折旧与折旧基点 · 处置申请与它的审批 · 处置 / 折旧的分录 ·
        --    保养维修、停机、保养间隔(家仍是 equipment —— 加工那一页)─────────────────────────────────────────────
        ('fixed_asset',  1, 'fixed_asset_history',              'fixed_assets',             'fixed_asset_id',      '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  2, 'fixed_asset_cost_entries',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  3, 'fixed_asset_depreciation',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  4, 'fixed_asset_depreciation_anchors', 'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  5, 'asset_disposal_requests',          'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  6, 'approval_log',                     'asset_disposal_requests',  'subject_id',          '{"subject_type": "asset_disposal_request"}'::jsonb, 'down', true, true),
        ('fixed_asset',  7, 'equipment_maintenance',            'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  8, 'equipment_downtime',               'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  9, 'equipment_service_intervals',      'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 10, 'shift_handover_equipment_refs',    'equipment_downtime',       'downtime_id',         '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 11, 'journal_entries',                  'fixed_assets',             'disposal_journal_id', '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 12, 'journal_entries',                  'fixed_asset_depreciation', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 13, 'journal_entries',                  'journal_entries',          'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 对账单:行与每一行的匹配 · 对账记录与它写明的差额 ────────────────────────────────────────────────────
        ('bank_statement', 1, 'bank_statement_lines',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 2, 'bank_line_matches',                  'bank_statement_lines', 'statement_line_id', '{}'::jsonb, 'down', true, true),
        ('bank_statement', 3, 'bank_reconciliations',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 4, 'bank_reconciliation_variance_items', 'bank_reconciliations', 'reconciliation_id', '{}'::jsonb, 'down', true, true),
        -- ── GST 期间:申报那一刻抄下来的每一格 · 申报申请与它的审批。★ Q22:更正期间【不】挂在原期间上(那样更正件之后的
        --    每一次改动都会出现在原件上);更正件自己的记录以"为 GST-… 开的更正"开头,原件页上那一条链接照旧 ──────────────
        ('gst_period', 1, 'gst_return_boxes',    'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 2, 'gst_filing_requests', 'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 3, 'approval_log',        'gst_filing_requests', 'subject_id', '{"subject_type": "gst_filing_request"}'::jsonb, 'down', true, true),
        -- ── 汇率:它的修改史(录入 · 更正 · 撤回 —— 一件事两行:记录开始之后变更记录那一行说,之前修改史那一行说)──────
        ('fx_rate', 1, 'fx_rate_history', 'fx_rates', 'fx_rate_id', '{}'::jsonb, 'down', true, true),
        -- ── 管理包:没有成员(一份新包取代旧包时,旧包自己那几列说"被谁取代";不经 superseded_by 自连 —— 那会把前一份的
        --    整段历史拉到这一份上)
        -- ── 合同:七张条款表 · 它的申请(生效)与申请的审批(没有 pricing.view 的读者那几行是 Restricted,Q21)·
        --    把它挂到采购单 / 销售订单上的那一份快照(家仍在那张订单上)────────────────────────────────────────────
        ('contract',  1, 'contract_grade_specs',           'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  2, 'contract_insurance_obligations', 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  3, 'contract_volume_commitments',    'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  4, 'contract_pricing_terms',         'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  5, 'contract_settlement_terms',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  6, 'contract_refining_charges',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  7, 'contract_penalty_elements',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  8, 'terms_requests',                 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  9, 'approval_log',                   'terms_requests', 'subject_id',  '{"subject_type": "terms_request"}'::jsonb, 'down', true, false),
        ('contract', 10, 'contract_document_terms',        'contracts',      'contract_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a)· 期末、设置与清单页上的记录 ══════════════════════════
        -- ── 锁期(Q25 · Q3 · M7):月结 / 反结的 period_closes 与 finance_settings 之间一个键都没有 —— 整张表属于那一行。
        --    关账在同一笔里写 period_closes 一行、把锁往后挪;反结在同一笔里给那一行盖反结的戳、把锁往回挪 —— 各是一条
        ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 年结:结转分录(往上)· 反结的冲销分录(往上)──────────────────────────────────────────────────
        ('year_close', 1, 'journal_entries', 'year_closes', 'closing_journal_id',  '{}'::jsonb, 'up', true, false),
        ('year_close', 2, 'journal_entries', 'year_closes', 'reversal_journal_id', '{}'::jsonb, 'up', true, false),
        -- ── 人工分录 / 冲销申请(Q17):它的审批(家在这里 —— 一张还没批的申请没有分录,它唯一的家是它自己)· 过账的那一张 ──
        ('journal_request', 1, 'approval_log',    'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, true),
        ('journal_request', 2, 'journal_entries', 'journal_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        -- ── 报销单(Q20):审批 · 收据(附件)· 批准时记下的那张费用单(往上)。/me 上报销人自己读同样的几张(M8)──────
        ('expense_claim',    1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, true),
        ('expense_claim',    2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        -- ── 行内转账:过账分录 · 冲销分录(往上)· 付出它 / 冲它的申请(往下,两把外键 —— 港口的先例)与申请的审批 ──
        ('bank_transfer', 1, 'journal_entries',  'bank_transfers',   'journal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 2, 'journal_entries',  'bank_transfers',   'reversal_entry_id',  '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 3, 'payment_requests', 'bank_transfers',   'result_transfer_id', '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 4, 'payment_requests', 'bank_transfers',   'transfer_id',        '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 5, 'approval_log',     'payment_requests', 'subject_id',         '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        -- ── 代扣税缴纳(Q30):它的分录 · 冲销那一张(经原分录的 reversed_by,往上)· 冲它的申请(wht_remittance_id)·
        --    付出它的申请(那种申请没有指向缴纳的外键 —— 只能经分录:payment_requests.result_journal_entry_id,往下)· 审批 ──
        ('wht_remittance', 1, 'journal_entries',  'wht_remittances',  'journal_entry_id',        '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 3, 'payment_requests', 'wht_remittances',  'wht_remittance_id',       '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 4, 'payment_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 5, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a · §d · §e)· 机制、设置与员工 ══════════════════════════════
        -- ── 账号(M9,Q24):授给它的角色(家在这里,Q22)· 它作为附加账号挂在谁身上 · 那张挂接史 · 它是谁的主账号
        --    (employees.user_id —— M10 只取那一列:那名员工别的每一次编辑不是账号的事)──────────────────────────────
        ('account', 1, 'user_roles',               'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 2, 'employee_accounts',        'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 3, 'employee_account_history', 'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 4, 'employees',                'auth.users', 'user_id', '{}'::jsonb, 'down', true, false),
        -- ── 审批方针(M7 · Q25):修改史整张属于那一行设置(两张表之间没有键 —— 锁期 / period_closes 的同一个做法)──────────
        ('approval_policy', 1, 'finance_settings_history', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 员工(Q28):任职履历 · 调薪申请与它的审批(只给 view_pay 的人读,别人那几行是 Restricted)· 培训(家在培训那一页,Q29)·
        --    附加账号与它的挂接史 · 账号的镜像(Q24 · Q21):主账号与附加账号(往上一跳到 auth.users,M9)与授给它们的角色 ——
        --    每一行照它自己的读规则:授权人人读得到,账号事件与挂接史只给 manage_permissions,别人是 Restricted ────────────────
        ('employee', 1, 'employment_history',       'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 2, 'salary_change_requests',   'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 3, 'approval_log',             'salary_change_requests', 'subject_id',  '{"subject_type": "salary_change_request"}'::jsonb, 'down', true, true),
        ('employee', 4, 'training_records',         'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 5, 'employee_accounts',        'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 6, 'employee_account_history', 'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 7, 'auth.users',               'employees',              'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 8, 'auth.users',               'employee_accounts',      'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false),
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a)· 请假与考勤 ══════════════════════════════════════════
        -- ── 请假:消耗账(批准时扣、取消时还 —— 家在这里)· 审批 ─────────────────────────────────────────────
        --    /me 上本人读同样的两张(M8);两张的读规则都只给 hr.view,所以本人看到的是 Restricted(Q4 · Q14)
        ('leave_request',    1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, true),
        ('leave_request',    2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, true),
        ('my_leave_request', 1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, false),
        ('my_leave_request', 2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, false),
        -- ── 医疗报销:审批 · 付它的那张费用单(往上,M4)· 费用的分录 · 核销 · 冲销它的费用单与分录(只给财务,别人 Restricted)──
        ('medical_claim',    1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, true),
        ('medical_claim',    2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('medical_claim',    5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, false),
        ('my_medical_claim', 2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('my_medical_claim', 5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        -- ── 加班:行(删掉的行从 DELETE 的影像里找)· 审批(送审 · 批准 · 退回)──────────────────────────────────
        ('overtime_batch',   1, 'overtime_lines',      'overtime_batches', 'batch_id',          '{}'::jsonb, 'down', true, true),
        ('overtime_batch',   2, 'approval_log',        'overtime_batches', 'subject_id',        '{"subject_type": "overtime_batch"}'::jsonb, 'down', true, true),
        -- ── 考勤:每人一行(开月 · 补新人 · 记录 · 完成时冻住的那几列 —— 完成那一下的整批改动在界面上是一句)──────────
        ('attendance_period', 1, 'attendance_lines',   'attendance_periods', 'period_id',       '{}'::jsonb, 'down', true, true),
        -- ── 假期发放(清单块)· 假别 · 公共假期(M11 集合):没有成员 ──────────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a)· 工资与评审 ══════════════════════════════════════════
        -- ── 工资期:工资行(每次保存删了重插 —— 一次操作里按员工配对,Q11;家在这里)· 过账 / 撤销的申请与它们的审批 ·
        --    这一期的分录(过账 · 发薪 · CPF · 代扣款)按 source_id + source_type = 'payroll' 找 —— 【不】经 journal_entry_id
        --    往上走:撤销过账会把那一列置空(unpost_payroll_period_internal),往上一跳读的是今天的样子,过账与它的冲销会一起丢掉;
        --    source_id 撤不掉。冲销分录自己的 source_id 是原分录(1c-1),所以它经 reversed_by 往上一跳。分录只给财务(别人 Restricted)
        ('payroll_period',     1, 'payroll_lines',    'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     2, 'payroll_requests', 'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     3, 'approval_log',     'payroll_requests',    'subject_id',        '{"subject_type": "payroll_request"}'::jsonb, 'down', true, true),
        ('payroll_period',     4, 'journal_entries',  'payroll_periods',     'source_id',         '{"source_type": "payroll"}'::jsonb, 'down', true, false),
        ('payroll_period',     5, 'journal_entries',  'journal_entries',     'reversed_by',       '{}'::jsonb, 'up',   true, false),
        -- ── 评审:目标(删掉的目标从 DELETE 的影像里找)· 审批(送审 · 批准 · 本人确认;作废不写审批)──────────────────
        --    批准时改的员工那一行与任职履历【不】挂进来(Q7):它们没有指回评审的键,评审那一段按评审自己的几列说出结论
        --    /my-reviews 上审核人读同样的两张(M12);审批那几行的读规则是 hr.view,不持它的审核人看到的是 Restricted(Q5 · Q4)
        ('performance_review', 1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, true),
        ('performance_review', 2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, true),
        ('my_review',          1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, false),
        ('my_review',          2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, false),
        -- ── MES-1:设备 —— 网关钥匙(发放与撤销;哈希被 never 规则遮住)。收件箱 · 传输日志 · 中断不进变更记录(MES-0 Q14),不在这里 ──
        ('device',             1, 'gateway_keys',     'devices',             'gateway_id',        '{}'::jsonb, 'down', true, true),
        -- ── MES-2:设备 —— 校准记录(记 · 作废;Q33)。地磅单 —— 它的称重(毛重 · 皮重 · 更正)、分出去的份、照片(传 · 撤)。
        --    草稿与确认时改过的值不挂进来:它们的读码是加工(查看),不是地磅单的门;确认队列与地磅单页上直接列它们 ──
        ('device',             2, 'instrument_calibrations', 'devices',      'device_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 1, 'weighings',        'weighbridge_tickets', 'ticket_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 2, 'weighbridge_ticket_shares', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 3, 'weighbridge_ticket_photos', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        -- ── MES-3a(2026-10-06,MES-3a Step 0 Q12 · Q10):执照 —— 它每一类 NEA 废物的库存上限(给 · 改 · 拿掉)。
        --    进料批 / 产出批 —— 它进厂那一刻库存上限的判法(一批一行,只追加)。──
        ('company_licence',    1, 'licence_storage_limits', 'company_compliance', 'licence_id',  '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     40, 'receipt_ceiling_checks', 'inbound_batches',    'inbound_batch_id', '{}'::jsonb, 'down', true, true),
        ('output_batch',      37, 'receipt_ceiling_checks', 'output_batches',     'output_batch_id',  '{}'::jsonb, 'down', true, false),
        -- ── MES-3b(2026-10-07,MES-3b Step 0 Q7 · Q27):每一次印标签(印 · 补印与理由)—— 挂在它印的那样东西下面。
        --    一张表挂三个主语,只有一处是家(trail_row_record 沿 home 往上走):进料批那一支,与 receipt_ceiling_checks 同一个选法 ──
        ('inbound_batch',     41, 'label_prints',           'inbound_batches',    'inbound_batch_id',    '{}'::jsonb, 'down', true, true),
        ('output_batch',      38, 'label_prints',           'output_batches',     'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('storage_location',   2, 'label_prints',           'storage_locations',  'storage_location_id', '{}'::jsonb, 'down', true, false),
        -- ── MES-4a(2026-10-07,MES-4a Step 0 Q33):加工单 —— 记下的值、异常事件、结平、表头更正(都只追加,都按 run_id 挂)。
        --    一道工序 —— 它的字段、挂着的机器、配方(按 operation_type_code 挂在根行的 code 下)与配方的每一版(挂在配方下)。──
        ('processing_run',     9, 'processing_run_values',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    10, 'processing_run_events',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    11, 'processing_run_closures',    'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    12, 'processing_run_corrections', 'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('operation_type',     1, 'operation_type_fields',      'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     2, 'operation_type_equipment',   'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     3, 'process_recipes',            'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     4, 'process_recipe_versions',    'process_recipes',  'recipe_id',           '{}'::jsonb, 'down', true, true),
        -- ── MES-4b(2026-10-07,MES-4b Step 0 Q28):交叉污染抽检 —— 挂在它那一炉(家)与它抽的那一批极片下面(receipt_ceiling_checks 的先例:
        --    一张表挂两个主语,只有一处是家)。没抽的那一种没有批次,只出现在加工单上。──
        ('processing_run',    13, 'contamination_checks',       'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('output_batch',      39, 'contamination_checks',       'output_batches',   'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-1(2026-10-08,MES-5a Step 0 Q31):放电 —— 逐模组结果、通道分配、拆去隔离的模组。家在那一炉(结果与分配挂在放电那一炉,
        --    拆分挂在拆分那一炉);也出现在它们说的那一批上,结果还出现在记下它的放电柜上(device_id;今天手工录入不填它)。──
        ('processing_run',    14, 'discharge_module_results',      'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    15, 'discharge_channel_assignments', 'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    16, 'discharge_module_splits',       'processing_runs', 'split_run_id',     '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     42, 'discharge_module_results',      'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     43, 'discharge_module_splits',       'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('output_batch',      40, 'discharge_module_results',      'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('output_batch',      41, 'discharge_module_splits',       'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('device',             3, 'discharge_module_results',      'devices',         'device_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-2(2026-10-08,MES-5a Step 0 Q31):电表读数住在那台电表下;一张电费单分给一炉的那一份住在那张单下,也出现在那一炉上。──
        ('device',             4, 'meter_readings',                'devices',                 'device_id',     '{}'::jsonb, 'down', true, true),
        ('electricity_allocation', 1, 'electricity_allocation_lines', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    17, 'electricity_allocation_lines',  'processing_runs',         'run_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5b-2(2026-10-09,MES-5b Step 0 Q32 · Q34;MES5B1-V37-NOT-ON-OPERATION-TRAIL,Tim):一张电费单的撤回住在那张单下,
        --    也出现在它覆盖过的每一炉上(经那一炉的那一行往上一跳到那张分摊 —— 垫脚石,自己的改动不进来 —— 再往下到撤回)。
        --    一道工序每一种产出形态的预期得率(V37)住在那道工序下(按 operation_type_code 挂在根行的 code 下,与它的字段同形)。──
        ('electricity_allocation', 2, 'electricity_allocation_reversals', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    18, 'electricity_allocations',          'electricity_allocation_lines', 'allocation_id', '{}'::jsonb, 'up',   false, false),
        ('processing_run',    19, 'electricity_allocation_reversals', 'electricity_allocations',      'allocation_id', '{}'::jsonb, 'down', true, false),
        ('operation_type',     5, 'operation_type_output_forms',      'operation_types',              'operation_type_code', '{}'::jsonb, 'down', true, true),
        -- ── MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划的目标品位与候选批次都住在那份计划下。──
        ('blending_plan',      1, 'blending_plan_targets',            'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        ('blending_plan',      2, 'blending_plan_lines',              'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        -- ── MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品的保管记录住在那份样品下;样品、它的保管记录与化验争议也出现在它们那一批上
        --    (家在样品 / 争议自己那里)。──
        ('sample',             1, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     44, 'samples',                          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     45, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     46, 'assay_disputes',                   'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      42, 'samples',                          'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      43, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('output_batch',      44, 'assay_disputes',                   'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-6a-2(2026-10-10,MES-6a Step 0 Q39):一份化验的指标(残粉 · 箔纯度 · 粒径)与它的金属行同一个形状 ——
        --    住在那份化验挂着的那一批下(化验没有自己的主语;它的金属行也是这样挂的)。──
        ('inbound_batch',     47, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        ('output_batch',      45, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-1(2026-10-15,MES-6b Step 0 Q39):不合格报告也出现在它那一批上(家在报告自己那里);质量验收限的判定住在产出批下
        --    (判定挂在批次上,没有自己的主语);合同的第八张条款表住在合同下。──
        ('inbound_batch',     48, 'nonconformance_reports',           'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      46, 'nonconformance_reports',           'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      47, 'quality_limit_judgements',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, true),
        ('contract',          11, 'contract_quality_limits',          'contracts',                    'contract_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-2(2026-10-15,MES-6b Step 0 Q38 · Q39):一张分析证书 —— 它的字节档案(家在证书)、作废它的 CFO 申请与那张申请的审批。
        --    证书也出现在两个批次主语下(家在证书自己那里):产出批 —— 它自己的证书、字节、作废申请与审批;进料批 —— 吃过这一批的加工单
        --    做出来的产出批上的证书(垫脚石:加工单 → 它的产出腿 → 那一批产出,只走一层;证书说的"来料化学确定度"正是这一批的事)。──
        ('coa',                1, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, true),
        ('coa',                2, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('coa',                3, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch',      48, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      49, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      50, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      51, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch',     49, 'processing_outputs',               'processing_runs',              'run_id',              '{}'::jsonb, 'down', false, false),
        ('inbound_batch',     50, 'output_batches',                   'processing_outputs',           'output_batch_id',     '{}'::jsonb, 'up',   false, false),
        ('inbound_batch',     51, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7a-2(2026-10-16,MES-7a Step 0 Q20):备件出给保养与退回 —— 没有自己的主语(它没有自己的页)。家在设备(经那一条保养记录);
        --    也出现在进料批下(出的是这一批),连同那张分录(借 6800 / 贷 1200,source_type = maintenance_part,财务读)。──
        ('equipment',          5, 'maintenance_part_issues',          'equipment_maintenance',        'maintenance_id',      '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     52, 'maintenance_part_issues',          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     53, 'journal_entries',                  'maintenance_part_issues',      'source_id',           '{"source_type": "maintenance_part"}'::jsonb, 'down', true, false)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 10 · 视图(镜像原样):库存滚动 DROP + CREATE(多一列)· 质量树与待定值 CREATE OR REPLACE(列不变)· 备件库存(新)──
DROP VIEW public.stock_rollforward_monthly;
DROP VIEW public.stock_rollforward_monthly_all;

-- db/views/stock_rollforward_monthly_all.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q8,Tim):【库存的月度滚动】—— 基视图,不给人读。从 inventory_movements(库存的唯一真源)按
--   business_date 的月、按单位:期初 · 收货 · 加工产出 · 加工消耗(消耗与回滚还原的净额)· 销售 · 注销 · 盘点调整 · 回滚作废 ·
--   出给保养(MES-7a-2:备件出给保养记录,减去退回的 —— maintenance_issue 与 maintenance_return 之和)·
--   搬动(转移与状态变更,两条腿相抵,净额恒为 0)· 期末。每一个流向都取那一行流水的 qty_delta 原样(出为负、进为正)。
--   【没有"对得上"的旗标 —— 刻意的】期末 = 期初 + 本月各行之和,按构造成立;一个两边动不开的旗标是装饰(AGENTS.md
--   「两边只有在能分开的时候才是一个检查」)。所以这里只给数,不给判断。
--   【没有业务日期的流水】(FIN-32 之前写下的行,business_date 为空 —— 表的注释:不回填,界面读作"未知")不进任何一个月:
--     它们在 month 为空的那一行(每个单位一行),期初 / 期末为空。于是"某个月的期末"只是【有日期的】流水之和 —— 页面照直说。
--   月份从最早一条有日期的流水所在的月,连续到今天(新加坡日历)所在的月;没有流水的月也有一行(期初 = 期末)。
--   一个流水类型若不在下面的清单里,它不进任何一列 —— 期末于是对不上库存,看得见(不设"其他"兜底,AGENTS.md「兜底桶」)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql;
--   issued_to_maintenance added by db/migrations/2026-10-16-mes7a2-spare-parts.sql(DROP + CREATE:新列排在 voided 之后、moved 之前)。

CREATE VIEW public.stock_rollforward_monthly_all WITH (security_invoker = off) AS
 WITH mv AS (
         SELECT (date_trunc('month'::text, m.business_date::timestamp without time zone))::date AS month,
            COALESCE(ib.unit, ob.unit) AS unit,
            m.movement_type,
            m.qty_delta
           FROM inventory_movements m
             LEFT JOIN inbound_batches ib ON ib.id = m.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = m.output_batch_id
        ), months AS (
         SELECT u.unit,
            (g.g)::date AS month
           FROM ( SELECT DISTINCT mv.unit
                   FROM mv) u
             CROSS JOIN LATERAL generate_series((( SELECT min(mv.month) AS min
                   FROM mv
                  WHERE mv.month IS NOT NULL))::timestamp without time zone, (date_trunc('month'::text, (now() AT TIME ZONE 'Asia/Singapore'::text)))::timestamp without time zone, '1 mon'::interval) g(g)
        ), flows AS (
         SELECT mv.month,
            mv.unit,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'receipt'::text), 0::numeric) AS received,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'processing_produce'::text), 0::numeric) AS produced,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = ANY (ARRAY['processing_consume'::text, 'reversal_restore'::text])), 0::numeric) AS consumed,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'sale'::text), 0::numeric) AS sold,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'writeoff'::text), 0::numeric) AS written_off,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'adjustment'::text), 0::numeric) AS adjusted,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = 'reversal_void'::text), 0::numeric) AS voided,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = ANY (ARRAY['maintenance_issue'::text, 'maintenance_return'::text])), 0::numeric) AS issued_to_maintenance,
            COALESCE(sum(mv.qty_delta) FILTER (WHERE mv.movement_type = ANY (ARRAY['transfer_out'::text, 'transfer_in'::text, 'status_change_out'::text, 'status_change_in'::text])), 0::numeric) AS moved
           FROM mv
          GROUP BY mv.month, mv.unit
        ), dated AS (
         SELECT ms.month,
            ms.unit,
            COALESCE(f.received, 0::numeric) AS received,
            COALESCE(f.produced, 0::numeric) AS produced,
            COALESCE(f.consumed, 0::numeric) AS consumed,
            COALESCE(f.sold, 0::numeric) AS sold,
            COALESCE(f.written_off, 0::numeric) AS written_off,
            COALESCE(f.adjusted, 0::numeric) AS adjusted,
            COALESCE(f.voided, 0::numeric) AS voided,
            COALESCE(f.issued_to_maintenance, 0::numeric) AS issued_to_maintenance,
            COALESCE(f.moved, 0::numeric) AS moved
           FROM months ms
             LEFT JOIN flows f ON f.month = ms.month AND f.unit = ms.unit
        ), step AS (
         SELECT d.month,
            d.unit,
            d.received,
            d.produced,
            d.consumed,
            d.sold,
            d.written_off,
            d.adjusted,
            d.voided,
            d.issued_to_maintenance,
            d.moved,
            d.received + d.produced + d.consumed + d.sold + d.written_off + d.adjusted + d.voided + d.issued_to_maintenance + d.moved AS net
           FROM dated d
        )
 SELECT s.month,
    s.unit,
    COALESCE(sum(s.net) OVER (PARTITION BY s.unit ORDER BY s.month ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0::numeric) AS opening,
    s.received,
    s.produced,
    s.consumed,
    s.sold,
    s.written_off,
    s.adjusted,
    s.voided,
    s.issued_to_maintenance,
    s.moved,
    sum(s.net) OVER (PARTITION BY s.unit ORDER BY s.month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS closing
   FROM step s
UNION ALL
 SELECT NULL::date AS month,
    f.unit,
    NULL::numeric AS opening,
    f.received,
    f.produced,
    f.consumed,
    f.sold,
    f.written_off,
    f.adjusted,
    f.voided,
    f.issued_to_maintenance,
    f.moved,
    NULL::numeric AS closing
   FROM flows f
  WHERE f.month IS NULL;

COMMENT ON VIEW public.stock_rollforward_monthly_all IS
    'MES-5b-1:库存的月度滚动(inventory_movements 按 business_date 的月、按单位):期初 · 收货 · 加工产出 · 加工消耗 · 销售 · 注销 · 调整 · 回滚作废 · 出给保养(MES-7a-2,减去退回)· 搬动 · 期末。没有"对得上"的旗标(期末按构造 = 期初 + 本月之和)。没有业务日期的流水在 month 为空的那一行。基视图,不给人读。';

REVOKE ALL ON public.stock_rollforward_monthly_all FROM authenticated, anon;

-- db/views/stock_rollforward_monthly.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q8,Tim):【库存的月度滚动 —— 带门的外壳】。/operation/balance 的第二块读它。
--   门与月度平衡同一组码(module.processing.view / module.finance.view / module.inventory.view 任一):只有数量,没有一分钱。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql;
--   issued_to_maintenance added by db/migrations/2026-10-16-mes7a2-spare-parts.sql。

CREATE VIEW public.stock_rollforward_monthly WITH (security_invoker = off) AS
 SELECT month,
    unit,
    opening,
    received,
    produced,
    consumed,
    sold,
    written_off,
    adjusted,
    voided,
    issued_to_maintenance,
    moved,
    closing
   FROM stock_rollforward_monthly_all
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.stock_rollforward_monthly IS
    'MES-5b-1:库存的月度滚动,带门(module.processing.view / module.finance.view / module.inventory.view 任一)。算术全在 stock_rollforward_monthly_all。';

GRANT SELECT ON public.stock_rollforward_monthly TO authenticated;
REVOKE ALL ON public.stock_rollforward_monthly FROM anon;

-- db/views/batch_balance_tree_all.sql
-- MES-5b-1(2026-10-08,规格 §4.2;MES-0 Q59;MES-5b Step 0 Q3–Q7 · Q10 · Q11,Tim):【一个批次的质量去了哪里 —— 往下走的树】—— 基视图,不给人读。
--   每一个批次(进料与产出)是一棵树的根(root_kind / root_id)。树上的结点(node_type):
--     batch       根批次自己(depth 0),x = 它收进来的量(收货 + 加工产出的流水之和)
--     fate        一个批次结点的去向,line_key:on_hand · sold · written_off · adjusted · voided(回滚作废)·
--                 maintenance(MES-7a-2:出给保养记录的备件,减去退回的)· consumed(喂进消耗那几炉)·
--                 split(拆去隔离转给子批)· consumed_not_kg(喂进一炉单位不全是 kg 的单 —— 料离开了库存,但那一炉不展开、不合计)·
--                 unexplained(收进来的 − 以上之和;流水与投料腿对得上时恒为 0 —— 两边是两份真源,所以它动得开,是一个检查,不是装饰)
--     run         这个批次喂进的一炉(消耗或拆分),x = 这一条投料腿的量
--     run_output  那一炉的一条产出腿 = 一个子批次结点(x = 产出量,run_id = 产出它的那一炉);子批次自己的去向挂在它下面,并且接着往下走
--     run_loss    那一炉有名字的损耗(每一类更正链的末端),line_key = 类别,loss_basis = measured / derived
--     run_remainder  那一炉的余数(拆分那一炉没有:它没有损耗、没有余数,Q3 · Q11)
--     event       不进合计、另列的事:line_key = pass_through(深度放电 —— 料穿过去,"放电并核实,由 PROC-…")·
--                 reversed(回滚了的单,带回滚时刻与更正它的那一炉)· not_kg(喂进一炉单位不全是 kg 的单)
--   【份额(Q4):按投入质量成比例,逐层乘下去,精确】一炉的产出、损耗与余数按每条投料腿的 quantity_consumed ÷ 那一炉的投入分给它;
--     一个子批次接着带着它分到的那一份走进下一炉。份额写成一对精确的数 share_num / share_den(各层投料量之积 / 各层投入之积),
--     不做除法,所以每一层【精确】加得起来:一个结点的未缩放量 x 等于它孩子们的 x 之和(批次:收进来的 = 各去向;
--     一炉:投入 = 各产出 + 各损耗 + 余数;产出腿 = 子批次收进来的),同一层的孩子共用同一对份额。
--     qty = x × share_num ÷ share_den 只是给屏幕看的(四舍五入只在屏幕上)。
--   【不是 batch_lineage】那张往上走的表在一炉多产出时把整条投料腿重复到每一条产出上(Step 0 §1.8),加不起来,所以不复用。
--   只有【没回滚、单位全是 kg】的消耗与拆分那几炉会被展开(processing_run_flow_all 的 flow = consumption / transfer、not_kg = false)。
--   批次 → 一炉 → 产出的走法只经 processing_inputs / processing_outputs;一个产出批次只由一条产出腿生出来(processing_outputs 的约定),
--   所以子批次收进来的 = 那条产出腿的量。深度上限 20(工序链今天最长 6 段)。
--   读者:batch_balance_tree(带门)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql;
--   the maintenance fate line added by db/migrations/2026-10-16-mes7a2-spare-parts.sql。

CREATE OR REPLACE VIEW public.batch_balance_tree_all WITH (security_invoker = off) AS
 WITH RECURSIVE batches AS (
         SELECT 'inbound'::text AS kind,
            b.id,
            b.code,
            b.material_id,
            b.unit
           FROM inbound_batches b
        UNION ALL
         SELECT 'output'::text AS kind,
            b.id,
            b.code,
            b.material_id,
            b.unit
           FROM output_batches b
        ), legs AS (
         SELECT pi.id AS leg_id,
            pi.run_id,
                CASE
                    WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END AS kind,
            COALESCE(pi.inbound_batch_id, pi.output_batch_id) AS batch_id,
            pi.quantity_consumed AS q,
            f.flow,
            f.not_kg,
            f.input_qty AS run_input
           FROM processing_inputs pi
             JOIN processing_run_flow_all f ON f.run_id = pi.run_id
        ), walk(root_kind, root_id, kind, batch_id, node_key, parent_key, depth, num, den, via_output_qty, via_run_id) AS (
         SELECT b.kind,
            b.id,
            b.kind,
            b.id,
            'r'::text AS node_key,
            NULL::text AS parent_key,
            0 AS depth,
            1::numeric AS num,
            1::numeric AS den,
            NULL::numeric AS via_output_qty,
            NULL::uuid AS via_run_id
           FROM batches b
        UNION ALL
         SELECT w.root_kind,
            w.root_id,
            'output'::text AS kind,
            po.output_batch_id,
            (((w.node_key || '/'::text) || l.leg_id::text) || '/o:'::text) || po.id::text,
            (w.node_key || '/'::text) || l.leg_id::text,
            w.depth + 2,
            w.num * l.q,
            w.den * l.run_input,
            po.quantity_produced,
            l.run_id
           FROM walk w
             JOIN legs l ON l.kind = w.kind AND l.batch_id = w.batch_id
             JOIN processing_outputs po ON po.run_id = l.run_id
          WHERE (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND NOT l.not_kg AND l.run_input > 0::numeric AND w.depth < 40
        ), mvagg AS (
         SELECT
                CASE
                    WHEN m.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END AS kind,
            COALESCE(m.inbound_batch_id, m.output_batch_id) AS batch_id,
            COALESCE(sum(m.qty_delta) FILTER (WHERE m.movement_type = ANY (ARRAY['receipt'::text, 'processing_produce'::text])), 0::numeric) AS received,
            sum(m.qty_delta) AS on_hand,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'sale'::text), 0::numeric) AS sold,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'writeoff'::text), 0::numeric) AS written_off,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'adjustment'::text), 0::numeric) AS adjusted,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = 'reversal_void'::text), 0::numeric) AS voided,
            COALESCE(- sum(m.qty_delta) FILTER (WHERE m.movement_type = ANY (ARRAY['maintenance_issue'::text, 'maintenance_return'::text])), 0::numeric) AS maintenance
           FROM inventory_movements m
          GROUP BY (
                CASE
                    WHEN m.inbound_batch_id IS NOT NULL THEN 'inbound'::text
                    ELSE 'output'::text
                END), (COALESCE(m.inbound_batch_id, m.output_batch_id))
        ), legagg AS (
         SELECT l.kind,
            l.batch_id,
            COALESCE(sum(l.q) FILTER (WHERE l.flow = 'consumption'::text AND NOT l.not_kg), 0::numeric) AS consumed,
            COALESCE(sum(l.q) FILTER (WHERE l.flow = 'transfer'::text AND NOT l.not_kg), 0::numeric) AS split,
            COALESCE(sum(l.q) FILTER (WHERE (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND l.not_kg), 0::numeric) AS consumed_not_kg
           FROM legs l
          GROUP BY l.kind, l.batch_id
        ), nodes AS (
         SELECT w.root_kind,
            w.root_id,
            w.kind,
            w.batch_id,
            w.node_key,
            w.parent_key,
            w.depth,
            w.num,
            w.den,
            w.via_output_qty,
            w.via_run_id,
            COALESCE(ma.received, 0::numeric) AS received,
            COALESCE(ma.on_hand, 0::numeric) AS on_hand,
            COALESCE(ma.sold, 0::numeric) AS sold,
            COALESCE(ma.written_off, 0::numeric) AS written_off,
            COALESCE(ma.adjusted, 0::numeric) AS adjusted,
            COALESCE(ma.voided, 0::numeric) AS voided,
            COALESCE(ma.maintenance, 0::numeric) AS maintenance,
            COALESCE(la.consumed, 0::numeric) AS consumed,
            COALESCE(la.split, 0::numeric) AS split,
            COALESCE(la.consumed_not_kg, 0::numeric) AS consumed_not_kg
           FROM walk w
             LEFT JOIN mvagg ma ON ma.kind = w.kind AND ma.batch_id = w.batch_id
             LEFT JOIN legagg la ON la.kind = w.kind AND la.batch_id = w.batch_id
        ), tree AS (
         SELECT n.root_kind,
            n.root_id,
            n.node_key,
            n.parent_key,
            n.depth,
                CASE
                    WHEN n.depth = 0 THEN 'batch'::text
                    ELSE 'run_output'::text
                END AS node_type,
            NULL::text AS line_key,
            COALESCE(n.via_output_qty, n.received) AS x,
            n.num AS share_num,
            n.den AS share_den,
            n.kind AS batch_kind,
            n.batch_id,
            n.via_run_id AS run_id,
            NULL::text AS loss_category_code,
            NULL::text AS loss_basis
           FROM nodes n
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            (n.node_key || '|'::text) || v.line_key,
            n.node_key,
            n.depth + 1,
            'fate'::text,
            v.line_key,
            v.x,
            n.num,
            n.den,
            n.kind,
            n.batch_id,
            NULL::uuid,
            NULL::text,
            NULL::text
           FROM nodes n
             CROSS JOIN LATERAL ( VALUES ('on_hand'::text,n.on_hand,1), ('sold'::text,n.sold,2), ('written_off'::text,n.written_off,3), ('adjusted'::text,n.adjusted,4), ('voided'::text,n.voided,5), ('maintenance'::text,n.maintenance,6), ('consumed'::text,n.consumed,7), ('split'::text,n.split,8), ('consumed_not_kg'::text,n.consumed_not_kg,9), ('unexplained'::text,n.received - n.on_hand - n.sold - n.written_off - n.adjusted - n.voided - n.maintenance - n.consumed - n.split - n.consumed_not_kg,10)) v(line_key, x, ord)
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            (n.node_key || '/'::text) || l.leg_id::text,
            n.node_key,
            n.depth + 1,
                CASE
                    WHEN (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND NOT l.not_kg THEN 'run'::text
                    ELSE 'event'::text
                END,
                CASE
                    WHEN (l.flow = ANY (ARRAY['consumption'::text, 'transfer'::text])) AND NOT l.not_kg THEN l.flow
                    WHEN l.flow = 'pass_through'::text THEN 'pass_through'::text
                    WHEN l.flow = 'reversed'::text THEN 'reversed'::text
                    ELSE 'not_kg'::text
                END,
            l.q,
            n.num,
            n.den,
            n.kind,
            n.batch_id,
            l.run_id,
            NULL::text,
            NULL::text
           FROM nodes n
             JOIN legs l ON l.kind = n.kind AND l.batch_id = n.batch_id
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            (((n.node_key || '/'::text) || l.leg_id::text) || '/l:'::text) || pl.id::text,
            (n.node_key || '/'::text) || l.leg_id::text,
            n.depth + 2,
            'run_loss'::text,
            pl.loss_category_code,
            pl.quantity,
            n.num * l.q,
            n.den * l.run_input,
            NULL::text,
            NULL::uuid,
            l.run_id,
            pl.loss_category_code,
            pl.basis
           FROM nodes n
             JOIN legs l ON l.kind = n.kind AND l.batch_id = n.batch_id
             JOIN processing_run_losses pl ON pl.run_id = l.run_id
          WHERE l.flow = 'consumption'::text AND NOT l.not_kg AND l.run_input > 0::numeric AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = pl.id))
        UNION ALL
         SELECT n.root_kind,
            n.root_id,
            ((n.node_key || '/'::text) || l.leg_id::text) || '/rem'::text,
            (n.node_key || '/'::text) || l.leg_id::text,
            n.depth + 2,
            'run_remainder'::text,
            f.remainder_state,
            f.remainder_qty,
            n.num * l.q,
            n.den * l.run_input,
            NULL::text,
            NULL::uuid,
            l.run_id,
            NULL::text,
            NULL::text
           FROM nodes n
             JOIN legs l ON l.kind = n.kind AND l.batch_id = n.batch_id
             JOIN processing_run_flow_all f ON f.run_id = l.run_id
          WHERE l.flow = 'consumption'::text AND NOT l.not_kg AND l.run_input > 0::numeric
        )
 SELECT t.root_kind,
    t.root_id,
    rb.code AS root_code,
    t.node_key,
    t.parent_key,
    t.depth,
    t.node_type,
    t.line_key,
    t.x,
    t.share_num,
    t.share_den,
    t.x * t.share_num / t.share_den AS qty,
    t.batch_kind,
    t.batch_id,
    bb.code AS batch_code,
    bb.unit,
    mat.name AS material_name,
    mat.form_code,
    t.run_id,
    rf.run_code,
    rf.operation_type_code,
    rf.process_date,
    rf.flow,
    rf.remainder_state,
    rf.era_mes4a,
    rf.deleted_at AS reversed_at,
    cr.code AS corrects_run_code,
    cb.code AS corrected_by_run_code,
    t.loss_category_code,
    t.loss_basis
   FROM tree t
     JOIN batches rb ON rb.kind = t.root_kind AND rb.id = t.root_id
     LEFT JOIN batches bb ON bb.kind = t.batch_kind AND bb.id = t.batch_id
     LEFT JOIN materials mat ON mat.id = bb.material_id
     LEFT JOIN processing_run_flow_all rf ON rf.run_id = t.run_id
     LEFT JOIN processing_runs cr ON cr.id = rf.corrects_run_id
     LEFT JOIN LATERAL ( SELECT c.code
           FROM processing_runs c
          WHERE c.corrects_run_id = t.run_id
          ORDER BY c.created_at, c.code
         LIMIT 1) cb ON true;

COMMENT ON VIEW public.batch_balance_tree_all IS
    'MES-5b-1:每一个批次往下走的质量树 —— 批次 → 去向(在手 · 卖出 · 注销 · 调整 · 回滚作废 · 出给保养(MES-7a-2)· 消耗 · 拆去隔离 · 未解释)→ 喂进的每一炉 → 它的产出(子批次,接着往下走)、有名字的损耗与余数;放电、回滚与单位不是 kg 的单另列成事件。份额按投入质量成比例,写成精确的一对 share_num / share_den,每一层的未缩放量 x 精确相加;qty = x × num ÷ den 只给屏幕。基视图,不给人读。';

REVOKE ALL ON public.batch_balance_tree_all FROM authenticated, anon;

-- db/views/pending_values.sql
-- MES-1(2026-10-06,MES-0 §5 · Q92 · Q93;MES-1 Step 0 Q1 · Q2,Tim):【还没给的标准值】—— /settings/pending-values 读它。
--   一支一个值(像 operations_now 那样),每一支带着它自己的权限码;读者只看得到他持码的那几支(末尾的 WHERE)。
--   每一行是一件具体还空着的事:哪一个值(value_code,对应 docs/mes-pending-values.md 里那一行)、空在哪一条记录上、去哪儿填。
--   给了值,那一行就自己消失(这张视图不存任何东西)。
-- 【MES-1 播两支】
--   V5  网关的心跳间隔 —— 每一台没停用、间隔为空的网关一行。由集成商在网关调试时给(MES-0 §5.1 V5)。
--   V6  传输异常的工作时间 —— 读班次的起止时刻(shifts.starts_at / ends_at,为空是设计如此:没人说过几点到几点)。
--       每一个启用、而起止为空的班次一行。由 Tim 给(V6)。
-- 【MES-2 加两支】(2026-10-06,MES-2 Step 0 Q12 · Q30,Tim)
--   V8   校准到期前多少天开始提醒 —— 一个值,ingest_settings.calibration_lead_days 为空时一行(去处:/operation/calibration)。
--        由校准机构 / 仪器厂商给,仪器安装时(MES-0 §5.1)。没给:到期前的提醒不上牌,过期照样上牌。
--   V33  每一台【在用的】仪器(秤 · 地磅 · 电表 · 在线仪表,interface_status 不是 reserved,没停用)的量程 —— 量程为空的每台一行
--        (去处:它的设备页)。由仪器厂商给(规格 §8.2)。没给:确认读数时不判量程(WEIGHING_ABOVE_CAPACITY 只在给了时拒)。
-- 【MES-3a 加五支】(2026-10-06,MES-0 §5.1 V2 · V3 · V4 · V29;MES-3a Step 0 Q21 · Q31,Tim)
--   V2   一张执照对一类 NEA 废物的库存上限 —— 今天在效的那张执照 × 每一个启用的类别,没有 licence_storage_limits 行的一行
--        (去处:/purchasing/licences;门 module.suppliers.view)。由 NEA 执照条件给。类别列表是空的时它也是空的(V29 先来)。
--   V29  NEA 废物类别 —— 类别列表里一个启用的都没有时一行;有了之后,每一种没删、种类吃得下状态轴(电池料)而没有类别的物料一行
--        (去处:/settings/dictionaries 或那个物料;门 module.materials.view)。由 NEA 执照给。
--   V3   每一个启用的安全状态的滞留提醒天数 —— dwell_warning_days 为空的每个一行(去处:/settings/dictionaries;门 module.materials.view)。
--        由 Tim 与 WSH 负责人给,或执照的贮存条件。
--   V4   每一个启用的安全状态要不要隔离 —— requires_quarantine 为空的每个一行(同上)。引导只定了两个(鼓包或漏液 = 要,已放电 = 不要)。
--   V34  隔离库位 —— 有任何一个状态要隔离,而一个在用的隔离库位都没有时一行(去处:/inventory/locations;门 module.inventory.view)。
--        没有它,鼓包或漏液的料收不进来(QUARANTINE_LOCATION_REQUIRED)。由 Tim / 仓库在第一批这样的料到之前给。
-- 【MES-3b 加三支】(2026-10-07,MES-0 §5.1 V30 · V31;MES-3b Step 0 Q29 · V35,Tim)
--   V30  每一个启用的危险品 UN 编号的包装标记文字、包装说明、标签尺寸 —— 三样里有任何一样为空的每个编号一行
--        (去处:/settings/dictionaries;门 module.materials.view)。由有 DG 资质的货代在第一次出口之前给。
--   V31  每一种没删的电池料(种类吃得下状态轴)的 HS 编码 —— 为空的每种一行(去处:那个物料;门 module.materials.view)。
--        由报关行在第一次出口之前给。
--   V35  每一种没删的电池料的危险品 UN 编号 —— 没选的每种一行(同上)。由货代与 Tim 在第一次出口或第一次危险品发货之前给。
--        没给:标签与发货单上提示"没给",不拒(Q15)。
-- 【MES-4a 加两支、改一支】(2026-10-07,MES-0 §5.1 V1 · V7;MES-4a Step 0 Q35,Tim)
--   V1   每一道启用的【转化型】工序的物料平衡容差(投入的百分比)—— balance_tolerance_pct 为空的每道一行(去处:那道工序的页面;
--        门 module.processing.view)。由 Tim 与 cto 在每一段调试结束时给。没给:任何不为零的余数都要书面说明才能结平(Q46)。
--        状态改变型(放电)不列 —— 它投入恒等于产出,没有容差可言。
--   V36  每一个启用的、声明了【有范围】(has_range)而上下限都空着的参数 —— 一个字段一行(去处:那道工序的页面)。由设备厂商或
--        工艺工程师在那一段调试时给。没给:那个字段的值照记,不判越界。引导的字段一个都没声明有范围,所以今天是零行。
--   V6   【改了去处,一支答两个值】班次的起止时刻 —— MES-1 的 V6(传输异常的工作时间)与 MES-0 的 V7(加工单的班次时刻)读的是
--        同一组列(shifts.starts_at / ends_at),一支一行就够,两行说的会是同一件事。去处从 /operation/handovers(那一页只读班次,
--        改不了时刻)搬到 /settings/dictionaries(MES-4a 给班次加了一种"时刻"字段)。
-- 【MES-4b 加两支】(2026-10-07,MES-0 §5.1 V10 · V11;MES-4b Step 0 Q29,Tim)
--   V10  每一道启用的、勾了「Electrolyte evaporates in this step」而电解液份额为空的工序 —— 一道一行(去处:那道工序的页面;
--        门 module.processing.view)。由电芯供应商的规格书 / 工艺工程师在第一批极片分离之前给。引导一道都没勾,所以今天是零行。
--        没给:那一段的电解液挥发只能量出来,算不出来(ELECTROLYTE_SHARE_NOT_SET)。
--   V11  每一条启用的交叉污染流的警戒线(contamination_streams.warning_pct)—— 为空的每条一行(去处:/settings/dictionaries;
--        门 module.processing.view)。由 Tim / 第一份黑粉承购合同的规格在第一份承购合同之前给。没给:抽检照记,判不了超没超(NULL)。
-- 【MES-5a-1 加一支】(2026-10-08,MES-0 §5.1 V9;MES-5a Step 0 Q8 · Q32,Tim)
--   V9   放电通过电压(materials.discharge_pass_voltage_v,按物料 —— 模组的终止电压取决于串联节数)。【只在这种物料的一批已经有了
--        放电结果之后才列】,免得页面一下子被每一种装电芯的物料填满(去处:物料编辑页;门 module.materials.view)。由 Bosch 文档 /
--        模组规格书在放电调试时给。没给:结果照记,判定照收,那一格是"判不了"(contradicts_pass_voltage 为 NULL)。
-- 【MES-5a-2 加一支】(2026-10-08,MES-0 §5.1 V25;MES-5a Step 0 Q25 · Q32,Tim)
--   V25  共用池的电怎么摊(electricity_settings.shared_pool_rule)—— 有一台没停用、没挂机器的电表(共用池),而规则为空时一行
--        (去处:/finance/electricity;门 module.finance.view)。由 Tim 在电表接上之后的第一张电费单时给。没给:不计量的电与
--        共用池量到的电在每一次分摊里都留在间接费用 6200。今天线上一台电表都没有,所以是零行。
-- 【MES-6a-1 加两支】(2026-10-09,MES-0 §5.1 V14 · V16;MES-6a Step 0 Q14 · Q22 · Q42,Tim)
--   V16  没有合同天数的样品留多少天(quality_settings.internal_retention_days)—— 为空、而且有一份没处置、留样日 Not yet set 的样品时一行
--        (去处:/quality/samples 的设定;门 module.quality.view)。由 Tim / 质量在第一份要留的样品时给。没给:那样的样品没有留样日,不进提醒。
--        只有一份没处置的 not_set 样品时才列 —— V9 的先例:没人能动手的行不列。
--   V14  仲裁费怎么分(contract_settlement_terms.arbitration_fee_rule,只卖方合同有)—— 每一份【有过一件开着或已结案的争议】(经那件争议的
--        销售单的合同副本认合同)、而它的结算口径里规则为空的合同一行(去处:那份合同;门 module.customers.view —— 条款自己的读码)。
--        由对手方合同在签约时给。没给:争议照立,仲裁费照记,对手方那一份算不出来(NULL)。
--   (V15 没有支:F / Cl 的惩罚阈值是逐份合同的条款,声明了 per_element 却没填时结算按名拒 PENALTY_ELEMENTS_NOT_FILED;V17 归 MES-6b。)
-- 【MES-6b-1 加一支】(2026-10-15,MES-0 §5.1 V17;MES-6a Step 0 Q5;MES-6b Step 0 Q37,Tim)
--   V17  水分与粒径(以及任何一个化验指标)的验收限,逐份卖方合同 —— 每一份没删的卖方合同,【至少挂了一张销售单】、而它的结算口径里
--        quality_limit_basis 为空(或还没有结算口径)的一行(去处:那份合同;门 module.customers.view —— 条款自己的读码)。由 Tim / 那份承购合同给。
--        V9 的先例:还没有一张销售单挂上来的合同不列(没人能对它动手的行不列;从此新生效的卖方合同都必须先声明,见 contract_activation_missing)。
--        没给:那张单上的预留与化验不判质量验收限(judge_quality_limits 只认 per_parameter),不开不合格报告。
-- 【MES-7a-2 加一支】(2026-10-16,MES-0 §5.1 V21;MES-7a Step 0 Q17,Tim)
--   V21  备件的最低库存(materials.safety_stock_qty,按备件物料 —— 已经在驱动 safety_stock_below 那条提醒)。【只在这种备件已经收过至少一批
--        时才列】—— V9 的先例:一种还没收过货的备件,没人能对它动手。给它的人:cto,或设备供应商在验收时给的推荐备件清单。
--        没给:那种备件低于多少都不提醒(safety_stock_below 只认填了的物料)。
-- 【规矩】之后每一刀加它自己的那几支,并在【同一个提交里】往 docs/mes-pending-values.md 加它们的行(Tim,Q2)。
-- 【属主视图】读 devices / shifts 不过 RLS,所以每一支的码在末尾的 WHERE 里问一次。

CREATE OR REPLACE VIEW public.pending_values WITH (security_invoker = off) AS
 SELECT p.value_code,
    p.permission,
    p.item_id,
    p.item_code,
    p.item_label,
    p.href
   FROM ( SELECT 'V5'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = 'gateway'::text AND d.retired_at IS NULL AND d.heartbeat_interval_s IS NULL
        UNION ALL
         SELECT 'V6'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            sh.code AS item_code,
            sh.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM shifts sh
          WHERE sh.is_active AND sh.starts_at IS NULL AND sh.ends_at IS NULL
        UNION ALL
         SELECT 'V8'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            'calibration_lead_days'::text AS item_code,
            'Calibration reminder lead days'::text AS item_label,
            '/operation/calibration'::text AS href
           FROM ingest_settings st
          WHERE st.id AND st.calibration_lead_days IS NULL
        UNION ALL
         SELECT 'V33'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = ANY (ARRAY['scale'::text, 'weighbridge'::text, 'meter'::text, 'inline_instrument'::text])
            AND d.retired_at IS NULL AND d.interface_status <> 'reserved'::text AND d.capacity IS NULL
        UNION ALL
         SELECT 'V2'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            c.code AS item_code,
            (cc.cert_no || ' · '::text) || c.name_en AS item_label,
            '/purchasing/licences'::text AS href
           FROM company_compliance cc
             CROSS JOIN nea_waste_categories c
          WHERE cc.id = storage_licence_in_force((now() AT TIME ZONE 'Asia/Singapore'::text)::date) AND c.is_active
            AND NOT (EXISTS ( SELECT 1
                   FROM licence_storage_limits l
                  WHERE l.licence_id = cc.id AND l.category_code = c.code))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            'nea_waste_categories'::text AS item_code,
            'NEA waste categories'::text AS item_label,
            '/settings/dictionaries'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.nea_waste_category_code IS NULL
            AND (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V3'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.dwell_warning_days IS NULL
        UNION ALL
         SELECT 'V4'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.requires_quarantine IS NULL
        UNION ALL
         SELECT 'V34'::text AS value_code,
            'module.inventory.view'::text AS permission,
            NULL::uuid AS item_id,
            'quarantine_location'::text AS item_code,
            'Quarantine location'::text AS item_label,
            '/inventory/locations'::text AS href
          WHERE (EXISTS ( SELECT 1
                   FROM inbound_safety_states st
                  WHERE st.is_active AND st.requires_quarantine IS TRUE))
            AND NOT (EXISTS ( SELECT 1
                   FROM storage_locations l
                  WHERE l.is_active AND l.is_quarantine))
        UNION ALL
         SELECT 'V30'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            g.code AS item_code,
            g.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM dangerous_goods_codes g
          WHERE g.is_active AND (g.marking_text IS NULL OR g.packing_instruction IS NULL OR g.label_size IS NULL)
        UNION ALL
         SELECT 'V31'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.hs_code IS NULL
        UNION ALL
         SELECT 'V35'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.dg_code IS NULL
        UNION ALL
         SELECT 'V1'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            ot.code AS item_code,
            ot.name_en AS item_label,
            '/operation/operation-types/'::text || ot.code AS href
           FROM operation_types ot
             JOIN operation_kinds k ON k.code = ot.kind_code
          WHERE ot.is_active AND k.produces_outputs AND ot.balance_tolerance_pct IS NULL
        UNION ALL
         SELECT 'V36'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            (f.operation_type_code || '/'::text) || f.field_code AS item_code,
            f.name_en AS item_label,
            '/operation/operation-types/'::text || f.operation_type_code AS href
           FROM operation_type_fields f
             JOIN operation_types ot ON ot.code = f.operation_type_code
          WHERE f.is_active AND ot.is_active AND f.has_range AND f.range_min IS NULL AND f.range_max IS NULL
        UNION ALL
         SELECT 'V10'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            ot.code AS item_code,
            ot.name_en AS item_label,
            '/operation/operation-types/'::text || ot.code AS href
           FROM operation_types ot
          WHERE ot.is_active AND ot.electrolyte_loss_applies AND ot.electrolyte_share_pct IS NULL
        UNION ALL
         SELECT 'V11'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            cs.code AS item_code,
            cs.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM contamination_streams cs
          WHERE cs.is_active AND cs.warning_pct IS NULL
        UNION ALL
         SELECT 'V9'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
          WHERE m.deleted_at IS NULL AND m.discharge_pass_voltage_v IS NULL AND (EXISTS ( SELECT 1
                   FROM discharge_module_results r
                     LEFT JOIN inbound_batches ib ON ib.id = r.inbound_batch_id
                     LEFT JOIN output_batches ob ON ob.id = r.output_batch_id
                  WHERE COALESCE(ib.material_id, ob.material_id) = m.id))
        UNION ALL
         SELECT 'V25'::text AS value_code,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            'shared_pool_rule'::text AS item_code,
            'Shared-pool electricity rule'::text AS item_label,
            '/finance/electricity'::text AS href
           FROM electricity_settings es
          WHERE es.id AND es.shared_pool_rule IS NULL AND (EXISTS ( SELECT 1
                   FROM devices d
                  WHERE d.kind = 'meter'::text AND d.equipment_id IS NULL AND d.retired_at IS NULL))
        UNION ALL
         SELECT 'V37'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            (tf.operation_type_code || '/'::text) || tf.form_code AS item_code,
            (ot.name_en || ' · '::text) || COALESCE(mf.name_en, tf.form_code) AS item_label,
            '/operation/operation-types/'::text || tf.operation_type_code AS href
           FROM operation_type_output_forms tf
             JOIN operation_types ot ON ot.code = tf.operation_type_code
             LEFT JOIN material_forms mf ON mf.code = tf.form_code
          WHERE ot.is_active AND tf.expected_yield_pct IS NULL AND (EXISTS ( SELECT 1
                   FROM processing_run_flow_all f
                  WHERE f.operation_type_code = tf.operation_type_code AND f.flow = 'consumption'::text AND f.era_mes4a))
        UNION ALL
         SELECT 'V16'::text AS value_code,
            'module.quality.view'::text AS permission,
            NULL::uuid AS item_id,
            'internal_retention_days'::text AS item_code,
            'Internal sample retention (days)'::text AS item_label,
            '/quality/samples'::text AS href
           FROM quality_settings qs
          WHERE qs.id AND qs.internal_retention_days IS NULL AND (EXISTS ( SELECT 1
                   FROM samples s
                  WHERE s.retain_until_source = 'not_set'::text AND NOT (EXISTS ( SELECT 1
                           FROM sample_events e
                          WHERE e.sample_id = s.id AND e.event_kind = 'disposed'::text))))
        UNION ALL
         SELECT 'V14'::text AS value_code,
            'module.customers.view'::text AS permission,
            c.id AS item_id,
            c.code AS item_code,
            c.title AS item_label,
            '/contracts/'::text || c.id::text AS href
           FROM contracts c
          WHERE c.deleted_at IS NULL AND (EXISTS ( SELECT 1
                   FROM assay_disputes d
                     JOIN contract_document_terms t ON t.sales_order_id = d.sales_order_id
                  WHERE t.contract_id = c.id AND (d.status = ANY (ARRAY['open'::text, 'resolved'::text])))) AND NOT (EXISTS ( SELECT 1
                   FROM contract_settlement_terms cst
                  WHERE cst.contract_id = c.id AND cst.arbitration_fee_rule IS NOT NULL))
        UNION ALL
         SELECT 'V17'::text AS value_code,
            'module.customers.view'::text AS permission,
            c.id AS item_id,
            c.code AS item_code,
            c.title AS item_label,
            '/contracts/'::text || c.id::text AS href
           FROM contracts c
          WHERE c.deleted_at IS NULL AND c.customer_id IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM contract_document_terms t
                  WHERE t.contract_id = c.id AND t.sales_order_id IS NOT NULL)) AND NOT (EXISTS ( SELECT 1
                   FROM contract_settlement_terms cst
                  WHERE cst.contract_id = c.id AND cst.quality_limit_basis IS NOT NULL))
        UNION ALL
         SELECT 'V21'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            ('/materials/'::text || m.id::text) || '/edit'::text AS href
           FROM materials m
          WHERE m.deleted_at IS NULL AND m.kind_code = 'spare_part'::text AND m.safety_stock_qty IS NULL AND (EXISTS ( SELECT 1
                   FROM inbound_batches b
                  WHERE b.material_id = m.id))) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。MES-5a-1 加 V9(物料的放电通过电压,只在那种物料有了放电结果之后才列);MES-5a-2 加 V25(共用池的电怎么摊,有共用池电表而规则为空时一行)。MES-5b-1 加 V37(每道工序 × 每种产出形态的预期质量得率;只在那道工序有了至少一张 MES-4a 之后的消耗炉次时才列 —— V9 的先例:没人能动手的行不列)。MES-6a-1 加 V16(没有合同天数的样品留多少天;只在有一份没处置、留样日 Not yet set 的样品时才列)与 V14(仲裁费怎么分;每一份有过一件开着或已结案的争议而规则为空的合同一行)。MES-6b-1 加 V17(卖方合同的质量验收限;每一份挂了销售单而口径没声明的卖方合同一行)。MES-7a-2 加 V21(备件的最低库存;每一种收过至少一批而最低库存为空的备件物料一行)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- db/views/spare_part_stock.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12 · Q13 · Q15,Tim):【备件库存 —— 机器页的"出备件"表单从这里挑批】。一行 = 一张 spare_part 物料的进料批
--   (没注销)。它回答表单在按之前必须先知道的三件事,用的是 issue_spare_parts 自己的判据(复述同一列、同一个比较,不是代指):
--     available_qty   可用桶里有多少(stock_status = 'available' 的流水之和 —— 出库只从这个桶取,PART_ISSUE_EXCEEDS_AVAILABLE 比的就是它)
--     priced          这一批有没有采购价(unit_price IS NOT NULL —— SPARE_PART_UNPRICED 判的就是这一列;暂定价也是价)
--     hold_ncr_code   它在不在质量暂扣里(ncr_holds 是暂扣唯一的判据,与 batch_quality_hold 同一句;给的是报告编号,一个标签)
--   ★ 【不带钱】priced 是一个布尔(派生出来的事实),不是价格:一个持 module.inventory.edit 而看不见价格的仓管,要知道的只是"这一批出不出得了",
--     不是"它值多少"(AGENTS.md xmodule 的处置 (a):派生的事实走属主权限,门写回视图体里)。pricing_status 照原样带着(它在列清单授权里)。
--   ★ 为什么不直接读 inbound_batches:那张表的价格列对这些读者是收回的,而 pricing_status 的默认值是 provisional —— 一批从没定过价的货
--     也读作 provisional,用它当"有没有价"会让表单与函数说两句不同的话(GST-3「屏幕上的判据若是数据库判据的代名词」)。
--   门:module.inventory.view(出库的码 module.inventory.edit 蕴含它)。属主权限:读批次、流水与不合格报告都不过 RLS,所以门写在体里。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE VIEW public.spare_part_stock WITH (security_invoker = off) AS
 SELECT b.id AS inbound_batch_id,
    b.code AS batch_code,
    m.id AS material_id,
    m.code AS material_code,
    m.name AS material_name,
    b.unit,
    COALESCE(( SELECT sum(mv.qty_delta) AS sum
           FROM inventory_movements mv
          WHERE mv.inbound_batch_id = b.id AND mv.stock_status = 'available'::text), 0::numeric) AS available_qty,
    b.remaining_qty,
    b.unit_price IS NOT NULL AS priced,
    b.pricing_status,
    ( SELECT n.code
           FROM nonconformance_reports n
          WHERE n.inbound_batch_id = b.id AND ncr_holds(n.status, n.disposition, b.deleted_at, b.remaining_qty)
          ORDER BY n.opened_at, n.code
         LIMIT 1) AS hold_ncr_code,
    b.arrival_date
   FROM inbound_batches b
     JOIN materials m ON m.id = b.material_id
  WHERE b.deleted_at IS NULL AND m.kind_code = 'spare_part'::text AND has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.spare_part_stock IS
    'MES-7a-2:备件(spare_part)的进料批与它们出不出得了 —— 可用数量、有没有采购价(布尔,不是价格)、在不在质量暂扣里(报告编号)。判据与 issue_spare_parts 逐字同源。门 module.inventory.view,属主权限。不带钱。';

GRANT SELECT ON public.spare_part_stock TO authenticated;
REVOKE ALL ON public.spare_part_stock FROM anon;

-- ── 11 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.maintenance_part_issues
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.maintenance_part_issues
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 12 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.issue_spare_parts(uuid, date, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.issue_spare_parts(uuid, date, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.return_spare_parts(uuid, numeric, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.return_spare_parts(uuid, numeric, date, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reprice_split(numeric, numeric, numeric, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reprice_split(numeric, numeric, numeric, numeric, numeric) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_maintenance_movement() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_maintenance_movement() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_maintenance_movement() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_part_issue_write() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_part_issue_write() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_part_issue_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_maintenance_capitalise_parts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_maintenance_capitalise_parts() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_maintenance_capitalise_parts() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.inbound_batch_maintenance_net_qty(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inbound_batch_maintenance_net_qty(uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.inbound_batch_maintenance_net_qty(uuid) FROM authenticated;

-- ── 13 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes7a2_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE mes7a2_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行没动;admin 持目录里每一个码(79)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes7a2_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes7a2_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A2_PROOF|a grant changed: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7A2_PROOF|admin does not hold every one of the 79 codes';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES7A2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes7a2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes7a2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES7A2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes7a2_pending_before b EXCEPT SELECT a.k, a.id FROM mes7a2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes7a2_pending_after a EXCEPT SELECT b.k, b.id FROM mes7a2_pending_before b)) THEN
        RAISE EXCEPTION 'MES7A2_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) IS DISTINCT FROM (SELECT inbound_batches FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inventory_movements t ) IS DISTINCT FROM (SELECT inventory_movements FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM price_history t ) IS DISTINCT FROM (SELECT price_history FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t ) IS DISTINCT FROM (SELECT materials FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM material_kinds t ) IS DISTINCT FROM (SELECT material_kinds FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_maintenance t ) IS DISTINCT FROM (SELECT equipment_maintenance FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_downtime t ) IS DISTINCT FROM (SELECT equipment_downtime FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_service_intervals t ) IS DISTINCT FROM (SELECT equipment_service_intervals FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_assets t ) IS DISTINCT FROM (SELECT fixed_assets FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM nonconformance_reports t ) IS DISTINCT FROM (SELECT nonconformance_reports FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) IS DISTINCT FROM (SELECT certificates_of_destruction FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_analysis t ) IS DISTINCT FROM (SELECT certificates_of_analysis FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM coa_issues t ) IS DISTINCT FROM (SELECT coa_issues FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM warehouse_requests t ) IS DISTINCT FROM (SELECT warehouse_requests FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_price_requests t ) IS DISTINCT FROM (SELECT receipt_price_requests FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) IS DISTINCT FROM (SELECT expenses FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t ) IS DISTINCT FROM (SELECT processing_runs FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_inputs t ) IS DISTINCT FROM (SELECT processing_inputs FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM stocktakes t ) IS DISTINCT FROM (SELECT stocktakes FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM stocktake_lines t ) IS DISTINCT FROM (SELECT stocktake_lines FROM mes7a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t WHERE code <> '6800') IS DISTINCT FROM (SELECT accounts FROM mes7a2_rows_before) THEN
        RAISE EXCEPTION 'MES7A2_PROOF|a pre-existing batch, movement, journal, price, material, kind, maintenance, downtime, interval, asset, NCR, certificate, byte record, request, expense, payment, approval, run, stocktake or account changed';
    END IF;

    -- ④ 科目恰好多一行 6800(系统、启用、费用);流水 14 种类型;出库表与两种新流水都是 0 行;旧的 reprice_split 不在了
    IF (SELECT count(*) FROM accounts WHERE code = '6800' AND is_system AND is_active AND account_type = 'expense'
          AND name_en = 'Repairs & Maintenance') <> 1 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|6800 Repairs & Maintenance must exist once, as an active system expense account';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'inventory_movements_movement_type_check')),
                                            '''[a-z_]+''::text', 'g')) <> 14 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|the movement type check should name 14 types';
    END IF;
    IF EXISTS (SELECT 1 FROM maintenance_part_issues)
       OR EXISTS (SELECT 1 FROM inventory_movements WHERE movement_type IN ('maintenance_issue', 'maintenance_return'))
       OR EXISTS (SELECT 1 FROM journal_entries WHERE source_type = 'maintenance_part') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|no issue, movement or entry of the new kinds may exist';
    END IF;
    IF to_regprocedure('public.reprice_split(numeric, numeric, numeric, numeric)') IS NOT NULL
       OR to_regprocedure('public.reprice_split(numeric, numeric, numeric, numeric, numeric)') IS NULL THEN
        RAISE EXCEPTION 'MES7A2_PROOF|reprice_split must exist only with five arguments';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_inventory_movements_maintenance_ctx' AND tgrelid = 'public.inventory_movements'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_inventory_movements_quality_hold' AND tgrelid = 'public.inventory_movements'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_inventory_movements_through_function' AND tgrelid = 'public.inventory_movements'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_maintenance_part_issues_direct' AND tgrelid = 'public.maintenance_part_issues'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_maintenance_part_issues_immutable' AND tgrelid = 'public.maintenance_part_issues'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zzz_change_log' AND tgrelid = 'public.maintenance_part_issues'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_equipment_maintenance_parts_capitalise' AND tgrelid = 'public.equipment_maintenance'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_equipment_maintenance_direct' AND tgrelid = 'public.equipment_maintenance'::regclass) THEN
        RAISE EXCEPTION 'MES7A2_PROOF|a guard trigger is missing';
    END IF;

    -- ⑤ 本事务往变更记录只写了科目那一行(按 txid 认 —— 同一时刻同事们在线上的写不算在本刀头上);require_calibrated_since 仍空
    SELECT string_agg(c.table_name || ':' || c.op, ', ' ORDER BY c.seq) INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes7a2_log_before), 0) AND c.txid = txid_current();
    IF v_bad IS DISTINCT FROM 'accounts:INSERT' THEN
        RAISE EXCEPTION 'MES7A2_PROOF|change_log rows of this transaction: % (expected only the 6800 account)', v_bad;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A2_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:提醒 66 支、待定值 24 支(多了 V21);299 张表;出库表的审计成员在册(设备是家)
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 24 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|operations_now should have 66 arms and pending_values 24';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 299 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|expected 299 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'equipment' AND m.table_name = 'maintenance_part_issues' AND m.home) THEN
        RAISE EXCEPTION 'MES7A2_PROOF|part issues must live under the equipment trail';
    END IF;

    -- ⑦ 函数面:三支员工调得到;四支内层与触发器调不到;anon 能执行的【恰好】两支;新表与新视图 anon 读不到
    IF NOT has_function_privilege('authenticated', 'public.issue_spare_parts(uuid, date, jsonb)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.issue_spare_parts(uuid, date, jsonb)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|public.issue_spare_parts(uuid, date, jsonb) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.return_spare_parts(uuid, numeric, date, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.return_spare_parts(uuid, numeric, date, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|public.return_spare_parts(uuid, numeric, date, text) must be callable by staff and not by anon';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.reprice_split(numeric, numeric, numeric, numeric, numeric)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.reprice_split(numeric, numeric, numeric, numeric, numeric)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|public.reprice_split(numeric, numeric, numeric, numeric, numeric) must be callable by staff and not by anon';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_maintenance_movement()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_maintenance_movement()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|public.guard_maintenance_movement() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_part_issue_write()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_part_issue_write()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|public.guard_part_issue_write() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_maintenance_capitalise_parts()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_maintenance_capitalise_parts()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|public.guard_maintenance_capitalise_parts() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.inbound_batch_maintenance_net_qty(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.inbound_batch_maintenance_net_qty(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|public.inbound_batch_maintenance_net_qty(uuid) must be a function nobody outside can call';
    END IF;
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES7A2_PROOF|anon executes: %', v_bad;
    END IF;
    IF has_table_privilege('anon', 'public.maintenance_part_issues'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.spare_part_stock'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|anon reads a new relation';
    END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑨ 变更记录:覆盖零缺口(出库表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes7a2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES7A2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes7a2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes7a2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
