-- db/migrations/2026-10-07-mes4b-fields-and-products.sql
-- MES-4b —— 电芯结构、新的产出产品与编号、损耗的依据与电解液、交叉污染抽检(MES 组的第六刀,v1.4.42;发布那一行在 docs/handbacks/MES-4b.md 的抬头)。
-- 由 db/scripts/build_mes4b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-07:MES-4b Step 0 的 Q1–Q34 全部照建议裁定,Q9 与 Q17 两条按 Tim 改过的;docs/surveys/MES-4b/STEP0-HANDBACK.md)
--   ① 电芯结构(Q3–Q8):cell_constructions(wound · stacked · unknown;is_determined)· 两张批次表 + cell_construction_code
--      (进料批是遮蔽表:列 + 列级授权 + _masked 视图,一支迁移)· guard_batch_cell_construction(只对装电芯的形态成立;喂过一张已提交的
--      加工单之后锁住)· set_batch_cell_construction · 两支收货函数末尾一个可缺省的参数 · operation_types.requires_cell_construction
--      (引导 electrode_separation · electrode_line)· commit_processing_run 在这两道工序上要求投料带确定的结构,并让装电芯的产出继承它。
--   ② 产品与编号(Q9–Q15):六种新形态(正极粉 · 负极粉 · 铜箔 · 铝箔 · 收集的粉尘 · 线束/BMS/汇流排;可售性按 Tim 改过的 Q9)·
--      material_forms.output_document_key · document_types +12 行与 12 条序列 · generate_output_code 按形态取前缀(新前缀五位、有洞、不按年重置)·
--      11 支有洞的取号函数不再截断(超过 9,999 照实长出去;低于 10,000 的号逐字不变)· 工序 ↔ 形态的信息行 +7。
--   ③ 损耗的依据与电解液(Q16–Q20):processing_run_losses.basis(measured | derived,必填)+ derived_share_pct · loss_categories.may_be_derived ·
--      operation_types.electrolyte_share_pct(V10)与 electrolyte_loss_applies(「Electrolyte evaporates in this step」,引导全部为假)·
--      record_derived_electrolyte_loss · rederive_electrolyte_loss · record_run_loss / correct_run_loss 明写 measured · 平衡视图多一列算出来的那一截。
--   ④ 交叉污染(Q21–Q26):contamination_streams(正极 · 负极;警戒线 V11 引导为空)· contamination_checks(只追加)· 记 / 更正两支 + 一支内层 ·
--      contamination_shift_status(_all) · contamination_check_rows · 提醒臂 contamination_check_missing。
--   ⑤ 读者与登记(Q28–Q30):pending_values +2 支(V10 · V11)· operations_now +1 支 · 审计记录(加工单与产出批 + 抽检;两本字典)·
--      变更记录绑三张新表 · 例外表 +2 行 · check_mirrors 的 RUNTIME CONFIG 清单 +4 张。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据、批次或加工单;
--   不建任何物料;不给任何批次记结构;不勾任何工序的电解液挥发、不给份额、不给警戒线;require_calibrated_since 保持空;
--   不碰 MES-3a / 3b / 4a 的任何设定。只播:三种结构、两条流、六种形态(可售性按 Q9)、它们的映射、7 行工序 ↔ 形态、12 行单据种类与序列、
--   两道工序的 requires_cell_construction、电解液挥发那一类的 may_be_derived 与说明、例外表的两行;既有的损耗行记成 measured(线上 0 行)。
--
-- 【破窗】见 docs/surveys/MES-4b/STEP0-HANDBACK.md §10:部署之前,极片分离与自动极片线的一炉提交不了(线上没有一批记着结构,而旧应用
--   没有地方记它 —— 旧页面上是一句原样的码);新产出批在映射了的形态上铸新前缀;旧的搜索页把 12 个新单据种类的标签印成键。其余照旧。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   既有的每一张加工单、每一批进料与产出(除了多出来的那一列,而它全是空的)、每一条损耗行逐字未变;变更记录只在引导的那几张表上动了、
--   恰好 43 行;新的数据表是空的;没有一道工序勾了电解液挥发、给了份额;没有一条流给了警戒线;开关是空的;anon 能执行的【恰好】两支;
--   内层谁都调不到;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口;每一张被记录的表的绑定键都是它的主键;
--   提醒臂 57 支;待补的值 17 支;单据种类 55 行(有洞 23);每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES4B_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.cell_constructions') IS NOT NULL OR to_regclass('public.contamination_streams') IS NOT NULL
       OR to_regclass('public.contamination_checks') IS NOT NULL THEN
        RAISE EXCEPTION 'MES4B_PRE|MES-4b tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                 AND ((table_name IN ('inbound_batches', 'output_batches') AND column_name = 'cell_construction_code')
                      OR (table_name = 'processing_run_losses' AND column_name IN ('basis', 'derived_share_pct'))
                      OR (table_name = 'loss_categories' AND column_name = 'may_be_derived')
                      OR (table_name = 'material_forms' AND column_name = 'output_document_key')
                      OR (table_name = 'operation_types' AND column_name IN ('electrolyte_share_pct', 'electrolyte_loss_applies', 'requires_cell_construction')))) THEN
        RAISE EXCEPTION 'MES4B_PRE|MES-4b columns already exist';
    END IF;
    IF (SELECT count(*) FROM material_forms) <> 13 OR (SELECT count(*) FROM document_types) <> 43
       OR (SELECT count(*) FROM loss_categories) <> 7 OR (SELECT count(*) FROM operation_types) <> 7 THEN
        RAISE EXCEPTION 'MES4B_PRE|dictionaries are not the MES-4a shape (forms 13, document types 43, loss categories 7, operations 7)';
    END IF;
    IF EXISTS (SELECT 1 FROM document_types WHERE prefix IN ('CPW', 'APW', 'CUF', 'ALF', 'SEP', 'DST', 'CEL', 'CSG', 'STR', 'HBB', 'CTS', 'ANS')) THEN
        RAISE EXCEPTION 'MES4B_PRE|a new output prefix is already registered';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES4B_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES4B_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 56 THEN
        RAISE EXCEPTION 'MES4B_PRE|operations_now should have 56 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 15 THEN
        RAISE EXCEPTION 'MES4B_PRE|pending_values should have 15 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES4B_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes4b_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes4b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes4b_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes4b_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes4b_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_runs t) AS runs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_inputs t) AS inputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_outputs t) AS outputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_run_losses t) AS losses,
       (SELECT count(*) FROM processing_run_losses) AS loss_n,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inbound_batches t) AS inbound,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM output_batches t) AS output,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM materials t) AS materials;

-- ── 1 · 先建的函数:两张批次表上要挂的触发器(镜像原样)──────────────────────────

-- db/functions/guard_batch_cell_construction.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q45;MES-4b Step 0 Q4 · Q7,Tim):【电芯结构这一列的两条规矩】—— 挂在 inbound_batches 与 output_batches 上
--   (BEFORE INSERT OR UPDATE OF cell_construction_code, material_id),所以收货、提交加工单的继承、批次页、直连 SQL 四条路一起盖住。
--   ① 只对仍装着电芯的形态成立:物料的形态 implies_dismantling 为假 → CELL_CONSTRUCTION_NOT_APPLICABLE|<批号>|<形态>。
--      【没有形态的物料不拦】不知道它是什么形态,不等于知道它不装电芯 —— 与 guard_inbound_condition_applicable 同一条
--      ("不知道"绝不能被当成"不适用"来拒人)。空着永远合法。
--   ② 喂过一张已提交、没回滚的加工单之后不再改(改成别的值或改回空):CELL_CONSTRUCTION_LOCKED|<那张加工单>。
--      更正的路是回滚那一张(回滚之后它不再是 committed,锁就开了)。
--   不是 SECURITY DEFINER:它是触发器;写入只经两支收货函数、commit_processing_run 与 set_batch_cell_construction(都是 DEFINER),
--   或持表的写码的直连 UPDATE —— 那一条也照样过这两条规矩。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.guard_batch_cell_construction()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_form       text;
    v_dismantles boolean;
    v_run        text;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.cell_construction_code IS NOT DISTINCT FROM OLD.cell_construction_code
       AND NEW.material_id IS NOT DISTINCT FROM OLD.material_id THEN
        RETURN NEW;
    END IF;

    IF NEW.cell_construction_code IS NOT NULL THEN
        SELECT f.code, f.implies_dismantling INTO v_form, v_dismantles
          FROM public.materials m LEFT JOIN public.material_forms f ON f.code = m.form_code
         WHERE m.id = NEW.material_id;
        IF v_form IS NOT NULL AND NOT v_dismantles THEN
            RAISE EXCEPTION 'CELL_CONSTRUCTION_NOT_APPLICABLE|%|%', NEW.code, v_form
              USING HINT = '电芯结构(卷绕 / 叠片)只对仍装着电芯的形态成立(整包、模组、散电芯、已开壳电芯、混合料)。这一批的物料形态里没有电芯。';
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.cell_construction_code IS DISTINCT FROM OLD.cell_construction_code THEN
        SELECT r.code INTO v_run
          FROM public.processing_inputs pi JOIN public.processing_runs r ON r.id = pi.run_id
         WHERE r.status = 'committed' AND r.deleted_at IS NULL
           AND ((TG_TABLE_NAME = 'inbound_batches' AND pi.inbound_batch_id = NEW.id)
                OR (TG_TABLE_NAME = 'output_batches' AND pi.output_batch_id = NEW.id))
         ORDER BY r.process_date, r.code
         LIMIT 1;
        IF v_run IS NOT NULL THEN
            RAISE EXCEPTION 'CELL_CONSTRUCTION_LOCKED|%', v_run
              USING HINT = '这一批已经喂过一张已提交的加工单 —— 那一炉是按这个结构跑的。要改,先回滚那一张。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 2 · 两本新字典(镜像原样,带它们的引导、策略与触发器)──────────────────────────

-- db/tables/cell_constructions.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q45;MES-4b Step 0 Q3–Q8,Tim):【电芯是卷绕的还是叠片的】—— 一个【批次】的事实,不是物料的。
--   规格 §3.4:同一类物料的批次可能因来源不同而结构不同;卷绕与叠片走两台不同的极片分离设备。
--   引导三行:wound(卷绕)· stacked(叠片)· unknown(看过了,分不出来)。is_determined 是【规则列】:
--   极片分离 / 自动极片线的投料批必须带一个 is_determined 为真的值(INPUT_CELL_CONSTRUCTION_REQUIRED)——
--   unknown 与"没记"一样过不去,但它们【不是】同一件事:unknown 是一次看过之后的结论,空是没人看过。
--   RUNTIME CONFIG(/settings/dictionaries,module.processing.edit —— 路由是加工的事实)。
--   读:加工、进料、产出三个查看码任一(批次页与加工单表单都要画它的名字)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.cell_constructions (
    code          text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name_en       text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh       text NOT NULL CHECK (btrim(name_zh) <> ''),
    -- 【规则列】这个值是不是一个【确定的】结构 —— 只有为真的值过得了极片分离的投料闸。
    is_determined boolean NOT NULL,
    is_active     boolean NOT NULL DEFAULT true,
    sort_order    integer NOT NULL DEFAULT 0,
    notes         text
);

COMMENT ON TABLE public.cell_constructions IS
    'MES-4b:电芯结构(规格 §3.4 —— 卷绕 / 叠片走两台不同的分离设备)。批次的属性(inbound_batches / output_batches.cell_construction_code),只对仍装着电芯的形态成立(material_forms.implies_dismantling)。引导 wound · stacked · unknown;is_determined 为真的才过得了极片分离的投料闸。RUNTIME CONFIG。';

COMMENT ON COLUMN public.cell_constructions.is_determined IS
    'MES-4b(Q3 · Q5):这个值是不是一个【确定的】结构。operation_types.requires_cell_construction 为真的工序(引导:electrode_separation · electrode_line),每一批投料都必须带一个 is_determined 为真的值;空或 unknown → INPUT_CELL_CONSTRUCTION_REQUIRED|<批号>。';

INSERT INTO public.cell_constructions (code, name_en, name_zh, is_determined, sort_order, notes) VALUES
    ('wound', 'Wound', '卷绕', true, 10, 'Spec §3.4: jelly-roll cells; separated on the wound-cell machine.'),
    ('stacked', 'Stacked', '叠片', true, 20, 'Spec §3.4: stacked-electrode cells; separated on the stacked-cell machine.'),
    ('unknown', 'Unknown (inspected, cannot tell)', '未知(看过,分不出)', false, 30, 'MES-0 Q45: somebody looked and could not tell. Not the same as not recorded — but neither passes the electrode-separation input check.');

ALTER TABLE public.cell_constructions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cell_constructions select by permission" ON public.cell_constructions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]));
CREATE POLICY "cell_constructions write by permission" ON public.cell_constructions
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.cell_constructions TO authenticated;
REVOKE ALL ON public.cell_constructions FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.cell_constructions
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');

-- db/tables/contamination_streams.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q52 · V11;MES-4b Step 0 Q21,Tim):【交叉污染抽检的两条流】—— 正极片里混了多少负极、负极片里混了多少正极。
--   一行 = 一条流:它抽检哪一种极片(sheet_form_code)、在里面找哪一种外来物(foreign_form_code)、超过多少要标出来(warning_pct,V11)。
--   引导两行:cathode(抽正极片,找负极片)· anode(抽负极片,找正极片)。warning_pct 引导为空 = Not yet set(V11:Tim / 第一份
--   黑粉承购合同的规格给)—— 为空时一次抽检的结果是"判不了",不是"在范围内"。
--   【它为什么是一张表,不是两个写死的码】提醒臂(contamination_check_missing)要从【数据】里认出哪些产出是这条流的极片 ——
--   一张表让"多一条流"是一行,而不是改一支视图。V11 也要有一行可以住。
--   RUNTIME CONFIG(/settings/dictionaries,module.processing.edit)。读:加工或产出查看码(极片批的买方关心的质量事实)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contamination_streams (
    code              text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name_en           text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh           text NOT NULL CHECK (btrim(name_zh) <> ''),
    -- 抽检的是哪一种极片 —— 一次抽检必须挂在这一炉的一条这种形态的产出腿上
    sheet_form_code   text NOT NULL REFERENCES public.material_forms (code),
    -- 在里面找的外来物是哪一种形态
    foreign_form_code text NOT NULL REFERENCES public.material_forms (code),
    -- V11:超过多少(外来物质量占样品质量的百分比)要标出来。为空 = Not yet set。只标出来,从不拒。
    warning_pct       numeric CHECK (warning_pct IS NULL OR (warning_pct >= 0 AND warning_pct <= 100)),
    is_active         boolean NOT NULL DEFAULT true,
    sort_order        integer NOT NULL DEFAULT 0,
    notes             text,
    CONSTRAINT contamination_streams_forms_differ CHECK (sheet_form_code <> foreign_form_code)
);

COMMENT ON TABLE public.contamination_streams IS
    'MES-4b:交叉污染抽检的流(规格 §3.4 —— 至少每班一次)。一行 = 抽哪一种极片、找哪一种外来物、警戒线(V11)。引导 cathode · anode。RUNTIME CONFIG。';

COMMENT ON COLUMN public.contamination_streams.warning_pct IS
    'MES-4b(V11):污染率警戒线,外来物质量占样品质量的百分比。为空 = Not yet set(Tim / 第一份黑粉承购合同的规格给)—— 为空时一次抽检判不了(above_warning 为 NULL),不是"在范围内"。超过它只标出来,从不拒。每一次抽检记下当时的值(contamination_checks.warning_pct_at),改它不会重判旧的抽检。';

INSERT INTO public.contamination_streams (code, name_en, name_zh, sheet_form_code, foreign_form_code, sort_order, notes) VALUES
    ('cathode', 'Cathode stream', '正极流', 'cathode_sheet', 'anode_sheet', 10, 'Spec §3.4: anode material found in the cathode sheets.'),
    ('anode', 'Anode stream', '负极流', 'anode_sheet', 'cathode_sheet', 20, 'Spec §3.4: cathode material found in the anode sheets.');

ALTER TABLE public.contamination_streams ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contamination_streams select by permission" ON public.contamination_streams
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.output.view'::text]));
CREATE POLICY "contamination_streams write by permission" ON public.contamination_streams
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.contamination_streams TO authenticated;
REVOKE ALL ON public.contamination_streams FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contamination_streams
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');

-- ── 3 · 产出批的编号(Q12–Q15):12 条序列 + 12 行单据种类(OUT 那一行留着)──────────────────────────
CREATE SEQUENCE public.output_cpw_code_seq;
CREATE SEQUENCE public.output_apw_code_seq;
CREATE SEQUENCE public.output_cuf_code_seq;
CREATE SEQUENCE public.output_alf_code_seq;
CREATE SEQUENCE public.output_sep_code_seq;
CREATE SEQUENCE public.output_dst_code_seq;
CREATE SEQUENCE public.output_cel_code_seq;
CREATE SEQUENCE public.output_csg_code_seq;
CREATE SEQUENCE public.output_str_code_seq;
CREATE SEQUENCE public.output_hbb_code_seq;
CREATE SEQUENCE public.output_cts_code_seq;
CREATE SEQUENCE public.output_ans_code_seq;
INSERT INTO public.document_types
    (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission)
VALUES
    ('output_cathode_powder', 'CPW', 'output_batches', 'gapped', 'output_cpw_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_anode_powder', 'APW', 'output_batches', 'gapped', 'output_apw_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_copper_foil', 'CUF', 'output_batches', 'gapped', 'output_cuf_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_aluminium_foil', 'ALF', 'output_batches', 'gapped', 'output_alf_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_separator', 'SEP', 'output_batches', 'gapped', 'output_sep_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_collected_dust', 'DST', 'output_batches', 'gapped', 'output_dst_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_cell', 'CEL', 'output_batches', 'gapped', 'output_cel_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_casing', 'CSG', 'output_batches', 'gapped', 'output_csg_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_structural_parts', 'STR', 'output_batches', 'gapped', 'output_str_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_harness_bms_busbar', 'HBB', 'output_batches', 'gapped', 'output_hbb_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_cathode_sheet', 'CTS', 'output_batches', 'gapped', 'output_cts_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]),
    ('output_anode_sheet', 'ANS', 'output_batches', 'gapped', 'output_ans_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[], ARRAY['module.output.view']::text[]);

-- ── 4 · 物料形态(Q9 · Q12):产出号的映射列;六种新形态(可售性按 Tim 改过的 Q9);映射 ──────────────────────────
ALTER TABLE public.material_forms ADD COLUMN output_document_key text REFERENCES public.document_types (key);
COMMENT ON COLUMN public.material_forms.output_document_key IS
'MES-4b(MES-0 Q54;MES-4b Step 0 Q12 · Q13):这个形态的产出批取哪一种号 —— document_types 的 key(那一行说前缀与序列)。
为空 = 通用的 output_batch(OUT)。generate_output_code 读它;前缀字面量只许活在 document_types 里(fixture 100 第 6 臂)。
新前缀的序列从第一个号起就是五位(CPW-2026-00001),有洞、不按年重置。改映射是迁移级动作。';
INSERT INTO public.material_forms (code, name_en, name_zh, implies_dismantling, may_be_sold, sort_order, notes) VALUES
    ('cathode_powder',     'Cathode powder',          '正极粉',           false, true,  14, '【MES-4b · 规格 §3.5】正极片粉化的产品(正负极分开剥)。可售(Q9)。'),
    ('anode_powder',       'Anode powder',            '负极粉',           false, true,  15, '【MES-4b · 规格 §3.5】负极片粉化的产品。**可售 —— Tim 改了 Step 0 的推荐(Q9):它是一种成品。**'),
    ('copper_foil',        'Copper foil',             '铜箔',             false, true,  16, '【MES-4b · 规格 §3.5】负极剥粉之后留下的集流体。可售(Q9)。'),
    ('aluminium_foil',     'Aluminium foil',          '铝箔',             false, true,  17, '【MES-4b · 规格 §3.5】正极剥粉之后留下的集流体。可售(Q9)。'),
    ('collected_dust',     'Collected dust',          '收集的粉尘',       false, false, 18, '【MES-4b · 规格 §3.5】除尘收集、称过的粉尘 —— 一条产出腿,进物料平衡。**它不是损耗 dust_spill**:收回来称过的是产出,跑掉的才是损耗。**暂不可售(Q9)。**'),
    ('harness_bms_busbar', 'Harness / BMS / busbar',  '线束 / BMS / 汇流排', false, true, 19, '【MES-4b · 规格 §3.2】人工拆解时单独称的线束、管理板与汇流排。可售(Q9)。');
UPDATE public.material_forms SET output_document_key = 'output_cathode_powder' WHERE code = 'cathode_powder';
UPDATE public.material_forms SET output_document_key = 'output_anode_powder' WHERE code = 'anode_powder';
UPDATE public.material_forms SET output_document_key = 'output_copper_foil' WHERE code = 'copper_foil';
UPDATE public.material_forms SET output_document_key = 'output_aluminium_foil' WHERE code = 'aluminium_foil';
UPDATE public.material_forms SET output_document_key = 'output_separator' WHERE code = 'separator';
UPDATE public.material_forms SET output_document_key = 'output_collected_dust' WHERE code = 'collected_dust';
UPDATE public.material_forms SET output_document_key = 'output_cell' WHERE code IN ('loose_cells', 'de_cased_cell');
UPDATE public.material_forms SET output_document_key = 'output_casing' WHERE code = 'casing';
UPDATE public.material_forms SET output_document_key = 'output_structural_parts' WHERE code = 'structural_parts';
UPDATE public.material_forms SET output_document_key = 'output_harness_bms_busbar' WHERE code = 'harness_bms_busbar';
UPDATE public.material_forms SET output_document_key = 'output_cathode_sheet' WHERE code = 'cathode_sheet';
UPDATE public.material_forms SET output_document_key = 'output_anode_sheet' WHERE code = 'anode_sheet';

-- ── 5 · 工序 ↔ 形态的信息行(Q10:不在提交时校验,选择器也不过滤)──────────────────────────
INSERT INTO public.operation_type_output_forms (operation_type_code, form_code, notes) VALUES
    ('electrode_powder_line', 'cathode_powder', '【MES-4b · 规格 §3.5】正负极分开剥。'),
    ('electrode_powder_line', 'anode_powder', '【MES-4b · 规格 §3.5】'),
    ('electrode_powder_line', 'copper_foil', '【MES-4b · 规格 §3.5】'),
    ('electrode_powder_line', 'aluminium_foil', '【MES-4b · 规格 §3.5】'),
    ('electrode_powder_line', 'collected_dust', '【MES-4b · 规格 §3.5】除尘收集、称过的粉尘 —— 产出,不是损耗。'),
    ('battery_powder_line', 'collected_dust', '【MES-4b · 规格 §3.5】同上。'),
    ('manual_disassembly', 'harness_bms_busbar', '【MES-4b · 规格 §3.2】线束、管理板与汇流排单独称。');

-- ── 6 · 损耗类别(Q16 · Q17 · Q18):may_be_derived;电解液挥发那一类可以算出来,说明写上 Tim 的工厂事实 ──────────────────────────
ALTER TABLE public.loss_categories ADD COLUMN may_be_derived boolean NOT NULL DEFAULT false;
UPDATE public.loss_categories SET may_be_derived = true,
       notes = '【MES-4b,Tim 的工厂事实(Step 0 Q17)】挥发出来的电解液由抽风气流带走,经风管送到后端的环保(尾气处理)设备处理 —— 设备里一台压缩机让气体单向流动;压缩机是设备,不是工序,不挂在加工单上。它仍然是这一段的一笔【有名字的损耗】。哪几段挥发由工序上的「Electrolyte evaporates in this step」勾选说(Tim 自己勾);那一段给了电解液份额(V10)之后,这一笔可以按份额算出来(basis = derived),也可以量出来。
【R4,Tim 的工艺路线】电解液目前计划挥发掉 —— 它既不是产品也不是废物收据,是【消失掉的质量】。**它没有并进 moisture,理由是 metal_fate**:moisture 那一行断言"金属留着",而电解液带不带走金属【今天没有人知道】(线上产出批化验 0 条)。并进去等于免费送出一个未经证实的断言,而那个断言会直接流进回收率 —— 那正是 W2/F4 记过账的那一种污染。'
 WHERE code = 'electrolyte_evaporation';
COMMENT ON COLUMN public.loss_categories.may_be_derived IS
'MES-4b(MES-0 Q51;MES-4b Step 0 Q18):这一类损耗能不能是【算出来的】(processing_run_losses.basis = derived)。引导只有 electrolyte_evaporation 为真 ——
record_derived_electrolyte_loss 只认它。算出来的永远是 份额 × 投入,从来不是余数。';

-- ── 7 · 工序(Q5 · Q17):电解液份额(V10)· 「Electrolyte evaporates in this step」(引导全部为假)· 要求投料带结构 ──────────────────────────
ALTER TABLE public.operation_types
    ADD COLUMN electrolyte_share_pct numeric CHECK (electrolyte_share_pct IS NULL OR (electrolyte_share_pct >= 0 AND electrolyte_share_pct <= 100)),
    ADD COLUMN electrolyte_loss_applies boolean NOT NULL DEFAULT false,
    ADD COLUMN requires_cell_construction boolean NOT NULL DEFAULT false;
UPDATE public.operation_types SET requires_cell_construction = true WHERE code IN ('electrode_separation', 'electrode_line');
COMMENT ON COLUMN public.operation_types.electrolyte_share_pct IS
    'MES-4b(V10;MES-0 Q51;MES-4b Step 0 Q17):这一段一炉电解液占投入质量的百分比(0–100)。为空 = Not yet set(电芯供应商的规格书 / 工艺工程师给,第一批极片分离之前)。只在 electrolyte_loss_applies 为真的工序上有意义:算出来的电解液损耗 = 份额 × total_input / 100(record_derived_electrolyte_loss),份额抄进那一行。';
COMMENT ON COLUMN public.operation_types.electrolyte_loss_applies IS
    'MES-4b(Tim 的工厂事实,Step 0 Q17):「Electrolyte evaporates in this step」—— 这一段有电解液挥发。它标的是损耗【发生】在哪一段,不是压缩机装在哪(压缩机是设备,不是工序)。引导全部为假,Tim 在工序页上自己勾。为真才可以记一笔算出来的电解液损耗;V10 只列为真而份额为空的工序。';
COMMENT ON COLUMN public.operation_types.requires_cell_construction IS
    'MES-4b(规格 §3.4;MES-0 Q45;MES-4b Step 0 Q5):这一段的每一批投料都必须带一个确定的电芯结构(cell_constructions.is_determined)—— 空或 unknown → INPUT_CELL_CONSTRUCTION_REQUIRED|<批号>。引导:electrode_separation 与 electrode_line。结构 ↔ 机器只记录、不校验(Q8)。';

-- ── 8 · 进料批的电芯结构(Q4):一列 + 列级授权 + 遮蔽视图(三件事一起)+ 守卫触发器 ──────────────────────────
ALTER TABLE public.inbound_batches ADD COLUMN cell_construction_code text REFERENCES public.cell_constructions (code);
GRANT SELECT (id, code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, stage, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, purchase_order_id, purchase_order_line_id, pricing_formula_id, pricing_status, deleted_by, delete_reason, declared_qty, chemistry_certainty_code,
    -- CMPL-1:进口尽调那四列。【不敏感】,所以进列清单授权 —— 给遮蔽表加列
    -- 必须同时做三件事(ADD COLUMN + 本授权 + _masked 视图),少一件就"写得进、读不出"。
    imported, import_permit_ref, import_permit_verified_by, import_permit_verified_at,
    -- PROC-1B-iii:实际到的货能不能深度放电。同上,三件事一件都不能少 ——
    -- 而这一列漏掉的后果特别隐蔽:"读不到"会显示成"未记录",
    -- 与本刀刻意设计的"缺一侧就是 NULL"长得一模一样。
    deep_discharge_actual_code,
    -- RECV-SOURCE-1:来源理由四列。不敏感(审计轨迹第一环,不是钱),
    -- 进列清单授权 —— 三件事(列 + 本授权 + _masked 视图)同一支迁移。
    source_reason_code, source_reason_note,
    source_reason_recorded_by, source_reason_recorded_at,
    -- MES-4b:电芯结构。不敏感(工艺路由要用的事实),进列清单授权 —— 三件事(列 + 本授权 + _masked 视图)同一支迁移。
    cell_construction_code)
    ON public.inbound_batches TO authenticated;
CREATE TRIGGER trg_inbound_batches_cell_construction
    BEFORE INSERT OR UPDATE OF cell_construction_code, material_id ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_cell_construction();
COMMENT ON COLUMN public.inbound_batches.cell_construction_code IS
'MES-4b(规格 §3.4;MES-4b Step 0 Q4–Q7):这一批电芯是卷绕还是叠片(cell_constructions)。为空 = 没记(收货时可选)。只对仍装着电芯的形态成立
(material_forms.implies_dismantling;没有形态的物料不拦 —— 不知道不等于不适用),别的形态 CELL_CONSTRUCTION_NOT_APPLICABLE。
在批次页上补或改(set_batch_cell_construction:进料编辑码或加工提交码),直到这一批喂过一张已提交、没回滚的加工单(CELL_CONSTRUCTION_LOCKED|<加工单>)。
极片分离 / 自动极片线的投料必须带一个确定的值(INPUT_CELL_CONSTRUCTION_REQUIRED)。不遮蔽:列级授权 + _masked 视图原样透出。';

-- db/views/inbound_batches_masked.sql
-- ★ ROLE-1 Batch 4a(2026-09-25,Tim 的 Q9 线):本视图是【采购那一侧】的价格 —— 遮蔽码从 data.view_prices
--   换成 data.view_purchase_prices(今天持 view_prices 的每一个角色一并拿到它,仓库只拿它)。
-- 【PROC-2:多一列 chemistry_certainty_code】遮蔽表加一列是三件事,这是第三件 ——
-- gate 的 colgrant 判据是「一张表一旦有 _masked 伴生,每一列都必须在那张视图里,
-- 授权与否都一样」,所以这一列即便是非敏感的、已经列级授权了,也必须在这里出现。
-- 遮蔽伴生视图:inbound_batches 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:unit_price → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.inbound.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- RECV-SOURCE-1(2026-09-01)追加四列(source_reason_code / _note /
-- _recorded_by / _recorded_at),不遮蔽 —— 同 CMPL-1 那四列的处置。
--
-- GRN-1a:declared_qty 追加在末尾。它【不遮蔽】—— 它是一个量,不是价;而它必须
-- 出现在本视图里,因为 colgrant 的规矩是"一张表有了 _masked,它的每一列都得在里面"
-- (WO-1a)。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

-- CMPL-1(2026-08-30)追加四列(imported / import_permit_ref /
-- import_permit_verified_by / import_permit_verified_at)。
-- 【它们是【不敏感】的,所以走列清单 GRANT + 出现在本视图里,不做遮蔽】——
-- 真正敏感的仍然只有 unit_price,按 data.view_prices 透出。
-- 【给遮蔽表加列是三件事一起做】ADD COLUMN + 列清单 GRANT + 本视图;
-- 少任何一件,应用都会"写得进、读不出"(FIN-6 的原样重演),而 gate 的
-- colgrant 判词会在 live 与 rebuild 两侧同时点名。
CREATE OR REPLACE VIEW public.inbound_batches_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status,
    deleted_by,
    delete_reason,
    declared_qty,
    chemistry_certainty_code,
    imported,
    import_permit_ref,
    import_permit_verified_by,
    import_permit_verified_at,
    -- PROC-1B-iii fu1:遮蔽表加一列 = 三件事(列 + 列级授权 + 本视图)。
    -- 【不遮蔽,原样透出】它是工艺路由要用的事实,不是钱、不是个人信息。
    deep_discharge_actual_code,
    -- RECV-SOURCE-1:来源理由四列。【不遮蔽,原样透出】—— 审计轨迹的第一环,
    -- 不是钱、不是个人信息;colgrant 的规矩是"有 _masked 伴生,每一列都得在里面"。
    source_reason_code,
    source_reason_note,
    source_reason_recorded_by,
    source_reason_recorded_at,
    -- MES-4b:电芯结构。【不遮蔽,原样透出】—— 工艺路由要用的事实;三件事的第三件。
    cell_construction_code
   FROM inbound_batches
  WHERE has_permission('module.inbound.view'::text);;

GRANT SELECT ON public.inbound_batches_masked TO authenticated;

-- ── 9 · 产出批的电芯结构(Q4 · Q6;不是遮蔽表)+ 守卫触发器 ──────────────────────────
ALTER TABLE public.output_batches ADD COLUMN cell_construction_code text REFERENCES public.cell_constructions (code);
CREATE TRIGGER trg_output_batches_cell_construction
    BEFORE INSERT OR UPDATE OF cell_construction_code, material_id ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_cell_construction();
COMMENT ON COLUMN public.output_batches.cell_construction_code IS
'MES-4b(规格 §3.4;MES-4b Step 0 Q4–Q7):这一批电芯是卷绕还是叠片(cell_constructions)。为空 = 没记。只对仍装着电芯的形态成立
(material_forms.implies_dismantling;没有形态的物料不拦 —— 不知道不等于不适用),别的形态 CELL_CONSTRUCTION_NOT_APPLICABLE。
提交加工单时从投料继承(每一批投料都是同一个值;否则留空,到批次页上补)。喂过一张已提交、没回滚的加工单之后不再改
(CELL_CONSTRUCTION_LOCKED|<加工单>)—— 改它就是回滚那一张。极片分离的投料必须带一个确定的值(INPUT_CELL_CONSTRUCTION_REQUIRED)。';

-- ── 10 · 损耗的依据(Q16):必填、没有默认值 —— 既有行(线上 0 行)记成 measured,随后拿掉默认值,每一扇门明写自己是哪一种 ──────────────
ALTER TABLE public.processing_run_losses
    ADD COLUMN basis text NOT NULL DEFAULT 'measured' CHECK (basis IN ('measured', 'derived')),
    ADD COLUMN derived_share_pct numeric;
ALTER TABLE public.processing_run_losses ALTER COLUMN basis DROP DEFAULT;
ALTER TABLE public.processing_run_losses
    ADD CONSTRAINT processing_run_losses_basis_shape CHECK ((basis = 'derived') = (derived_share_pct IS NOT NULL));
COMMENT ON COLUMN public.processing_run_losses.basis IS
'MES-4b(规格 §3.4 "marked measured or derived";MES-0 Q51;MES-4b Step 0 Q16):measured = 量出来的(敲进来的公斤数);derived = 算出来的
(电解液份额 V10 × 这一炉的投入 / 100,derived_share_pct 记下用的份额)。**derived 永远不是余数**(投入 − 产出 − 别的损耗)——
那会让每一炉按构造结平(AGENTS.md 的兜底桶)。只有 loss_categories.may_be_derived 为真的类别(electrolyte_evaporation)能是 derived。
更正可以重新算(rederive_electrolyte_loss)或改成量出来的(correct_run_loss),都要理由;结平的算术不分 basis(平衡面板单独报出算出来的那一截)。';

-- ── 11 · 交叉污染抽检(镜像原样)──────────────────────────────────────────────────────

-- db/tables/contamination_checks.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q21–Q26,Tim):【一次交叉污染抽检】—— 只追加,逐次记。
--   一行挂在一炉(run_id)与一条流(stream_code)上;班次从那一炉读(processing_runs.process_date · shift_code),【不另存】——
--   所以表头更正改了班次(correct_run_header),抽检跟着走。
--   两种:
--     sampled      抽了:样品质量与其中外来物的质量(克;外来物 ≤ 样品)、抽样时刻、方法(自由文本);抽的那一批是这一炉的一条
--                  【这条流的极片】产出腿(output_batch_id)。污染率 = 外来物 / 样品 × 100(生成列)。
--     not_sampled  这一班没抽 —— 必须写理由。它关掉这一班这条流的提醒,而"没抽"这件事留在记录里(Q23)。
--   警戒线(V11)在记录那一刻抄进 warning_pct_at;above_warning = 污染率 > 那条线(线为空时 NULL = 判不了,不是"在范围内")。
--   超过只标出来,从不拒(Q21)。与物料平衡无关:污染不改质量(规格 §3.4),结平不等它、也不读它。
--   【更正】新行指回原行(corrects_id 唯一)+ 必填理由;读链的末端。种类可以在更正时改(抽了 ↔ 没抽)。
--   只经 record_contamination_check / correct_contamination_check(action.processing_aftercare)写;UPDATE / DELETE / TRUNCATE 语句级拒。
--   读:加工或产出查看码(极片批买方关心的质量事实)—— 人读的那一份经 contamination_check_rows(带门的属主视图:
--   只持产出码的人读不到 processing_runs,一张 invoker 视图会安静地丢行 —— AGENTS.md 的 xmodule)。
--   不建取样仪器(Q26):样品天平不在设备登记里,校准闸仍只管称重。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contamination_checks (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id             uuid NOT NULL REFERENCES public.processing_runs (id),
    stream_code        text NOT NULL REFERENCES public.contamination_streams (code),
    kind               text NOT NULL CHECK (kind IN ('sampled', 'not_sampled')),
    output_batch_id    uuid REFERENCES public.output_batches (id),
    sample_mass_g      numeric,
    foreign_mass_g     numeric,
    rate_pct           numeric GENERATED ALWAYS AS (
                           CASE WHEN kind = 'sampled' AND sample_mass_g > 0 THEN foreign_mass_g * 100 / sample_mass_g END) STORED,
    warning_pct_at     numeric,
    above_warning      boolean GENERATED ALWAYS AS (
                           CASE WHEN kind = 'sampled' AND sample_mass_g > 0 AND warning_pct_at IS NOT NULL
                                THEN foreign_mass_g * 100 / sample_mass_g > warning_pct_at END) STORED,
    sampled_at         timestamptz,
    method             text,
    not_sampled_reason text,
    recorded_at        timestamptz NOT NULL DEFAULT now(),
    recorded_by        uuid DEFAULT auth.uid(),
    corrects_id        bigint UNIQUE REFERENCES public.contamination_checks (id),
    correction_reason  text,
    CONSTRAINT contamination_checks_sampled_shape CHECK (
        kind <> 'sampled' OR (output_batch_id IS NOT NULL AND sample_mass_g > 0 AND foreign_mass_g >= 0
                              AND foreign_mass_g <= sample_mass_g AND sampled_at IS NOT NULL AND not_sampled_reason IS NULL)),
    CONSTRAINT contamination_checks_not_sampled_shape CHECK (
        kind <> 'not_sampled' OR (output_batch_id IS NULL AND sample_mass_g IS NULL AND foreign_mass_g IS NULL
                                  AND sampled_at IS NULL AND not_sampled_reason IS NOT NULL AND btrim(not_sampled_reason) <> '')),
    CONSTRAINT contamination_checks_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> ''))
);

COMMENT ON TABLE public.contamination_checks IS
    'MES-4b:交叉污染抽检,逐次、只追加(规格 §3.4)。sampled = 样品与外来物质量(克)、抽样时刻、方法,挂在这一炉这条流的一条极片产出腿上;not_sampled = 这一班没抽,带理由。污染率与"超过警戒线"是生成列;警戒线记录时抄下。班次读自那一炉。更正 = 新行(corrects_id + 理由);读链的末端。';

COMMENT ON COLUMN public.contamination_checks.above_warning IS
    'MES-4b(Q21 · V11):污染率是否高于记录那一刻的警戒线(warning_pct_at)。线为空 → NULL = 判不了,不是"在范围内"。只标出来,从不拒。';

CREATE INDEX contamination_checks_run ON public.contamination_checks (run_id);
CREATE INDEX contamination_checks_output_batch ON public.contamination_checks (output_batch_id);

CREATE TRIGGER trg_contamination_checks_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.contamination_checks
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.contamination_checks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contamination_checks select by permission" ON public.contamination_checks
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.output.view'::text]));
GRANT SELECT ON public.contamination_checks TO authenticated;
REVOKE ALL ON public.contamination_checks FROM anon;

-- 带 code 列的表要么是单据、要么在例外表里带一句理由(fixture 102 · check-document-registry)。镜像原样。
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    ('cell_constructions',            '电芯结构目录(MES-4b):code 是卷绕 / 叠片 / 未知,批次引用它'),
    ('contamination_streams',         '交叉污染抽检的流目录(MES-4b):code 是流代号(正极 / 负极),抽检记录引用它');

-- ── 12 · 取号函数(CODE-WIDTH-4,Q13 · Q14):不再截断;产出那一支按形态取前缀(表镜像里的那几支,原样)──────────────

CREATE OR REPLACE FUNCTION public.generate_inbound_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
        NEW.code := document_type_prefix('inbound_batch') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('inbound_code_seq')::TEXT AS n) s);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_material_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
        NEW.code := document_type_prefix('material') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('material_code_seq')::TEXT AS n) s);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_supplier_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
  IF NEW.code IS NULL OR NEW.code = '' THEN
    -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
    NEW.code := document_type_prefix('supplier') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('supplier_code_seq')::TEXT AS n) s);
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_customer_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
        NEW.code := document_type_prefix('customer') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('customer_code_seq')::TEXT AS n) s);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.assign_contract_code()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
        NEW.code := document_type_prefix('contract') || '-' || to_char(COALESCE(NEW.effective_from, CURRENT_DATE), 'YYYY')
                    || '-' || (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('public.contract_code_seq')::TEXT AS n) s);
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.generate_stocktake_code()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
        NEW.code := document_type_prefix('stocktake') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('stocktake_code_seq')::TEXT AS n) s);
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.generate_processing_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
        NEW.code := document_type_prefix('processing_run') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('processing_code_seq')::TEXT AS n) s);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_task_code()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
        NEW.code := document_type_prefix('task') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('task_code_seq')::TEXT AS n) s);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_output_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE
    v_key    text;
    v_prefix text;
    v_seq    text;
    v_n      text;
    v_width  integer;
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        SELECT f.output_document_key INTO v_key
          FROM materials m JOIN material_forms f ON f.code = m.form_code
         WHERE m.id = NEW.material_id;
        v_key := COALESCE(v_key, 'output_batch');
        v_prefix := document_type_prefix(v_key);
        SELECT d.sequence_name INTO v_seq FROM document_types d WHERE d.key = v_key;
        v_width := CASE WHEN v_key = 'output_batch' THEN 4 ELSE 5 END;
        v_n := nextval(('public.' || v_seq)::regclass)::text;
        NEW.code := v_prefix || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' || LPAD(v_n, GREATEST(v_width, length(v_n)), '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 13 · 新函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/set_batch_cell_construction.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-4b Step 0 Q4 · Q7,Tim):【在批次页上补或改电芯结构】—— 进料批与产出批共用这一扇门。
--   p_kind:'inbound' | 'output'(BATCH_KIND_UNKNOWN)。码:批次那个模块的编辑码,或 action.processing_commit(站台的操作员 ——
--   他在投料之前最先看见是卷绕还是叠片);都没有 → PERMISSION_DENIED|<模块编辑码>。
--   p_code 为空 = 清掉(回到"没记")。不认识或已停用的结构 → CELL_CONSTRUCTION_UNKNOWN|<码>。批次不在或已注销 → BATCH_NOT_FOUND。
--   适用性与锁由表上的 guard_batch_cell_construction 判(同一份判据,直连 SQL 也过它)—— 这里一个字都不重复。
--   与原值相同 → 什么都不写(不落一条空的变更记录)。返回批号。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.set_batch_cell_construction(p_kind text, p_batch_id uuid, p_code text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code    text := NULLIF(btrim(COALESCE(p_code, '')), '');
    v_batch   text;
    v_current text;
BEGIN
    IF p_kind = 'inbound' THEN
        IF NOT has_any_permission(ARRAY['module.inbound.edit', 'action.processing_commit']) THEN
            RAISE EXCEPTION 'PERMISSION_DENIED|module.inbound.edit';
        END IF;
    ELSIF p_kind = 'output' THEN
        IF NOT has_any_permission(ARRAY['module.output.edit', 'action.processing_commit']) THEN
            RAISE EXCEPTION 'PERMISSION_DENIED|module.output.edit';
        END IF;
    ELSE
        RAISE EXCEPTION 'BATCH_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    IF v_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM cell_constructions c WHERE c.code = v_code AND c.is_active) THEN
        RAISE EXCEPTION 'CELL_CONSTRUCTION_UNKNOWN|%', v_code;
    END IF;

    IF p_kind = 'inbound' THEN
        SELECT b.code, b.cell_construction_code INTO v_batch, v_current
          FROM inbound_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL FOR UPDATE;
    ELSE
        SELECT b.code, b.cell_construction_code INTO v_batch, v_current
          FROM output_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL FOR UPDATE;
    END IF;
    IF v_batch IS NULL THEN
        RAISE EXCEPTION 'BATCH_NOT_FOUND|%', p_batch_id;
    END IF;
    IF v_current IS NOT DISTINCT FROM v_code THEN
        RETURN v_batch;
    END IF;

    IF p_kind = 'inbound' THEN
        UPDATE inbound_batches SET cell_construction_code = v_code, updated_by = auth.uid(), updated_at = now() WHERE id = p_batch_id;
    ELSE
        UPDATE output_batches SET cell_construction_code = v_code, updated_by = auth.uid(), updated_at = now() WHERE id = p_batch_id;
    END IF;
    RETURN v_batch;
END;
$function$;

-- db/functions/record_derived_electrolyte_loss.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q51 · V10;MES-4b Step 0 Q16–Q20,Tim):【给一炉记一笔算出来的电解液挥发】。
--   量 = 这道工序的电解液份额(operation_types.electrolyte_share_pct,V10)× 这一炉的投入(total_input)/ 100,保留三位小数;
--   份额抄进那一行(derived_share_pct),basis = 'derived'。**从来不是余数**(投入 − 产出 − 别的损耗)—— 那会让每一炉按构造结平。
--   只在提交之后、由人在加工单页上按下去才记(从不在提交时自动算)。码:action.processing_aftercare(PERMISSION_DENIED|…)。
--   拒(按这个先后):加工单没提交 / 已回滚(RUN_NOT_COMMITTED)· 状态改变型的一炉(ELECTROLYTE_LOSS_STATE_CHANGING|<工序>)·
--   工序没勾「Electrolyte evaporates in this step」(ELECTROLYTE_LOSS_NOT_APPLICABLE|<工序>)· 份额没给(ELECTROLYTE_SHARE_NOT_SET|<工序>)·
--   这一类不许算(RUN_LOSS_NOT_DERIVABLE|<类别>)· 这一类已经有一条(RUN_LOSS_ALREADY_RECORDED|<类别> —— 要改就更正它)·
--   算出来是 0(RUN_LOSS_QTY_INVALID|0)· 有名字的损耗之和超过 投入 − 产出(表上的约束触发器 LOSS_CATEGORIES_EXCEED_LOSS_QTY)。
--   一炉结过平之后再记一笔 → 水位线被越过,那一炉回到"没结平"。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.record_derived_electrolyte_loss(p_run_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cat     constant text := 'electrolyte_evaporation';
    v_run     processing_runs%ROWTYPE;
    v_ot      operation_types%ROWTYPE;
    v_produce boolean;
    v_qty     numeric;
    v_id      bigint;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    SELECT * INTO v_ot FROM operation_types WHERE code = v_run.operation_type_code;
    SELECT k.produces_outputs INTO v_produce FROM operation_kinds k WHERE k.code = v_ot.kind_code;
    IF v_produce IS NOT TRUE THEN
        RAISE EXCEPTION 'ELECTROLYTE_LOSS_STATE_CHANGING|%', COALESCE(v_run.operation_type_code, '?')
          USING HINT = '状态改变型的一炉(放电)投入恒等于产出、损耗恒为 0 —— 没有电解液挥发可记。';
    END IF;
    IF NOT v_ot.electrolyte_loss_applies THEN
        RAISE EXCEPTION 'ELECTROLYTE_LOSS_NOT_APPLICABLE|%', v_ot.code
          USING HINT = '这道工序没有勾「Electrolyte evaporates in this step」。哪几段有电解液挥发,在工序页上勾。';
    END IF;
    IF v_ot.electrolyte_share_pct IS NULL THEN
        RAISE EXCEPTION 'ELECTROLYTE_SHARE_NOT_SET|%', v_ot.code
          USING HINT = '这道工序的电解液份额(V10)还没给 —— 没有份额就算不出来。可以改成量出来的,或先在工序页上给份额。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM loss_categories c WHERE c.code = v_cat AND c.is_active AND c.may_be_derived) THEN
        RAISE EXCEPTION 'RUN_LOSS_NOT_DERIVABLE|%', v_cat;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_losses l WHERE l.run_id = p_run_id AND l.loss_category_code = v_cat) THEN
        RAISE EXCEPTION 'RUN_LOSS_ALREADY_RECORDED|%', v_cat;
    END IF;
    v_qty := round(v_ot.electrolyte_share_pct * v_run.total_input / 100, 3);
    IF v_qty IS NULL OR v_qty <= 0 THEN
        RAISE EXCEPTION 'RUN_LOSS_QTY_INVALID|%', COALESCE(v_qty, 0);
    END IF;
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, notes, basis, derived_share_pct)
    VALUES (p_run_id, v_cat, v_qty, NULLIF(btrim(COALESCE(p_notes, '')), ''), 'derived', v_ot.electrolyte_share_pct)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/rederive_electrolyte_loss.sql
-- MES-4b(2026-10-07,MES-0 Q51;MES-4b Step 0 Q19,Tim):【按现在的份额重新算一笔电解液挥发】—— 更正的一种(另一种是改成量出来的:correct_run_loss)。
--   不改原行:落一条新行指回它(corrects_id)+ 必填理由,basis = 'derived',份额照【此刻】的工序设置抄下。
--   码:action.processing_aftercare。拒:找不到(RUN_LOSS_NOT_FOUND)· 加工单没提交 / 已回滚(RUN_NOT_COMMITTED)· 已被更正过(RUN_LOSS_SUPERSEDED)·
--   理由空(RUN_LOSS_CORRECTION_REASON_REQUIRED)· 这一类不许算(RUN_LOSS_NOT_DERIVABLE)· 状态改变型 / 没勾 / 份额没给(同 record_derived_electrolyte_loss)·
--   算出来与当前那一条完全相同(RUN_LOSS_CORRECTION_SAME_VALUE —— 量与依据都一样,没有东西可更正)· 算出来是 0(RUN_LOSS_QTY_INVALID)。
--   之和仍不许超过 投入 − 产出;结过平的一炉回到"没结平"。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.rederive_electrolyte_loss(p_loss_id bigint, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig    processing_run_losses%ROWTYPE;
    v_run     processing_runs%ROWTYPE;
    v_ot      operation_types%ROWTYPE;
    v_produce boolean;
    v_qty     numeric;
    v_id      bigint;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_orig FROM processing_run_losses WHERE id = p_loss_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_LOSS_NOT_FOUND|%', p_loss_id;
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = v_orig.run_id FOR UPDATE;
    IF v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.code;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_losses x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'RUN_LOSS_SUPERSEDED|%', v_orig.id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'RUN_LOSS_CORRECTION_REASON_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM loss_categories c WHERE c.code = v_orig.loss_category_code AND c.may_be_derived) THEN
        RAISE EXCEPTION 'RUN_LOSS_NOT_DERIVABLE|%', v_orig.loss_category_code;
    END IF;
    SELECT * INTO v_ot FROM operation_types WHERE code = v_run.operation_type_code;
    SELECT k.produces_outputs INTO v_produce FROM operation_kinds k WHERE k.code = v_ot.kind_code;
    IF v_produce IS NOT TRUE THEN
        RAISE EXCEPTION 'ELECTROLYTE_LOSS_STATE_CHANGING|%', COALESCE(v_run.operation_type_code, '?');
    END IF;
    IF NOT v_ot.electrolyte_loss_applies THEN
        RAISE EXCEPTION 'ELECTROLYTE_LOSS_NOT_APPLICABLE|%', v_ot.code;
    END IF;
    IF v_ot.electrolyte_share_pct IS NULL THEN
        RAISE EXCEPTION 'ELECTROLYTE_SHARE_NOT_SET|%', v_ot.code;
    END IF;
    v_qty := round(v_ot.electrolyte_share_pct * v_run.total_input / 100, 3);
    IF v_qty IS NULL OR v_qty <= 0 THEN
        RAISE EXCEPTION 'RUN_LOSS_QTY_INVALID|%', COALESCE(v_qty, 0);
    END IF;
    IF v_orig.basis = 'derived' AND v_qty = v_orig.quantity AND v_ot.electrolyte_share_pct = v_orig.derived_share_pct THEN
        RAISE EXCEPTION 'RUN_LOSS_CORRECTION_SAME_VALUE';
    END IF;
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, notes, corrects_id, correction_reason, basis, derived_share_pct)
    VALUES (v_orig.run_id, v_orig.loss_category_code, v_qty, v_orig.notes, v_orig.id, btrim(p_reason), 'derived', v_ot.electrolyte_share_pct)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/contamination_check_internal.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q21–Q23,Tim):【一次交叉污染抽检的判据与落库】—— 记与更正共用这一份,判据只写一遍。
--   内层:不是 DEFINER,authenticated 调不到(只经 record_contamination_check / correct_contamination_check)。
--   拒(按这个先后):
--     RUN_NOT_COMMITTED|<单>                          加工单没提交或已回滚
--     CONTAMINATION_RUN_PREDATES_RECORD|<单>          MES-4a 之前记的单 —— 没有班次,抽检挂不上一个班
--     CONTAMINATION_STREAM_UNKNOWN|<流>               不认识或已停用的流
--     CONTAMINATION_RUN_HAS_NO_SHEET|<单>|<流>        这一炉没有产出这条流的极片(没抽、没抽都无从谈起)
--     CONTAMINATION_KIND_UNKNOWN|<种类>
--     CONTAMINATION_FIELDS_MIXED|<种类>               抽了却带着"没抽的理由",或没抽却带着质量 / 批次 / 时刻
--     抽了:CONTAMINATION_BATCH_NOT_SHEET_OF_RUN|<批>(抽的那一批不是这一炉这条流的一条极片产出腿)·
--           CONTAMINATION_MASS_INVALID|<样品>|<外来物>(样品 > 0、0 ≤ 外来物 ≤ 样品,克)· CONTAMINATION_SAMPLED_AT_REQUIRED
--     没抽:CONTAMINATION_REASON_REQUIRED
--   警戒线(V11)此刻的值抄进 warning_pct_at;超过只标出来(生成列 above_warning),从不拒。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.contamination_check_internal(p_run_id uuid, p_stream_code text, p_kind text, p_output_batch_id uuid, p_sample_mass_g numeric, p_foreign_mass_g numeric, p_sampled_at timestamp with time zone, p_method text, p_not_sampled_reason text, p_corrects_id bigint, p_correction_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run    processing_runs%ROWTYPE;
    v_stream contamination_streams%ROWTYPE;
    v_batch  text;
    v_id     bigint;
BEGIN
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    IF v_run.started_at IS NULL OR v_run.shift_code IS NULL THEN
        RAISE EXCEPTION 'CONTAMINATION_RUN_PREDATES_RECORD|%', v_run.code
          USING HINT = '这一张是 MES-4a 之前记的,没有班次 —— 抽检按班挂,挂不上。';
    END IF;
    SELECT * INTO v_stream FROM contamination_streams WHERE code = p_stream_code AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTAMINATION_STREAM_UNKNOWN|%', COALESCE(p_stream_code, '?');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id
                     JOIN materials m ON m.id = ob.material_id
                    WHERE po.run_id = p_run_id AND m.form_code = v_stream.sheet_form_code) THEN
        RAISE EXCEPTION 'CONTAMINATION_RUN_HAS_NO_SHEET|%|%', v_run.code, v_stream.code;
    END IF;

    IF p_kind = 'sampled' THEN
        IF NULLIF(btrim(COALESCE(p_not_sampled_reason, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'CONTAMINATION_FIELDS_MIXED|sampled';
        END IF;
        SELECT ob.code INTO v_batch
          FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id
          JOIN materials m ON m.id = ob.material_id
         WHERE po.run_id = p_run_id AND po.output_batch_id = p_output_batch_id AND m.form_code = v_stream.sheet_form_code;
        IF v_batch IS NULL THEN
            RAISE EXCEPTION 'CONTAMINATION_BATCH_NOT_SHEET_OF_RUN|%',
                COALESCE((SELECT ob.code FROM output_batches ob WHERE ob.id = p_output_batch_id), COALESCE(p_output_batch_id::text, '?'));
        END IF;
        IF p_sample_mass_g IS NULL OR p_sample_mass_g <= 0 OR p_foreign_mass_g IS NULL OR p_foreign_mass_g < 0
           OR p_foreign_mass_g > p_sample_mass_g THEN
            RAISE EXCEPTION 'CONTAMINATION_MASS_INVALID|%|%', COALESCE(p_sample_mass_g::text, '?'), COALESCE(p_foreign_mass_g::text, '?');
        END IF;
        IF p_sampled_at IS NULL THEN
            RAISE EXCEPTION 'CONTAMINATION_SAMPLED_AT_REQUIRED';
        END IF;
    ELSIF p_kind = 'not_sampled' THEN
        IF p_output_batch_id IS NOT NULL OR p_sample_mass_g IS NOT NULL OR p_foreign_mass_g IS NOT NULL OR p_sampled_at IS NOT NULL THEN
            RAISE EXCEPTION 'CONTAMINATION_FIELDS_MIXED|not_sampled';
        END IF;
        IF NULLIF(btrim(COALESCE(p_not_sampled_reason, '')), '') IS NULL THEN
            RAISE EXCEPTION 'CONTAMINATION_REASON_REQUIRED';
        END IF;
    ELSE
        RAISE EXCEPTION 'CONTAMINATION_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    INSERT INTO contamination_checks (run_id, stream_code, kind, output_batch_id, sample_mass_g, foreign_mass_g, warning_pct_at,
                                      sampled_at, method, not_sampled_reason, corrects_id, correction_reason)
    VALUES (p_run_id, v_stream.code, p_kind,
            CASE WHEN p_kind = 'sampled' THEN p_output_batch_id END,
            CASE WHEN p_kind = 'sampled' THEN p_sample_mass_g END,
            CASE WHEN p_kind = 'sampled' THEN p_foreign_mass_g END,
            v_stream.warning_pct,
            CASE WHEN p_kind = 'sampled' THEN p_sampled_at END,
            NULLIF(btrim(COALESCE(p_method, '')), ''),
            CASE WHEN p_kind = 'not_sampled' THEN btrim(p_not_sampled_reason) END,
            p_corrects_id, NULLIF(btrim(COALESCE(p_correction_reason, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/record_contamination_check.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q21–Q25,Tim):【在加工单页上记一次交叉污染抽检】(或"这一班没抽",带理由)。
--   码:action.processing_aftercare(提交之后补记的那一个码,MES-4a)。判据全在 contamination_check_internal。返回新行 id。
--   一个班可以抽不止一次(多条都留着);任何一条当前的抽检(两种都算)关掉那一班那条流的提醒(contamination_check_missing)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.record_contamination_check(p_run_id uuid, p_stream_code text, p_kind text, p_output_batch_id uuid DEFAULT NULL::uuid, p_sample_mass_g numeric DEFAULT NULL::numeric, p_foreign_mass_g numeric DEFAULT NULL::numeric, p_sampled_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_method text DEFAULT NULL::text, p_not_sampled_reason text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    RETURN contamination_check_internal(p_run_id, p_stream_code, p_kind, p_output_batch_id, p_sample_mass_g, p_foreign_mass_g,
                                        p_sampled_at, p_method, p_not_sampled_reason, NULL, NULL);
END;
$function$;

-- db/functions/correct_contamination_check.sql
-- MES-4b(2026-10-07,规格 §4.2;MES-4b Step 0 Q21,Tim):【更正一次交叉污染抽检】—— 不改原行,落一条新的指回它,理由必填。
--   码:action.processing_aftercare。加工单与流照抄原行;种类可以改(抽了 ↔ 没抽);判据与记一条新的完全同一份(contamination_check_internal)。
--   拒:找不到(CONTAMINATION_CHECK_NOT_FOUND)· 已被更正过(CONTAMINATION_CHECK_SUPERSEDED|<id> —— 只能更正链的末端)·
--   理由空(CONTAMINATION_CORRECTION_REASON_REQUIRED)。警戒线照【此刻】的值抄下。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.correct_contamination_check(p_check_id bigint, p_kind text, p_output_batch_id uuid, p_sample_mass_g numeric, p_foreign_mass_g numeric, p_sampled_at timestamp with time zone, p_method text, p_not_sampled_reason text, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig contamination_checks%ROWTYPE;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_orig FROM contamination_checks WHERE id = p_check_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTAMINATION_CHECK_NOT_FOUND|%', p_check_id;
    END IF;
    IF EXISTS (SELECT 1 FROM contamination_checks x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'CONTAMINATION_CHECK_SUPERSEDED|%', v_orig.id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CONTAMINATION_CORRECTION_REASON_REQUIRED';
    END IF;
    RETURN contamination_check_internal(v_orig.run_id, v_orig.stream_code, p_kind, p_output_batch_id, p_sample_mass_g, p_foreign_mass_g,
                                        p_sampled_at, p_method, p_not_sampled_reason, v_orig.id, p_reason);
END;
$function$;

-- ── 14 · 改过的函数(镜像原样,同签名)──────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text, p_started_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ended_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_shift_code text DEFAULT NULL::text, p_recipe_version_id uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT NULL::jsonb, p_corrects_run_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id      uuid := auth.uid();
    v_process_date date;
    v_run_id       uuid;
    v_total_input  numeric := 0;
    v_total_output numeric := 0;
    v_input        jsonb;
    v_output       jsonb;
    v_inbound_id   uuid;
    v_output_id    uuid;   -- FIN-25:再加工投料(产出批为源)
    v_consumed     numeric;
    v_remaining    numeric;
    v_available     numeric;
    v_held          numeric;
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
    v_wo           work_orders%ROWTYPE;   -- WO-1b
    -- PROC-WIRE-1B-i:这一炉跑的是哪道工序,以及那道工序【吃不吃料、产不产批】。
    -- 【分支读的是字典那两列,不是一个写死的字符串,也不是调用方传的旗标】
    -- 【PROC-SUPPORT-1】v_consumes / v_produces 不再有"没有工序时"的默认值 ——
    -- 到得了这里就一定有工序,两个值都由字典填。留着 := true 会是一句谎:
    -- 它读起来像"还有一条没有工序的路",而那条路已经在上面被拒掉了。
    v_op           text;
    v_consumes     boolean;
    v_produces     boolean;
    v_result_state text;
    -- MES-4a:机器的挂接、更正的原单、配方那一版、每条产出腿的称重
    v_corr         processing_runs%ROWTYPE;
    v_recipe       record;
    v_since        date;
    v_n            integer;
    v_wid          uuid;
    v_w            weighings%ROWTYPE;
    v_wcal         record;
    v_dev          uuid;
    v_out_qty      numeric[] := ARRAY[]::numeric[];
    v_out_wid      uuid[] := ARRAY[]::uuid[];
    v_key          text;
    -- MES-4b:电芯结构 —— 这道工序要不要它、每一批投料带着什么、产出继承什么
    v_req_cc       boolean;
    v_batch_code   text;
    v_cc           text;
    v_cc_vals      text[] := ARRAY[]::text[];
    v_cc_any_null  boolean := false;
    v_cc_inherit   text;
    v_dismantles   boolean;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25):提交加工归仓库 —— action.processing_commit(warehouse · admin)。
    PERFORM require_permission('action.processing_commit');
    IF p_process_date IS NULL THEN
        RAISE EXCEPTION 'PROCESS_DATE_REQUIRED';
    END IF;

    -- FIN-36:分摊基准【必填】。不在这里回退到 finance_settings 的公司默认值 ——
    -- 那只会把"没人选过"从 schema 挪进函数,同一个病换一层楼。表单永远带着值来
    -- (预选自 finance_settings.default_allocation_basis),所以必填没有代价。
    IF p_allocation_basis IS NULL THEN
        RAISE EXCEPTION 'ALLOCATION_BASIS_REQUIRED';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★【PROC-SUPPORT-1:工序【必填】,而且【自己一条码】】★
    --
    -- 【为什么它必须与下面那四条拒绝分开,绝不合并】
    -- 下一步动作完全不同:
    --   · OPERATION_TYPE_REQUIRED        → 【你还没选工序】,回去选一个;
    --   · OPERATION_TYPE_UNKNOWN         → 选了,但那个码不存在或已停用;
    --   · OPERATION_PRODUCES_NO_OUTPUTS  → 选对了码,但这一单的形状与它矛盾;
    --   · STATE_CHANGE_LOSS_NOT_ZERO     → 同上,矛盾在损耗那一栏;
    --   · INPUT_SAFETY_STATE_NOT_ACCEPTED→ 码没错,是这一批料这道工序不收。
    -- 合并任何两条,屏幕上就会有一句话对应两个去处,而操作员会走错门。
    -- (与 PROC-3 那三条"听起来绝不一样"的拒绝同一条理由,fixture 154 钉着。)
    --
    -- 【位置为什么在这里】紧跟 PROCESS_DATE_REQUIRED / ALLOCATION_BASIS_REQUIRED,
    -- 也就是【所有必填项一起,在任何业务判断之前】。放到下面去,一张没选工序的
    -- 单会先撞上 NO_INPUTS 之类的话,而那句话是【真的,但没用】。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_operation_type_code IS NULL THEN
        RAISE EXCEPTION 'OPERATION_TYPE_REQUIRED'
          USING HINT = '从今天起每一张加工单必须说出它跑的是哪一道工序。产出有无、状态改变型的损耗守恒、逐工序安全状态受理、工序本身是否存在 —— 四道闸全都读这一列,而它为空时前三道要么关掉、要么降级成一条更弱的规则。历史上那 14 张没有工序的单是测试残留,刻意不回填,报表把它们显示成【未归属】。';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,MES-0 Q42;MES-4a Step 0 Q7,Tim):【开始、结束、班次】与上面三条必填【一起】,在任何业务判断之前。
    --   判据只有一份(assert_run_header):表上的 INSERT 触发器问的是同一支,correct_run_header 改时刻时也问它。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM assert_run_header(p_process_date, p_started_at, p_ended_at, p_shift_code);

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:解析工序类型。**分支由【工序】决定,不由调用方传旗标决定** ——
    -- 一个 p_is_state_changing 参数会让"这一炉算不算直通"变成调用方的意见,
    -- 而它是那道工序的事实。两者的区别在第一次有人传错的时候才显形,那太晚了。
    -- 【PROC-SUPPORT-1:这一段不再被 IF ... IS NOT NULL 包着】—— 上面那条拒绝
    -- 已经保证到得了这里就有工序。留着那个 IF 会读起来像"还有一条没有工序的路"。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT ot.code, k.consumes_input, k.produces_outputs, ot.resulting_safety_state_code, ot.requires_cell_construction
      INTO v_op, v_consumes, v_produces, v_result_state, v_req_cc
      FROM operation_types ot
      JOIN operation_kinds k ON k.code = ot.kind_code
     WHERE ot.code = p_operation_type_code AND ot.is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OPERATION_TYPE_UNKNOWN|%', p_operation_type_code
          USING HINT = '未知或已停用的工序。停用的意思是"以后别再选它",不是"把历史改掉"。';
    END IF;
    IF p_allocation_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', p_allocation_basis;
    END IF;

    -- ── WO-1b:工单这一支【只在给了参数的时候才存在】────────────────────────
    -- 【为什么是可选的,而不是必填】临时起意的加工是合法的 —— 车间不会为了系统
    -- 先去补一张计划。把它变成必填,得到的不是纪律,是一堆事后补的假工单。
    -- 差异报表因此必须把 work_order_id 为空的那些显示成【计划外】这一个具名的
    -- 类别,而不是让它们悄悄消失(那是 WO-1c 的事,规则记在这里)。
    IF p_work_order_id IS NOT NULL THEN
        SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'WO_NOT_FOUND|%', p_work_order_id;
        END IF;
        -- 【只有放行了的工单可以开工】草稿是还没答应的事(与 reserve_stock 只认
        -- 已确认订单同一条);而 closed / cancelled 是【已经结束的事】,再往上挂
        -- 一次加工会让那张单的完成度在它收工之后继续变 —— 收工时写进理由行的
        -- 那句"runs=N"从此不再复算得出来。
        IF v_wo.status <> 'released' THEN
            RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
        END IF;
    END IF;

    -- ── EQP-2a:机器这一支【也只在给了参数的时候才存在】────────────────────
    -- ════════════════════════════════════════════════════════════════════════
    -- ★★【PROC-SUPPORT-1 / R2:equipment_id 【不】跟着 operation_type_code
    --      一起变成必填。这不是一次对称性偏好,是一次【字典完整性】判断。】★★
    --
    -- 【量出来的,不是想出来的】线上 fixed_assets 只有 2 行,而且两行【都是
    --  深度放电机】(FA-2026-0001 Bosch Deep Discharging Machine、
    --  FA-2026-0002 Mobile Discharging Solution),两行的 in_service_date 都是 NULL。
    -- 于是"一台机器一道工序"这个假设在线上【两个方向都是假的】:
    --   · deep_discharge ↔ 两台机器 → 工序【推不出】机器,不能"顺手带出来";
    --   · manual_disassembly / electrode_line / electrode_powder_line /
    --     battery_powder_line —— 五道工序里的【四道】,一台在册机器都没有。
    --     一旦 equipment_id 必填,这四道工序的加工单【一张都提交不了】。
    --
    -- 所以两列的区别是:
    --   · operation_type_code 的字典【完整】—— 5 道工序全部已播种,任何一张单
    --     都答得出来,于是必填的代价是零;
    --   · equipment_id 的字典【残缺】—— 5 道里 4 道无资产可指,于是必填的代价
    --     是让四道工序停摆。
    --
    -- ★【给后来人:不要"修"掉这处不对称】★ 它看起来像是漏了一半,不是。
    -- 要让 equipment_id 也必填,前置条件是【可以查询的】,不是一次感觉:
    --   (1) 每一道启用的工序至少有一台在册、在役的资产;
    --   (2) 而那需要一条【工序 ↔ 资产】的关联,**今天这个库里根本没有这条关联**
    --       —— 那才是真正的前置缺口,记在 docs/processing-support-as-built.md。
    -- 在那之前,空【是一个具名类别(未归属)】,不是零。
    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-2a 的三条(没找到 · 早于取得 · 晚于处置)与 MES-4a 的工序 ↔ 资产规则,判据都在 assert_run_equipment ——
    -- correct_run_header 改机器时问的是同一支。投用之前不拒、试车照收的理由见那支函数与上面这段。
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,MES-0 Q41;MES-4a Step 0 Q9,Tim):【上面那段等的前置条件到了】—— 工序 ↔ 资产的关联
    --   (operation_type_equipment)。一道工序只要挂着【至少一台没处置的】机器,这一炉就必须说出是哪一台,而且必须是挂着的那几台之一。
    --   处置掉的机器不算数(一道只挂着一台已处置机器的工序 = 没有挂机器)。没有挂任何机器的工序照旧:机器可选。
    --   【为什么不在"没挂机器"时也拒一台被点名的机器】那正是 U1-B 的可选选择器今天的样子,而挂不挂是 Tim 的数据 ——
    --   在他挂之前,一张记下了用哪台机器的单是更多的信息,不是错。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM assert_run_equipment(v_op, p_equipment_id, p_process_date);

    -- ── MES-4a(MES-0 Q49;Q31):这一张来更正哪一张 —— 原单必须已经回滚,而且只能被更正一次 ─────────────
    IF p_corrects_run_id IS NOT NULL THEN
        SELECT * INTO v_corr FROM processing_runs WHERE id = p_corrects_run_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_corrects_run_id;
        END IF;
        IF v_corr.status <> 'reversed' THEN
            RAISE EXCEPTION 'RUN_CORRECTS_NOT_REVERSED|%', v_corr.code
              USING HINT = '数量的更正 = 先经回滚申请(CFO 批)把原单冲掉,再记这一张新单指回它。原单还没冲销。';
        END IF;
        IF EXISTS (SELECT 1 FROM processing_runs r WHERE r.corrects_run_id = p_corrects_run_id) THEN
            RAISE EXCEPTION 'RUN_ALREADY_CORRECTED|%|%', v_corr.code,
                (SELECT r.code FROM processing_runs r WHERE r.corrects_run_id = p_corrects_run_id);
        END IF;
    END IF;

    -- ── MES-4a(MES-0 Q44;Q16):配方的那一版 —— 必须是这道工序的、配方还启用着 ─────────────
    IF p_recipe_version_id IS NOT NULL THEN
        SELECT rv.id, rv.version, rv.param_values, rc.code, rc.operation_type_code, rc.is_active INTO v_recipe
          FROM process_recipe_versions rv JOIN process_recipes rc ON rc.id = rv.recipe_id
         WHERE rv.id = p_recipe_version_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RECIPE_VERSION_NOT_FOUND|%', p_recipe_version_id;
        END IF;
        IF v_recipe.operation_type_code <> v_op THEN
            RAISE EXCEPTION 'RECIPE_VERSION_NOT_FOR_OPERATION|%|%', v_recipe.code, v_op;
        END IF;
        IF NOT v_recipe.is_active THEN
            RAISE EXCEPTION 'RECIPE_INACTIVE|%', v_recipe.code;
        END IF;
    END IF;

    v_process_date := p_process_date;
    -- 0. 基本校验
    IF p_inputs IS NULL OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'NO_INPUTS';
    END IF;
    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:产出的有无,由【工序】说了算
    --   * 会产出的工序(转化型)少了产出 → 照旧 NO_OUTPUTS,一个字没松;
    --   * 不产出的工序(状态改变型,R3)带着产出来 → 【也是拒】,而且是另一条码。
    -- 后者容易被漏掉:只放松一侧会让一张"放电还产出了黑粉"的单悄悄成立。
    -- 【PROC-SUPPORT-1:这道闸现在【总是】有一个工序可读】—— 此前 v_produces
    -- 在无工序时默认 true,于是这条 IF 走的是"照旧"那一支,闸等于不存在。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_produces THEN
        IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN
            RAISE EXCEPTION 'NO_OUTPUTS';
        END IF;
    ELSE
        IF p_outputs IS NOT NULL AND jsonb_array_length(p_outputs) > 0 THEN
            RAISE EXCEPTION 'OPERATION_PRODUCES_NO_OUTPUTS|%', v_op
              USING HINT = '这道工序【按定义】不产新批次(R3:同一批进、同一批出,只改状态)。带着产出提交它,说明选错了工序或者选错了单。';
        END IF;
    END IF;
    IF p_loss_qty IS NOT NULL AND p_loss_qty < 0 THEN
        RAISE EXCEPTION 'LOSS_NEGATIVE';
    END IF;

    -- 0b. 同一批次(不论来源)不能重复添加。FIN-25:投料可为进料批或产出批,
    --     恰一非空;两个都给或都不给 → INPUT_PARENT_INVALID。
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_inputs) elem
        WHERE num_nonnulls(elem->>'inbound_batch_id', elem->>'output_batch_id') <> 1
    ) THEN
        RAISE EXCEPTION 'INPUT_PARENT_INVALID';
    END IF;
    IF (SELECT count(DISTINCT COALESCE(elem->>'inbound_batch_id', elem->>'output_batch_id'))
        FROM jsonb_array_elements(p_inputs) elem) <> jsonb_array_length(p_inputs) THEN
        RAISE EXCEPTION 'DUPLICATE_INPUT';
    END IF;

    -- 1. 遍历投入:校验库存(并锁行)+ 累计投入合计
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_consumed IS NULL OR v_consumed <= 0 THEN
            RAISE EXCEPTION 'INPUT_QTY_INVALID';
        END IF;

        IF v_inbound_id IS NOT NULL THEN
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches
            WHERE id = v_inbound_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_inbound_id;
            END IF;
        ELSE
            -- FIN-25:产出批投料 —— 同一套校验、同一把锁。库存机器本就共用
            -- (inventory_movements 两侧 XOR,remaining_qty 两表同义)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches
            WHERE id = v_output_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_output_id;
            END IF;
        END IF;
        -- IOD-1:投得进去的是【可用】,不是【物理剩余】—— 被扣住的货还在批次里,
        -- 但它不可动用。拒绝同时说出可用与暂扣两个数,否则人看着 remaining 够
        -- 却投不进去,屏幕上没有任何解释。
        v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                                 WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                                   AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                                   AND m.stock_status = 'available'), 0);
        v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                            WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                              AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                              AND m.stock_status = 'on_hold'), 0);
        IF v_consumed > v_available THEN
            RAISE EXCEPTION 'IOD_CONSUME_EXCEEDS_AVAILABLE|%|%|%', v_consumed, v_available, v_held;
        END IF;

        v_total_input := v_total_input + v_consumed;
    END LOOP;

    -- 2. 遍历产出:校验 + 累计产出合计
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,规格 §3.2 · §4.1;MES-0 Q22;MES-4a Step 0 Q24–Q26,Tim):【每一条产出腿都是称出来的】
    --   一条腿二选一:
    --     · weighing_id —— 挑一条现成的称重:确认了的、单独的净重(不挂地磅单)、没被更正过、没给别的腿用过;
    --     · weight_kg(+ 可选 device_id)—— 在这里敲一个重量:经正常的录入路径在同一笔事务里落一条手工称重(record_manual_weighing_internal)。
    --   腿的数量【就是】那次称重的公斤数(单位只能是 kg —— OUTPUT_UNIT_NOT_KG);再带一个不一样的 quantity → OUTPUT_QTY_NOT_WEIGHING。
    --   两样都没有 → OUTPUT_WEIGHING_REQUIRED|<第几条>。
    --   校准(MES-3a 的裁定 1,同一个判据 weighing_calibration_all):仪器在读数那一天【已知】不在校准期内 → 永远拒
    --   (READING_INSTRUMENT_NOT_CALIBRATED);没有记录仪器 → 开关 require_calibrated_since 空着时只标出来,开关给了且加工日在它之后才拒。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT s.require_calibrated_since INTO v_since FROM ingest_settings s WHERE s.id;
    v_n := 0;
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_n := v_n + 1;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
        IF NULLIF(v_output->>'unit', '') IS NOT NULL AND v_output->>'unit' <> 'kg' THEN
            RAISE EXCEPTION 'OUTPUT_UNIT_NOT_KG|%|%', v_n, v_output->>'unit';
        END IF;
        v_wid := NULLIF(v_output->>'weighing_id', '')::uuid;
        IF v_wid IS NOT NULL AND NULLIF(v_output->>'weight_kg', '') IS NOT NULL THEN
            RAISE EXCEPTION 'OUTPUT_WEIGHING_AMBIGUOUS|%', v_n;
        END IF;
        IF v_wid IS NULL THEN
            IF NULLIF(v_output->>'weight_kg', '') IS NULL THEN
                RAISE EXCEPTION 'OUTPUT_WEIGHING_REQUIRED|%', v_n
                  USING HINT = 'MES-4a 起每一条产出腿都要有一次称重:挑一条现成的,或在这里敲重量(会记成一次手工称重)。';
            END IF;
            v_qty := (v_output->>'weight_kg')::numeric;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
            END IF;
            v_dev := NULLIF(v_output->>'device_id', '')::uuid;
            v_wid := record_manual_weighing_internal(v_qty, v_dev);
        END IF;
        SELECT * INTO v_w FROM weighings WHERE id = v_wid;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'WEIGHING_NOT_FOUND|%', v_wid;
        END IF;
        IF v_w.ticket_id IS NOT NULL OR v_w.role <> 'net' THEN
            RAISE EXCEPTION 'WEIGHING_NOT_STANDALONE_NET|%', v_n;
        END IF;
        IF EXISTS (SELECT 1 FROM weighings x WHERE x.corrects_id = v_w.id) THEN
            RAISE EXCEPTION 'WEIGHING_SUPERSEDED|%', v_w.id;
        END IF;
        IF v_wid = ANY (v_out_wid) THEN
            RAISE EXCEPTION 'WEIGHING_ALREADY_USED|%', v_n;
        END IF;
        IF EXISTS (SELECT 1 FROM processing_outputs po WHERE po.weighing_id = v_wid) THEN
            RAISE EXCEPTION 'WEIGHING_ALREADY_USED|%', (SELECT r.code FROM processing_outputs po JOIN processing_runs r ON r.id = po.run_id
                                                         WHERE po.weighing_id = v_wid);
        END IF;
        SELECT wc.status, wc.device_code, wc.captured_on INTO v_wcal FROM weighing_calibration_all wc WHERE wc.weighing_id = v_wid;
        IF v_wcal.status = 'not_recorded' THEN
            IF v_since IS NOT NULL AND v_process_date >= v_since THEN
                RAISE EXCEPTION 'OUTPUT_WEIGHING_INSTRUMENT_NOT_RECORDED|%', v_n;
            END IF;
        ELSIF v_wcal.status <> 'in_calibration' THEN
            RAISE EXCEPTION 'READING_INSTRUMENT_NOT_CALIBRATED|%|%', v_wcal.device_code, to_char(v_wcal.captured_on, 'YYYY-MM-DD');
        END IF;
        v_qty := v_w.weight_kg;
        IF NULLIF(v_output->>'quantity', '') IS NOT NULL AND (v_output->>'quantity')::numeric <> v_qty THEN
            RAISE EXCEPTION 'OUTPUT_QTY_NOT_WEIGHING|%|%|%', v_n, v_output->>'quantity', v_qty;
        END IF;
        v_out_wid := array_append(v_out_wid, v_wid);
        v_out_qty := array_append(v_out_qty, v_qty);
        v_total_output := v_total_output + v_qty;
    END LOOP;

    -- 3. 质量守恒:产出不能大于投入
    IF v_total_output > v_total_input THEN
        RAISE EXCEPTION 'OUTPUT_EXCEEDS_INPUT|%|%', v_total_output, v_total_input;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:直通式的质量账
    -- **料【穿过】工序,没有被吃掉** —— 所以投入 = 产出 = 通过量,损耗【真的是 0】
    -- (放电不带走任何质量;这不是"没量过所以填 0",是 R3 说的同一批进同一批出)。
    -- 不这么写的话:total_output = 0 会让质量平衡读成"投了 100 出来 0",
    -- 而 loss_qty = COALESCE(p_loss_qty, 100 - 0) 会凭空记下一笔【等于全部投入】
    -- 的损耗 —— 一张放电单会报告它把碰过的东西全毁了。
    -- 【PROC-SUPPORT-1 实测:无工序时这一整段【从不执行】】—— v_produces 默认
    -- true,于是 NOT v_produces 永远为假。线上量到的那 3 公斤损耗就是这么来的。
    -- ════════════════════════════════════════════════════════════════════════
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,规格 §4.1;MES-4a Step 0 Q17,Tim):【loss_qty 是推出来的:投入 − 产出】
    --   此前它是 COALESCE(p_loss_qty, 投入 − 产出)—— 调用方敲一个不同的数,那个数就被相信了,而它与投入 − 产出之间的差
    --   没有任何人过问(规格 §4.1:一笔只以差额存在的损耗没有审计价值)。现在敲一个不同的数按名拒;
    --   有名字的损耗(processing_run_losses)不许超过它,剩下的就是余数,由结平说出来。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_produces AND p_loss_qty IS NOT NULL AND p_loss_qty <> v_total_input - v_total_output THEN
        RAISE EXCEPTION 'LOSS_QTY_NOT_INPUT_MINUS_OUTPUT|%|%', p_loss_qty, v_total_input - v_total_output
          USING HINT = '损耗总量就是投入减产出,不另填。有名字的损耗在加工单页上分类记;剩下没解释的由结平说出来。';
    END IF;

    IF NOT v_produces THEN
        v_total_output := v_total_input;
        IF COALESCE(p_loss_qty, 0) <> 0 THEN
            RAISE EXCEPTION 'STATE_CHANGE_LOSS_NOT_ZERO|%|%', v_op, p_loss_qty
              USING HINT = '状态改变型工序不带走质量,所以它的损耗只能是 0。填了别的数,要么选错了工序,要么这一炉其实是转化型。';
        END IF;
    END IF;

    -- 4. 建加工单表头(code 由触发器生成)
    INSERT INTO processing_runs (
        process_date, total_input, total_output, loss_qty, notes, status,
        allocation_basis, work_order_id, created_by, updated_by, equipment_id,
        operation_type_code, started_at, ended_at, shift_code, recipe_version_id, corrects_run_id
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        CASE WHEN v_produces THEN v_total_input - v_total_output ELSE 0 END,
        p_notes, 'committed', p_allocation_basis, p_work_order_id, v_user_id, v_user_id,
        p_equipment_id,
        v_op, p_started_at, p_ended_at, p_shift_code, p_recipe_version_id, p_corrects_run_id
    )
    RETURNING id INTO v_run_id;

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿 + 记库存流水(消耗)
    --    FIN-25:ctx 提前到这里 —— 投入腿的守卫触发器(guard_processing_input)
    --    只放行函数上下文;原来 ctx 在第 6 步(产出)才设,投入腿就会被自己拒掉。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_inbound_id IS NOT NULL THEN
            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-i:【直通式不扣库存】
            -- 一炉深度放电结束之后,那批货还在院子里,还是那么多克。
            -- 扣掉它 = 账上把一批还存在的货销掉,而这是那个"只放松 NO_OUTPUTS"
            -- 的实现最先造成的破坏(它会把 remaining_qty 扣到 0)。
            -- **投入腿照记** —— 那是【通过量】,记的是"这批料走过这道工序",
            -- 不是"这批料被吃掉了"。设备用量与工时因此仍然读得到它。
            -- ════════════════════════════════════════════════════════════
            IF v_consumes THEN
                SELECT remaining_qty INTO v_remaining
                FROM inbound_batches WHERE id = v_inbound_id;
                v_new_remaining := v_remaining - v_consumed;

                UPDATE inbound_batches
                SET remaining_qty = v_new_remaining,
                    stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
                    updated_by = v_user_id,
                    updated_at = now()
                WHERE id = v_inbound_id;

                -- IOD-1:投料走 drain_stock —— 可能跨几个库位桶,于是写出多行(规则见其函数头)
                PERFORM drain_stock(
                    p_qty => v_consumed, p_movement_type => 'processing_consume',
                    p_business_date => v_process_date, p_inbound_batch_id => v_inbound_id,
                    p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);
            END IF;

            INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
            VALUES (v_run_id, v_inbound_id, v_consumed);

            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-i:**R3 的"改状态"就落在这里**
            -- 被这道工序【解决掉】的状态从批次上删掉,再写上结果状态。
            -- 不删的话,一批放完电的货会永远带着"未放电",于是下一道工序
            -- 仍然拒绝它 —— 那正是本刀要解的那个死锁,只是换了个位置复发。
            -- ════════════════════════════════════════════════════════════
            -- ★ MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q22 · Q2,Tim):解决掉的状态被【结束】(记下是哪一张加工单),
            --   不再被删;写上的结果状态记 created_by_run_id —— 回滚据这两列把这一炉做过的事原样撤回。
            --   结果状态已经开着(批次本来就带着它)→ 不插(开着的只有一条),于是回滚也不会结束那条不是它写的。
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                UPDATE inbound_batch_safety_states s
                   SET ended_at = now(), ended_by = v_user_id, ended_by_run_id = v_run_id,
                       end_reason = 'resolved by processing run ' || (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_run_id)
                 WHERE s.inbound_batch_id = v_inbound_id AND s.ended_at IS NULL
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_by_run_id)
                VALUES (v_inbound_id, v_result_state, v_run_id)
                ON CONFLICT (inbound_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
            END IF;
        ELSE
            -- ════════════════════════════════════════════════════════════
            -- ★【PROC-WIRE-1B-ii:那条占位的拒绝在这里被【拆掉】】★
            -- 此前这里按名拒 STATE_CHANGE_OUTPUT_INPUT_UNSUPPORTED,理由是
            -- 结构性的:安全状态只有进料批有,"把状态改成已放电"这件事在
            -- 产出批上【无处可写】,放过去会得到一炉什么都没改的放电。
            -- **PROC-WIRE-1B-ii 建了 output_batch_safety_states,那个理由不复存在** ——
            -- 于是拒绝也必须跟着走。R1 说得很清楚:闸问的是【这批料和它的
            -- 状态】,不是【这批料从哪来】;一道工序因为料是自己产的就拒绝它,
            -- 正是那处不对称本身。
            -- 【留着它会更坏】表建好了、拒绝还在,下一个人会以为这条路仍然
            -- 没通,而 fixture 会对着一条早该消失的拒绝变绿。
            -- ════════════════════════════════════════════════════════════
            -- FIN-25:产出批投料。state 是【销售状态】(表注),消耗不碰它 ——
            -- 只扣 remaining_qty,流水挂 output_batch_id(XOR 的另一侧)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches WHERE id = v_output_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_output_id;

            PERFORM drain_stock(
                p_qty => v_consumed, p_movement_type => 'processing_consume',
                p_business_date => v_process_date, p_output_batch_id => v_output_id,
                p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);

            INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
            VALUES (v_run_id, v_output_id, v_consumed);

            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-ii:**R3 的"改状态",产出批这一侧** ——
            -- 与上面进料那一段逐字同形。不删被解决掉的状态,一批放完电的
            -- 自产料会永远带着"未放电",下一道工序仍然拒绝它 —— 那就是
            -- 1B-i 解掉的那个死锁,换到产出批上原样复发。
            -- ════════════════════════════════════════════════════════════
            -- ★ MES-3a:与进料侧逐字同形 —— 结束,不删;结果状态记 created_by_run_id。
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                UPDATE output_batch_safety_states s
                   SET ended_at = now(), ended_by = v_user_id, ended_by_run_id = v_run_id,
                       end_reason = 'resolved by processing run ' || (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_run_id)
                 WHERE s.output_batch_id = v_output_id AND s.ended_at IS NULL
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
                VALUES (v_output_id, v_result_state, v_run_id)
                ON CONFLICT (output_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
            END IF;
        END IF;
        -- ════════════════════════════════════════════════════════════════════
        -- ★ MES-4b(2026-10-07,规格 §3.4;MES-0 Q45;MES-4b Step 0 Q5 · Q6,Tim):【分极片的工序要知道电芯是卷绕还是叠片】
        --   operation_types.requires_cell_construction 为真(引导:electrode_separation · electrode_line)时,每一批投料都必须带一个
        --   确定的结构(cell_constructions.is_determined)—— 没记或 unknown → INPUT_CELL_CONSTRUCTION_REQUIRED|<批号>。
        --   是一个标志,不是这里的一张码表。【放在投入腿落下之后】—— 投入腿的守卫先判安全状态(起火那一道闸先说话:
        --   一批没放电的料,要先听到"这道工序不收它",而不是"先记下它是卷绕还是叠片")。同时记下每一批的值,第 6 步据此决定产出继承什么。
        -- ════════════════════════════════════════════════════════════════════
        IF v_inbound_id IS NOT NULL THEN
            SELECT b.code, b.cell_construction_code INTO v_batch_code, v_cc FROM inbound_batches b WHERE b.id = v_inbound_id;
        ELSE
            SELECT b.code, b.cell_construction_code INTO v_batch_code, v_cc FROM output_batches b WHERE b.id = v_output_id;
        END IF;
        IF v_req_cc AND (v_cc IS NULL OR NOT EXISTS (SELECT 1 FROM cell_constructions c WHERE c.code = v_cc AND c.is_determined)) THEN
            RAISE EXCEPTION 'INPUT_CELL_CONSTRUCTION_REQUIRED|%', v_batch_code
              USING HINT = '这道工序按电芯结构分设备(卷绕 / 叠片)。先在批次页上记下这一批是哪一种 —— 没记或"看过分不出"都过不去。';
        END IF;
        IF v_cc IS NULL THEN
            v_cc_any_null := true;
        ELSE
            v_cc_vals := array_append(v_cc_vals, v_cc);
        END IF;
    END LOOP;

    -- MES-4b(Q6):每一批投料都带着【同一个】结构 → 装电芯的产出继承它;有一批没记、或彼此不同 → 留空,到批次页上补。
    IF NOT v_cc_any_null AND (SELECT count(DISTINCT x) FROM unnest(v_cc_vals) x) = 1 THEN
        v_cc_inherit := v_cc_vals[1];
    END IF;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    v_n := 0;
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_n := v_n + 1;
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := v_out_qty[v_n];     -- MES-4a:称出来的公斤数(上面第 2 步定下的)
        v_unit        := 'kg';
        v_purity      := NULLIF(v_output->>'purity', '');
        -- MES-4b(Q6):只有【明确装着电芯】的形态继承结构(没有形态的物料不继承 —— 不知道它装不装电芯)。
        SELECT f.implies_dismantling INTO v_dismantles
          FROM materials m JOIN material_forms f ON f.code = m.form_code WHERE m.id = v_material_id;

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by, cell_construction_code
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id, CASE WHEN v_dismantles IS TRUE THEN v_cc_inherit END
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced, weighing_id)
        VALUES (v_run_id, v_new_output_id, v_qty, v_out_wid[v_n]);
    END LOOP;

    -- 用毕即清(price_ctx 同一条理由:免得同事务内后续的直改被误放行 ——
    -- fixture 19F 实测:不清,守卫触发器对残留 ctx 放行裸 INSERT)
    PERFORM set_config('evoltrya.movement_ctx', '', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,MES-0 Q43 · Q44;MES-4a Step 0 Q11 · Q16,Tim):【这一炉记下的参数与指标】
    --   配方那一版先预填它的参数(source = 'recipe');p_values 里给了的字段用给的值(source = 'manual')。
    --   配方里一个后来退役了的字段不预填(退役 = 以后别再用它)。必填【不在这里判】—— 在结平时判(Q11)。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_values IS NOT NULL AND jsonb_typeof(p_values) <> 'object' THEN
        RAISE EXCEPTION 'RUN_VALUES_INVALID';
    END IF;
    IF p_recipe_version_id IS NOT NULL THEN
        FOR v_key IN SELECT k FROM jsonb_object_keys(v_recipe.param_values) k ORDER BY k LOOP
            CONTINUE WHEN p_values IS NOT NULL AND p_values ? v_key;
            CONTINUE WHEN NOT EXISTS (SELECT 1 FROM operation_type_fields f
                                       WHERE f.operation_type_code = v_op AND f.field_code = v_key AND f.is_active);
            PERFORM record_run_value_internal(v_run_id, v_key, v_recipe.param_values -> v_key, 'recipe', NULL, NULL);
        END LOOP;
    END IF;
    IF p_values IS NOT NULL THEN
        FOR v_key IN SELECT k FROM jsonb_object_keys(p_values) k ORDER BY k LOOP
            CONTINUE WHEN jsonb_typeof(p_values -> v_key) = 'null';
            PERFORM record_run_value_internal(v_run_id, v_key, p_values -> v_key, 'manual', NULL, NULL);
        END LOOP;
    END IF;

    -- ── COD-1:这一投料可能【刚好把某一票货加工完】────────────────────────
    -- 销毁证书是一条【必须存在】的记录(像化验报告),不等谁打开页面。
    -- 幂等,没完成就什么也不做;判据在 cod_delivery_completion(),不在这里。
    FOR v_inbound_id IN
        SELECT DISTINCT pi.inbound_batch_id FROM processing_inputs pi
         WHERE pi.run_id = v_run_id AND pi.inbound_batch_id IS NOT NULL
    LOOP
        PERFORM refresh_cod_for_batch(v_inbound_id);
    END LOOP;

    RETURN v_run_id;
END;
$function$;

-- db/functions/record_run_loss.sql
-- MES-4a(2026-10-07,规格 §4.1 · §4.2;MES-0 Q49;MES-4a Step 0 Q28,Tim):【给一炉记一条有名字的损耗】—— 只追加的那张表的两扇门之一。
--   此前页面直连 upsert 这张表;现在只经这里与 correct_run_loss。码与此前那三条写策略同一组:module.processing.edit 或
--   action.processing_aftercare(仓库 —— 提交加工的人记它的损耗,ROLE-1 Batch 3b Q2)。
--   加工单必须已提交、没回滚(RUN_NOT_COMMITTED);类别必须启用着(RUN_LOSS_CATEGORY_UNKNOWN);量为正(RUN_LOSS_QTY_INVALID);
--   这一类已经有一条(任何一条,哪怕撤回成 0)→ RUN_LOSS_ALREADY_RECORDED|<类别>(要改就更正它)。
--   有名字的损耗之和不许超过 loss_qty(= 投入 − 产出)—— 表上的约束触发器 LOSS_CATEGORIES_EXCEED_LOSS_QTY。返回新行 id。
--   MES-4b(2026-10-07,Step 0 Q16):这扇门记的永远是【量出来的】—— basis = 'measured',明写,不靠默认值。
--   算出来的电解液挥发走 record_derived_electrolyte_loss。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_run_loss(p_run_id uuid, p_loss_category_code text, p_quantity numeric, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run processing_runs%ROWTYPE;
    v_id  bigint;
BEGIN
    IF NOT has_any_permission(ARRAY['module.processing.edit', 'action.processing_aftercare']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.processing_aftercare';
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM loss_categories c WHERE c.code = p_loss_category_code AND c.is_active) THEN
        RAISE EXCEPTION 'RUN_LOSS_CATEGORY_UNKNOWN|%', COALESCE(p_loss_category_code, '?');
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'RUN_LOSS_QTY_INVALID|%', p_quantity;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_losses l WHERE l.run_id = p_run_id AND l.loss_category_code = p_loss_category_code) THEN
        RAISE EXCEPTION 'RUN_LOSS_ALREADY_RECORDED|%', p_loss_category_code;
    END IF;
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, notes, basis)
    VALUES (p_run_id, p_loss_category_code, p_quantity, NULLIF(btrim(COALESCE(p_notes, '')), ''), 'measured')
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/correct_run_loss.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q28,Tim):【更正一条有名字的损耗】—— 不改原行,落一条新的指回它。
--   码:module.processing.edit 或 action.processing_aftercare。理由必填(RUN_LOSS_CORRECTION_REASON_REQUIRED);只能更正链的末端
--   (RUN_LOSS_SUPERSEDED|<id>);新量不为负(RUN_LOSS_QTY_INVALID)—— 0 就是【撤回】这一类;与原值相同按名拒(RUN_LOSS_CORRECTION_SAME_VALUE)。
--   类别与加工单照抄原行。之和仍不许超过 loss_qty。之后结平的水位线被越过 → 那一炉回到"没结平"(Q19)。返回新行 id。
--   MES-4b(2026-10-07,Step 0 Q19):这扇门落的更正永远是【量出来的】(basis = 'measured')—— 一笔算出来的电解液挥发
--   改成量出来的就走这里;重新算走 rederive_electrolyte_loss。原行是算出来的时,与原值相同【不】拒:依据变了(量过了),那就是一次更正。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.correct_run_loss(p_loss_id bigint, p_quantity numeric, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run  processing_runs%ROWTYPE;
    v_orig processing_run_losses%ROWTYPE;
    v_id   bigint;
BEGIN
    IF NOT has_any_permission(ARRAY['module.processing.edit', 'action.processing_aftercare']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.processing_aftercare';
    END IF;
    SELECT * INTO v_orig FROM processing_run_losses WHERE id = p_loss_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_LOSS_NOT_FOUND|%', p_loss_id;
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = v_orig.run_id FOR UPDATE;
    IF v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.code;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_losses x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'RUN_LOSS_SUPERSEDED|%', v_orig.id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'RUN_LOSS_CORRECTION_REASON_REQUIRED';
    END IF;
    IF p_quantity IS NULL OR p_quantity < 0 THEN
        RAISE EXCEPTION 'RUN_LOSS_QTY_INVALID|%', p_quantity;
    END IF;
    IF p_quantity = v_orig.quantity AND v_orig.basis = 'measured' THEN
        RAISE EXCEPTION 'RUN_LOSS_CORRECTION_SAME_VALUE';
    END IF;
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, notes, corrects_id, correction_reason, basis)
    VALUES (v_orig.run_id, v_orig.loss_category_code, p_quantity, v_orig.notes, v_orig.id, btrim(p_reason), 'measured')
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

-- db/functions/trail_subjects.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):审计记录的【主语登记表】。页面只说"哪一种记录、哪一条",从不说表名;
--   表名、根键、以及【这一页自己的查看权限码】只住在这里(服务端)。不在这里的主语 → TRAIL_SUBJECT_UNKNOWN。
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1 · M3 · M6)多了三列:
--   view_codes   【任一】即可进(M1)—— 与页面守卫同一组码。一页只认一个码时就是一个元素的数组。
--                warehouse_request:/inventory 那一块(module.inventory.view)与财务(module.finance.view)都读它。
--   root_rule    (AUDIT-TRAIL-1d-1 多了两种:'collection' —— M11,一张表整张是一条记录;'gate:<名字>' —— M12,比表的规则更窄)
--                'table'(默认):根行还要过它自己那张表的读规则,过不了 → TRAIL_NOT_PERMITTED。
--                'page'(M3):页面的码就是门;根行自己的那几次改动照子行的规矩走 —— 读者过不了根表的读规则,
--                那几条就是 Restricted(Q4)。equipment 用它:根表 fixed_assets 只给财务读,而这一页给加工的人。
--   root_columns 非空(M6):根行只取这几列的改动(一块面板只管它自己编辑的那几个字段,Q25 的同一条规矩)。
--                NULL = 整行。1b-3 的三个阈值面板会用到它;本刀先建好,fixture 237 用一个临时主语证它。
-- view_codes 与页面守卫逐字同一组码:
--   purchase_order → /purchasing/orders/[id]        requireModule(MOD.purchasing) = module.purchasing.view
--   processing_run → /operation/processing/[id]     requireModule(MOD.processing) = module.processing.view
--   operation_type → /operation/operation-types/[code] requireModule(MOD.processing) = module.processing.view(MES-4a)
--   role           → /settings/roles/[id]           requireManagePermissions()     = action.manage_permissions
--   inbound_batch  → /inbound/[id]/edit             requireModule(MOD.inbound)     = module.inbound.view
--   output_batch   → /output/[id]/edit              requireModule(MOD.output)      = module.output.view
--   work_order     → /operation/orders/[id]         requireModule(MOD.processing)  = module.processing.view
--   stocktake      → /stocktakes/[id]               requireModule(MOD.stocktakes)  = module.stocktakes.view
--   equipment      → /operation/equipment/[id]      requireModule(MOD.processing)  = module.processing.view
--   shift_handover → /operation/handovers/[id]      requireModule(MOD.processing)  = module.processing.view
--   warehouse_request → /inventory 的申请一块        requireModule(MOD.inventory)   = module.inventory.view(+ 财务)
-- AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a 的商务那一半):
--   quote          → /sales/quotes/[id]              requireModule(MOD.sales)       = module.sales.view
--   sales_order    → /sales/orders/[id]              requireModule(MOD.sales)       = module.sales.view
--   shipment       → /sales/shipments/[id]           action.ship_goods,否则 requireModule(MOD.sales)(M1:任一)
--   customer       → /sales/customers/[id]           requireModule(MOD.customers)   = module.customers.view
--   commission_agreement → /sales/commissions/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   supplier       → /suppliers/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   container      → /logistics/containers/[id]      requireModule(MOD.logistics)   = module.logistics.view
--   forwarder      → /logistics/forwarders/[id]      requireModule(MOD.logistics)   = module.logistics.view
--                    根表是 suppliers(读规则 module.suppliers.view)—— M3:页面的码是门,根行自己的改动逐行判
--   lane · port    → /logistics/lanes(只有清单页,按条合起来,见 app/components/trail/ListTrail.tsx)module.logistics.view
--   company_licence → /purchasing/licences(只有清单页)门是 module.purchasing.view,而这张表的读规则是
--                    module.suppliers.view —— 这一块只画在持 suppliers.view 的那一支里(页面本来就那样分),所以登记后者
-- AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a 的主数据与工具):
--   material       → /materials/[id]/edit(只有这一页,Q2)requireModule(MOD.materials) = module.materials.view
--   storage_location → /inventory/locations/[id]/edit(只有这一页)requireModule(MOD.inventory) = module.inventory.view
--   metal_price    → /tools/pricing/metal-prices/[id]/edit(只有这一页)requireEditPermission('action.metal_prices')
--   pricing_formula → /tools/pricing/formulas/[id]/edit(只有这一页)requireModule(MOD.pricing) = module.pricing.view
--   task           → /tools/tasks/[id]                requireModule(MOD.tasks)       = module.tasks.view
--                    私人任务也读得到(Q3):根行要过 tasks 自己的读规则(团队任务 · 自己的 · 或持 module.tasks.view_all)——
--                    那正是"谁打得开这一页"的同一个判据,而遮蔽那一步本来就先问任务隐私
--   processing_settings → /operation/orders 的工单阈值面板          module.processing.view;M6:只取面板编辑的两列
--   pricing_settings    → /tools/pricing/metal-prices 的异常阈值面板  module.pricing.view;M6:只取那一列
--   receiving_settings  → /purchasing/discrepancies 的收货阈值面板   module.inbound.view(面板只画在这一支里);M6:三列
--                    三张都是单行表,主键 id boolean —— M5:页面传 'true',读法按根行自己的类型重建那个键
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第一刀:账上的单据):
--   journal_entry   → /finance/journal/[id]             requireModule(MOD.finance)     = module.finance.view
--   invoice         → /finance/invoices/[id]            requireModule(MOD.finance)     = module.finance.view
--   credit_note     → /finance/credit-notes/[id]        requireModule(MOD.finance)     = module.finance.view
--   payment         → /finance/payments/[id]            requireModule(MOD.finance)     = module.finance.view
--   payment_request → /finance/payment-requests/[id]    requireModule(MOD.finance)     = module.finance.view
--                    (行内转账、代扣税缴纳与它们的冲销也住在这一页 —— 它们没有自己的页,Q17)
--   expense         → /finance/expenses/[id]            requireModule(MOD.finance)     = module.finance.view
--   payable         → /finance/payables/[batchId]       requireModule(MOD.finance)     = module.finance.view
--                    根表是 inbound_batches(读规则 module.inbound.view)—— M3:页面的码是门(Q5,forwarder 的先例);
--                    M6:只取应付那几列(数量、单价、供应商、采购单、计价状态、到货日、注销三列)—— 批次的仓库那一面
--                    (化验、安全状态、库位……)住在 /inbound/[id]/edit 的 inbound_batch 上,不在应付页上再说一遍。
--                    注销那三列必须在里面:M6 丢掉 root_columns 之外的戳(record_trail),不在里面注销就看不见(Q5 的横幅)。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第二刀:其余的单据与合同):
--   sale            → /finance/receivables/[saleId]     requireModule(MOD.finance)     = module.finance.view
--   freight         → /finance/freight/[id]             requireModule(MOD.finance)     = module.finance.view
--                    (根表的读规则是 inbound.view OR finance.view,再加一条 finance.edit 的 ALL —— 页面的码过得了,不需要 M3)
--   fixed_asset     → /finance/assets/[id]              requireModule(MOD.finance)     = module.finance.view
--                    根表与 equipment 同一张 fixed_assets(supplier / forwarder 的先例:一张表两个主语,Q10)——
--                    equipment 的门是加工,这一页的门是财务;根表的读规则就是 finance.view,所以是 'table'
--   bank_statement  → /finance/bank/statements/[id]     requireModule(MOD.finance)     = module.finance.view
--                    删掉的对账单也读得到(Q6:持 data.view_deleted 的人只读打开;根表的读规则不过滤已删的行)
--   gst_period      → /finance/gst/[periodId]           requireModule(MOD.finance)     = module.finance.view
--   fx_rate         → /finance/fx/[id]/edit(只有这一页,Q2)requireModule(MOD.finance) = module.finance.view
--                    撤回了的汇率也读得到(Q7:页面对本来的读者只读打开)
--   management_pack → /finance/packs/[id]               requireModule(MOD.finance)     = module.finance.view
--   contract        → /contracts/[id]                   requireModule(MOD.suppliers)   = module.suppliers.view
--                    根表的读规则按方向:卖方合同要 customers.view、买方合同要 suppliers.view —— 页面在 RLS 下读、读不到就 404,
--                    所以 'table' 与页面同一个答案(看不见的合同对他而言不存在)
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第三刀:期末、设置与清单页上的记录):
--   finance_lock    → /finance/settings 锁期面板之下 · /finance/close 关账史之下(Q25 · Q29)  module.finance.view
--                    根表 finance_settings(单行,id boolean —— M5,页面传 'true');M6:只取 locked_before 一列;
--                    月结 / 反结(period_closes)经 M7 整张表属于这一行(两张表之间一个键都没有,Q3)
--   finance_gst     → /finance/settings GST 面板之下                                       module.finance.view
--                    同一行(M5);M6:只取 gst_registered、gst_registration_no 两列 —— 两块面板各看各的(Q25);
--                    这一行上没有面板的六列(gst_rate_pct · system_start_date · 三个财年列 · default_allocation_basis)
--                    哪一块都不取,只在 /settings/change-history 上找得到(Q4);审批方针那四列归 AT-1d(Q2)
--   company_profile → /finance/company                                                     requireModule(MOD.finance)
--                    单行(M5),整行 —— 一块面板编辑整行;银行那五列按 HISTORY-1 的规则对不持 data.view_banking 的人遮
--   year_close      → /finance/close 年结那一块(清单块,ListTrail)                          module.finance.view
--   journal_request → /finance/journal 每一张申请卡片里(Q17,一张一块)                     module.finance.view
--   expense_claim   → /finance/claims 每一张报销单一块(Q20)                                module.finance.view
--   my_expense_claim → /me 报销人自己那几张(Q20 的另一半)—— ★ M8:没有页面码(view_codes 为空数组),
--                    根行自己那张表的读规则就是门(expense_claims:module.finance.view 或者【这张单说的就是你】);
--                    只许与 'table' 同用(record_trail 里拒绝 'page' —— 那会对每一个人敞开)。
--                    审批留痕那一支(approval_log 的 expense_claim)不给本人开口子,所以本人看到的是 Restricted(Q4)
--   bank_transfer   → /finance/bank 转账那一块(清单块)                                     module.finance.view
--   wht_remittance  → /finance/wht 缴纳那一块(清单块)                                      module.finance.view
--   cash_forecast · cash_forecast_line → /finance/cash-forecast(清单块,Q16:冻结 + 作废旧的一张是一次操作)
--   bank_import_profile → /finance/bank/import(清单块,删掉的也读)                         module.finance.view
--   (重估 / 折旧 / 工资付款 / 加工成本结算的批次与批量汇率【不】另立主语:它们各自的清单块读 journal_entry · expense ·
--    fx_rate 那几个现成主语,Q16 的 op_key 把一次操作并成一条 —— Q18 · Q19)
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第一刀:机制、设置与员工):
--   account         → /settings/accounts 每一行一块(Q24)        requireManagePermissions()     = action.manage_permissions
--                    ★ M9:根表 auth.users 不在 public 里 —— trail_log_only_tables() 给它一份安全投影与声明的读码;
--                    事件(建立 / 停用 / 恢复 / 失败 / 回滚)住在 change_log(record_account_event)
--   approval_policy → /settings/approvals(Q25,1c 的 Q2 挪过来)requireFunction(FN.approvals) = action.manage_permissions
--                    同一行 finance_settings(M5);M6:只取它编辑的四列;修改史 finance_settings_history 经 M7 整张属于这一行。
--                    根表的读规则是 module.finance.view —— 'table':读者两个码都要(线上唯一持 manage_permissions 的 admin 两个都有,Q23)
--   employee        → /hr/employees/[id]                        requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这就是你】—— 与页面同一个答案
--   department      → /hr/departments/[id]/edit(只有这一页)   requireModule(MOD.hr)          = module.hr.view
--   training_record → /hr/training/[id]/edit(只有这一页,Q29) requireModule(MOD.hr)          = module.hr.view
--   import_batch    → /settings/import 的批次一块(清单块,Q24) can('action.bulk_import')      = action.bulk_import
--   dictionary_*    → /settings/dictionaries 每一段一块(Q4)    每一段自己的查看码(registry.ts 的 viewPermission)
--                    ★ M11:'collection' —— 没有根行,那张字典表的每一行、change_log 里它的每一行都属于这一块;根键照写那张表的主键
--                    (code),record_trail 不用它。
--   ☞ M12('gate:reviewer')本刀没有主语用它(它的第一个用户是 AT-1d-3 的 /my-reviews —— 1d-3 已接上,见下面 my_review);fixture 244 用一个临时主语证它。
-- AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第二刀:请假与考勤):
--   leave_request     → /hr/leave/[id]                  requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这张单说的就是你】—— 与页面同一个答案
--   my_leave_request  → /me 本人那几张(Q14,M8:没有页面码 —— 根行自己的读规则就是门;审批与消耗那几行对本人是 Restricted)
--   leave_grant       → /hr/leave/grants 那一块(清单块,按年)         module.hr.view
--   leave_types       → /hr/leave/types(M11 集合,根键 code)         module.hr.view
--   public_holidays   → /hr/leave/holidays(M11 集合 —— 假期是【硬删】的,一行删掉之后只剩变更记录里那一份影像)
--   medical_claim     → /hr/claims/[id]                 requireModule(MOD.hr)          = module.hr.view
--   my_medical_claim  → /me 本人那几张(Q14,M8)
--   overtime_batch    → /hr/overtime/[id]               requireFunction(FN.overtime)   = M1:hr.view · overtime_enter · overtime_approve
--                    (与页面守卫、与 overtime_batches 的读规则逐字同一组码)
--   attendance_period → /hr/attendance/[id]             requireModule(MOD.hr)          = module.hr.view
-- AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第三刀:工资与评审):
--   payroll_period      → /hr/payroll/[id]              requireModule(MOD.hr)          = module.hr.view
--                      根表的读规则是 hr.view —— 与页面同一个答案;工资行的金额对不持 data.view_pay 的人照遮蔽规则说 Restricted
--   performance_review  → /hr/reviews/[id]              requireModule(MOD.hr)          = module.hr.view
--                      根表的读规则是 (hr.view 且 view_reviews) 或审核人 或【这是你的、已批】—— 页面读 performance_reviews_masked,
--                      同一个谓词,读不到就 notFound;所以 auditor / finance(hr.view,不持 view_reviews)两边都进不去
--   my_review           → /my-reviews/[id](审核人那一页,没有模块守卫)  M8 + M12:没有页面码,root_rule 'gate:reviewer' ——
--                      根行先过表的读规则,【再】过 trail_root_gate('reviewer'):只给这一份评审点名的审核人,
--                      不给被评审的本人(他在批准之后经"own approved"那一条读得到行,但这一段不是给他的,Q5)
--   review_cycle        → /hr/reviews/cycles 那一块(清单块,每一轮一条)   module.hr.view(Q6:没有成员 —— 开轮时铺下的那几份评审
--                      不挂进来,轮次那一块只说"开了 / 关了";每一份评审自己的那一段以"Annual review opened (cycle …)"开头)
--   review_rating_scale → /hr/reviews/scale(M11 集合,根键 code)      module.hr.view
--   kpi_entry           → /hr/kpi/score 那一块(清单块,选中那一个月的条目;只在 canSeeScores 那一支里画)  module.hr.view
--                      根表的读规则是 (hr.view 且 view_reviews) 或本人 —— 不持 view_reviews 的读者在页面那一支就进不来
-- 【后面几刀加主语】加一行这里、在 trail_subject_members 里登记它的子行与相关行、需要的话在
--   trail_prelog_sources 里登记"记录开始之前"的来源,然后在 lib/trail/ 里补它的措辞 —— 见 docs/change-log.md §9。
-- MES-1(2026-10-06,MES-1 Step 0 Q21 · Q22,Tim):
--   device          → /operation/devices/[id]           requireModule(MOD.processing) = module.processing.view
--                     成员 gateway_keys(钥匙的发放与撤销;哈希被 never 规则遮住)。收件箱、传输日志与中断不进变更记录(MES-0 Q14),
--                     所以不在这里 —— 设备页把中断单独列成一块(Q21)。
--   ingest_settings → /operation/devices 上的传输上限面板  module.processing.view;单行设置作根(M5),修改史就是变更记录(Q22)
CREATE OR REPLACE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_codes text[], root_table text, root_key text, root_rule text, root_columns text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_order',    ARRAY['module.purchasing.view'],    'purchase_orders',    'id', 'table', NULL::text[]),
        ('processing_run',    ARRAY['module.processing.view'],    'processing_runs',    'id', 'table', NULL),
        ('role',              ARRAY['action.manage_permissions'], 'roles',              'id', 'table', NULL),
        ('inbound_batch',     ARRAY['module.inbound.view'],       'inbound_batches',    'id', 'table', NULL),
        ('output_batch',      ARRAY['module.output.view'],        'output_batches',     'id', 'table', NULL),
        ('work_order',        ARRAY['module.processing.view'],    'work_orders',        'id', 'table', NULL),
        ('stocktake',         ARRAY['module.stocktakes.view'],    'stocktakes',         'id', 'table', NULL),
        ('equipment',         ARRAY['module.processing.view'],    'fixed_assets',       'id', 'page',  NULL),
        ('shift_handover',    ARRAY['module.processing.view'],    'shift_handovers',    'id', 'table', NULL),
        ('warehouse_request', ARRAY['module.inventory.view', 'module.finance.view'], 'warehouse_requests', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-2
        ('quote',             ARRAY['module.sales.view'],         'quotes',             'id', 'table', NULL),
        ('sales_order',       ARRAY['module.sales.view'],         'sales_orders',       'id', 'table', NULL),
        ('shipment',          ARRAY['module.sales.view', 'action.ship_goods'], 'shipments', 'id', 'table', NULL),
        ('customer',          ARRAY['module.customers.view'],     'customers',          'id', 'table', NULL),
        ('commission_agreement', ARRAY['module.suppliers.view'],  'commission_agreements', 'id', 'table', NULL),
        ('supplier',          ARRAY['module.suppliers.view'],     'suppliers',          'id', 'table', NULL),
        ('container',         ARRAY['module.logistics.view'],     'containers',         'id', 'table', NULL),
        ('forwarder',         ARRAY['module.logistics.view'],     'suppliers',          'id', 'page',  NULL),
        ('lane',              ARRAY['module.logistics.view'],     'lanes',              'id', 'table', NULL),
        ('port',              ARRAY['module.logistics.view'],     'ports',              'id', 'table', NULL),
        ('company_licence',   ARRAY['module.suppliers.view'],     'company_compliance', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-3
        ('material',          ARRAY['module.materials.view'],     'materials',          'id', 'table', NULL),
        ('storage_location',  ARRAY['module.inventory.view'],     'storage_locations',  'id', 'table', NULL),
        ('metal_price',       ARRAY['action.metal_prices'],       'metal_prices',       'id', 'table', NULL),
        ('pricing_formula',   ARRAY['module.pricing.view'],       'pricing_formulas',   'id', 'table', NULL),
        ('task',              ARRAY['module.tasks.view'],         'tasks',              'id', 'table', NULL),
        ('processing_settings', ARRAY['module.processing.view'],  'processing_settings', 'id', 'table',
            ARRAY['wo_input_overrun_pct', 'wo_output_shortfall_pct']),
        ('pricing_settings',  ARRAY['module.pricing.view'],       'pricing_settings',   'id', 'table',
            ARRAY['metal_price_change_warn_pct']),
        ('receiving_settings', ARRAY['module.inbound.view'],      'receiving_settings', 'id', 'table',
            ARRAY['grn_short_pct', 'grn_over_pct', 'grn_assay_tolerance_pct']),
        -- AUDIT-TRAIL-1c-1
        ('journal_entry',     ARRAY['module.finance.view'],       'journal_entries',    'id', 'table', NULL),
        ('invoice',           ARRAY['module.finance.view'],       'invoices',           'id', 'table', NULL),
        ('credit_note',       ARRAY['module.finance.view'],       'credit_notes',       'id', 'table', NULL),
        ('payment',           ARRAY['module.finance.view'],       'payments',           'id', 'table', NULL),
        ('payment_request',   ARRAY['module.finance.view'],       'payment_requests',   'id', 'table', NULL),
        ('expense',           ARRAY['module.finance.view'],       'expenses',           'id', 'table', NULL),
        ('payable',           ARRAY['module.finance.view'],       'inbound_batches',    'id', 'page',
            ARRAY['supplier_id', 'purchase_order_id', 'quantity', 'unit', 'unit_price', 'pricing_status', 'arrival_date',
                  'deleted_at', 'deleted_by', 'delete_reason']),
        -- AUDIT-TRAIL-1c-2
        ('sale',              ARRAY['module.finance.view'],       'sales_records',      'id', 'table', NULL),
        ('freight',           ARRAY['module.finance.view'],       'freight_documents',  'id', 'table', NULL),
        ('fixed_asset',       ARRAY['module.finance.view'],       'fixed_assets',       'id', 'table', NULL),
        ('bank_statement',    ARRAY['module.finance.view'],       'bank_statements',    'id', 'table', NULL),
        ('gst_period',        ARRAY['module.finance.view'],       'gst_periods',        'id', 'table', NULL),
        ('fx_rate',           ARRAY['module.finance.view'],       'fx_rates',           'id', 'table', NULL),
        ('management_pack',   ARRAY['module.finance.view'],       'management_packs',   'id', 'table', NULL),
        ('contract',          ARRAY['module.suppliers.view'],     'contracts',          'id', 'table', NULL),
        -- AUDIT-TRAIL-1c-3
        ('finance_lock',      ARRAY['module.finance.view'],       'finance_settings',   'id', 'table', ARRAY['locked_before']),
        ('finance_gst',       ARRAY['module.finance.view'],       'finance_settings',   'id', 'table',
            ARRAY['gst_registered', 'gst_registration_no']),
        ('company_profile',   ARRAY['module.finance.view'],       'company_profile',    'id', 'table', NULL),
        ('year_close',        ARRAY['module.finance.view'],       'year_closes',        'id', 'table', NULL),
        ('journal_request',   ARRAY['module.finance.view'],       'journal_requests',   'id', 'table', NULL),
        ('expense_claim',     ARRAY['module.finance.view'],       'expense_claims',     'id', 'table', NULL),
        ('my_expense_claim',  ARRAY[]::text[],                    'expense_claims',     'id', 'table', NULL),
        ('bank_transfer',     ARRAY['module.finance.view'],       'bank_transfers',     'id', 'table', NULL),
        ('wht_remittance',    ARRAY['module.finance.view'],       'wht_remittances',    'id', 'table', NULL),
        ('cash_forecast',     ARRAY['module.finance.view'],       'cash_forecasts',     'id', 'table', NULL),
        ('cash_forecast_line', ARRAY['module.finance.view'],      'cash_forecast_lines', 'id', 'table', NULL),
        ('bank_import_profile', ARRAY['module.finance.view'],     'bank_import_profiles', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-1
        ('account',           ARRAY['action.manage_permissions'], 'auth.users',         'id', 'table', NULL),
        ('approval_policy',   ARRAY['action.manage_permissions'], 'finance_settings',   'id', 'table',
            ARRAY['approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code']),
        ('employee',          ARRAY['module.hr.view'],            'employees',          'id', 'table', NULL),
        ('department',        ARRAY['module.hr.view'],            'departments',        'id', 'table', NULL),
        ('training_record',   ARRAY['module.hr.view'],            'training_records',   'id', 'table', NULL),
        ('import_batch',      ARRAY['action.bulk_import'],        'import_batches',     'id', 'table', NULL),
        ('dictionary_substances',          ARRAY['module.materials.view'], 'substances',             'code', 'collection', NULL),
        ('dictionary_battery_chemistries', ARRAY['module.materials.view'], 'battery_chemistries',    'code', 'collection', NULL),
        ('dictionary_material_kinds',      ARRAY['module.materials.view'], 'material_kinds',         'code', 'collection', NULL),
        ('dictionary_inbound_safety_states', ARRAY['module.materials.view'], 'inbound_safety_states', 'code', 'collection', NULL),
        ('dictionary_laboratories',        ARRAY['module.inbound.view'],   'laboratories',           'code', 'collection', NULL),
        ('dictionary_inbound_source_reasons', ARRAY['module.inbound.view'], 'inbound_source_reasons', 'code', 'collection', NULL),
        -- MES-3a(2026-10-06,MES-3a Step 0 Q4 · Q12):NEA 废物类别字典 —— 与其余六本同一个形状(清单块,/settings/dictionaries)
        ('dictionary_nea_waste_categories', ARRAY['module.materials.view'], 'nea_waste_categories', 'code', 'collection', NULL),
        -- MES-3b(2026-10-07):危险品 UN 编号字典(module.materials.view)· 标签模板字典(module.inventory.view)
        ('dictionary_dangerous_goods_codes', ARRAY['module.materials.view'], 'dangerous_goods_codes', 'code', 'collection', NULL),
        ('dictionary_label_templates',      ARRAY['module.inventory.view'], 'label_templates',       'code', 'collection', NULL),
        -- MES-4a(2026-10-07,MES-4a Step 0 Q33):一道工序 —— 它的参数与指标、挂着的机器、配方与每一版、容差(根行自己那几列);
        --   页面 /operation/operation-types/[code],门 module.processing.view;根键 code(成员按 operation_type_code 挂在它下面)。
        --   异常事件种类字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('operation_type',    ARRAY['module.processing.view'],    'operation_types',    'code', 'table', NULL),
        ('dictionary_processing_event_types', ARRAY['module.processing.view'], 'processing_event_types', 'code', 'collection', NULL),
        --   班次字典 —— MES-4a 把它放进 /settings/dictionaries(新的"时刻"字段:V6 · V7 的去处),于是它也有一段清单块的记录。
        ('dictionary_shifts', ARRAY['module.processing.view'], 'shifts', 'code', 'collection', NULL),
        -- MES-4b(2026-10-07,MES-4b Step 0 Q3 · Q21):电芯结构字典与交叉污染流字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('dictionary_cell_constructions', ARRAY['module.processing.view'], 'cell_constructions', 'code', 'collection', NULL),
        ('dictionary_contamination_streams', ARRAY['module.processing.view'], 'contamination_streams', 'code', 'collection', NULL),
        -- AUDIT-TRAIL-1d-2
        ('leave_request',     ARRAY['module.hr.view'],            'leave_requests',     'id', 'table', NULL),
        ('my_leave_request',  ARRAY[]::text[],                    'leave_requests',     'id', 'table', NULL),
        ('leave_grant',       ARRAY['module.hr.view'],            'leave_grants',       'id', 'table', NULL),
        ('leave_types',       ARRAY['module.hr.view'],            'leave_types',        'code', 'collection', NULL),
        ('public_holidays',   ARRAY['module.hr.view'],            'public_holidays',    'id', 'collection', NULL),
        ('medical_claim',     ARRAY['module.hr.view'],            'medical_claims',     'id', 'table', NULL),
        ('my_medical_claim',  ARRAY[]::text[],                    'medical_claims',     'id', 'table', NULL),
        ('overtime_batch',    ARRAY['module.hr.view', 'action.overtime_enter', 'action.overtime_approve'], 'overtime_batches', 'id', 'table', NULL),
        ('attendance_period', ARRAY['module.hr.view'],            'attendance_periods', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-3
        ('payroll_period',      ARRAY['module.hr.view'],          'payroll_periods',     'id', 'table', NULL),
        ('performance_review',  ARRAY['module.hr.view'],          'performance_reviews', 'id', 'table', NULL),
        ('my_review',           ARRAY[]::text[],                  'performance_reviews', 'id', 'gate:reviewer', NULL),
        ('review_cycle',        ARRAY['module.hr.view'],          'review_cycles',       'id', 'table', NULL),
        ('review_rating_scale', ARRAY['module.hr.view'],          'review_rating_scale', 'code', 'collection', NULL),
        ('kpi_entry',           ARRAY['module.hr.view'],          'kpi_entries',         'id', 'table', NULL),
        -- MES-1
        ('device',              ARRAY['module.processing.view'],  'devices',             'id', 'table', NULL),
        ('ingest_settings',     ARRAY['module.processing.view'],  'ingest_settings',     'id', 'table', NULL),
        -- MES-2(2026-10-06,MES-2 Step 0 Q33):地磅单 —— 收货或物流查看码任一(与表的读策略逐字同一对,Q22)
        ('weighbridge_ticket',  ARRAY['module.inbound.view', 'module.logistics.view'], 'weighbridge_tickets', 'id', 'table', NULL)
    ) AS s(subject, view_codes, root_table, root_key, root_rule, root_columns);
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
        ('output_batch',      39, 'contamination_checks',       'output_batches',   'output_batch_id',     '{}'::jsonb, 'down', true, false)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- db/functions/generate_device_code.sql
-- MES-1(2026-10-06,Q28):设备编号 DEV-YYYY-NNNN —— 有洞(nextval 回滚不还号),保存时生成。
-- 形状与 generate_task_code 逐字同一个(前缀经 document_type_prefix('device') 读,年取 NOW(),四位补零);
-- 只填空的 code。不是 SECURITY DEFINER:它是 devices 的 BEFORE INSERT 触发器,插入只经 save_device。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.generate_device_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
        NEW.code := document_type_prefix('device') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('device_code_seq')::TEXT AS n) s);
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/generate_weighbridge_ticket_code.sql
-- MES-2(2026-10-06,MES-0 Q53;MES-2 Step 0 Q16):地磅单编号 WB-YYYY-NNNN —— 有洞(nextval 回滚不还号),保存时生成。
-- 形状与 generate_device_code 逐字同一个(前缀经 document_type_prefix('weighbridge_ticket') 读,年取 NOW(),四位补零);
-- 只填空的 code。不是 SECURITY DEFINER:它是 weighbridge_tickets 的 BEFORE INSERT 触发器,插入只经确认 / 手工录入那几支函数。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.generate_weighbridge_ticket_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        -- MES-4b(CODE-WIDTH-4,Step 0 Q14):补到 4 位、【不截断】—— 超过 9,999 照实长出去;低于 10,000 的号逐字不变。
        NEW.code := document_type_prefix('weighbridge_ticket') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    (SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('weighbridge_ticket_code_seq')::TEXT AS n) s);
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 15 · 签名变了的两支:DROP 旧的、CREATE 新的(末尾一个可缺省的参数)────────────────────────

DROP FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text);

-- db/functions/create_inbound_batch.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19,Tim):末尾多三个参数(p_ticket_id · p_ticket_share_kg · p_quantity_reason),都带默认值 ——
--   签名变了,所以迁移是 DROP + CREATE(preflight 不许 CREATE OR REPLACE 换签名);已部署的旧应用不传它们,照样解析到这一支。
-- MES-3a(2026-10-06,MES-3a Step 0 Q9 · Q10 · Q19,Tim):写入之前过隔离闸(请求里带着要隔离的状态,就只能收进隔离库位);
--   落库之后对着执照的库存上限判一次并记下来(receipt_ceiling_check_internal)。签名不变;返回值多一个 'ceiling'(那一行)。
-- MES-4b(2026-10-07,MES-4b Step 0 Q4,Tim):末尾多一个可缺省的参数 p_cell_construction(电芯结构,收货时可选;空 = 没记)——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它,照样解析到这一支。适用性与锁由表上的 guard_batch_cell_construction 判。

CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_currency text DEFAULT NULL::text, p_ticket_id uuid DEFAULT NULL::uuid, p_ticket_share_kg numeric DEFAULT NULL::numeric, p_quantity_reason text DEFAULT NULL::text, p_cell_construction text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ceiling jsonb;
    v_user    uuid := auth.uid();
    v_id      uuid;
    v_warn    text[];
    v_pricing jsonb := NULL;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q1):建收货单归仓库 —— action.receive_goods
    --   (warehouse · admin),不再是 module.inbound.edit。先问它,所以拒绝点名的是它;带价那一支另外
    --   还要 action.price_receipts + data.view_purchase_prices(下面,不变 —— Batch 3b Q5)。
    PERFORM require_permission('action.receive_goods');
    -- ★ ROLE-1 Batch 4a(grilling Q4):建单【带价】就是定价 —— 要 action.price_receipts 与
    --   data.view_purchase_prices,在【写入之前】按名拒,整笔建单回滚;绝不悄悄丢掉那个价。
    --   不带价的建单只要 module.inbound.edit(仓库照建)。
    IF p_unit_price IS NOT NULL THEN
        PERFORM require_permission('action.price_receipts');
        PERFORM require_permission('data.view_purchase_prices');
    END IF;

    -- IOD-2-fu1:到货日【按名】必填。不写这一句,漏出去的是 FIN-32 的约束原文。
    -- 【不给默认值】:CURRENT_DATE 会让留空比填对更容易通过。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- MES-2(Tim 2026-10-06,MES-0 Q21 · MES-2 Step 0 Q19):建单【那一刻】挂一张地磅单的份 —— 数量默认 = 这一份,
    --   人填了别的数要写理由(收货单两个都留着:份的公斤数在 weighbridge_ticket_shares,数量在这里)。写入之前按名拒。
    IF p_ticket_id IS NULL AND (p_ticket_share_kg IS NOT NULL OR p_quantity_reason IS NOT NULL) THEN
        RAISE EXCEPTION 'TICKET_SHARE_WITHOUT_TICKET';
    END IF;
    IF p_ticket_id IS NOT NULL THEN
        IF COALESCE(p_unit, 'kg') <> 'kg' THEN
            RAISE EXCEPTION 'RECEIPT_TICKET_NEEDS_KG|%', p_unit;
        END IF;
        IF p_ticket_share_kg IS NULL OR p_ticket_share_kg <= 0 THEN
            RAISE EXCEPTION 'TICKET_SHARE_KG_INVALID';
        END IF;
        IF p_quantity IS DISTINCT FROM p_ticket_share_kg AND btrim(COALESCE(p_quantity_reason, '')) = '' THEN
            RAISE EXCEPTION 'RECEIPT_QUANTITY_REASON_REQUIRED|%|%', p_quantity, p_ticket_share_kg;
        END IF;
    END IF;

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q19,Tim):带着要隔离的状态(鼓包或漏液)只能收进一个在用的隔离库位 ——
    --   读的是【请求里】的状态(状态在落库之后才写,所以不能等它们),写入之前按名拒 QUARANTINE_LOCATION_REQUIRED。
    PERFORM assert_quarantine_landing(p_safety_states, p_location_id);

    -- GRN-1a:p_declared_qty 原样落库,【不拒绝任何差异】,也【绝不从采购行推断】。
    -- PROC-2c:确定度随表头一起落 —— 适用性由 trg_inbound_batches_condition_applicable
    -- 判(它在库里,所以这条路、批次页面、直连 SQL 三条一起盖住)。
    -- RECV-SOURCE-1:理由原样落库,拒绝(RECEIPT_SOURCE_REQUIRED /
    -- SOURCE_REASON_EXPLANATION_REQUIRED)由 guard_receipt_source_stated 抛 ——
    -- 本函数一个字都不重复它们,重复一遍就是第二份会漂开的判断。
    -- INB-PAY-1:unit_price 【不在这里落】—— 见下面定价那一段。
    -- MES-4b(Q4):电芯结构可选;给了就必须是一个在用的值(写入之前按名拒,不让外键报一串约束名)。
    IF NULLIF(btrim(COALESCE(p_cell_construction, '')), '') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM cell_constructions c WHERE c.code = btrim(p_cell_construction) AND c.is_active) THEN
        RAISE EXCEPTION 'CELL_CONSTRUCTION_UNKNOWN|%', btrim(p_cell_construction);
    END IF;

    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, notes, purchase_order_id, purchase_order_line_id,
        declared_qty, chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by, cell_construction_code)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_notes, p_purchase_order_id, p_purchase_order_line_id,
        p_declared_qty, p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user, NULLIF(btrim(COALESCE(p_cell_construction, '')), ''))
    RETURNING id INTO v_id;

    -- PROC-2c:安全状态【只在给了参数时才碰】。
    -- 【NULL 与 '{}' 在这里是两件事】NULL = "这条路没提这件事"(既有调用点),
    -- '{}' = "明说了:一个状态都没有"。两者结果相同(零行),但只有前者
    -- 保证【一个字节都不动】—— F1 钉的正是这个。
    IF p_safety_states IS NOT NULL THEN
        PERFORM set_inbound_safety_states(v_id, p_safety_states);
    END IF;

    -- 用毕即清 —— 同 commit_processing_run 的 movement_ctx:免得同事务内后续的
    -- 插入把这个库位当成自己的(那正是 ctx 这种机制唯一的锋利处)。
    PERFORM set_config('evoltrya.location_ctx', '', true);

    -- MES-3a(2026-10-06,MES-0 Q32 · Q33;MES-3a Step 0 Q5–Q10,Tim):对着执照的库存上限判一次,并且【每一张都记下来】
    --   (receipt_ceiling_checks)。在落库之后判 —— 这一批的入库流水已经在存量里;超过一个给了的上限就按名拒
    --   STORAGE_CEILING_EXCEEDED,整笔回滚。没给上限 / 没有类别 / 没有在效执照:照收,记下是哪一种。
    v_ceiling := receipt_ceiling_check_internal(v_id, NULL);

    -- MES-2:地磅单的份【先于】定价落下 —— 建单带价时的定价会过校准闸,闸要看得见这张单的读数。
    IF p_ticket_id IS NOT NULL THEN
        PERFORM weighbridge_share_internal(p_ticket_id, v_id, NULL, p_ticket_share_kg,
                                           CASE WHEN p_quantity IS DISTINCT FROM p_ticket_share_kg THEN p_quantity_reason END);
    END IF;

    -- INB-PAY-1:建单带价 = 建单 + 定价,【同一事务】。
    -- ★ ROLE-1 Batch 4b(Tim 的 Q4):建单带价从此是【建单(不带价)+ 同一事务里提一张定价申请】
    --   (来源 desk)—— CFO 批了才进账;收货页上看得见它在等 CFO。提交时照批准那一刻的同一支过账
    --   试跑,所以非正价格、非法币种、缺牌价照旧按名拒,任何一条拒绝都让整笔建单回滚。
    --   审批关着时申请生下来就是 approved 并当场过账(与从前一样一步到位)。
    IF p_unit_price IS NOT NULL THEN
        v_pricing := receipt_price_submit_internal(v_id, p_unit_price, p_currency, 'desk', NULL, NULL, NULL);
    END IF;

    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    -- INB-PAY-1:定价的分解随之返回;不带价时为 null。ROLE-1 Batch 4b 起它是那张申请
    -- (request_id / label / status;审批关着时还有 journal_code)。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn),
                              'pricing', v_pricing, 'ceiling', v_ceiling);
END;
$function$

;

DROP FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text);

-- db/functions/receive_inbound_batch_against_po.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19,Tim):末尾多三个参数(p_ticket_id · p_ticket_share_kg · p_quantity_reason),都带默认值 ——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它们,照样解析到这一支。
-- MES-3a(2026-10-06,MES-3a Step 0 Q9 · Q10 · Q19,Tim):写入之前过隔离闸(请求里带着要隔离的状态,就只能收进隔离库位);
--   落库之后对着执照的库存上限判一次并记下来(receipt_ceiling_check_internal)。签名不变;返回值多一个 'ceiling'(那一行)。
-- MES-4b(2026-10-07,MES-4b Step 0 Q4,Tim):末尾多一个可缺省的参数 p_cell_construction(电芯结构,收货时可选;空 = 没记)——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它,照样解析到这一支。适用性与锁由表上的 guard_batch_cell_construction 判。

CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_ticket_id uuid DEFAULT NULL::uuid, p_ticket_share_kg numeric DEFAULT NULL::numeric, p_quantity_reason text DEFAULT NULL::text, p_cell_construction text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ceiling jsonb;
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q1):现场收货归仓库 —— action.receive_goods。
    PERFORM require_permission('action.receive_goods');

    -- IOD-2-fu1:同上 —— 现场收货这条路一样进得到 FIN-32 的约束。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- MES-2(MES-2 Step 0 Q19):见 create_inbound_batch 里同一段 —— 份在建单那一刻给,数量与份不同要写理由。
    IF p_ticket_id IS NULL AND (p_ticket_share_kg IS NOT NULL OR p_quantity_reason IS NOT NULL) THEN
        RAISE EXCEPTION 'TICKET_SHARE_WITHOUT_TICKET';
    END IF;
    IF p_ticket_id IS NOT NULL THEN
        IF p_ticket_share_kg IS NULL OR p_ticket_share_kg <= 0 THEN
            RAISE EXCEPTION 'TICKET_SHARE_KG_INVALID';
        END IF;
        IF p_quantity IS DISTINCT FROM p_ticket_share_kg AND btrim(COALESCE(p_quantity_reason, '')) = '' THEN
            RAISE EXCEPTION 'RECEIPT_QUANTITY_REASON_REQUIRED|%|%', p_quantity, p_ticket_share_kg;
        END IF;
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q19,Tim):带着要隔离的状态(鼓包或漏液)只能收进一个在用的隔离库位 ——
    --   读的是【请求里】的状态(状态在落库之后才写,所以不能等它们),写入之前按名拒 QUARANTINE_LOCATION_REQUIRED。
    PERFORM assert_quarantine_landing(p_safety_states, p_location_id);

    -- 单位固定 kg、stage 用默认值 —— 与收货表单今天的行为逐字一致。
    -- 【采购单侧的那一串拒绝(PO_NOT_RECEIVABLE / PO_LINE_MISMATCH /
    --  PO_NOT_APPROVED / SUPPLIER_QUALIFICATION_EXPIRED)仍由表上的触发器抛出】,
    -- 这个函数一个字都不重复它们 —— 重复一遍就是第二份会漂开的判断。
    -- RECV-SOURCE-1 的两条拒绝(RECEIPT_SOURCE_REQUIRED / PO_HEADER_WITHOUT_LINE)
    -- 同一条:触发器抛,这里不抄。
    -- 【GRN-1a:收错料【不拒绝】】—— 换料是一个正当的、可以谈成的场景,
    -- 而拒绝会把它变成一次不可能完成的收货。它由 grn_discrepancies 点名
    -- (material_mismatch),由人去判断。
    -- MES-4b(Q4):电芯结构可选;给了就必须是一个在用的值(写入之前按名拒,不让外键报一串约束名)。
    IF NULLIF(btrim(COALESCE(p_cell_construction, '')), '') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM cell_constructions c WHERE c.code = btrim(p_cell_construction) AND c.is_active) THEN
        RAISE EXCEPTION 'CELL_CONSTRUCTION_UNKNOWN|%', btrim(p_cell_construction);
    END IF;

    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        notes, purchase_order_id, purchase_order_line_id, declared_qty,
        chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by, cell_construction_code)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, p_quantity, 'kg', p_arrival_date,
        p_notes, p_purchase_order_id, p_purchase_order_line_id, p_declared_qty,
        p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user, NULLIF(btrim(COALESCE(p_cell_construction, '')), ''))
    RETURNING id INTO v_id;

    -- PROC-2c:见 create_inbound_batch 里同一段注释 —— NULL 与 '{}' 是两件事。
    IF p_safety_states IS NOT NULL THEN
        PERFORM set_inbound_safety_states(v_id, p_safety_states);
    END IF;

    PERFORM set_config('evoltrya.location_ctx', '', true);

    -- MES-3a(2026-10-06,MES-0 Q32 · Q33;MES-3a Step 0 Q5–Q10,Tim):对着执照的库存上限判一次,并且【每一张都记下来】
    --   (receipt_ceiling_checks)。在落库之后判 —— 这一批的入库流水已经在存量里;超过一个给了的上限就按名拒
    --   STORAGE_CEILING_EXCEEDED,整笔回滚。没给上限 / 没有类别 / 没有在效执照:照收,记下是哪一种。
    v_ceiling := receipt_ceiling_check_internal(v_id, NULL);
    IF p_ticket_id IS NOT NULL THEN
        PERFORM weighbridge_share_internal(p_ticket_id, v_id, NULL, p_ticket_share_kg,
                                           CASE WHEN p_quantity IS DISTINCT FROM p_ticket_share_kg THEN p_quantity_reason END);
    END IF;
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn), 'ceiling', v_ceiling);
END;
$function$

;

-- ── 16 · 视图(镜像原样):平衡视图末尾加一列 · 交叉污染三张新的 · 待补的值与提醒 ──────────────────────

-- db/views/processing_run_balance_all.sql
-- MES-4a(2026-10-07,规格 §4.1;MES-0 Q46–Q48;MES-4a Step 0 Q17–Q22,Tim):【一炉的物料平衡,一份算术】—— 基视图,不给人读。
--   投入(表头 total_input)= 产出(表头 total_output)+ 有名字的损耗(每一类更正链末端之和)+ 余数。余数就是"没解释的质量"。
--   balance_state:
--     reversed        已回滚 / 已删 —— 不进任何清单
--     not_applicable  状态改变型(放电):投入恒等于产出、损耗恒为 0,没有平衡可结(Q20)
--     before_closure  开始时刻为空 = MES-4a 之前记下的单:不能结、不进清单,不回填(Q21)
--     closed          最新一次结平【还是当前的】—— 它之后没有更晚的损耗行、值行(按 id 水位线,Q19)
--     open            其余:还没结,或结过而被之后的更正重开
--   required_missing:这道工序上必填、启用着、而这一炉没有当前值的字段码(结平时拒,Q11)。
--   outputs_unweighed:没挂称重的产出腿条数(结平时拒,Q22 —— MES-4a 之后的单按构造是 0)。
--   tolerance_pct:这道工序【此刻】的容差(为空 = Not yet set);within_tolerance:余数的绝对值不超过 投入 × 容差%(容差为空时 NULL)。
--   derived_loss_qty(MES-4b,Step 0 Q20):有名字的损耗里【算出来的】那一截(basis = derived 的当前行之和)。算术不变 ——
--   算出来的就是又一笔有名字的损耗,余数 = 投入 − 产出 − 有名字的损耗(不分 basis);面板单独报出这一截。列只在末尾加。
--   【一份算术三个读者】close_run_balance(以属主身份读它)· processing_run_balance(带门的外壳,加工单页与清单读)·
--   operations_now 的 processing_balance_unclosed 与月末那一行(processing_runs_unclosed_balance)。
--   【属主视图、不带谓词、SELECT 从 authenticated 收回】—— 读者经 processing_run_balance。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE VIEW public.processing_run_balance_all WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    r.status,
    r.operation_type_code,
    k.produces_outputs,
    r.started_at,
    r.total_input AS input_qty,
    r.total_output AS output_qty,
    r.loss_qty,
    COALESCE(nl.named_loss_qty, 0::numeric) AS named_loss_qty,
    r.total_input - r.total_output - COALESCE(nl.named_loss_qty, 0::numeric) AS remainder_qty,
    ot.balance_tolerance_pct AS tolerance_pct,
        CASE
            WHEN ot.balance_tolerance_pct IS NULL THEN NULL::boolean
            ELSE abs(r.total_input - r.total_output - COALESCE(nl.named_loss_qty, 0::numeric)) <= (r.total_input * ot.balance_tolerance_pct / 100::numeric)
        END AS within_tolerance,
    COALESCE(ow.outputs_total, 0::bigint) AS outputs_total,
    COALESCE(ow.outputs_unweighed, 0::bigint) AS outputs_unweighed,
    COALESCE(rq.required_missing, ARRAY[]::text[]) AS required_missing,
    lc.id AS last_closure_id,
    lc.closed_at AS last_closed_at,
    (lc.id IS NOT NULL AND COALESCE(mx.max_loss_id, 0::bigint) <= lc.loss_watermark AND COALESCE(mx.max_value_id, 0::bigint) <= lc.value_watermark) AS closure_current,
        CASE
            WHEN r.status <> 'committed'::text OR r.deleted_at IS NOT NULL THEN 'reversed'::text
            WHEN NOT k.produces_outputs THEN 'not_applicable'::text
            WHEN r.started_at IS NULL THEN 'before_closure'::text
            WHEN lc.id IS NOT NULL AND COALESCE(mx.max_loss_id, 0::bigint) <= lc.loss_watermark AND COALESCE(mx.max_value_id, 0::bigint) <= lc.value_watermark THEN 'closed'::text
            ELSE 'open'::text
        END AS balance_state,
    COALESCE(mx.max_loss_id, 0::bigint) AS max_loss_id,
    COALESCE(mx.max_value_id, 0::bigint) AS max_value_id,
    COALESCE(nl.derived_loss_qty, 0::numeric) AS derived_loss_qty
   FROM processing_runs r
     LEFT JOIN operation_types ot ON ot.code = r.operation_type_code
     LEFT JOIN operation_kinds k ON k.code = ot.kind_code
     LEFT JOIN LATERAL ( SELECT sum(l.quantity) AS named_loss_qty,
            sum(l.quantity) FILTER (WHERE l.basis = 'derived'::text) AS derived_loss_qty
           FROM processing_run_losses l
          WHERE l.run_id = r.id AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = l.id))) nl ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS outputs_total,
            count(*) FILTER (WHERE po.weighing_id IS NULL) AS outputs_unweighed
           FROM processing_outputs po
          WHERE po.run_id = r.id) ow ON true
     LEFT JOIN LATERAL ( SELECT array_agg(f.field_code ORDER BY f.sort_order, f.field_code) AS required_missing
           FROM operation_type_fields f
          WHERE f.operation_type_code = r.operation_type_code AND f.is_required AND f.is_active
            AND NOT (EXISTS ( SELECT 1
                   FROM processing_run_values v
                  WHERE v.run_id = r.id AND v.field_code = f.field_code
                    AND num_nonnulls(v.value_number, v.value_text, v.value_bool) > 0
                    AND NOT (EXISTS ( SELECT 1
                           FROM processing_run_values x
                          WHERE x.corrects_id = v.id))))) rq ON true
     LEFT JOIN LATERAL ( SELECT c.id, c.closed_at, c.loss_watermark, c.value_watermark
           FROM processing_run_closures c
          WHERE c.run_id = r.id
          ORDER BY c.id DESC
         LIMIT 1) lc ON true
     LEFT JOIN LATERAL ( SELECT ( SELECT max(l.id) AS max
                   FROM processing_run_losses l
                  WHERE l.run_id = r.id) AS max_loss_id,
            ( SELECT max(v.id) AS max
                   FROM processing_run_values v
                  WHERE v.run_id = r.id) AS max_value_id) mx ON true;

COMMENT ON VIEW public.processing_run_balance_all IS
    'MES-4a:一炉的物料平衡(规格 §4.1)—— 投入 · 产出 · 有名字的损耗 · 余数 · 此刻的容差与判断 · 缺的必填值 · 没称重的产出 · 最新结平是否当前 · balance_state(reversed / not_applicable / before_closure / closed / open)。基视图,不给人读:读者经 processing_run_balance;结平与两支清单以属主身份读它。';

REVOKE ALL ON public.processing_run_balance_all FROM authenticated, anon;

-- db/views/processing_run_balance.sql
-- MES-4a(2026-10-07,MES-4a Step 0 Q19 · Q22,Tim):【一炉的物料平衡 —— 带门的外壳】。加工单页的平衡面板、加工单清单的那一栏读它。
--   门与 processing_runs 的读规则同一个码(module.processing.view);算术在 processing_run_balance_all,这里一个字都不重算。
--   MES-4b:末尾多一列 derived_loss_qty(有名字的损耗里算出来的那一截,Step 0 Q20)。
--   属主权限:基视图从 authenticated 收回了;视图读视图走属主替换(AGENTS.md「属主视图替得了表」)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE VIEW public.processing_run_balance WITH (security_invoker = off) AS
 SELECT run_id,
    run_code,
    process_date,
    status,
    operation_type_code,
    produces_outputs,
    started_at,
    input_qty,
    output_qty,
    loss_qty,
    named_loss_qty,
    remainder_qty,
    tolerance_pct,
    within_tolerance,
    outputs_total,
    outputs_unweighed,
    required_missing,
    last_closure_id,
    last_closed_at,
    closure_current,
    balance_state,
    derived_loss_qty
   FROM processing_run_balance_all
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_run_balance IS
    'MES-4a:一炉的物料平衡,带门(module.processing.view)。算术全在 processing_run_balance_all。';

GRANT SELECT ON public.processing_run_balance TO authenticated;
REVOKE ALL ON public.processing_run_balance FROM anon;

-- db/views/material_lookup.sql
-- FIX-1 item 3(2026-09-05):物料的【查名】视图 —— id / 编号 / 名称。
-- 收货、产出与化验三处表单用它把单据指向一种物料;化验成分、规格、安全库存
-- 与废物分类【不出现】—— 那些是物料主数据的内容,不是叫出名字要的东西。
-- ★ 暴露面【就是】下面的列清单。
-- NOTE: introduced by db/migrations/2026-09-05-fix1-cross-module-lookup-views.sql.

-- ★ FIX-2a(2026-09-05):体内谓词放宽/修正,列未改动。
--   替换用的是 -- ★ FIX-2a(2026-09-05):体内谓词放宽/修正,列未改动。
--   替换用的是 -- ★ FIX-2a(2026-09-05):体内谓词放宽/修正,列未改动。
--   替换用的是 CREATE OR REPLACE VIEW,而它【会丢掉 WITH (...)】——
--   迁移末尾因此补了一句 ALTER VIEW ... SET (security_invoker = off)。

-- MES-4b(2026-10-07,MES-4b Step 0 Q4):末尾多一列 form_code —— 收货表单与批次页据它判"这一批装不装电芯"
--   (电芯结构那一格只对 implies_dismantling 的形态摆出来;页面与库里的守卫给同一个答案)。形态是一个字典码,不是成分或价。
CREATE OR REPLACE VIEW public.material_lookup WITH (security_invoker = off) AS
 SELECT m.id,
    m.code,
    m.name,
    m.deleted_at,
    m.unit,
    m.kind_code,
    k.name_en AS kind_name_en,
    k.name_zh AS kind_name_zh,
    m.waste_classification_code,
    m.form_code
   FROM materials m
     LEFT JOIN material_kinds k ON k.code = m.kind_code
  WHERE has_permission('module.materials.view'::text) OR has_permission('module.inbound.view'::text) OR has_permission('module.output.view'::text) OR has_permission('module.inventory.view'::text) OR has_permission('module.purchasing.view'::text) OR has_permission('module.processing.view'::text);

COMMENT ON VIEW public.material_lookup IS
    'FIX-1 item 3:物料的【查名】视图 —— 只有 id/编号/名称。收货、产出与化验表单用它把单据指向一种物料,而【不】因此拿到化验成分、规格、安全库存或废物分类。属主权限 + 体内谓词 materials.view OR inbound.view OR output.view;新读到它的只有 warehouse(operations 本来就持 materials.view)。暴露面就是这张视图的列清单。';

-- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q8 · Batch 3b grilling Q4):谓词加 module.processing.view ——
--   建工单、提交加工与加工单详情三页改读本视图(不读 materials),仓库拿 processing.view 而【不】拿 materials.view;
--   加工页不该靠一个不相干的码(inbound.view)碰巧读得到物料名。列清单不变。
GRANT SELECT ON public.material_lookup TO authenticated;

-- db/views/contamination_shift_status_all.sql
-- MES-4b(2026-10-07,规格 §3.4 "at least once per shift";MES-0 Q52;MES-4b Step 0 Q21–Q24,Tim):【每一个班、每一条流,抽过没有】—— 基视图,不给人读。
--   一行 = (加工日, 班次, 流):那一天那一班有一张 MES-4a 起记的、已提交没回滚的加工单产出了这条流的极片(contamination_streams.sheet_form_code)。
--   check_state:checked(有一条当前的 sampled)· not_sampled(只有当前的 not_sampled —— 没抽,有理由)· missing(一条当前的抽检都没有)。
--   抽检挂在哪一张单上都算(同一天同一班的任何一张);只算已提交没回滚的单上的、没被更正过的那一条。班次读自那一炉(不另存)。
--   first_run_id / first_run_code:这一格最早的那一炉(按开始时刻、再按单号)—— 提醒臂点进去的那一张(fixture 47 的行号规矩)。
--   max_rate_pct / any_above_warning:当前 sampled 里最高的污染率,以及有没有一条超过它记录时的警戒线(都判不了时 NULL)。
--   【一份算术两个读者】contamination_shift_status(带门的外壳,/operation/contamination 读)· operations_now 的 contamination_check_missing。
--   MES-4a 之前的单没有班次,永远不出现。与物料平衡无关。
--   【属主视图、不带谓词、SELECT 从 authenticated 收回】—— 只持产出码的人读不到 processing_runs,一张 invoker 视图会安静地丢行。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE VIEW public.contamination_shift_status_all WITH (security_invoker = off) AS
 WITH sheet_runs AS (
         SELECT DISTINCT r.id AS run_id,
            r.code AS run_code,
            r.process_date,
            r.shift_code,
            r.started_at,
            s.code AS stream_code
           FROM processing_runs r
             JOIN processing_outputs po ON po.run_id = r.id
             JOIN output_batches ob ON ob.id = po.output_batch_id
             JOIN materials m ON m.id = ob.material_id
             JOIN contamination_streams s ON s.sheet_form_code = m.form_code
          WHERE r.status = 'committed'::text AND r.deleted_at IS NULL AND r.started_at IS NOT NULL AND r.shift_code IS NOT NULL AND s.is_active
        ), current_checks AS (
         SELECT c.id,
            c.stream_code,
            c.kind,
            c.rate_pct,
            c.above_warning,
            r.process_date,
            r.shift_code
           FROM contamination_checks c
             JOIN processing_runs r ON r.id = c.run_id
          WHERE r.status = 'committed'::text AND r.deleted_at IS NULL AND NOT (EXISTS ( SELECT 1
                   FROM contamination_checks x
                  WHERE x.corrects_id = c.id))
        ), cells AS (
         SELECT sr.process_date,
            sr.shift_code,
            sr.stream_code,
            (array_agg(sr.run_id ORDER BY sr.started_at, sr.run_code))[1] AS first_run_id,
            (array_agg(sr.run_code ORDER BY sr.started_at, sr.run_code))[1] AS first_run_code,
            array_agg(sr.run_code ORDER BY sr.started_at, sr.run_code) AS run_codes
           FROM sheet_runs sr
          GROUP BY sr.process_date, sr.shift_code, sr.stream_code
        )
 SELECT cl.process_date,
    cl.shift_code,
    cl.stream_code,
    cl.first_run_id,
    cl.first_run_code,
    cl.run_codes,
    COALESCE(ck.sampled_count, 0::bigint) AS sampled_count,
    COALESCE(ck.not_sampled_count, 0::bigint) AS not_sampled_count,
    ck.max_rate_pct,
    ck.any_above_warning,
        CASE
            WHEN COALESCE(ck.sampled_count, 0::bigint) > 0 THEN 'checked'::text
            WHEN COALESCE(ck.not_sampled_count, 0::bigint) > 0 THEN 'not_sampled'::text
            ELSE 'missing'::text
        END AS check_state
   FROM cells cl
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE c.kind = 'sampled'::text) AS sampled_count,
            count(*) FILTER (WHERE c.kind = 'not_sampled'::text) AS not_sampled_count,
            max(c.rate_pct) AS max_rate_pct,
            bool_or(c.above_warning) AS any_above_warning
           FROM current_checks c
          WHERE c.process_date = cl.process_date AND c.shift_code = cl.shift_code AND c.stream_code = cl.stream_code) ck ON true;

COMMENT ON VIEW public.contamination_shift_status_all IS
    'MES-4b:每一个(加工日, 班次, 流)抽过没有 —— checked / not_sampled / missing。基视图,不给人读:读者经 contamination_shift_status;operations_now 的 contamination_check_missing 以属主身份读它。';

REVOKE ALL ON public.contamination_shift_status_all FROM authenticated, anon;

-- db/views/contamination_shift_status.sql
-- MES-4b(2026-10-07,MES-4b Step 0 Q25,Tim):【每一个班、每一条流,抽过没有 —— 带门的外壳】。/operation/contamination 读它。
--   门:加工或产出查看码任一(极片批的买方关心的质量事实,Q25)。算术全在 contamination_shift_status_all,这里一个字都不重算。
--   属主权限:基视图从 authenticated 收回了;视图读视图走属主替换。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE VIEW public.contamination_shift_status WITH (security_invoker = off) AS
 SELECT process_date,
    shift_code,
    stream_code,
    first_run_id,
    first_run_code,
    run_codes,
    sampled_count,
    not_sampled_count,
    max_rate_pct,
    any_above_warning,
    check_state
   FROM contamination_shift_status_all
  WHERE has_any_permission(ARRAY['module.processing.view'::text, 'module.output.view'::text]);

COMMENT ON VIEW public.contamination_shift_status IS
    'MES-4b:每一个(加工日, 班次, 流)抽过没有,带门(加工或产出查看码)。算术全在 contamination_shift_status_all。';

GRANT SELECT ON public.contamination_shift_status TO authenticated;
REVOKE ALL ON public.contamination_shift_status FROM anon;

-- db/views/contamination_check_rows.sql
-- MES-4b(2026-10-07,MES-4b Step 0 Q21 · Q25,Tim):【一次一次的交叉污染抽检,带上它挂着的那一炉与那一批】—— 带门的属主视图。
--   加工单页、产出批页与 /operation/contamination 读它。门:加工或产出查看码任一。
--   【为什么是属主视图】只持产出码的人读不到 processing_runs(那张表的读规则是加工码),一张 invoker 视图把它们 join 起来会
--   安静地丢掉每一行(AGENTS.md 的 xmodule)。这里借过去的只有那一炉的单号、加工日与班次 —— 一个显示标签与两个它本来就挂着的事实。
--   is_current:没有被别的行更正过(链的末端)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE VIEW public.contamination_check_rows WITH (security_invoker = off) AS
 SELECT c.id,
    c.run_id,
    r.code AS run_code,
    r.process_date,
    r.shift_code,
    c.stream_code,
    c.kind,
    c.output_batch_id,
    ob.code AS output_batch_code,
    c.sample_mass_g,
    c.foreign_mass_g,
    c.rate_pct,
    c.warning_pct_at,
    c.above_warning,
    c.sampled_at,
    c.method,
    c.not_sampled_reason,
    c.recorded_at,
    c.recorded_by,
    c.corrects_id,
    c.correction_reason,
    NOT (EXISTS ( SELECT 1
           FROM contamination_checks x
          WHERE x.corrects_id = c.id)) AS is_current
   FROM contamination_checks c
     JOIN processing_runs r ON r.id = c.run_id
     LEFT JOIN output_batches ob ON ob.id = c.output_batch_id
  WHERE has_any_permission(ARRAY['module.processing.view'::text, 'module.output.view'::text]);

COMMENT ON VIEW public.contamination_check_rows IS
    'MES-4b:交叉污染抽检逐次,带那一炉的单号 / 加工日 / 班次与那一批的批号;is_current = 链的末端。带门(加工或产出查看码)的属主视图。';

GRANT SELECT ON public.contamination_check_rows TO authenticated;
REVOKE ALL ON public.contamination_check_rows FROM anon;

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
          WHERE cs.is_active AND cs.warning_pct IS NULL) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
-- ★ MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q24,Tim):加一支 contamination_check_missing —— 一个班、一条流没有抽检
--   (那一天那一班有一张 MES-4a 起记的、已提交没回滚的单产出了这条流的极片,而同一天同一班任何一张单上都没有一条当前的抽检,
--   两种都算 —— contamination_shift_status_all 的 check_state = 'missing')。门 module.processing.view;item_id = 那一格最早的那一炉
--   (fixture 47:一行提醒要指着一条真实的行),subject = 流。记一条"没抽"(带理由)也关掉它。
-- ★ MES-4a(2026-10-07,MES-0 Q48;MES-4a Step 0 Q22,Tim):加一支 processing_balance_unclosed —— 物料平衡还没结的加工单
--   (MES-4a 起记的、转化型的、已提交没回滚的、最新结平不当前的;processing_run_balance_all 的 balance_state = 'open')。
--   门 module.processing.view;点进去是那张加工单(平衡面板在上面)。只是提醒:月末那一行也只警告,不挡关账。
-- ★ ROLE-1 Batch 2a(2026-09-24,Q9):加一支 supplier_pending_approval —— 等 CFO 批的供应商
--   (action.supplier_approve;只有持这个码的人看得见,点进去由 set_supplier_status 裁)。
--   等了多久从【最后一次送审】起算(supplier_status_history),没有那一行时退回 updated_at。
-- ★ PAY-REQ-1(2026-09-23):加一支 payment_request_pending —— 等 CFO 批的付款申请
--   (module.finance.view;finance 与 cfo 都看得见,点进去由 decide_payment_request 裁谁能批)。
-- ★ PAYROLL-APR-1(2026-09-24):加一支 payroll_request_pending —— 等 CFO 批的工资过账 / 撤销申请
--   (data.view_pay:看得见工资数的人才看得见这一格;点进去由 decide_payroll_request 裁谁能批)。
--   item_id 是【工资期】的 id,不是申请的 —— 申请没有自己的页面,它住在工资期页上。
-- ★ ROLE-1 Batch 4b(2026-09-25):加一支 receipt_price_request_pending —— 等 CFO 批的收货定价申请
--   (data.view_purchase_prices,Tim 的 Q10:看得见采购价的人都看得见这一格;点进去由
--   decide_receipt_price_request 裁谁能批)。item_id 是【收货】的 id —— 申请住在收货页上。
-- ★ APR-5b(2026-09-25):加两支。shipping_release_pending —— 等 CFO 批的发货放行(module.sales.view:
--   读得到放行的人都看得见这一格;点进去由 decide_shipping_release 裁谁能批);item_id 是【订单】的 id ——
--   放行住在订单页上。shipping_release_ready —— 放行过、还有没发完的订单(action.ship_goods:仓库的信号;
--   剩余与发货队列读同一张 sales_order_line_releasable_all;点进去是 /logistics/shipping)。
-- ★ APR-6(2026-09-25):加一支 journal_request_pending —— 等 CFO 批的手工凭证 / 冲销申请
--   (module.finance.view:读得到凭证的人都看得见这一格;点进去由 decide_journal_request 裁谁能批)。
--   item_id 是【申请】的 id —— 一张手工凭证在批准之前还没有分录,申请住在凭证列表页上(/finance/journal)。
--   subject 是摘要 / 冲销理由(申请没有对手方)。
-- ★ APR-7(2026-09-25):加一支 warehouse_request_pending —— 等 CFO 批的注销 / 回滚 / 证书作废申请
--   (module.finance.view:与 decide_warehouse_request 的门同一个码;点进去由它裁谁能批)。item_id 是【申请】的 id ——
--   申请住在库存页上(/inventory#wr-<id>);subject 是提单人的理由。
-- ★ APR-8(2026-09-26):加一支 terms_request_pending —— 等 CFO 批的定价公式 / 合同生效申请
--   (module.pricing.view:公式页的门,cfo 持;点进去由 decide_terms_request 裁谁能批)。item_id 是【申请】的 id;
--   doc_kind 分开两处住址:formula → 公式列表页(/tools/pricing/formulas#tr-<id>),contract → 合同页(/contracts#tr-<id>)。
--   subject 是提单人的理由。
-- ★ APR-9(2026-09-27):加两支。asset_disposal_pending —— 等 CFO 批的固定资产处置申请(module.finance.view:与
--   decide_asset_disposal_request 的门同一个码;item_id 是【申请】的 id,住在资产页 /finance/assets#adr-<id>)。
--   salary_change_pending —— 等批的调薪申请(data.view_pay:看得见工资的人 —— 财务、CFO、cco;谁能批由
--   decide_salary_change_request 按人裁)。★ item_id 是【员工】的 id:申请住在那个人的档案页
--   (/hr/employees/<id>#salary-requests);item_code 是 label,subject 是提单人的理由。月薪数不进这张视图。
-- ★ APR-10(2026-09-27):加一支 gst_filing_pending —— 等 CFO 批的 GST 申报申请(module.finance.view:与
--   decide_gst_filing_request 的门同一个码)。★ item_id 是【期间】的 id:申请住在那一期的页面上
--   (/finance/gst/<id>#gst-filing);item_code 是 label,subject 是提单人的附言(可空)。
--
-- 【为什么是一张视图而不是九个页面各查各的】仪表盘的每一块牌子背后都是"有多少件
-- 事在等"这一类问题;九个问题九处写,就是九份会各自漂移的实现。hr_alerts 已经证明
-- 过这个形状:一个 UNION,每一种等待状态一支,页面只负责画。
--
-- 【属主权限 + 每支自带 permission 列,外层一次性把关】(OPS-14 修法 (a))。
-- 本视图横跨六个模块,invoker 会让 RLS 把读者无权模块的行【静默丢掉】—— 行消失
-- 在这里意味着"那个数少算了",而不是报错。属主权限读全量,外层
-- WHERE has_permission(a.permission) 按【调用者】逐支裁决:无权的支【整支缺席】,
-- 不是零。谓词写一次而不是九遍 —— hr_alerts 的注释说过,复述 N 遍只会给下一个
-- 加支的人留一个漏写的机会;这里每支【声明】自己的权限码,外层【执行】它。
--
-- 【缺席 ≠ 零,页面必须自己分辨】视图对无权读者不发一行,于是"没有行"有两种
-- 含义:真的零,或者你看不见。app/page.tsx 先查权限再渲染每块牌子 —— 无权显示
-- 「受限」(common.restricted),绝不显示 0。这是仪表盘最容易犯、且任何 gate 都
-- 查不出的那个错(0 与"你看不见"在屏幕上一模一样 —— moduleGuard 的老病换了件衣服)。
--
-- 【item_type 写成 'x'::text 字面量】check-i18n 的 sqlLiteralAs 解析器现读本文件,
-- dashboard.item.* 的后缀集合就是这里的支列表 —— 加一支,键检查自动跟着变宽。
--
-- 【两笔贵的读数,按界所限】(OPS-16 报告点名的两处):
--   * fx_rate_gaps 按 (日期,币种) 对每组跑 fx_rate_asof,本身不受期间约束 ——
--     这里限 rate_date >= CURRENT_DATE - 45:仪表盘答"最近有没有漏",完整历史
--     归 /finance/month-end 按月翻。谓词落在分组键上,能下推进聚合。
--   * 银行对账这支【只数报表侧的未匹配行】(bank_statement_lines,行数 = 导入量,
--     天然有界)。bank_reconciliation_status 的账簿侧 LATERAL 要扫 journal_lines
--     全表 —— 那是对账页的活,不上人人都开的首页。
--
-- 【不在此列的】批次毛利 —— 有未决的设计问题(哪些限定词随数字走、已过账 COGS
-- 还是当前成本),自成一切,谓词已录在 AGENTS.md 常设决定 2。月结的七个信号 ——
-- /finance/month-end 是它们的枢纽,首页放一个入口,不复制信号。
--
-- NOTE: introduced by db/migrations/2026-08-09-ops18-operations-now-and-the-dashboard.sql.
-- EXEC-3a(2026-08-16):再【两】支 —— work_order_overdue 与
-- work_order_variance_beyond(WO-1c 记下的两个候选)。差异那一支的两个阈值
-- 现读 processing_settings,【两个数不是一个】(投入超耗是成本问题、
-- 产出短交是收率问题,合成一个数等于说它们一样严重)。
-- 【本刀一度加了资质那两支,而它们 CMP-2 就已经在了】—— 清单文件里那行
-- "Candidate, not built" 是过时的,重复分支由 fixture 37C 与 30A 当场抓住,
-- fu1 撤掉。见 db/migrations/2026-08-16-exec3a-fu1-*.sql。
-- 【batch_margin 撤了】:一个卖出去的批次毛利偏低是一个【状态】,没有清除动作 ——
-- 看板装的是待办,毛利的家是 /margin;可处理的那一半已经是 arm 15。
--
-- EXEC-1a(2026-08-16):两支高管臂 —— metal_quote_stale(行情陈旧,阈值现读
-- pricing_settings.metal_quote_stale_days,按 price_date 不按 created_at)与
-- orders_unfulfilled(confirmed / partially_shipped 的订单)。规格见
-- docs/dashboard-arm-inventory.md;【谁要看哪一支】见 docs/exec-views-plan.md。
--
-- OPS-19(2026-08-09):补上原始定稿漏掉的四支(awaiting_assay / batch_unpriced /
-- invoice_overdue / ar_over_90 + ap_over_90),并新增 output_unsold_aging —— sales
-- 这一行唯一够得着的支(它没有 module.finance.view,当初猜的 AR 支对它同样是「受限」)。
-- assay_unapplied 的粒度同时从"一份未执行化验一行"改成"一个批次一行",与
-- awaiting_assay 同源同粒度、互斥;live 该支当时为 0,故不改变任何现有数字。
--
-- ── SUP-TYPE-1a(2026-08-18):qualification_missing 收窄到【供货的】供应商 ──
-- EXEC-3a 在 2026-08-16-exec3a-four-executive-arms.sql:349 写着:判据是"一张都没有"
-- 而不是"缺某一类",因为没有一张"谁必须持哪张证"的要求矩阵;并且明写着
-- **"有了'这家需要合规文件'的标记之后,这一支应当收窄到它"**。
-- **那个标记现在有了(suppliers.supplies_goods),这一支已经收窄,那句话到此退休。**
-- 提交信息改不了历史文件,所以退休记录写在这里 —— 沿着引用走过来的人在这里落地。
--
-- 【为什么必须收窄:实测过的永久亮灯】SUP-TYPE-0 把它走了一遍:把一个只收钱、
-- 不供货的往来户沿合法路径推到 status='active',这一支当场亮起、days_waiting 一路
-- 长下去,而它永远不会灭 —— 房东不会去办危废证。收窄之后同样的走法【不再亮】,
-- 而一个没有证书的【真供应商】仍然照亮(fixture 89 两边都钉)。
--
-- CMP-1(2026-08-09):两支资质臂。qualification_expiring 到【类型自己的 lead days】就上牌,
-- 过期后【不落牌、无 -30 天下限】—— 工作证过期 30 天人已走,证书过期两年而进场仍可能,
-- 它就还站在那儿(live 那张 2024 年就过期的 Article 18 正是证据)。续期(valid_until
-- 前移)即安静。qualification_missing 是"一张证都没有"的缺席臂(与 awaiting_assay /
-- assay_unapplied 的分立同理)。disposition='ignore' 的类型不上牌。
-- 【规格在 docs/dashboard-arm-inventory.md】每一支是什么意思、挂哪个权限码、界在
-- 哪里、以及【哪些支被考虑过又被排除、为什么】都在那里。
-- 定稿只存在于一次对话里,代价是四支 —— 所以规矩是:
-- 【加一支 = 在同一个提交里往那份清单加一行】。
--
-- MAR-1(2026-08-10):支的权限从【一个码】放宽到【一个谓词】—— permission(必须有)
-- + permission_any(任意其一,由 arm_permission_any 一处声明,SELECT 与 WHERE 共用)。
-- 起因是批次毛利跨两个模块(prices AND (finance OR processing)),而没有任何 live 角色
-- 同时持有后两者。合成一个新权限码那条路被否掉:那会是谁能看毛利的第二份定义,
-- 与 batch_margin 自己的谓词必然漂开。fixture 45 三种读者各钉一次。
-- ASY-P1(2026-08-17):awaiting_assay 那一支【换了问题】。原来问的是"这个批次一份
-- 化验都没有"(batch_assay_status.assay_count = 0),它看不见"化验做了一半",
-- 也灭不掉料已耗尽那两盏灯(线上 IN-2026-0011 / IN-2026-0153,remaining_qty = 0)。
-- 现在读 batch_required_assay_gaps:物料声明了要验哪些金属、其中至少一种还没有被
-- 一份【已应用的】化验覆盖、并且【还取得到样】。subject 从供应商名换成【缺哪几种
-- 金属】—— subject 这一列在每一支里放的都是那一支最该让人看见的事实,而能让人
-- 下一步动起来的是缺哪几种。判据与理由住在那张视图里,不在这里。
-- LINKS-1(2026-08-11):每支多带一个 item_id —— 支从"指向一张列表"变成"指向那一件事"。
-- 【item_id 指的是谁】承载【补救动作】的那张页面所对应的行。十七支里它就是等待中的
-- 那一行;两支里是它的父:bank_unmatched(行没有页面,匹配动作在对账工作台上 →
-- 对账单)与 margin_cost_not_allocated(补救是给加工单分摊成本 → 加工单)。
-- 于是同一支的几行可以共用一个 item_id,那是对的,不是重复 —— fixture 47 因此断言
-- 的是"item_id 落在这一支该落的那张表里",不是"一行一个 id",也不是互不相同。
-- 【SO-3a:应收也成了两种单据】ar_over_90 的 doc_kind 从此非空('sale' 销售记录 /
-- 'invoice' 订单流发票),item_id 相应二选一 —— 门牌各是应收单据页与发票页,
-- app/page.tsx 按 doc_kind 分支,认不出的种类不给链接(与 ap 同一条)。
-- 【doc_kind 是披露】应付账款本来就是两种单据(ap_open_items 自己就按它分支,
-- 应付列表页也一直照它画链接),这张视图先前只是没说出口。其余十八支主体只有一种,
-- 该列为 NULL。【fx_rate_gap 没有 item_id】它的主体是一条不存在的牌价行,缺的东西
-- 没有 id —— 它指向按币种过滤的列表,那是"诚实过滤的列表"那类答案,不是按码搜索。
-- 每支的门牌与"补救是否在那张页面上"这条判据,写在 docs/dashboard-arm-inventory.md。
-- NOTE: item_id / doc_kind added by
-- db/migrations/2026-08-11-links1-operations-now-item-id.sql(列集变了 → DROP + CREATE)。
-- SS-1(2026-08-13):第二十支 safety_stock_below —— 物料的可用量低于它自己的
-- 安全库存阈值。【阈值 NULL 的物料一次都不响】:NULL 是"还没有人决定要盯它",
-- 不是"阈值为零",而把不响读成"查过了没问题"正是 METAL-1 的那一课。
-- 可用量来自 material_stock_available(一处求和,暂扣不算 —— 阈值问的是"还有多少
-- 能用的货",一次暂扣若能掩盖缺货,这个告警就在最该说话的时刻哑掉)。
-- item_date 用【最后一次库存移动】退回今天:阈值告警是持续状态,没有发生日;
-- 去算"哪天跌破的"要在首页翻整段流水史,那条界不允许(credit_over_limit 同形)。

-- LOG-5a(2026-08-20):第 23–26 支 —— 物流的四支告警。全部是【臂】(算出来、
-- 会自愈),不是 notifications 的事件。末尾的 WHERE 多了一个【放宽】算子
-- arm_permission_widen():它与收窄用的 arm_permission_any() 方向相反,
-- 对除 free_time_expiring 以外的每一支都返回 NULL(fixture 102G 逐支断言)。
-- LOG-5d(2026-08-20):同一种里程碑之内,算数的是【最后被录入】的那一条
-- (recorded_at DESC, id DESC)。此前按 event_date DESC 排,于是一条把日期
-- 改【早】的更正永远排不到前面、一次都不会生效(线上 CTR-2026-0009)。
-- EQP-2c(2026-08-21):第 27–28 支 —— 保养【到期】与【将到期】,两支不是一支。
-- 列契约一字未动。规格见 docs/dashboard-arm-inventory.md;推导与它的基线
-- (那两条"低读数有两种意思"的事实)整段写在 equipment_service_status 的视图注释里。
-- 【放宽】两支都走 arm_permission_widen(processing OR finance)—— 机器卡在财务、
-- 干活的人在加工,而它们底下每一张表/视图的读者都是这两个码的 OR。
-- CMPL-1(2026-08-30)追加两支:
--   · company_licence_expiring —— **形状逐字取自 qualification_expiring**,只是把
--     supplier_compliance 换成 company_compliance(少一跳供应商)。它读的仍是
--     certificate_types 自带的 warn_lead_days 与 disposition,所以 gwc 加进字典那天
--     它的到期提醒【自动就有】。**没有另起一套到期机制。**
--   · import_permit_unverified —— 是进口货、而那张进口准证还没有人核过。
--     **它不拦任何东西**:拦的那一半由 nea_import 的 block 处置在收货上做
--     (supplier_receiving_blocked → trg_inbound_batches_po_receivable),
--     这一支说的是"这一票还欠一次人工核对"。理由见 db/tables/inbound_batches.sql 的列注。
-- MES-1(2026-10-06,MES-1 Step 0 Q16 · Q17 · Q23,Tim):第 48–49 支 ——
--   · gateway_silent:一台网关此刻在沉默 —— 它的心跳间隔给了,而最后一次听到它已经超过那个间隔(gateway_health.status = silent)。
--     一次都没听到过的("Not yet heard from")与间隔没给的("Not yet set")【不上牌】:前者是还没调试的正常状态(Q16),
--     后者是沉默无从判断(Q17)。item_id = 那台网关(/operation/devices/[id])。
--   · capture_inbox_failed:收件箱里有转换失败的行 —— 按设备合成一块(item_id = 设备,subject = 设备名 · 失败行数,
--     item_date = 最早的那一行)。不为 awaiting_transform 上牌:那是每一个还没接上转换器的类的正常状态(Q23)。
--   两支都只要 module.processing.view;规格在 docs/dashboard-arm-inventory.md。
-- MES-2(2026-10-06,MES-0 Q13;MES-2 Step 0 Q29 · Q32,Tim):第 50–52 支 ——
--   · capture_draft_pending:一张网关送来的草稿还没人确认 —— 一张一行,item_date = 落草稿那一天,所以 days_waiting 就是它的年龄
--     (草稿永不过期,MES-0 Q13)。门是 action.confirm_capture(能确认它的人才需要被催)。手工录入的草稿生下来就确认了,不上牌。
--   · instrument_calibration_due:一台【在用的】仪器(interface_status 不是 reserved,没停用)今天不在校准期内 —— 过期、没通过、
--     或从来没校过。item_date = 有效期(从来没校过的取它登记那一天)。
--   · instrument_calibration_approaching:在期内、有效期落在 V8 给的提前天数里。V8(calibration_lead_days)没给 → 这一支恒为空,
--     过期本身照样由上一支上牌(每一条记录自己的有效期是必填的)。
--   后两支读 instrument_calibration_now(属主视图,一份挑法、一句判据),门是 module.processing.view。
-- MES-3a(2026-10-06,MES-0 Q13 · Q35 · Q34;MES-3a Step 0 Q13 · Q16 · Q20,Tim):第 53–55 支 —— 三支都【只提醒,不拒】——
--   · storage_ceiling_exceeded:今天在效的执照下,一类 NEA 废物(或总量)的存量超过了给了的上限(storage_ceiling_status.status = exceeded)。
--     收货在超之前就被拒了,所以走到这里的是别的路:加工把料变成了另一类、回滚还回了料、上限被调低了。item_id = 执照,
--     item_code = 类别(总量是 *),门 module.inventory.view。
--   · safety_state_dwell:一批还在厂里的货,身上一条开着的状态待满了它的 dwell_warning_days(V3;没给的不上牌)。
--     一批 × 一条状态一行;item_date = 那条状态被记下的那一天,所以 days_waiting 就是它待了多久。doc_kind = inbound / output,
--     门逐行:进料 module.inbound.view,产出 module.output.view。
--   · quarantine_required:一批身上开着一条要隔离的状态(鼓包或漏液),却还有货放在非隔离库位(quarantine_exposure)。
--     一批 × 一个库位桶一行;doc_kind 与门同上;item_date = 那条状态被记下的那一天。
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
            'module.logistics.view'::text AS permission,
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
            'module.logistics.view'::text AS permission,
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
            'module.logistics.view'::text AS permission,
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
            'module.logistics.view'::text AS permission,
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
         SELECT 'gateway_silent'::text AS item_type,
            'module.processing.view'::text AS permission,
            gh.gateway_id AS item_id,
            NULL::text AS doc_kind,
            gh.code AS item_code,
            gh.name AS subject,
            gh.last_heard_at::date AS item_date
           FROM gateway_health gh
          WHERE gh.status = 'silent'::text
        UNION ALL
         SELECT 'capture_inbox_failed'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.device_id AS item_id,
            NULL::text AS doc_kind,
            f.device_code AS item_code,
            (f.device_name || ' · '::text) || f.failed_rows::text AS subject,
            f.first_failed AS item_date
           FROM ( SELECT b.device_id,
                    d.code AS device_code,
                    d.name AS device_name,
                    count(*) AS failed_rows,
                    min(b.received_at)::date AS first_failed
                   FROM ingest_inbox b
                     JOIN devices d ON d.id = b.device_id
                  WHERE b.status = 'failed'::text
                  GROUP BY b.device_id, d.code, d.name) f
        UNION ALL
         SELECT 'capture_draft_pending'::text AS item_type,
            'action.confirm_capture'::text AS permission,
            cd.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(dv.code, cd.data_class) AS item_code,
            (COALESCE(dv.name, cd.data_class) || ' · '::text) || COALESCE((cd.proposed ->> 'weight_kg'::text) || ' kg'::text, cd.data_class) AS subject,
            cd.created_at::date AS item_date
           FROM capture_drafts cd
             LEFT JOIN devices dv ON dv.id = cd.device_id
          WHERE cd.status = 'pending'::text
        UNION ALL
         SELECT 'instrument_calibration_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ic.device_id AS item_id,
            NULL::text AS doc_kind,
            ic.code AS item_code,
            (ic.name || ' · '::text) || ic.status AS subject,
            COALESCE(ic.valid_until, ic.registered_at::date) AS item_date
           FROM instrument_calibration_now ic
          WHERE ic.in_use AND ic.status <> 'in_calibration'::text
        UNION ALL
         SELECT 'instrument_calibration_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ic.device_id AS item_id,
            NULL::text AS doc_kind,
            ic.code AS item_code,
            ic.name AS subject,
            ic.valid_until AS item_date
           FROM instrument_calibration_now ic
          WHERE ic.in_use AND ic.approaching
        UNION ALL
         SELECT 'storage_ceiling_exceeded'::text AS item_type,
            'module.inventory.view'::text AS permission,
            sc.licence_id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(sc.category_code, '*'::text) AS item_code,
            (((sc.cert_no || ' · '::text) || sc.name_en) || ' · '::text) || round(sc.on_hand_t, 3)::text || ' / '::text || sc.limit_tonnes::text || ' t'::text AS subject,
            (now() AT TIME ZONE 'Asia/Singapore'::text)::date AS item_date
           FROM storage_ceiling_status sc
          WHERE sc.status = 'exceeded'::text
        UNION ALL
         SELECT 'safety_state_dwell'::text AS item_type,
                CASE dw.batch_kind
                    WHEN 'inbound'::text THEN 'module.inbound.view'::text
                    ELSE 'module.output.view'::text
                END AS permission,
            dw.batch_id AS item_id,
            dw.batch_kind AS doc_kind,
            dw.batch_code AS item_code,
            dw.name_en AS subject,
            dw.recorded_on AS item_date
           FROM safety_state_dwell dw
          WHERE dw.dwell_status = 'past'::text AND dw.on_site
        UNION ALL
         SELECT 'quarantine_required'::text AS item_type,
                CASE qe.batch_kind
                    WHEN 'inbound'::text THEN 'module.inbound.view'::text
                    ELSE 'module.output.view'::text
                END AS permission,
            qe.batch_id AS item_id,
            qe.batch_kind AS doc_kind,
            qe.batch_code AS item_code,
            (qe.name_en || ' · '::text) || COALESCE(qe.location_code, 'unspecified'::text) AS subject,
            qe.recorded_on AS item_date
           FROM quarantine_exposure qe
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
          WHERE w.unremitted_base > 0::numeric AND (w.due_date - CURRENT_DATE) <= 7
        UNION ALL
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
        UNION ALL
         SELECT 'payment_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            pr.id AS item_id,
            NULL::text AS doc_kind,
            pr.code AS item_code,
            COALESCE(s.legal_name, e.legal_name, c.legal_name) AS subject,
            pr.created_at::date AS item_date
           FROM payment_requests pr
             LEFT JOIN suppliers s ON s.id = pr.supplier_id
             LEFT JOIN employees e ON e.id = pr.employee_id
             LEFT JOIN customers c ON c.id = pr.customer_id
          WHERE pr.status = 'submitted'::text
        UNION ALL
         SELECT 'supplier_pending_approval'::text AS item_type,
            'action.supplier_approve'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            COALESCE(( SELECT max(h.changed_at) AS max
                   FROM supplier_status_history h
                  WHERE h.supplier_id = s.id AND h.to_status = 'pending_review'::text), s.updated_at)::date AS item_date
           FROM suppliers s
          WHERE s.status = 'pending_review'::supplier_status AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'payroll_request_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            q.payroll_period_id AS item_id,
            NULL::text AS doc_kind,
            q.label AS item_code,
            pp.code AS subject,
            q.created_at::date AS item_date
           FROM payroll_requests q
             JOIN payroll_periods pp ON pp.id = q.payroll_period_id
          WHERE q.status = 'submitted'::text
        UNION ALL
         SELECT 'receipt_price_request_pending'::text AS item_type,
            'data.view_purchase_prices'::text AS permission,
            rq.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            rq.label AS item_code,
            ib.code AS subject,
            rq.created_at::date AS item_date
           FROM receipt_price_requests rq
             JOIN inbound_batches ib ON ib.id = rq.inbound_batch_id
          WHERE rq.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            iq.invoice_id AS item_id,
            NULL::text AS doc_kind,
            iq.label AS item_code,
            c.legal_name AS subject,
            iq.created_at::date AS item_date
           FROM invoice_requests iq
             JOIN invoices i ON i.id = iq.invoice_id
             JOIN customers c ON c.id = i.customer_id
          WHERE iq.status = 'submitted'::text
        UNION ALL
         SELECT 'shipping_release_pending'::text AS item_type,
            'module.sales.view'::text AS permission,
            sr.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            sr.label AS item_code,
            c.legal_name AS subject,
            sr.created_at::date AS item_date
           FROM shipping_releases sr
             JOIN sales_orders so ON so.id = sr.sales_order_id
             JOIN customers c ON c.id = so.customer_id
          WHERE sr.status = 'submitted'::text
        UNION ALL
         SELECT 'journal_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            jq.id AS item_id,
            NULL::text AS doc_kind,
            jq.label AS item_code,
            jq.memo AS subject,
            jq.created_at::date AS item_date
           FROM journal_requests jq
          WHERE jq.status = 'submitted'::text
        UNION ALL
         SELECT 'warehouse_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            wq.id AS item_id,
            NULL::text AS doc_kind,
            wq.label AS item_code,
            wq.reason AS subject,
            wq.created_at::date AS item_date
           FROM warehouse_requests wq
          WHERE wq.status = 'submitted'::text
        UNION ALL
         SELECT 'terms_request_pending'::text AS item_type,
            'module.pricing.view'::text AS permission,
            tq.id AS item_id,
                CASE
                    WHEN tq.contract_id IS NOT NULL THEN 'contract'::text
                    ELSE 'formula'::text
                END AS doc_kind,
            tq.label AS item_code,
            tq.reason AS subject,
            tq.created_at::date AS item_date
           FROM terms_requests tq
          WHERE tq.status = 'submitted'::text
        UNION ALL
         SELECT 'asset_disposal_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            dq.id AS item_id,
            NULL::text AS doc_kind,
            dq.label AS item_code,
            dq.reason AS subject,
            dq.created_at::date AS item_date
           FROM asset_disposal_requests dq
          WHERE dq.status = 'submitted'::text
        UNION ALL
         SELECT 'salary_change_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            sq.employee_id AS item_id,
            NULL::text AS doc_kind,
            sq.label AS item_code,
            sq.reason AS subject,
            sq.created_at::date AS item_date
           FROM salary_change_requests sq
          WHERE sq.status = 'submitted'::text
        UNION ALL
         SELECT 'gst_filing_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            gq.period_id AS item_id,
            NULL::text AS doc_kind,
            gq.label AS item_code,
            gq.note AS subject,
            gq.created_at::date AS item_date
           FROM gst_filing_requests gq
          WHERE gq.status = 'submitted'::text
        UNION ALL
         SELECT 'processing_balance_unclosed'::text AS item_type,
            'module.processing.view'::text AS permission,
            b.run_id AS item_id,
            NULL::text AS doc_kind,
            b.run_code AS item_code,
            b.operation_type_code AS subject,
            b.process_date AS item_date
           FROM processing_run_balance_all b
          WHERE b.balance_state = 'open'::text
        UNION ALL
         SELECT 'contamination_check_missing'::text AS item_type,
            'module.processing.view'::text AS permission,
            cs.first_run_id AS item_id,
            NULL::text AS doc_kind,
            cs.first_run_code AS item_code,
            cs.stream_code AS subject,
            cs.process_date AS item_date
           FROM contamination_shift_status_all cs
          WHERE cs.check_state = 'missing'::text
        UNION ALL
         SELECT 'shipping_release_ready'::text AS item_type,
            'action.ship_goods'::text AS permission,
            q.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            q.order_code AS item_code,
            q.customer_name AS subject,
            q.released_on AS item_date
           FROM ( SELECT so.id AS sales_order_id,
                    so.code AS order_code,
                    c.legal_name AS customer_name,
                    max(r.decided_at)::date AS released_on
                   FROM shipping_releases r
                     JOIN shipping_release_lines rl ON rl.release_id = r.id
                     JOIN invoice_lines il ON il.id = rl.invoice_line_id
                     JOIN sales_orders so ON so.id = r.sales_order_id
                     JOIN customers c ON c.id = so.customer_id
                  WHERE r.status = 'approved'::text AND NOT il.invoice_voided
                    AND so.deleted_at IS NULL
                    AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
                    AND (( SELECT ra.releasable_qty
                           FROM sales_order_line_releasable_all ra
                          WHERE ra.invoice_line_id = il.id)) > COALESCE(( SELECT sum(sl.qty) AS sum
                           FROM shipment_lines sl
                          WHERE sl.sales_order_line_id = rl.sales_order_line_id), 0::numeric)
                  GROUP BY so.id, so.code, c.legal_name) q) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));;

GRANT SELECT ON public.operations_now TO authenticated;

-- ── 17 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──────────────────────────
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.cell_constructions
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.cell_constructions
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contamination_streams
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contamination_streams
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.contamination_checks
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.contamination_checks
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 18 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.set_batch_cell_construction(text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_batch_cell_construction(text, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_derived_electrolyte_loss(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_derived_electrolyte_loss(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.rederive_electrolyte_loss(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rederive_electrolyte_loss(bigint, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_contamination_check(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_contamination_check(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.correct_contamination_check(bigint, text, uuid, numeric, numeric, timestamp with time zone, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_contamination_check(bigint, text, uuid, numeric, numeric, timestamp with time zone, text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_batch_cell_construction() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_batch_cell_construction() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text) FROM authenticated;

-- ── 19 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes4b_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes4b_pending_after ON COMMIT DROP AS
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
    -- ① 授权一行都没动(本刀不加码、不改授权)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes4b_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes4b_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4B_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES4B_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes4b_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes4b_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES4B_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的加工单与它的腿逐字未变;批次与物料除了多出来的那一列(全空)逐字未变;损耗行全是 measured
    IF EXISTS ((SELECT b.k, b.id FROM mes4b_pending_before b EXCEPT SELECT a.k, a.id FROM mes4b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes4b_pending_after a EXCEPT SELECT b.k, b.id FROM mes4b_pending_before b)) THEN
        RAISE EXCEPTION 'MES4B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT runs FROM mes4b_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_inputs t) IS DISTINCT FROM (SELECT inputs FROM mes4b_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_outputs t) IS DISTINCT FROM (SELECT outputs FROM mes4b_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM materials t) IS DISTINCT FROM (SELECT materials FROM mes4b_rows_before) THEN
        RAISE EXCEPTION 'MES4B_PROOF|a pre-existing run, leg or material changed';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'cell_construction_code')::text, '|' ORDER BY t.id), '')) FROM inbound_batches t)
           IS DISTINCT FROM (SELECT inbound FROM mes4b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'cell_construction_code')::text, '|' ORDER BY t.id), '')) FROM output_batches t)
           IS DISTINCT FROM (SELECT output FROM mes4b_rows_before)
       OR EXISTS (SELECT 1 FROM inbound_batches WHERE cell_construction_code IS NOT NULL)
       OR EXISTS (SELECT 1 FROM output_batches WHERE cell_construction_code IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4B_PROOF|a pre-existing batch changed, or a batch got a cell construction';
    END IF;
    IF (SELECT count(*) FROM processing_run_losses) <> (SELECT loss_n FROM mes4b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'basis' - 'derived_share_pct')::text, '|' ORDER BY t.id), '')) FROM processing_run_losses t)
           IS DISTINCT FROM (SELECT losses FROM mes4b_rows_before)
       OR EXISTS (SELECT 1 FROM processing_run_losses WHERE basis <> 'measured' OR derived_share_pct IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4B_PROOF|a pre-existing loss row changed, or is not marked measured';
    END IF;

    -- ④ 变更记录只在引导的那几张表上动了,恰好 43 行:单据种类 12 · 物料形态 6 + 13(映射)· 工序 ↔ 形态 7 · 损耗类别 1 · 工序 2 · 例外表 2。
    --   两本新字典与抽检表的引导在它们的绑定之前插入(第 2 段 → 第 17 段),所以不进变更记录。
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes4b_log_before)
       AND c.table_name NOT IN ('document_types', 'material_forms', 'operation_type_output_forms', 'loss_categories',
                                'operation_types', 'document_type_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4B_PROOF|change_log moved on %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes4b_log_before)) <> 43 THEN
        RAISE EXCEPTION 'MES4B_PROOF|expected 43 change-log rows, got %',
            (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes4b_log_before));
    END IF;

    -- ⑤ 引导恰好是引导;新的数据表是空的;一道工序都没勾电解液、没给份额;一条流都没给警戒线;开关空着
    IF (SELECT string_agg(code || ':' || is_determined::text, ',' ORDER BY sort_order) FROM cell_constructions)
           IS DISTINCT FROM 'wound:true,stacked:true,unknown:false'
       OR (SELECT string_agg(code || ':' || sheet_form_code || ':' || foreign_form_code, ',' ORDER BY sort_order) FROM contamination_streams)
           IS DISTINCT FROM 'cathode:cathode_sheet:anode_sheet,anode:anode_sheet:cathode_sheet'
       OR EXISTS (SELECT 1 FROM contamination_streams WHERE warning_pct IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4B_PROOF|the two new dictionaries are not exactly their bootstrap (or a warning level was set)';
    END IF;
    IF (SELECT string_agg(code || ':' || may_be_sold::text, ',' ORDER BY sort_order) FROM material_forms WHERE sort_order >= 14)
           IS DISTINCT FROM 'cathode_powder:true,anode_powder:true,copper_foil:true,aluminium_foil:true,collected_dust:false,harness_bms_busbar:true'
       OR EXISTS (SELECT 1 FROM material_forms WHERE code IN ('cathode_powder', 'anode_powder', 'copper_foil', 'aluminium_foil', 'collected_dust', 'harness_bms_busbar')
                    AND implies_dismantling)
       OR (SELECT count(*) FROM material_forms) <> 19
       OR (SELECT count(*) FROM material_forms WHERE output_document_key IS NOT NULL) <> 13 THEN
        RAISE EXCEPTION 'MES4B_PROOF|material forms are not the 19 expected with the Q9 saleability and 13 mapped';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 55 OR (SELECT count(*) FROM document_types WHERE numbering = 'gapped') <> 23
       OR (SELECT count(*) FROM document_types WHERE table_name = 'output_batches') <> 13
       OR NOT EXISTS (SELECT 1 FROM document_types WHERE key = 'output_batch' AND prefix = 'OUT') THEN
        RAISE EXCEPTION 'MES4B_PROOF|document types are not 55 (23 gapped, 13 on output_batches, OUT kept)';
    END IF;
    IF (SELECT count(*) FROM operation_type_output_forms) <> 21 THEN
        RAISE EXCEPTION 'MES4B_PROOF|expected 21 operation-output-form rows';
    END IF;
    IF (SELECT string_agg(code, ',' ORDER BY code) FROM loss_categories WHERE may_be_derived) IS DISTINCT FROM 'electrolyte_evaporation' THEN
        RAISE EXCEPTION 'MES4B_PROOF|only electrolyte_evaporation may be derived';
    END IF;
    IF EXISTS (SELECT 1 FROM operation_types WHERE electrolyte_loss_applies OR electrolyte_share_pct IS NOT NULL)
       OR (SELECT string_agg(code, ',' ORDER BY code) FROM operation_types WHERE requires_cell_construction)
           IS DISTINCT FROM 'electrode_line,electrode_separation' THEN
        RAISE EXCEPTION 'MES4B_PROOF|an electrolyte flag or share was set, or the cell-construction operations are not the two';
    END IF;
    IF EXISTS (SELECT 1 FROM contamination_checks) THEN
        RAISE EXCEPTION 'MES4B_PROOF|contamination_checks is not empty';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES4B_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到;旧签名不在了
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES4B_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.set_batch_cell_construction(text, uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.set_batch_cell_construction(text, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.set_batch_cell_construction(text, uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4B_PROOF|public.set_batch_cell_construction(text, uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_derived_electrolyte_loss(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_derived_electrolyte_loss(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_derived_electrolyte_loss(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4B_PROOF|public.record_derived_electrolyte_loss(uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.rederive_electrolyte_loss(bigint, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.rederive_electrolyte_loss(bigint, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.rederive_electrolyte_loss(bigint, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4B_PROOF|public.rederive_electrolyte_loss(bigint, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_contamination_check(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_contamination_check(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_contamination_check(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4B_PROOF|public.record_contamination_check(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.correct_contamination_check(bigint, text, uuid, numeric, numeric, timestamp with time zone, text, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.correct_contamination_check(bigint, text, uuid, numeric, numeric, timestamp with time zone, text, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.correct_contamination_check(bigint, text, uuid, numeric, numeric, timestamp with time zone, text, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4B_PROOF|public.correct_contamination_check(bigint, text, uuid, numeric, numeric, timestamp with time zone, text, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4B_PROOF|public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4B_PROOF|public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text)'::regprocedure) THEN
        RAISE EXCEPTION 'MES4B_PROOF|public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text) must be an internal function nobody outside can call';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('cell_constructions', 'contamination_streams', 'contamination_checks', 'contamination_shift_status_all', 'contamination_shift_status', 'contamination_check_rows')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4B_PROOF|anon can read %', v_bad; END IF;
    IF to_regprocedure('public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text)') IS NOT NULL
       OR to_regprocedure('public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES4B_PROOF|an old receipt-function signature survived';
    END IF;
    IF has_column_privilege('authenticated', 'public.inbound_batches'::regclass, 'cell_construction_code', 'SELECT') IS NOT TRUE THEN
        RAISE EXCEPTION 'MES4B_PROOF|inbound_batches.cell_construction_code is not readable by authenticated (the grant is missing)';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;抽检表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES4B_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'contamination_checks' AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES4B_PROOF|a write policy exists on contamination_checks';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(三张新表都记,豁免仍是 8);遮蔽零缺口(仍是 105 条);每一张被记录的表的绑定键都是它的主键
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES4B_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES4B_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    SELECT string_agg(t.relname, ', ') INTO v_bad
      FROM (SELECT c.relname, substring(pg_get_triggerdef(tg.oid) FROM 'change_log_capture\((.*)\)') AS args
              FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND tg.tgname = 'zzz_change_log') t
      LEFT JOIN (SELECT c.relname, string_agg(quote_literal(a.attname), ', ' ORDER BY array_position(i.indkey::int2[], a.attnum)) AS cols
                   FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (i.indkey)
                  WHERE n.nspname = 'public' AND i.indisprimary GROUP BY c.relname) pk ON pk.relname = t.relname
     WHERE t.args IS DISTINCT FROM pk.cols;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4B_PROOF|change-log key is not the primary key on %', v_bad; END IF;

    -- ⑨ 提醒臂 56 → 57;待补的值 15 → 17 支
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 57 THEN
        RAISE EXCEPTION 'MES4B_PROOF|operations_now should have 57 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 17 THEN
        RAISE EXCEPTION 'MES4B_PROOF|pending_values should have 17 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes4b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES4B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes4b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES4B_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes4b_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
