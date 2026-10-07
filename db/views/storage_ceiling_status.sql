-- db/views/storage_ceiling_status.sql
-- MES-3a(2026-10-06,MES-0 Q32;MES-3a Step 0 Q6 · Q13 · Q32,Tim):【此刻在效的那张执照下,每一类 NEA 废物的存量对着上限】。
--   一行一类(启用的类别,加上停用了却还有存量或还有上限的),再加一行总量(category_code 为空 = 执照的 approved_storage_limit_tonnes
--   对着所有有类别的存量之和)。执照 = 今天(新加坡日历)在效的 gwdf(storage_licence_in_force);没有在效执照 → 零行(页面说出来)。
--   status:not_set(上限没给)· not_computable(存量里有换算不成吨的批)· exceeded(超了)· within。
--   读它的:/inventory/storage-safety · operations_now 的 storage_ceiling_exceeded 臂(只提醒,Q13)。
--   【属主视图 + 体内谓词】读执照、上限与存量基视图不过 RLS;门:module.suppliers.view(执照那一侧)或 module.inventory.view(库存那一侧)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE VIEW public.storage_ceiling_status WITH (security_invoker = off) AS
 WITH lic AS (
         SELECT cc.id,
            cc.cert_no,
            cc.approved_storage_limit_tonnes
           FROM company_compliance cc
          WHERE cc.id = storage_licence_in_force((now() AT TIME ZONE 'Asia/Singapore'::text)::date)
        ), cat_rows AS (
         SELECT lic.id AS licence_id,
            lic.cert_no,
            c.code AS category_code,
            c.name_en,
            c.name_zh,
            c.sort_order,
            l.limit_tonnes,
            oh.tonnes AS on_hand_t,
            COALESCE(oh.batches, 0::bigint) AS batches,
            COALESCE(oh.unconvertible_batches, 0::bigint) AS unconvertible_batches
           FROM lic
             CROSS JOIN nea_waste_categories c
             LEFT JOIN licence_storage_limits l ON l.licence_id = lic.id AND l.category_code = c.code
             LEFT JOIN nea_category_on_hand_all oh ON oh.category_code = c.code
          WHERE c.is_active OR oh.batches > 0 OR l.id IS NOT NULL
        UNION ALL
         SELECT lic.id AS licence_id,
            lic.cert_no,
            NULL::text AS category_code,
            'All NEA categories'::text AS name_en,
            '所有 NEA 类别'::text AS name_zh,
            2147483647 AS sort_order,
            lic.approved_storage_limit_tonnes AS limit_tonnes,
            ( SELECT sum(a.tonnes) AS sum
                   FROM nea_category_on_hand_all a) AS on_hand_t,
            COALESCE(( SELECT sum(a.batches) AS sum
                   FROM nea_category_on_hand_all a), 0::numeric)::bigint AS batches,
            COALESCE(( SELECT sum(a.unconvertible_batches) AS sum
                   FROM nea_category_on_hand_all a), 0::numeric)::bigint AS unconvertible_batches
           FROM lic
        )
 SELECT licence_id,
    cert_no,
    category_code,
    name_en,
    name_zh,
    sort_order,
    limit_tonnes,
    COALESCE(on_hand_t, 0::numeric) AS on_hand_t,
    batches,
    unconvertible_batches,
        CASE
            WHEN limit_tonnes IS NULL THEN 'not_set'::text
            WHEN unconvertible_batches > 0 THEN 'not_computable'::text
            WHEN COALESCE(on_hand_t, 0::numeric) > limit_tonnes THEN 'exceeded'::text
            ELSE 'within'::text
        END AS status
   FROM cat_rows
  WHERE has_permission('module.suppliers.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.storage_ceiling_status IS
    'MES-3a:今天在效的 gwdf 执照下,每一类 NEA 废物的存量(吨)对着上限,外加一行总量(category_code 为空)。status:not_set · not_computable · exceeded · within。没有在效执照 → 零行。门:module.suppliers.view 或 module.inventory.view。';

GRANT SELECT ON public.storage_ceiling_status TO authenticated;
REVOKE ALL ON public.storage_ceiling_status FROM anon;
