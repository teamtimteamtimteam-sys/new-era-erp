-- db/tables/output_batches.sql
-- 产出批次(加工产物,可售库存)。与 inbound_batches 同一套库存台账体系:
-- remaining_qty 由触发器维护、quantity 禁改、恒等式由 DEFERRABLE 约束触发器
-- 提交时校验(函数都在 db/functions/inventory_ledger_triggers.sql,挂载在本文件)。
-- state 是【销售状态】(库存中/部分售出/已售罄,中文取值),status 才是单据状态。
-- PROC-WIRE-1A:state 的取值改由字典表 output_batch_states 定义(CHECK → 外键),
-- **取值集合一个字没变**;并新增 purpose_code —— 【另一条轴】,答"这批是干什么用的"。
-- 两条轴不许合并:一批被工序吃光的投料 remaining_qty 归零而【不是】已售罄。
-- customer_id 可空:预售指定客户时才填。code 'OUT-YYYY-NNNN' 触发器取号(非无缝)。
-- 无 updated_at 触发器(建表早期漏挂)—— 镜像忠实于线上。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE public.output_code_seq;
-- MES-4b(2026-10-07,MES-0 Q54;MES-4b Step 0 Q12 · Q13):每一种产品前缀一条序列(document_types.sequence_name 登记它)。
--   有洞、不按年重置,号从第一个起就是五位(generate_output_code)。OUT 仍用 output_code_seq。
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

CREATE TABLE public.output_batches (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code          text NOT NULL UNIQUE,  -- 'OUT-YYYY-NNNN',触发器取号
    material_id   uuid NOT NULL REFERENCES public.materials (id),
    quantity      numeric NOT NULL,
    unit          text NOT NULL DEFAULT 'kg',
    remaining_qty numeric NOT NULL,
    CONSTRAINT output_batches_remaining_qty_nonneg CHECK (remaining_qty >= 0),
    output_date   date,
    state         text NOT NULL DEFAULT '库存中'
                  REFERENCES public.output_batch_states (code),
    customer_id   uuid REFERENCES public.customers (id),
    purity        text,
    notes         text,
    status        text NOT NULL DEFAULT 'draft',
    deleted_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid,
    -- ── AUDEL-1b 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────
    deleted_by    uuid,
    delete_reason text,
    -- ── PROC-WIRE-1A 追加的列 ────────────────────────────────────────────
    -- 这一批是干什么用的。**与 state 是两条轴**:state 答"卖掉了多少"。
    -- 【给默认值,而 PROC-BUILD-1 的 may_be_sold 不给】—— 两者的空意思不同:
    -- may_be_sold 不给默认是因为"加一个形态"是一次裁定时刻(法律许不许卖,
    -- 给了默认就等于替法律作答);而这一列的默认是【现状】—— 线上每一批今天
    -- 都是可售库存,既有的两条建批次路建的也都是可售库存。
    purpose_code  text NOT NULL DEFAULT 'saleable_stock'
                  REFERENCES public.output_batch_purposes (code),
    -- ── PROC-WIRE-1B-ii 追加的列 ─────────────────────────────────────────
    -- 【在制品:这一批在等哪一道工序】可空。**不建 WIP 表** —— 在制品那一行
    -- 就是本表这一行(PROC-WIRE-1A 立的),再存一份就会把同一批料数两遍。
    awaiting_operation_type_code text
                  REFERENCES public.operation_types (code),
    -- ── MES-4b 追加的列(2026-10-07,规格 §3.4;MES-4b Step 0 Q4–Q7,Tim)─────────────────────────
    -- 这一批电芯是卷绕还是叠片(cell_constructions)。只对仍装着电芯的形态成立(material_forms.implies_dismantling);
    -- 别的形态填了按名拒(CELL_CONSTRUCTION_NOT_APPLICABLE)。为空 = 没记。提交时从投料继承(每一批投料都同一个值时);
    -- 之后在批次页上改,直到这一批喂过一张已提交的加工单(CELL_CONSTRUCTION_LOCKED)。守卫:guard_batch_cell_construction。
    -- 本表【不是】遮蔽表(没有列级授权、没有 _masked 伴生 —— MES-4b Step 0 §1.1 实测),所以只有这一列。
    cell_construction_code text
                  REFERENCES public.cell_constructions (code),
    -- ── MES-5a-1 追加的列(2026-10-08,规格 §3.1;MES-5a Step 0 Q4,Tim)─────────────────────────
    -- 这一批有几个模组(与 inbound_batches.module_count 同义同规矩,守卫 guard_batch_module_count)。拆去隔离的那一批由拆分函数写上拆出去的模组数。
    module_count  integer CHECK (module_count IS NULL OR module_count > 0)
);


-- SEARCH-2 · 迁移 A:code 上的 trigram GIN —— 买的是【后缀匹配】(`%0001`)。
-- btree 服务得了后缀(强制走索引时规划器会选 code_key 做 Bitmap Index Scan),
-- 但它 seek 不了;今天 319 行上量不出差别,合成 20 万行时 12.0ms vs 33.4ms。
-- 扩展由 db/platform-prelude.sql §4 提供(连同那条 search_path)。
CREATE INDEX output_batches_code_trgm ON public.output_batches USING gin (code extensions.gin_trgm_ops);

-- SEARCH-2b · 迁移 C:「最近编辑过」要的那一条 —— `updated_by = auth.uid()`
-- 按 updated_at DESC 取前 5(T3)。SEARCH-0 §Q5 实测:这两列上此前一条索引都没有。
CREATE INDEX output_batches_recents ON public.output_batches (updated_by, updated_at DESC);

-- SEARCH-4 · 迁移 B:关联搜索走这一列。为将来的体量建,不为今天的毫秒数
--(320 行上规划器一律 Seq Scan;理由与迁移 A/C 逐字同族)。
CREATE INDEX output_batches_customer_id_rel ON public.output_batches (customer_id);
CREATE INDEX output_batches_material_id_rel ON public.output_batches (material_id);
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

COMMENT ON COLUMN public.output_batches.purpose_code IS
'PROC-WIRE-1A:这一批是干什么用的 —— 可售库存,还是下游工序的投料。
**与 state 是两条轴**:state 答"卖掉了多少",本列答"这批是干什么的"。
**线上既有行全部落在 saleable_stock**,那不是一次数据迁移,那就是它们今天的样子
(Tim 裁定线上 20 批产出全是测试残留,本刀不动它们中的任何一批)。
"这批投料用完了没有"【不需要】本轴表示 —— remaining_qty = 0 已经把它说清楚了,
而且消耗路(commit_processing_run)本来就只扣 remaining_qty。';


-- MES-4b(2026-10-07,MES-0 Q54 · Q57;MES-4b Step 0 Q12–Q14,Tim):前缀与序列【从这一批物料的形态选】——
--   materials.form_code → material_forms.output_document_key → document_types(前缀经 document_type_prefix,序列是登记的 sequence_name)。
--   没有形态、或形态没映射 → output_batch(OUT,output_code_seq)。前缀字面量一个都不写在这里(fixture 100 第 6 臂)。
--   号的宽度:OUT 照旧补到 4 位,新前缀补到 5 位 —— 两者都【不截断】:超过 9,999(或 99,999)就照实长出去
--   (此前 LPAD(…, 4, '0') 会把 10000 截成 1000,CODE-WIDTH-4)。低于 10,000 的号与此前逐字相同。
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

CREATE TRIGGER trg_generate_output_code
    BEFORE INSERT ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION generate_output_code();

-- MES-4b(Q4 · Q7):电芯结构只对装着电芯的形态成立;喂过一张已提交的加工单之后不再改(守卫函数在 db/functions/)。
--   名字排在 trg_generate_output_code 之后(BEFORE 触发器按名字先后跑)—— 拒绝里要报出批号。
CREATE TRIGGER trg_output_batches_cell_construction
    BEFORE INSERT OR UPDATE OF cell_construction_code, material_id ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_cell_construction();

-- MES-5a-1(Q4):模组数,与进料批同一个守卫。
CREATE TRIGGER trg_output_batches_module_count
    BEFORE INSERT OR UPDATE OF module_count, material_id ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_module_count();

-- 库存台账体系(函数见 db/functions/inventory_ledger_triggers.sql)
CREATE TRIGGER trg_output_batches_emit_receipt
    AFTER INSERT ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION emit_batch_receipt_movement();

CREATE TRIGGER trg_output_batches_writeoff
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW
    WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
    EXECUTE FUNCTION emit_batch_writeoff_movement();

CREATE TRIGGER trg_output_batches_quantity_guard
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW
    WHEN (NEW.quantity IS DISTINCT FROM OLD.quantity)
    EXECUTE FUNCTION reject_quantity_change();

CREATE CONSTRAINT TRIGGER trg_output_batches_invariant
    AFTER INSERT OR UPDATE ON public.output_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_ledger_invariant();

ALTER TABLE public.output_batches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "output_batches select by permission"
    ON public.output_batches
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'::text));

-- 【没有面向客户端的 INSERT 策略,这是刻意的】(IOD-1b,2026-08-13)
-- 建批次只有一扇门:create_inbound_batch / receive_inbound_batch_against_po
-- (产出侧是 create_output_batch)。它们是 SECURITY DEFINER,以属主身份写入,
-- 所以不需要这条策略;而撤掉它,直接 POST /rest/v1/<表> 会被 RLS 拒。
-- 【为什么】IOD-2 要在"货落进哪个库位"上设闸,而一个留着侧门的卡口不是卡口 ——
-- 先把门收成一扇,IOD-2 只需在这一扇门上加判断,不必追第二条路径。
-- 【IOD-2 已经落闸(2026-08-13)】判断就加在这一扇门上:check_location_class,
-- 见 storage_location_allowed_classes 表头。这条策略因此是【它的前提】,不是
-- 一次顺手收紧 —— 撤掉它,闸就又有了一条绕过去的路。
-- commit_processing_run 同为 DEFINER,不受影响(fixture 58 D 臂钉住)。

CREATE POLICY "output_batches update by permission"
    ON public.output_batches
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.output.edit'::text)) WITH CHECK (has_permission('module.output.edit'::text));

CREATE POLICY "output_batches delete by permission"
    ON public.output_batches
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.output.edit'::text));

-- AUDEL-1a:硬删按名拒(BATCH_NO_HARD_DELETE|批号),理由与 inbound_batches 逐字相同
-- (output_batch_metals 同样是 CASCADE)。守卫只挡 DELETE,软删照常。
CREATE TRIGGER trg_output_batches_no_hard_delete
    BEFORE DELETE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_no_hard_delete();

-- PROC-WIRE-1B-ii:让"在等哪一道"这一列的空与非空各自只有一个意思。
CREATE TRIGGER trg_output_batches_awaiting_operation
    BEFORE INSERT OR UPDATE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_output_batch_awaiting_operation();

-- ★ PROC-1B-iii(R4):**已经许给客户的货,不许被指定成下游工序的投料。** ★
-- 【为什么在表上,而不只在 set_output_batch_purpose 里】本表有一条敞开的
-- UPDATE 策略(module.output.edit),直插的 UPDATE 会整个绕开那个函数;
-- 而 CHECK 约束读不了另一张表。镜像那一侧(先指定、后预留)本来就是触发器
-- (sales_order_reservations 上的 trg_so_reservations_form_saleable)——
-- 把一条规则的两半用两种强度执行,正是它被绕过去的方式。
-- 【只挂 UPDATE,且只在 purpose_code 真的变了时】预留有外键指向本表,
-- 建批那一刻不可能有预留指着它;WHEN 让无关的 UPDATE 不必付这次查询。
CREATE TRIGGER trg_output_batches_not_promised
    BEFORE UPDATE OF purpose_code ON public.output_batches
    FOR EACH ROW
    WHEN (NEW.purpose_code IS DISTINCT FROM OLD.purpose_code)
    EXECUTE FUNCTION public.guard_output_batch_not_promised();

-- AUDEL-1b:置 deleted_at 必须走【门】(函数),且 deleted_by / delete_reason 必须填好。
-- 光加两列挡不住任何事 —— 软删本来就是一次直连 UPDATE。
CREATE TRIGGER trg_output_batches_soft_delete_provenance
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();

-- INV-VAL-1 R9:产出日【不许由有改回空】。建批那一刻的必填由
-- create_output_batch(OUTPUT_DATE_REQUIRED)与 commit_processing_run
-- (PROCESS_DATE_REQUIRED,产出日取它)各自拒;本触发器补的是它们拦不住的
-- 那一半 —— 直接 UPDATE 把已有的日期清掉。
-- 【不是 NOT NULL】:历史上没有产出日的行必须留得住(R9 不许回填),
-- 而 NOT NULL 会把它们锁到连备注都改不了。只拒【由有变无】。
CREATE TRIGGER guard_output_date_not_cleared
    BEFORE INSERT OR UPDATE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_receipt_date_not_cleared();

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.output_batches
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.output.edit');

COMMENT ON COLUMN public.output_batches.cell_construction_code IS
'MES-4b(规格 §3.4;MES-4b Step 0 Q4–Q7):这一批电芯是卷绕还是叠片(cell_constructions)。为空 = 没记。只对仍装着电芯的形态成立
(material_forms.implies_dismantling;没有形态的物料不拦 —— 不知道不等于不适用),别的形态 CELL_CONSTRUCTION_NOT_APPLICABLE。
提交加工单时从投料继承(每一批投料都是同一个值;否则留空,到批次页上补)。喂过一张已提交、没回滚的加工单之后不再改
(CELL_CONSTRUCTION_LOCKED|<加工单>)—— 改它就是回滚那一张。极片分离的投料必须带一个确定的值(INPUT_CELL_CONSTRUCTION_REQUIRED)。';

COMMENT ON COLUMN public.output_batches.module_count IS
'MES-5a-1(规格 §3.1;MES-5a Step 0 Q4 · Q6 · Q11):这一批有几个模组 —— 与 inbound_batches.module_count 同义同规矩(guard_batch_module_count)。
拆去隔离的那一批(discharge_quarantine_split 的产出)由 split_failed_modules_to_quarantine 写上拆出去的模组数。';
