-- db/migrations/2026-09-07-cod1-certificate-of-destruction.sql
-- COD-1:销毁证书 —— 交给【送料方】的那张纸,证明他交来的料被合法处理了。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【颗粒度:一次进货一张证书,整批加工完才成立】
-- ════════════════════════════════════════════════════════════════════════════
-- COD-0 的勘察是按"一张加工单一张证书"写的,Tim 之后改了裁定。改了之后:
--   * 一个进料批只属于一个供应商 —— 勘察 S1 的"混供应商"问题在证书这一层
--     【不存在】,不需要任何摊分;
--   * 纸上的数量就是这一票货自己的数量,"还剩多少没加工"按定义是零;
--   * 证书住在【进料批】页上,而仓储现场本来就持有 module.inbound.view。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【"整批加工完"是【派生】的,不是一个状态位 —— 这是实测过的】
-- ════════════════════════════════════════════════════════════════════════════
-- 现成的两个候选都不能承载一张法律文件,COD-1 逐个量过:
--
--   ① inbound_batches.stage = '已加工完'
--      【它是一个显示标签,不是判据】本表 13 个触发器【没有一个】守 stage;
--      app/inbound/[id]/edit 的表单上就是一个三选一的下拉框,人可以直接选;
--      create_inbound_batch 还收 p_stage 参数,一张批次可以【一建出来就是】
--      '已加工完'。而全仓库【没有任何生产代码读它做判断】。
--      拿它当闸,等于让仓管在下拉框里选一下就签发一张销毁证书。
--
--   ② remaining_qty = 0
--      【它说的是"这批空了",不是"这批被加工了"】实测 2026-09-07:11 张进料批
--      remaining_qty = 0,其中【只有 3 张】是被加工空的,另外 8 张是【注销】
--      注销空的。按它签发,等于告诉供应商"你的料我们处理了",而实际上它被报废了。
--
-- 所以判据是一句【对台账的查询】,而不是一个存下来的标记 —— 与 void_invoice
-- 的下游检查同一条规矩:*"判据是【派生】的……不设状态位 —— 状态位会与真相漂开"*。
-- 判据写在 cod_delivery_completion() 里,【只有那一份实现】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么"有过盘点调整"【不】拒绝 —— Tim 2026-09-07 的裁定与它的实测依据】
-- ════════════════════════════════════════════════════════════════════════════
-- 供应商送来的电池是【带壳过磅】的,而加工量(尤其 EV 包)是【拆壳之后】才算的,
-- 所以账实差是常态,不是错误。COD-1 量过那层壳落在哪里:
--   commit_processing_run 第 298 行 loss_qty = COALESCE(p_loss_qty,
--   v_total_input - v_total_output) —— 【损耗是加工单上的一个申报数字,
--   它不产生任何库存流水】,而投料腿消耗的是【过磅的全量】。
-- 也就是说拆下来的壳走的是 loss_qty(或一条废料产出腿),【不是】注销、
-- 【不是】盘点调整。于是判据里那句"不许有注销"照留不误:
--   * writeoff 流水只有一个写入者(emit_batch_writeoff_movement,只在
--     deleted_at 由空变非空时开火)—— 它的意思就是"这票货被报废了";
--   * adjustment 流水只有一个写入者(post_stocktake)—— 它的意思是"重数了一遍"。
-- 重数了一遍不是拒发证书的理由,所以判据【不看】adjustment,也不设任何阈值。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【冻结:两样都冻,这是本仓库第一次 —— 也是本刀唯一一次刻意的背离】
-- ════════════════════════════════════════════════════════════════════════════
-- 现成的八个 *_issues 族【只冻字节】,并且明写不另存推导结果;另一族四个成员
-- (contract_document_terms / pricing_term_commitments / invoices.bill_to_snapshot
-- / GST-2)【只抄数据】,不留字节。**没有任何一族两样都做。**
--
-- 销毁证书两样都要,理由是结构性的:
--   * 【字节证明那张纸没被改过】—— sha256 对得上,供应商手里那份就是发出去的那份;
--   * 【数据行才渲染得出一个网页】—— 一个 blob 加一个哈希【渲染不成网页】,
--     服务器只能把文件再发一遍,而核验页要【显示】证书的内容。
-- 纸是副本,核验页是原件。所以 snapshot(数据)与 cod_issues(字节)并存。
--
-- NOTE: 镜像见 db/tables/certificates_of_destruction.sql、db/tables/cod_issues.sql
-- 与 db/functions/ 下同名文件。

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1 · 权限:action.issue_cod
-- ═══════════════════════════════════════════════════════════════════════════
-- 【action 类,不是 module、也不是 data】签发是一个【动作】,与
-- action.bulk_import / action.manage_permissions 同一类;权限参考页
-- (app/settings/reference/page.tsx)已经认得这个类目,不用改一行代码。
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order)
VALUES ('action.issue_cod', 'action',
        'Issue certificate of destruction', '签发销毁证书',
        'Issue a certificate of destruction to the supplier who delivered the material.',
        '向送料方签发销毁证书',
        920);

-- 【仓储现场 + admin】过磅收货的人就是知道这票货处理完了的人。
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'action.issue_cod' FROM public.roles r WHERE r.code IN ('warehouse', 'admin');

-- ═══════════════════════════════════════════════════════════════════════════
-- 2 · 证书本身
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE public.certificates_of_destruction (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id  uuid NOT NULL REFERENCES public.inbound_batches (id),
    -- 【这一票货是哪一天加工完的】= 消耗它的【未冲销】加工单里最晚的那个 process_date。
    -- 它是派生的,所以【必须在签发时冻进 snapshot】—— 一旦后续有单被冲销,
    -- 它就再也算不回来了(S6 点名的那一条)。
    completed_on      date NOT NULL,
    -- 【没签发就没有号】nothing that was never sent consumes a number。
    -- 号在签发那一刻由 next_cod_code() 铸出,之前一直是 NULL。
    code              text,
    status            text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'issued', 'void')),
    issued_at         timestamptz,
    issued_by         uuid,
    -- 【核验令牌:与证书号毫无关系】UUID,122 位随机。改一位数字得到的是一个
    -- 【不存在】的值,而不是另一张证书 —— 这正是它不能由号码推出来的理由。
    verification_token uuid,
    -- 【冻结的数据行】签发那一刻纸上的每一个值,解析成文字与数字,绝不是外键。
    -- 读取路径【不许】拿里面的 id 回查内容(见 contract_document_terms 的警告:
    -- *"一旦那么写,抄就退化成了引用,而退化是静悄悄的"*)。
    snapshot          jsonb,
    void_reason       text,
    voided_at         timestamptz,
    voided_by         uuid,
    -- 【作废之后顶上来的那一张】数据变了要重发时非空;因冲销而作废时【为空】——
    -- 冲销说的是"这次加工没发生",于是这票货不再是加工完的,没有替代品。
    replaced_by_cod_id uuid REFERENCES public.certificates_of_destruction (id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    -- 签发过的必须号、令牌、快照、签发时刻俱全 —— 缺一个就渲染不出核验页。
    CONSTRAINT cod_issued_fields_present CHECK (
        status <> 'issued' OR (code IS NOT NULL AND verification_token IS NOT NULL
                               AND snapshot IS NOT NULL AND issued_at IS NOT NULL)),
    -- 作废必须有理由 —— 与 void_invoice 的 REASON_REQUIRED 同一条。
    CONSTRAINT cod_void_has_reason CHECK (
        status <> 'void' OR (void_reason IS NOT NULL AND btrim(void_reason) <> ''
                             AND voided_at IS NOT NULL)),
    -- 【没签发就不许有号】反向也钉住,免得将来某条路径顺手预铸一个号。
    CONSTRAINT cod_pending_has_no_number CHECK (
        status <> 'pending' OR (code IS NULL AND verification_token IS NULL AND snapshot IS NULL))
);

-- 【一票货同时只能有一张活证书】作废掉的留着 —— 供应商手里那张纸要查得到。
CREATE UNIQUE INDEX uq_cod_live_per_batch
    ON public.certificates_of_destruction (inbound_batch_id) WHERE status <> 'void';
-- 号在全库唯一(无缝编号的另一半:MAX+1 靠它不出现重号)。
CREATE UNIQUE INDEX uq_cod_code ON public.certificates_of_destruction (code) WHERE code IS NOT NULL;
CREATE UNIQUE INDEX uq_cod_token
    ON public.certificates_of_destruction (verification_token) WHERE verification_token IS NOT NULL;

COMMENT ON TABLE public.certificates_of_destruction IS
    'COD-1:销毁证书。一次进货一张,【整批加工完】才存在(判据见 cod_delivery_completion(),它是派生的、不是状态位)。四个状态:pending(已成立、未签发、【没有号】)/ issued(号、签发人、日期、印章、PDF、二维码、令牌、数据全冻)/ void(作废,行留着,字节与快照一字不动)/ 以及第四个【组装不出来】—— 那不是一行,是 cod_certificate_data() 的一句具名拒绝。【纸上没有任何产出批、没有化验、没有工序、没有人名】—— 产出是 Evoltrya 的产品,不是送料方的事。';

COMMENT ON COLUMN public.certificates_of_destruction.snapshot IS
    'COD-1:签发那一刻纸上每一个值的【副本】,解析成文字与数字。★与八个 *_issues 族的"只冻字节"是【刻意的背离】★ —— 字节证明那张纸没被改过,但一个 blob 加一个哈希【渲染不成网页】;核验页要显示证书的内容,所以必须有一行数据。纸是副本,核验页是原件。里面的 *_id 只回答"这来自哪一行",【任何读取路径都不许拿它回查内容】。';

ALTER TABLE public.certificates_of_destruction ENABLE ROW LEVEL SECURITY;

-- 【读:一个权限码,不多不少】S7 的裁定 —— 判据必须正好是一个能力,
-- 而且这张表【不接受供应商 id 作参数】,所以它成不了一扇查供应商的门。
CREATE POLICY "certificates_of_destruction select by permission"
    ON public.certificates_of_destruction
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('action.issue_cod'::text));
-- 【没有 INSERT / UPDATE / DELETE 策略,这是刻意的】唯一写入口是本刀的
-- 四支 SECURITY DEFINER 函数。档案不该有第二个写法。

-- 【签发之后,证书的内容一个字都不许改 —— 只许作废】
-- 与 invoices 同形:单据行本身可变(只能变成 void),而字节档案完全不可变。
CREATE OR REPLACE FUNCTION public.guard_cod_immutable_after_issue()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF OLD.status = 'pending' THEN
        RETURN NEW;   -- 还没发出去,pending → issued / 删除,都由函数把关
    END IF;
    -- 已签发或已作废:身份与内容冻住,只留作废那几列可写。
    IF NEW.code IS DISTINCT FROM OLD.code
       OR NEW.verification_token IS DISTINCT FROM OLD.verification_token
       OR NEW.snapshot IS DISTINCT FROM OLD.snapshot
       OR NEW.issued_at IS DISTINCT FROM OLD.issued_at
       OR NEW.issued_by IS DISTINCT FROM OLD.issued_by
       OR NEW.inbound_batch_id IS DISTINCT FROM OLD.inbound_batch_id
       OR NEW.completed_on IS DISTINCT FROM OLD.completed_on THEN
        RAISE EXCEPTION 'COD_ISSUED_IMMUTABLE|%', COALESCE(OLD.code, OLD.id::text);
    END IF;
    -- 【作废不可逆】—— 与 void_invoice 的 INVOICE_ALREADY_VOID 同一条。
    IF OLD.status = 'void' AND NEW.status <> 'void' THEN
        RAISE EXCEPTION 'COD_ALREADY_VOID|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_cod_immutable_after_issue
    BEFORE UPDATE ON public.certificates_of_destruction
    FOR EACH ROW EXECUTE FUNCTION public.guard_cod_immutable_after_issue();

-- 【签发过的证书不许硬删】pending 的可以(它从来不算数,见 refresh_cod_for_batch)。
CREATE OR REPLACE FUNCTION public.guard_cod_no_delete_after_issue()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'COD_NO_DELETE|%', COALESCE(OLD.code, OLD.id::text);
    END IF;
    RETURN OLD;
END;
$function$;

CREATE TRIGGER trg_cod_no_delete_after_issue
    BEFORE DELETE ON public.certificates_of_destruction
    FOR EACH ROW EXECUTE FUNCTION public.guard_cod_no_delete_after_issue();

-- ═══════════════════════════════════════════════════════════════════════════
-- 3 · 字节档案 —— so_issues 那一族的第九份
-- ═══════════════════════════════════════════════════════════════════════════
-- 【与另外八份唯一的不同:没有 version】
-- 另外八份里"重发"是同一份文件的新一版,号沿用。销毁证书不是:数据变了就
-- 【作废旧的、发一张新号的】(Tim 的裁定),所以【永远不会有第二版】。
-- 唯一的"再发一次"是把同一份字节再发给弄丢了纸的供应商 —— 那是取档,不是新版本。
-- 留一个恒等于 1 的 version 列,等于声明一件不会发生的事。
CREATE TABLE public.cod_issues (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cod_id     uuid NOT NULL REFERENCES public.certificates_of_destruction (id),
    file_path  text NOT NULL,
    sha256     text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at  timestamptz NOT NULL DEFAULT now(),
    issued_by  uuid,
    UNIQUE (cod_id)
);

COMMENT ON TABLE public.cod_issues IS
    'COD-1:销毁证书的字节档案,形状取自 so_issues / po_issues / shipment_issues / cn_issues / qt_issues / invoice_issues / statement_issues / traceability_report_issues(这是第九份)。【没有 version】—— 重发的定义在本族不同:数据变了就作废旧的、发一张新号的,所以永远没有第二版。【作废【不动】本表一个字】—— 供应商手里那份仍然查得到、仍然对得上哈希,这正是 append-only 的意义。';

CREATE OR REPLACE FUNCTION public.guard_cod_issue_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【自己报名,不靠外键顺带挡】改它或删它,就是把"当时发出去的是什么"
    -- 这个问题变成没有答案。
    RAISE EXCEPTION 'COD_ISSUE_IMMUTABLE|%', TG_OP;
END;
$function$;

CREATE TRIGGER trg_cod_issues_append_only
    BEFORE UPDATE OR DELETE ON public.cod_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_cod_issue_append_only();

ALTER TABLE public.cod_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "cod_issues select by permission"
    ON public.cod_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('action.issue_cod'::text));
-- 【没有 INSERT 策略,这是刻意的】唯一写入口是 record_cod_issue()。

-- ═══════════════════════════════════════════════════════════════════════════
-- 4 · 取号 —— COD-YYYY-NNNN
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.next_cod_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】与 next_traceability_report_code / next_credit_note_code
    -- 逐字同一套:共用一把锁会让一种单据烧掉另一种的号,而无缝的意思正是
    -- "号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('cod_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM certificates_of_destruction
    WHERE code LIKE 'COD-' || v_year::text || '-%';
    RETURN 'COD-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5 · 判据:这一票货加工完了没有 —— 【只有这一份实现】
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么它没有权限判据】它返回的是一个【派生事实】(布尔 + 一个日期),
-- 不含任何身份信息、价格或供应商数据 —— 而 remaining_qty 本来就对
-- module.inbound.view 开着。更要紧的是:refresh_cod_for_batch() 在
-- commit_processing_run 里以【投料的那个人】的身份跑,而运营角色并不持有
-- action.issue_cod;在这里设闸会把加工本身闸死。
-- (AGENTS.md 1097:派生事实以属主权限算,读者自己的模块判据写在【用它的】函数里。)
CREATE OR REPLACE FUNCTION public.cod_delivery_completion(p_inbound_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ib          record;
    v_consumed    numeric;
    v_completed   date;
    v_other_doors numeric;
    v_runs_total  integer;
    v_runs_dated  integer;
BEGIN
    SELECT ib.id, ib.code, ib.quantity, ib.remaining_qty, ib.unit, ib.deleted_at
      INTO v_ib FROM inbound_batches ib WHERE ib.id = p_inbound_batch_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'BATCH_NOT_FOUND');
    END IF;

    -- ① 【被注销的料没有被处理,它被报废了】实测:线上 11 张 remaining_qty = 0
    --    的进料批里,8 张是这一类。按 remaining_qty 签发就是替这 8 张撒谎。
    IF v_ib.deleted_at IS NOT NULL THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'DELIVERY_WRITTEN_OFF',
                                  'batch_code', v_ib.code);
    END IF;

    -- ② 【有没有从别的门出去过】writeoff 只有一个写入者(软删),
    --    sale 是卖掉 —— 两者都不是"被我们处理掉了"。
    --    ★ adjustment 【刻意不在这个清单里】★ 见文件抬头:带壳过磅、拆壳后计量,
    --    账实差是常态;重数一遍不是拒发证书的理由,也不设任何阈值。
    SELECT COALESCE(sum(-m.qty_delta), 0) INTO v_other_doors
      FROM inventory_movements m
     WHERE m.inbound_batch_id = p_inbound_batch_id
       AND m.qty_delta < 0
       AND m.movement_type IN ('writeoff', 'sale');
    IF v_other_doors > 0 THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'DELIVERY_LEFT_BY_ANOTHER_DOOR',
                                  'batch_code', v_ib.code, 'quantity', v_other_doors);
    END IF;

    -- ③ 【被【未冲销】的加工单吃掉了多少】冲销的单不算 —— 冲销说的是那次加工没发生。
    SELECT COALESCE(sum(pi.quantity_consumed), 0),
           max(r.process_date),
           count(*), count(r.process_date)
      INTO v_consumed, v_completed, v_runs_total, v_runs_dated
      FROM processing_inputs pi
      JOIN processing_runs r ON r.id = pi.run_id
     WHERE pi.inbound_batch_id = p_inbound_batch_id
       AND r.deleted_at IS NULL;

    -- ④ 【一克都没加工过的,不可能是"加工完了"】没有这一句,一张被盘点调整
    --    清零的批次会读成"完成",而它根本没进过产线。
    IF v_consumed <= 0 THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'NOTHING_PROCESSED',
                                  'batch_code', v_ib.code);
    END IF;

    -- ⑤ 还有料在场 = 还没加工完。
    IF v_ib.remaining_qty > 0 THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'DELIVERY_NOT_FULLY_PROCESSED',
                                  'batch_code', v_ib.code,
                                  'remaining', v_ib.remaining_qty, 'unit', v_ib.unit);
    END IF;

    -- ⑥ 【完成日期算不出来就拒绝,绝不拿今天顶上】process_date 可空(早期数据),
    --    而这个日期要印在一张法律文件上。与 FIN-10「永不默认入账日」同一条。
    IF v_completed IS NULL THEN
        RETURN jsonb_build_object('complete', false, 'reason', 'COMPLETION_DATE_UNKNOWN',
                                  'batch_code', v_ib.code, 'runs', v_runs_total);
    END IF;

    RETURN jsonb_build_object(
        'complete', true,
        'batch_code', v_ib.code,
        'completed_on', v_completed,
        'consumed', v_consumed,
        'runs_total', v_runs_total,
        'runs_dated', v_runs_dated);
END;
$function$;

COMMENT ON FUNCTION public.cod_delivery_completion(uuid) IS
    'COD-1:【这一票货整批加工完了没有】—— 销毁证书成立与否的唯一判据,派生自库存台账,不是任何一个状态位。实测过的两个现成候选都不能用:inbound_batches.stage 是一个【人可以在下拉框里选】的显示标签(13 个触发器没有一个守它,全仓库没有生产代码读它);remaining_qty = 0 说的是"这批空了"而不是"被加工了"(2026-09-07 实测:11 张空批里 8 张是注销空的)。六条有序判断,每一条都返回一个【具名】理由,调用方原样往上抛 —— 一张"来源不详"的证书比没有证书更坏。';

-- ═══════════════════════════════════════════════════════════════════════════
-- 6 · 组装 —— 一票进货 → 一张证书的全部内容
-- ═══════════════════════════════════════════════════════════════════════════
-- 【一道门,正好一个权限码】S7 的裁定。而且它【只收进料批 id】,永远不收
-- 供应商 id —— 那正是让它成不了一扇"查供应商"的门的那一条。
--
-- 【它拿到的供应商信息只有【名字】】不是一份供应商档案:没有地址、没有联系人、
-- 没有价格、没有别的身份数据。仓储现场因此够得着证书的主体,而 suppliers 本身
-- 仍然对他们关着(RLS: module.suppliers.view,warehouse 不持有)。
--
-- 【它一张带判据的视图都不读】—— 这是本刀相对 COD-0 勘察的一处改动:
-- 在"一次进货一张证书"的颗粒度下,加上"纸上没有任何产出批"的裁定,
-- 证书【不需要血缘】。batch_lineage_all 是从 processing_outputs 往【上】递归、
-- 回答"这个产出批是哪来的",与本文件的方向相反。所以 fixture 83 的那条教训
-- (owner rights 顶不掉视图体内的 has_permission,零行会读成"这批料没有来源")
-- 在这里以【不读那类视图】的方式兑现,而不是以"读对了哪一支"的方式。
CREATE OR REPLACE FUNCTION public.cod_certificate_data(p_inbound_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ib   record;
    v_comp record;
    v_lic  record;
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

    -- 【执照:在组装时【读】company_compliance,不是读一个设置开关】
    -- 于是把真正的 GWDF 号录进去那一天,之后每一张证书自动带上它 ——
    -- 不用改一行代码,也没有任何要有人记得去翻的开关。
    -- ★ status IS NULL 是【没有人说过】,不是 active ★(与
    -- approved_storage_limit_tonnes 的那条注释同一句话)。
    SELECT cc.cert_no, cc.issuing_body, cc.valid_from, cc.valid_until, cc.status, cc.scope
      INTO v_lic
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf'
       AND cc.deleted_at IS NULL
       AND cc.status = 'active'
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
     ORDER BY cc.valid_until DESC NULLS LAST
     LIMIT 1;

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
        'licence', CASE WHEN v_lic.cert_no IS NULL THEN NULL ELSE jsonb_build_object(
            'cert_no', v_lic.cert_no, 'issuing_body', v_lic.issuing_body,
            'valid_from', v_lic.valid_from, 'valid_until', v_lic.valid_until,
            'scope', v_lic.scope) END,
        'certificate', CASE WHEN v_cod.id IS NULL THEN NULL ELSE jsonb_build_object(
            'id', v_cod.id, 'code', v_cod.code, 'status', v_cod.status,
            'issued_at', v_cod.issued_at,
            'verification_token', v_cod.verification_token) END,
        'provenance', jsonb_build_object('run_ids', v_runs)
    );
END;
$function$;

COMMENT ON FUNCTION public.cod_certificate_data(uuid) IS
    'COD-1:把一票进货组装成一张销毁证书的全部内容。【一道门,正好一个权限码 action.issue_cod】,并且【只收进料批 id、永不收供应商 id】—— 那是让它成不了一扇查供应商的门的那一条。返回的供应商信息【只有名字与编号】,suppliers 本身对仓储现场仍然关着。【纸上没有产出批、没有化验、没有工序、没有人名】。【它一张带判据的视图都不读】—— 这个颗粒度下证书不需要血缘。第四个状态"组装不出来"由 CANNOT_CERTIFY|批号|具名理由 抛出,判据不在这里重写(只有 cod_delivery_completion 说了算)。';

-- ═══════════════════════════════════════════════════════════════════════════
-- 7 · 作废 —— void_invoice 的机制,逐条转写
-- ═══════════════════════════════════════════════════════════════════════════
-- 【内部那一支不查权限】它由 rollback_processing_run 调用,而冲销加工单的人
-- (运营角色)并不持有 action.issue_cod。在这里设闸会把冲销闸死 ——
-- 而"冲销之后那张证书还挂在外面说着假话"比谁按的按钮要紧得多。
CREATE OR REPLACE FUNCTION public.void_cod_internal(p_cod_id uuid, p_reason text,
                                                    p_replaced_by uuid DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【作废【不动】字节档案与快照一个字】—— 供应商手里那张纸仍然查得到、
    -- 仍然对得上哈希。与 invoice_issues 在作废后原样保留同一条。
    UPDATE certificates_of_destruction
       SET status = 'void', void_reason = p_reason,
           voided_at = clock_timestamp(), voided_by = auth.uid(),
           replaced_by_cod_id = p_replaced_by
     WHERE id = p_cod_id AND status = 'issued';
END;
$function$;

CREATE OR REPLACE FUNCTION public.void_cod(p_cod_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cod record;
BEGIN
    IF NOT has_permission('action.issue_cod') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    -- 【没有 p_reversal_date】证书不入账,没有期间可言。void_invoice 的第 8 条:
    -- 一个用不上的参数要【拒绝】而不是收下再丢掉 —— 收下再丢掉是在对调用者撒谎。
    -- 这里更进一步:那个参数压根不存在。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    SELECT c.id, c.code, c.status INTO v_cod
      FROM certificates_of_destruction c WHERE c.id = p_cod_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(p_cod_id::text, '?');
    END IF;
    -- 【只有已签发的才作废得掉,而且作废不是幂等的】与 INVOICE_ALREADY_VOID 同一条。
    IF v_cod.status <> 'issued' THEN
        RAISE EXCEPTION 'COD_NOT_ISSUED|%|%', COALESCE(v_cod.code, v_cod.id::text), v_cod.status;
    END IF;

    PERFORM void_cod_internal(p_cod_id, p_reason, NULL);
    RETURN jsonb_build_object('cod_id', p_cod_id, 'code', v_cod.code, 'status', 'void');
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 8 · 自动成立与自动作废 —— 证书是一条【必须存在】的记录
-- ═══════════════════════════════════════════════════════════════════════════
-- Tim 的裁定:销毁证书不是"谁打开了页面才被造出来"的东西。它像化验报告一样
-- 【必须存在】—— 客户要不要是另一个问题。所以一票货加工完的那一刻,
-- 未签发的证书就成立了;签发是把一条已经存在的记录变成一份寄出去的文件。
--
-- 【幂等】重复调用不做第二件事;每一个会动 remaining_qty 的地方都可以放心地叫它。
CREATE OR REPLACE FUNCTION public.refresh_cod_for_batch(p_inbound_batch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_done jsonb;
    v_cod  record;
BEGIN
    IF p_inbound_batch_id IS NULL THEN RETURN; END IF;

    v_done := cod_delivery_completion(p_inbound_batch_id);

    SELECT c.id, c.status, c.code INTO v_cod
      FROM certificates_of_destruction c
     WHERE c.inbound_batch_id = p_inbound_batch_id AND c.status <> 'void'
     FOR UPDATE;

    IF (v_done->>'complete')::boolean THEN
        IF v_cod.id IS NULL THEN
            INSERT INTO certificates_of_destruction (inbound_batch_id, completed_on)
            VALUES (p_inbound_batch_id, (v_done->>'completed_on')::date);
        END IF;
        RETURN;
    END IF;

    -- 不再成立了。两种收场,而它们【不是同一件事】:
    IF v_cod.id IS NULL THEN
        RETURN;
    ELSIF v_cod.status = 'pending' THEN
        -- 【从未签发的证书删掉,什么都不消耗】它没有号、没有令牌、没出过这栋楼。
        -- 留着一条"曾经成立过"的空记录,只会让页面上出现一张不能签发的证书。
        DELETE FROM certificates_of_destruction WHERE id = v_cod.id;
    ELSE
        -- 【已签发 → 作废,且【没有替代品】】冲销说的是"这次加工没发生",
        -- 于是这一票货不再是加工完的。将来重新加工到完,那时会成立一张【新的】证书。
        PERFORM void_cod_internal(v_cod.id, 'PROCESSING_REVERSED|' || COALESCE(v_done->>'reason', '?'), NULL);
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.refresh_cod_for_batch(uuid) IS
    'COD-1:让销毁证书跟上库存台账。【证书是一条必须存在的记录】—— 一票货整批加工完的那一刻它就成立,不等谁打开页面。幂等,由 commit_processing_run / rollback_processing_run / 软删三处各一行调用。不再成立时两种收场,而它们不是同一件事:从未签发的【删掉】(没有号、没出过楼,什么都不消耗),已签发的【作废且没有替代品】(冲销说的是那次加工没发生)。';

-- ═══════════════════════════════════════════════════════════════════════════
-- 9 · 签发 —— 执照闸就在这里
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么闸在函数里,以属主权限求值】company_compliance 的 RLS 借的是
-- module.suppliers.view 那道门(它自己的表注记着这是一扇借来的门),
-- 而【仓储现场不持有它】—— 于是签发的人读不到那条决定他能不能签发的记录。
-- 把执照读权限授给仓储现场是另一个方向的错(那会连供应商资质一起打开),
-- 所以判据在这里,以属主身份求值,读者一格都不多拿。
CREATE OR REPLACE FUNCTION public.issue_cod(p_cod_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cod   record;
    v_lic   record;
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

    -- ── 执照闸 ────────────────────────────────────────────────────────────
    -- 【status IS NULL 是"没有人说过",不是 active】与
    -- approved_storage_limit_tonnes 的那条注释同一句:*"NULL 不表示『没有上限』,
    -- 表示『没有人录过上限』"*。把 NULL 读成 active,正是这个仓库反复付账的那类缺陷。
    -- 【不发明任何占位执照号】—— 表今天是空的,所以今天什么都签发不了,而那是对的:
    -- NEA 发照之前 Tim 不会买料。
    SELECT cc.cert_no INTO v_lic
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf'
       AND cc.deleted_at IS NULL
       AND cc.status = 'active'
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
     LIMIT 1;
    IF NOT FOUND THEN
        -- 【拒绝要说得出下一步去哪】与 loadDocumentCompany 的 COMPANY_MISSING_MESSAGE
        -- 同一条:一句报不出去处的拒绝,等于把人留在原地。
        RAISE EXCEPTION 'COD_LICENCE_NOT_RECORDED|/purchasing/licences';
    END IF;

    -- 【签发那一刻再问一次判据】—— 不重写,问同一支函数。
    v_done := cod_delivery_completion(v_cod.inbound_batch_id);
    IF NOT (v_done->>'complete')::boolean THEN
        RAISE EXCEPTION 'CANNOT_CERTIFY|%|%', v_done->>'batch_code', v_done->>'reason';
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

COMMENT ON FUNCTION public.issue_cod(uuid) IS
    'COD-1:把一条已经成立的销毁证书变成一份寄出去的文件 —— 铸号(COD-YYYY-NNNN,无缝)、铸核验令牌(UUID,与号码毫无关系)、把纸上每一个值冻进 snapshot。【执照闸在这里,以属主权限求值】:company_compliance 借的是 module.suppliers.view 那道门,而仓储现场不持有它 —— 签发的人读不到那条管着他的记录,所以判据在函数里,读者一格都不多拿。【status IS NULL 是"没有人说过",不是 active】。【不发明占位执照号】—— 表今天是空的,所以今天签发不了,而那是对的。';

-- ═══════════════════════════════════════════════════════════════════════════
-- 10 · 字节入档
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_cod_issue(p_cod_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cod record;
BEGIN
    IF NOT has_permission('action.issue_cod') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    SELECT c.id, c.code, c.status INTO v_cod
      FROM certificates_of_destruction c WHERE c.id = p_cod_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(p_cod_id::text, '?');
    END IF;
    -- 【只有已签发的才有字节可存】没签发的没有号,那份 PDF 上印不出号来。
    IF v_cod.status <> 'issued' THEN
        RAISE EXCEPTION 'COD_NOT_ISSUED|%|%', COALESCE(v_cod.code, v_cod.id::text), v_cod.status;
    END IF;

    INSERT INTO cod_issues (cod_id, file_path, sha256, issued_by)
    VALUES (p_cod_id, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('cod_id', p_cod_id, 'code', v_cod.code, 'sha256', p_sha256);
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 11 · 三个挂钩 —— 每处【只加一次调用】,既有的每一行原样不动
-- ═══════════════════════════════════════════════════════════════════════════
-- 证书要跟上库存台账,而台账在三个地方动进料批的 remaining_qty:
--   * commit_processing_run   投料 → 可能【刚好加工完】→ 证书成立
--   * rollback_processing_run 冲销 → 料回来了 → 已签发的作废(没有替代品)
--   * soft_delete_inbound_batch 注销 → 这票货被报废了,不是被处理了 → 同上
-- 每一支都是把整支函数按【线上现有定义】原样重建,只多出一个 PERFORM。
-- 【为什么放在函数末尾】refresh 读的是 remaining_qty 与流水的最终状态;
-- 放在中间会读到一个还没落完的库存。

CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text)
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
    v_eq           fixed_assets%ROWTYPE;  -- EQP-2a:这一炉归给哪台机器
    -- PROC-WIRE-1B-i:这一炉跑的是哪道工序,以及那道工序【吃不吃料、产不产批】。
    -- 【分支读的是字典那两列,不是一个写死的字符串,也不是调用方传的旗标】
    -- 【PROC-SUPPORT-1】v_consumes / v_produces 不再有"没有工序时"的默认值 ——
    -- 到得了这里就一定有工序,两个值都由字典填。留着 := true 会是一句谎:
    -- 它读起来像"还有一条没有工序的路",而那条路已经在上面被拒掉了。
    v_op           text;
    v_consumes     boolean;
    v_produces     boolean;
    v_result_state text;
BEGIN
    PERFORM require_permission('module.processing.edit');
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
    -- PROC-WIRE-1B-i:解析工序类型。**分支由【工序】决定,不由调用方传旗标决定** ——
    -- 一个 p_is_state_changing 参数会让"这一炉算不算直通"变成调用方的意见,
    -- 而它是那道工序的事实。两者的区别在第一次有人传错的时候才显形,那太晚了。
    -- 【PROC-SUPPORT-1:这一段不再被 IF ... IS NOT NULL 包着】—— 上面那条拒绝
    -- 已经保证到得了这里就有工序。留着那个 IF 会读起来像"还有一条没有工序的路"。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT ot.code, k.consumes_input, k.produces_outputs, ot.resulting_safety_state_code
      INTO v_op, v_consumes, v_produces, v_result_state
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
    IF p_equipment_id IS NOT NULL THEN
        SELECT * INTO v_eq FROM fixed_assets WHERE id = p_equipment_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_FOUND|%', p_equipment_id;
        END IF;
        -- 【拒绝的边界钉在"真的不可能"上,不钉在"还没投用"上】
        -- 加工日早于取得日 = 那天这台机器还不是我们的。
        IF p_process_date < v_eq.acquisition_date THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_ACQUIRED|%|%|%',
                v_eq.code, v_eq.acquisition_date, p_process_date
              USING HINT = '这一炉的日期早于这台机器的取得日 —— 那天它还不是我们的';
        END IF;
        -- 处置之后它已经不在了。
        IF v_eq.status = 'disposed' AND v_eq.disposal_date IS NOT NULL
           AND p_process_date > v_eq.disposal_date THEN
            RAISE EXCEPTION 'EQUIPMENT_DISPOSED|%|%|%',
                v_eq.code, v_eq.disposal_date, p_process_date
              USING HINT = '这一炉的日期晚于这台机器的处置日 —— 那时它已经不在了';
        END IF;
        -- 【投用之前【不】拒 —— 这是 EQP-2a 对原设计改动最大的一处】
        -- 原设计要拒"加工日那天机器不在役",而 in_service_date 是【投用】日。
        -- 投用之前的试车是这盘生意里一件有名有姓的事:
        -- docs/equipment-survey.md 的资本化边界那一节把"试车料"与安装、调试并列。
        -- 拒掉它们,系统就【记不下那些正好用来证明投用日的加工】,也丢掉了
        -- 那段真实的磨损 —— 而 EQP-2b 的保养间隔要读它。
        -- 剩下被拒的两种都是真的不可能,所以它们【是拒绝,不是警告】。
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
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_qty := (v_output->>'quantity')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
        END IF;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
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
        operation_type_code
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        CASE WHEN v_produces THEN COALESCE(p_loss_qty, v_total_input - v_total_output)
             ELSE 0 END,
        p_notes, 'committed', p_allocation_basis, p_work_order_id, v_user_id, v_user_id,
        p_equipment_id,
        v_op
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
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                DELETE FROM inbound_batch_safety_states s
                 WHERE s.inbound_batch_id = v_inbound_id
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
                VALUES (v_inbound_id, v_result_state)
                ON CONFLICT (inbound_batch_id, safety_state_code) DO NOTHING;
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
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                DELETE FROM output_batch_safety_states s
                 WHERE s.output_batch_id = v_output_id
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code)
                VALUES (v_output_id, v_result_state)
                ON CONFLICT (output_batch_id, safety_state_code) DO NOTHING;
            END IF;
        END IF;
    END LOOP;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := (v_output->>'quantity')::numeric;
        v_unit        := COALESCE(NULLIF(v_output->>'unit', ''), 'kg');
        v_purity      := NULLIF(v_output->>'purity', '');

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
        VALUES (v_run_id, v_new_output_id, v_qty);
    END LOOP;

    -- 用毕即清(price_ctx 同一条理由:免得同事务内后续的直改被误放行 ——
    -- fixture 19F 实测:不清,守卫触发器对残留 ctx 放行裸 INSERT)
    PERFORM set_config('evoltrya.movement_ctx', '', true);

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

CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_run_deleted_at timestamptz;
    v_process_date date;     -- FIN-32:还原流水的业务日 = 原加工单的加工日
    v_bad_output record;
    v_input record;
    v_old_remaining numeric;
    v_new_remaining numeric;
    v_quantity numeric;
    v_cap uuid;             -- 首挂的资本化分录
    v_delta_id uuid;        -- PROC-COST-2:重分摊的差额分录,逐张
    v_code text;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- AUDEL-1b:【理由必填】回滚一张加工单是一次很大的操作动作 —— 它软删产出批、
    -- 还原投入、写一整串冲销流水 —— 而此前它【一个 why 都不记】。
    -- 校验放在任何写之前:被拒 = 什么都没发生。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ROLLBACK_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM processing_runs WHERE id = p_run_id), '?');
    END IF;
    -- 1. 锁定加工单，校验存在且未删除
    SELECT process_date INTO v_process_date FROM processing_runs WHERE id = p_run_id;
    SELECT deleted_at INTO v_run_deleted_at
    FROM processing_runs
    WHERE id = p_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;

    IF v_run_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_ALREADY_DELETED';
    END IF;

    -- 标记本次为回滚上下文,供产出批次软删触发器发出 reversal_void。
    PERFORM set_config('evoltrya.movement_ctx', 'reversal:' || p_run_id::text, true);

    -- 2. 安全检查：任何一个产出批次动过就拒绝
    SELECT ob.code, ob.state, ob.quantity, ob.remaining_qty
    INTO v_bad_output
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id
      AND ob.deleted_at IS NULL
      AND (ob.state <> '库存中' OR ob.remaining_qty <> ob.quantity)
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'OUTPUT_CONSUMED|%|%|%|%',
            v_bad_output.code, v_bad_output.state, v_bad_output.remaining_qty, v_bad_output.quantity;
    END IF;

    -- 3. 还原进料：加回 remaining_qty，重判 stage，记 reversal_restore 流水。
    --    FIN-25:产出批投料同样还原(不碰 state —— 那是销售状态)。
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        IF v_input.inbound_batch_id IS NOT NULL THEN
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM inbound_batches
            WHERE id = v_input.inbound_batch_id
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 进料批次已被删，跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.inbound_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:还原不是物理事件,是在更正一次记错的加工单 —— 业务日取
                -- 【原加工单的 process_date】,于是消耗与还原在同一天对消,
                -- 中间那几天的库存历史不会凭空少掉一批实际还在的货。
                --
                -- 【IOD-1:逐行镜像原始流水,不按规则重新分配】投料现在可能跨几个
                -- 库位桶写出多行;还原必须把货放回【它原来所在的那些桶】,而不是
                -- 按 drain 的顺序倒着来一遍 —— 那两者在一般情形下并不相等,
                -- 差额会安静地把库存挪到别的库位上。所以这里读原始的
                -- processing_consume 行,逐行取反。
                PERFORM mirror_consume_restore(p_run_id, v_input.inbound_batch_id, NULL,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        ELSE
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM output_batches
            WHERE id = v_input.output_batch_id AND deleted_at IS NULL
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 上游产出批已被删（如其自身加工单已冲销），跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.output_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:同上 —— 产出批投料的还原(FIN-25 那条边)业务日一样取原加工日
                PERFORM mirror_consume_restore(p_run_id, NULL, v_input.output_batch_id,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        END IF;
    END LOOP;

    -- 4. 软删这张单生成的产出批次(void 流水 + 归零由 BEFORE UPDATE 触发器处理)
    -- AUDEL-1b:软删要走门 —— 标记 + deleted_by + delete_reason,否则
    -- guard_soft_delete_provenance 会按名拒。产出批的删除理由【就是这次回滚的
    -- 理由】:它们不是被单独注销的,是被这次回滚带走的。
    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE output_batches
    SET deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id IN (
        SELECT output_batch_id FROM processing_outputs WHERE run_id = p_run_id
    )
    AND deleted_at IS NULL;

    -- 5. 软删加工单本身（腿表保留作审计）
    UPDATE processing_runs
    SET status = 'reversed',
        deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);   -- 用毕即清(同 movement_ctx)

    -- ════════════════════════════════════════════════════════════════════════
    -- 【解除资本化 —— 台账与分录在同一个地方一起解除】(PROC-COST-1 立,
    --   PROC-COST-2 把工序种类的判断【拿掉】)
    --
    -- 台账那一半由基函数按本单的 deleted_at 自动排除(形状免费提供的);
    -- 分录那一半必须显式冲销 —— 两半都在这里发生,所以它们永远不会各说各话。
    -- 少做任何一半:要么成本留在存货上而单已经没了(账挂在一张不存在的单上),
    -- 要么台账清了而存货虚高。
    --
    -- ★【PROC-COST-2:这里原来有一句 `IF v_sc_kind`,只管状态改变型】★
    -- 于是**转化型加工单回滚之后,它的资本化分录(借 1220 / 贷 1200 / 贷 5xxx)
    -- 原样立着** —— 产出批已经被软删,1220 上却还挂着它的成本。
    -- 那个判断本刀【拿掉】:两种工序共用同一段代码,不是照着它再写一份。
    --   * 状态改变型:冲销 借 1200 / 贷 5xxx,成本从原料批上退回费用;
    --   * 转化型:    冲销 借 1220 / 贷 1200 / 贷 5xxx —— 1220 上的产出成本
    --     被拿掉,而投料的 1200 同时被还回来,与第 3 步还原 remaining_qty 同向。
    --
    -- 【产出批软删【不再】另外入账,这两件事必须一起读】注销触发器在
    -- reversal 上下文里不写分录 —— 因为解除 1220 的是这里冲销的这张分录。
    -- 两处都做就是重复计数。
    --
    -- ★【差额分录也要冲 —— 只补首挂的话,一张被重分摊过的单仍然错】★
    -- 转化型重分摊走的是差额路径:capitalization_entry_id 仍指首挂,新的差额
    -- 分录记在 allocation_snapshot->'delta_entry_ids' 里。只冲首挂,差额留在
    -- 1220 上,而这张单看起来已经修好了 —— 那是最坏的一种半修。
    -- (状态改变型不会有差额分录:它走的是冲旧挂新,capitalization_entry_id
    --  永远指着唯一活着的那一张。这个循环对它自然空转,不需要分支。)
    --
    -- 【第四个候选:sales_records 上的 COGS 分录 —— 不需要任何处置】
    -- 第 2 步的 OUTPUT_CONSUMED 闸在任何产出动过之后就拒绝回滚,而一次销售
    -- 必然动 remaining_qty。**够不到的东西不需要修,但需要被点名**,
    -- 否则下一个读到这里的人会把这条推理重做一遍。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT code, capitalization_entry_id INTO v_code, v_cap
      FROM processing_runs WHERE id = p_run_id;

    IF v_cap IS NOT NULL
       AND (SELECT status FROM journal_entries WHERE id = v_cap) = 'posted' THEN
        PERFORM reverse_journal_entry_internal(v_cap, CURRENT_DATE,
            'Rollback ' || COALESCE(v_code, '?'));
    END IF;

    FOR v_delta_id IN
        SELECT (jsonb_array_elements_text(
                    COALESCE(pr.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)))::uuid
          FROM processing_runs pr WHERE pr.id = p_run_id
    LOOP
        IF (SELECT status FROM journal_entries WHERE id = v_delta_id) = 'posted' THEN
            PERFORM reverse_journal_entry_internal(v_delta_id, CURRENT_DATE,
                'Rollback ' || COALESCE(v_code, '?'));
        END IF;
    END LOOP;

    UPDATE processing_runs
       SET capitalization_entry_id = NULL, capitalized_cost_base = 0
     WHERE id = p_run_id;

    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)

    -- ── COD-1:冲销之后,这几票货不再是"加工完"的 ────────────────────────
    -- 【已签发的证书在这里作废,而且没有替代品】—— 冲销说的是那次加工没发生。
    -- 不做这一步,供应商手里那张纸就还在说着一件系统已经不再相信的事,
    -- 而没有任何东西会提醒任何人。将来重新加工到完,那时会成立一张新的证书。
    FOR v_input IN
        SELECT DISTINCT pi.inbound_batch_id FROM processing_inputs pi
         WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL
    LOOP
        PERFORM refresh_cod_for_batch(v_input.inbound_batch_id);
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.soft_delete_inbound_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_code text;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填,而且拒绝要按名】注销一批料是一次真实的物理事件
        -- (它会写一条 writeoff 流水)。没有理由的注销,事后没有人答得出为什么。
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|inbound_batches|%',
            COALESCE((SELECT code FROM inbound_batches WHERE id = p_batch_id), '?');
    END IF;

    SELECT code INTO v_code FROM inbound_batches
     WHERE id = p_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE inbound_batches
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user, updated_at = now()
     WHERE id = p_batch_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);

    -- ── COD-1:注销掉的料【不是被处理掉的】────────────────────────────────
    -- 实测:线上 11 张 remaining_qty = 0 的进料批里 8 张是这一类。
    -- 一张已签发的证书在这里作废 —— 它说的是"我们处理了你的料",而这票货被报废了。
    PERFORM refresh_cod_for_batch(p_batch_id);

    RETURN jsonb_build_object('id', p_batch_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 12 · 事务内自检 —— 装错了当场回滚,而不是留一个安静的半成品
-- ═══════════════════════════════════════════════════════════════════════════
DO $cod_install_check$
DECLARE
    v_perm  integer;
    v_roles integer;
    v_yes   integer;
    v_cods  integer;
BEGIN
    SELECT count(*) INTO v_perm FROM permissions WHERE code = 'action.issue_cod';
    IF v_perm <> 1 THEN RAISE EXCEPTION 'COD_INSTALL:权限没装上'; END IF;

    SELECT count(*) INTO v_roles FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'action.issue_cod';
    IF v_roles <> 2 THEN RAISE EXCEPTION 'COD_INSTALL:授权角色数是 %,应为 2', v_roles; END IF;

    -- 判据当场跑一遍全库:必须正好挑中那三张【被加工空】的进料批,
    -- 而不是十一张【remaining_qty = 0】的批次。这个 3 与 11 的差,
    -- 就是本刀最要紧的那条判断。
    SELECT count(*) INTO v_yes FROM inbound_batches ib
     WHERE (cod_delivery_completion(ib.id)->>'complete')::boolean;
    IF v_yes <> 3 THEN
        RAISE EXCEPTION 'COD_INSTALL:判据挑中 % 张进料批,2026-09-07 实测应为 3 张', v_yes;
    END IF;

    -- 回填:装上的这一刻,已经加工完的那几票货【就该有一张未签发的证书】——
    -- 证书是一条必须存在的记录,不是从今往后才开始存在的东西。
    INSERT INTO certificates_of_destruction (inbound_batch_id, completed_on)
    SELECT ib.id, (cod_delivery_completion(ib.id)->>'completed_on')::date
      FROM inbound_batches ib
     WHERE (cod_delivery_completion(ib.id)->>'complete')::boolean;

    SELECT count(*) INTO v_cods FROM certificates_of_destruction;
    IF v_cods <> 3 THEN RAISE EXCEPTION 'COD_INSTALL:回填出 % 张证书,应为 3', v_cods; END IF;

    -- 【没有一张带号】—— 从未签发的东西不消耗号码。
    IF EXISTS (SELECT 1 FROM certificates_of_destruction WHERE code IS NOT NULL) THEN
        RAISE EXCEPTION 'COD_INSTALL:回填的证书里有带号的,而它们一张都没签发过';
    END IF;

    RAISE NOTICE 'COD-1 装好:权限 1、授权 2、判据挑中 3、回填证书 3、带号 0';
END
$cod_install_check$;

COMMIT;
