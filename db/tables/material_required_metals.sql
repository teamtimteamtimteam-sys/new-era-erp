-- db/tables/material_required_metals.sql
-- ASY-P1:这种物料【应当化验哪些金属】。一物料一金属一行。
--
-- 【没有行 = 没有要求,而这是一个假设,不是一个事实】它读作"这种物料不需要化验",
-- 而它同样是"还没有人为这种物料想过这件事"的样子 —— 两者在本表里长得一模一样。
-- 所以界面那一半(ASY-P2)必须在【每一个】物料上把这个状态按名印出来(「无化验要求」),
-- 而不是让空白自己去说话。ASY-P1 落地时线上 4 个在册物料【全部】没有要求,
-- awaiting_assay 因此会安静下来,直到有人填进来 —— 那是这条默认的直接后果。
--
-- 【为什么不给一个"已决定:不需要"的第三态】那会是更诚实的模型,而它也会是一次
-- 关于"谁在什么时候决定的、凭什么"的设计,不属于 ASY-P1。缺口记在这里。
--
-- 惯例与 inbound_batch_metals / assay_result_metals 同形:属性行,没有代理键,
-- 没有软删,复合主键【就是】那条 UNIQUE (material_id, metal),父行删掉即级联。
--
-- 【七金属 CHECK 是第八处复制,不是第一处例外】全库没有 domain、没有 enum ——
-- 同一个集合内联在 7 张表的 CHECK 与 3 个函数的 IF 里(metal_prices /
-- inbound_batch_metals / output_batch_metals / assay_result_metals /
-- pricing_formula_metals / pricing_formula_history / pricing_term_commitment_metals;
-- calculate_metal_price_from_terms / record_assay_result / upsert_metal_prices)。
-- **加金属时要同时放宽全部这些。** 建一个 domain 是一次动 10 个地方的单独的刀,
-- 混进 ASY-P1 里就是趁人不注意改一条全库约定。
--
-- 【写只走函数】基表上【没有】INSERT/UPDATE/DELETE 策略 —— 没有策略 = 没有任何
-- authenticated 的写入路径过得了 RLS。唯一入口是 set_material_required_metals()
-- (SECURITY DEFINER,require_permission('module.materials.edit')),整套替换,
-- 于是不会出现"改了一半"的中间态。
--
-- NOTE: introduced by
-- db/migrations/2026-08-17-asyp1-required-metals-and-the-arm-that-tells-the-truth.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.material_required_metals (
    material_id uuid NOT NULL REFERENCES public.materials (id) ON DELETE CASCADE,
    metal       text NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    PRIMARY KEY (material_id, metal)
);

COMMENT ON TABLE public.material_required_metals IS
$$ASY-P1:这种物料【应当化验哪些金属】。一物料一金属一行。

【没有行 = 没有要求,而这是一个假设,不是一个事实】它读作"这种物料不需要化验",
而它同样是"还没有人为这种物料想过这件事"的样子 —— 两者在本表里长得一模一样。
所以界面那一半(ASY-P2)必须在【每一个】物料上把这个状态按名印出来(「无化验要求」),
而不是让空白自己去说话。本迁移落地时线上 4 个在册物料【全部】没有要求,
因此 awaiting_assay 会安静下来,直到有人填进来 —— 那是这条默认的直接后果,写在这里。

【为什么不给一个"已决定:不需要"的第三态】那会是更诚实的模型,而它也会是一次
关于"谁在什么时候决定的、凭什么"的设计,不属于这一刀。缺口记在这里。$$;

ALTER TABLE public.material_required_metals ENABLE ROW LEVEL SECURITY;

-- 【读跟着物料字典走】能看物料的人就能看它要求哪些金属 —— 这不是第二个秘密。
CREATE POLICY "material_required_metals select by permission"
    ON public.material_required_metals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.materials.view'::text));

-- 写没有策略 —— 见抬头。
