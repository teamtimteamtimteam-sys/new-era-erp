-- CONTRACT-1 fu1:同一种元素只规定一次 —— 而原来那条 UNIQUE 在最常见的情形下【不咬】。
--
-- ★【这是本刀自己的 fixture 抓出来的,不是事后想到的】★
--   `UNIQUE (contract_id, material_id, metal)` 在 material_id 为 NULL 时不生效,
--   因为唯一索引里 **NULL ≠ NULL**。而"不指料号、只写 Ni ≥ 18%"恰恰是
--   合同里【最常见】的写法 —— 于是同一份合同可以同时存在 Ni≥18 与 Ni≥20 两行,
--   而「哪一条说了算」就变成一次按写入顺序的破平局。
--   **那正是 contract_grade_specs 的表注声称躲开的那个坑(AGING-1)** ——
--   注释是对的,索引没跟上。
--
-- 处置:拆成两个部分唯一索引,让两种写法各自有唯一性。
BEGIN;
ALTER TABLE public.contract_grade_specs
    DROP CONSTRAINT contract_grade_specs_contract_id_material_id_metal_key;
CREATE UNIQUE INDEX contract_grade_specs_one_per_material_metal
    ON public.contract_grade_specs (contract_id, material_id, metal)
    WHERE material_id IS NOT NULL;
CREATE UNIQUE INDEX contract_grade_specs_one_per_metal_no_material
    ON public.contract_grade_specs (contract_id, metal)
    WHERE material_id IS NULL;
COMMIT;
