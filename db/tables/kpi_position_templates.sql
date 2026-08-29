-- db/tables/kpi_position_templates.sql
-- KPI-1:职位 KPI 模板 —— 每职位 5 条,权重合计 100(规格 §11 第 3 步、§9.3)。
-- 目标文本是规格第三章的【英文原文】,与 kpi_organisation 同一条规矩:一个字不许改。
--
-- ★★【它是【模板】,而人名下的那五条是它的【副本】】★★(§8.3)
--   一个人加入某职位时,把这五条**复制**到他名下;**日后改模板,不影响已经复制出去的**。
--   理由是仓库自己的先例,不是一句偏好:采购单的定价条款在【承诺那一刻抄下】(FIN-27)、
--   发票的税率在【开出那一刻冻结】(GST-2)。
--   **一个人某个周期被考核的是哪五条,是一件【已经发生】的事** ——
--   后来改了模板,不该回头改写他当时被考核的标准;那不是"更新",那是改历史。
--
-- 【version 是【复制时抄走的那个号】】改一条模板要把 version 加一,
--   于是人名下那份副本记着的 (source_template_id, source_template_version)
--   永远指得回"他当时被考核的是哪一版",即便模板后来变了。
--
-- ★【`evidence_source` 这一列【故意允许为空】,而空是原表的事实】★(§12.4)
--   原表第三页的列头 `Evidence / review source` 写着,而 **H5:H34 三十格没有一格有内容**。
--   「这不是转录漏了,是原表就没填。」说出来是因为它直接影响打分:
--   **一条没有证据来源的 KPI,打分时靠的是打分人自己记得该看什么。**
--   组织 KPI 那一层的 `measurement_evidence` 是填了的,缺的只有个人这一层。
--
-- NOTE: introduced by db/migrations/2026-08-29-kpi1-positions-and-the-kpi-framework.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.kpi_position_templates (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    position_id      uuid NOT NULL REFERENCES public.positions (id) ON DELETE RESTRICT,
    -- 原表的 `KPI ID` 列:V1..V5 / T1..T5 / C1..C5 / S1..S5 / A1..A5 / F1..F5
    kpi_ref          text NOT NULL CHECK (btrim(kpi_ref) <> ''),
    -- 原表 `Individual KPI` 列,原文
    title            text NOT NULL CHECK (btrim(title) <> ''),
    weight_pct       numeric NOT NULL CHECK (weight_pct > 0 AND weight_pct <= 100),
    -- 原表 `Quantifiable target / standard` 列,【原文】
    target_text      text NOT NULL CHECK (btrim(target_text) <> ''),
    -- ★ 原表三十格全空 —— 见抬头。允许为空是在陈述一个事实,不是留了个待办。
    evidence_source  text,
    is_provisional   boolean NOT NULL DEFAULT false,
    provisional_note text,
    -- 改一条模板就加一;人名下的副本记着复制那一刻的号
    version          integer NOT NULL DEFAULT 1 CHECK (version >= 1),
    sort_order       integer NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (position_id, kpi_ref),
    CONSTRAINT kpi_tpl_provisional_needs_note
        CHECK (NOT is_provisional OR (provisional_note IS NOT NULL AND btrim(provisional_note) <> ''))
);

CREATE INDEX idx_kpi_tpl_position ON public.kpi_position_templates (position_id, sort_order);

-- ── 模板 → 组织 KPI 的链接(多对多:原表里 S2 是 `O4 / O3`,T5 是 `O3 / O5`)──
-- 【这里用【真的外键】,而人名下的副本用【快照数组】—— 两者是刻意不同的】
--   模板是活的主数据,引用完整性要紧;副本是冻住的事实,自成一体要紧。
--   于是两张联动矩阵有两份推导,而那【不是重复】:复制之后改模板,
--   两边本来就该分开 —— 那正是"复制不是引用"这件事看得见的样子。
CREATE TABLE public.kpi_template_org_links (
    template_id  uuid NOT NULL REFERENCES public.kpi_position_templates (id) ON DELETE CASCADE,
    org_code     text NOT NULL REFERENCES public.kpi_organisation (code) ON DELETE RESTRICT,
    PRIMARY KEY (template_id, org_code)
);

ALTER TABLE public.kpi_position_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "kpi_position_templates select by permission"
    ON public.kpi_position_templates AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

ALTER TABLE public.kpi_template_org_links ENABLE ROW LEVEL SECURITY;
CREATE POLICY "kpi_template_org_links select by permission"
    ON public.kpi_template_org_links AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

-- ★【每个职位的模板权重合计 = 100 的闸】★(§9.3)
-- 与组织那条同一形状:DEFERRABLE,提交时按【职位】分组检查。
CREATE OR REPLACE FUNCTION public.guard_kpi_template_weight_total()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_bad record;
BEGIN
    -- 【只检查【有模板行的】职位】一个还没配模板的职位不是一个错的职位。
    FOR v_bad IN
        SELECT p.code, SUM(t.weight_pct) AS total
          FROM kpi_position_templates t JOIN positions p ON p.id = t.position_id
         GROUP BY p.code HAVING SUM(t.weight_pct) <> 100
    LOOP
        RAISE EXCEPTION 'KPI_TEMPLATE_WEIGHTS_NOT_100|%|%', v_bad.code, v_bad.total
          USING HINT = '一个职位的五条 KPI 权重合计必须正好 100 —— 加了第六条、或者把 25 改成 30 的那一刻它会变成 105,而加权分照样算得出来(规格 §9.3)';
    END LOOP;
    RETURN NULL;
END;
$function$;

CREATE CONSTRAINT TRIGGER trg_kpi_template_weight_total
    AFTER INSERT OR UPDATE OR DELETE ON public.kpi_position_templates
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.guard_kpi_template_weight_total();

COMMENT ON TABLE public.kpi_position_templates IS
    'KPI-1:职位 KPI 模板,每职位 5 条、权重合计 100(规格 §9.3 的闸,DEFERRABLE 约束触发器按职位分组在提交时检查)。目标文本是规格第三章的**英文原文**,一个字不许改;**安装种子表,逐行跟踪线上**。★**它是模板,人名下那五条是它的副本**★(§8.3):加入职位时【复制】,日后改模板不影响已复制的 —— 先例是 FIN-27 的已承诺定价条款与 GST-2 的开票冻结税率,因为"某个周期被考核的是哪五条"是一件已经发生的事。`version` 是复制时被抄走的那个号。★`evidence_source` 故意允许为空★:原表第三页那一列**三十格全空**(§12.4)—— 不是转录漏了,是原表没填,而它直接影响打分(没有证据来源时,打分靠的是打分人自己记得该看什么)。';

COMMENT ON TABLE public.kpi_template_org_links IS
    'KPI-1:模板 → 组织 KPI 的链接,多对多(原表里 S2 是 `O4 / O3`、T5 是 `O3 / O5`)。**这里是真外键,而人名下的副本用快照数组 —— 刻意不同**:模板是活的主数据(引用完整性要紧),副本是冻住的事实(自成一体要紧)。于是两张联动矩阵有两份推导,而那【不是重复】:改了模板之后两边本来就该分开,那正是"复制不是引用"看得见的样子。';

-- ⟨KPI-1 SEED BEGIN — 机器生成,勿手改⟩
-- 来源:docs/kpi-framework.md,经 db/scripts/kpi_seed_from_spec.py 逐格解析。
-- **改这些行要先改规格,再重新生成**(规格 §1:一至七章不能改)。

INSERT INTO public.kpi_position_templates (position_id, kpi_ref, title, weight_pct, target_text, is_provisional, provisional_note, sort_order) VALUES
    ((SELECT id FROM public.positions WHERE code = 'MD'), 'V1', 'Regulatory leadership & escalation', 25,
     'Own master regulatory roadmap; 100% critical regulatory milestones have named owner, due date and escalation; no critical regulator action >5 working days overdue.',
     false, NULL, 1),
    ((SELECT id FROM public.positions WHERE code = 'MD'), 'V2', 'Commissioning governance', 20,
     'Chair weekly equipment/commissioning review; ≥90% critical project milestones delivered by committed date; all red issues escalated within 2 working days.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 2),
    ((SELECT id FROM public.positions WHERE code = 'MD'), 'V3', 'Liquidity & funding decisions', 20,
     'Approve/secure cash plan that maintains ≥3 months fixed-OPEX liquidity buffer; 100% material cash commitments reviewed against 13-week forecast.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 3),
    ((SELECT id FROM public.positions WHERE code = 'MD'), 'V4', 'Strategic customers & supply continuity', 20,
     'Personally sponsor ≥5 priority strategic relationships by month 6; secure executive-level support for commitments covering ≥70% of planned initial capacity.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 4),
    ((SELECT id FROM public.positions WHERE code = 'MD'), 'V5', 'Safety & governance culture', 15,
     'Monthly management HSE/compliance review; 100% critical actions assigned and tracked; zero knowingly approved operation outside regulatory/safety controls.',
     false, NULL, 5),
    ((SELECT id FROM public.positions WHERE code = 'CFO'), 'T1', '13-week cash forecast', 25,
     'Update forecast weekly with 100% on-time completion; target forecast variance for next 4 weeks within ±10%.',
     false, NULL, 1),
    ((SELECT id FROM public.positions WHERE code = 'CFO'), 'T2', 'Liquidity buffer', 20,
     'Maintain minimum cash reserve ≥3 months fixed OPEX, with weekly visibility and documented mitigation for any projected breach.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 2),
    ((SELECT id FROM public.positions WHERE code = 'CFO'), 'T3', 'AR / collections discipline', 20,
     'Issue invoices within 2 working days of approved billing trigger; maintain DSO ≤45 days once meaningful billing begins; escalate overdue balances >30 days weekly.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 3),
    ((SELECT id FROM public.positions WHERE code = 'CFO'), 'T4', 'Financial controls for licensing & capex', 20,
     '100% licence, equipment and commissioning payments matched to approved budget/contract milestones; zero unapproved material commitments.',
     false, NULL, 4),
    ((SELECT id FROM public.positions WHERE code = 'CFO'), 'T5', 'Close & governance', 15,
     'Monthly management accounts and cash reconciliation completed by 5th working day; 100% material control exceptions logged and closed/actioned.',
     false, NULL, 5),
    ((SELECT id FROM public.positions WHERE code = 'CTO'), 'C1', 'Equipment delivery & installation', 25,
     '100% critical equipment specifications/POs confirmed; ≥90% critical delivery/installation milestones on time; installation sign-off completed.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 1),
    ((SELECT id FROM public.positions WHERE code = 'CTO'), 'C2', 'Commissioning & process acceptance', 25,
     'Complete ≥3 successful end-to-end commissioning runs from battery feed through separation/black mass output, with agreed safety, quality and process acceptance criteria met.',
     false, NULL, 2),
    ((SELECT id FROM public.positions WHERE code = 'CTO'), 'C3', 'Technical licensing support', 15,
     '100% required technical drawings, process descriptions, equipment data, risk assessments and regulator technical responses submitted by agreed dates.',
     false, NULL, 3),
    ((SELECT id FROM public.positions WHERE code = 'CTO'), 'C4', 'Process safety & operating readiness', 20,
     '100% critical SOPs, JSA/risk assessments, interlocks and emergency operating procedures completed and trained before relevant commissioning/operations.',
     false, NULL, 4),
    ((SELECT id FROM public.positions WHERE code = 'CTO'), 'C5', 'Maintenance resilience', 15,
     '100% critical equipment PM schedule and critical-spares list established before handover; downtime response protocol tested at least once.',
     false, NULL, 5),
    ((SELECT id FROM public.positions WHERE code = 'CCO'), 'S1', 'Priority customer conversion', 25,
     'Secure ≥3 priority customers at signed LOI/contract stage by month 3 and ≥5 by month 6, with clear volume/specification/price/terms.',
     false, NULL, 1),
    ((SELECT id FROM public.positions WHERE code = 'CCO'), 'S2', 'Revenue / order coverage', 25,
     'Build firm customer commitments covering ≥70% of planned initial processing capacity for the first 90 days after commissioning.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 2),
    ((SELECT id FROM public.positions WHERE code = 'CCO'), 'S3', 'Commercial terms & credit protection', 20,
     '100% customer contracts use approved pricing, Incoterms, payment milestones/deposits/credit limits and collection protections; 0 sales commitments without finance/operations capacity check.',
     false, NULL, 3),
    ((SELECT id FROM public.positions WHERE code = 'CCO'), 'S4', 'Order-to-cash readiness', 15,
     '100% contracted orders have feedstock check, production slot, assay/release, logistics, invoicing and collection owner documented before commitment.',
     false, NULL, 4),
    ((SELECT id FROM public.positions WHERE code = 'CCO'), 'S5', 'Customer quality / retention', 15,
     '100% customer product specifications and QA/assay requirements documented before shipment; 0 avoidable customer escalations caused by missing commercial/quality information.',
     false, NULL, 5),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-ACC'), 'A1', 'Cash & AR administration', 25,
     '100% customer invoices, receipts and AR ageing records maintained accurately; collection follow-up list updated and reconciled weekly.',
     false, NULL, 1),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-ACC'), 'A2', 'Corporate records & governance', 20,
     '100% statutory/corporate records, approvals, contracts and key registers maintained in a controlled repository; zero missing critical documents at monthly review.',
     false, NULL, 2),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-ACC'), 'A3', 'Licensing administration', 20,
     'Maintain master licence/regulatory document register with 100% submissions, approvals, expiry/renewal dates and regulator correspondence logged.',
     false, NULL, 3),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-ACC'), 'A4', 'Facility / HSE administration', 20,
     '100% required training, inspection, drill, incident and corrective-action records filed and current; monthly compliance pack issued on time.',
     false, NULL, 4),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-ACC'), 'A5', 'Payroll / people readiness', 15,
     '100% required employee onboarding, safety induction and training records complete before site duties; payroll/admin processed accurately and on schedule.',
     false, NULL, 5),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-WH'), 'F1', 'Warehouse & inventory readiness', 25,
     'Warehouse layout, segregation, labelling and inventory controls 100% ready before battery/material receipt; inventory accuracy ≥98% in monthly checks.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 1),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-WH'), 'F2', 'Inbound/ outbound declaration capability and clearance', 25,
     '100% inbound/outbound battery movements supported by required certification, documentation, classification, packaging and approved transport arrangements; 0 major logistics compliance breaches.',
     false, NULL, 2),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-WH'), 'F3', 'Feedstock coverage & inbound continuity', 20,
     'Maintain rolling inbound plan covering ≥100% of committed production requirements; escalate supply gaps ≥10 working days before planned receipt.',
     false, NULL, 3),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-WH'), 'F4', 'Dispatch & documentation', 15,
     '≥98% on-time dispatch readiness once sales begin; 100% shipping documents complete before dispatch and invoice trigger.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 4),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-WH'), 'F5', 'Warehouse safety & emergency readiness', 15,
     '100% warehouse staff trained on battery handling/emergency procedures; ≥2 emergency drills supported; 0 critical housekeeping/safety findings left overdue.',
     false, NULL, 5);

INSERT INTO public.kpi_template_org_links (template_id, org_code) VALUES
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'MD' AND t.kpi_ref = 'V1'), 'O1'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'MD' AND t.kpi_ref = 'V2'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'MD' AND t.kpi_ref = 'V3'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'MD' AND t.kpi_ref = 'V4'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'MD' AND t.kpi_ref = 'V5'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T1'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T2'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T3'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T4'), 'O1'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T4'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T5'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T5'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C1'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C2'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C3'), 'O1'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C4'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C5'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C5'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S1'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S2'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S2'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S3'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S3'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S4'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S4'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S5'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S5'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A1'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A2'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A2'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A3'), 'O1'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A4'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A5'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F1'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F1'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F2'), 'O1'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F2'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F3'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F4'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F4'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F5'), 'O5');
-- ⟨KPI-1 SEED END⟩
