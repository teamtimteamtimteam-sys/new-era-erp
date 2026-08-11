-- db/tables/materials.sql
-- 物料主档。code 'MAT-YYYY-NNNN' 由 BEFORE INSERT 触发器从序列取号(非无缝,
-- 主档无审计连号要求)。软删除 deleted_at;status 自由文本。
-- 注意线上【没有】updated_at 触发器(建表早期漏挂,updated_at 靠应用层写)——
-- 镜像忠实于线上;要补触发器请走迁移,别只改这里。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE public.material_code_seq;

CREATE TABLE public.materials (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code       text NOT NULL UNIQUE,  -- 'MAT-YYYY-NNNN',触发器取号
    name       text NOT NULL,
    category   text NOT NULL,
    chemistry  text,
    unit       text NOT NULL DEFAULT 'kg',
    spec       text,
    notes      text,
    status     text NOT NULL DEFAULT 'draft',
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid,
    -- ── MAT-1 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 受控废物分类。【NULL = 没有人分过类,不是"非受控"】—— 既有物料全部是 NULL
    -- 且【不回填】:给一条没人记录过的分类硬指一个值是伪造,而且是承重的伪造。
    -- 与 category(它在我们流程里是哪一种东西)、chemistry(正极化学体系)不重复:
    -- 那两个是【我们怎么看】,这个是【监管怎么看】,三者同时成立而互不蕴含。
    waste_classification_code text REFERENCES public.waste_classifications (code)
);

CREATE OR REPLACE FUNCTION public.generate_material_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'MAT-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('material_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_material_code
    BEFORE INSERT ON public.materials
    FOR EACH ROW EXECUTE FUNCTION generate_material_code();

ALTER TABLE public.materials ENABLE ROW LEVEL SECURITY;
CREATE POLICY "materials select by permission"
    ON public.materials
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.materials.view'::text));

CREATE POLICY "materials insert by permission"
    ON public.materials
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));

CREATE POLICY "materials update by permission"
    ON public.materials
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text)) WITH CHECK (has_permission('module.materials.edit'::text));

CREATE POLICY "materials delete by permission"
    ON public.materials
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.materials.edit'::text));

COMMENT ON COLUMN public.materials.waste_classification_code IS
$$MAT-1:这个物料的受控废物分类。

【NULL = 没有人分过类,不是"非受控"】既有物料全部是 NULL,而且【不回填】:
给一条没人记录过的分类硬指一个值就是伪造,并且是【承重的】伪造 —— 一个合规判断
会踩在它上面。同一个形状这个仓库已经遇到过三次(METAL-1 的 no_reference 与
「无检查记录」、METAL-2 的 price_index IS NULL),答案每次都一样。

【与 category / chemistry 不重复,已核对】category 说的是"它在我们的流程里是哪一种
东西"(进料-电池 / 产出-黑粉 / 耗材辅料),chemistry 说的是正极化学体系
(NMC / LFP / …)。两者都是【我们怎么看这批货】;本列说的是【监管怎么看它】,
是一个法规属性。三者会同时成立而互不蕴含:一种非受控的进料电池,与一种受控的
进料电池,category 与 chemistry 可以一模一样。$$;
