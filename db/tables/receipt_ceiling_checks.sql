-- db/tables/receipt_ceiling_checks.sql
-- MES-3a(2026-10-06,MES-0 Q33;MES-3a Step 0 Q7–Q10,Tim):【每一张收货单(与每一批手工建的产出批)进来那一刻,库存上限是怎么判的】。
--   一批一行、只追加。写它的只有 receipt_ceiling_check_internal(两支收货函数与 create_output_batch 在落库后、同一笔事务里调);
--   超过一个【给了的】上限就整笔拒(STORAGE_CEILING_EXCEEDED),于是这里只会留下放行了的那几种:
--     within               —— 这一类的上限给了,而且收进来之后没超(总上限给了的话也没超)
--     ceiling_not_set      —— 这一类的上限没给(Q33:照收,记下来);总上限给了的话照样判过、照样记在 total_* 两列
--     category_not_set     —— 物料没有 NEA 类别(今天每一种物料都是这样:类别列表还是空的,V29)
--     licence_not_in_force —— 收货那一天没有一张在效的 gwdf 执照(没录、没生效、过期、中止,或两张重叠 —— Q5:照收)
--     unit_not_convertible —— 这一批或这一类的存量里有换算不成吨的单位(件 / 别的),而这一类与总量都没有给上限(Q8)
--   on_hand_before_t / total_on_hand_before_t = 这一批进来【之前】的存量(吨,三种库存状态都算,Q7);quantity_t = 这一批。
--   【为什么不是 inbound_batches 上的一列】那张表是遮蔽表(一列 = 加列 + 列授权 + _masked 视图,三件事一支迁移);
--   而且产出批也要同一份记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.receipt_ceiling_checks (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id       uuid REFERENCES public.inbound_batches (id),
    output_batch_id        uuid REFERENCES public.output_batches (id),
    licence_id             uuid REFERENCES public.company_compliance (id),
    category_code          text REFERENCES public.nea_waste_categories (code),
    outcome                text NOT NULL CHECK (outcome IN ('within', 'ceiling_not_set', 'category_not_set',
                                                            'licence_not_in_force', 'unit_not_convertible')),
    quantity_t             numeric,
    on_hand_before_t       numeric,
    limit_t                numeric,
    total_on_hand_before_t numeric,
    total_limit_t          numeric,
    checked_on             date NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    CONSTRAINT receipt_ceiling_checks_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT receipt_ceiling_checks_inbound_once UNIQUE (inbound_batch_id),
    CONSTRAINT receipt_ceiling_checks_output_once UNIQUE (output_batch_id)
);

COMMENT ON TABLE public.receipt_ceiling_checks IS
    'MES-3a:每一张收货单与每一批手工产出批进来时,库存上限的判法(一批一行,只追加)。outcome:within · ceiling_not_set · category_not_set · licence_not_in_force · unit_not_convertible;超过给了的上限的那一次整笔被拒,不留行。数字都是吨,存量是这一批进来之前的。';

-- 【语句级,连 UPDATE 也是】没有 UPDATE / DELETE 策略时,authenticated 的 UPDATE / DELETE 在 RLS 那里是零行,行级触发器不会醒 ——
-- 一次"成功的空操作"(SILENT-1 那一族)。语句级零行也照样触发,属主路径也一样拒(这张表没有任何一条合法的改或删)。
CREATE TRIGGER trg_receipt_ceiling_checks_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.receipt_ceiling_checks
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_ceiling_check_append_only();

ALTER TABLE public.receipt_ceiling_checks ENABLE ROW LEVEL SECURITY;

-- 跟着那一批判:进料行要进料查看码,产出行要产出查看码。没有写策略:只有那支内层函数(属主身份)写。
CREATE POLICY "receipt_ceiling_checks select by permission" ON public.receipt_ceiling_checks
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
            OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text))));

REVOKE ALL ON public.receipt_ceiling_checks FROM anon;
