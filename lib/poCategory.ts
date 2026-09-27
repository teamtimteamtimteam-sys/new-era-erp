// lib/poCategory.ts
// ★ APR-10(Tim 2026-09-27,grilling Q5 · Q6):采购单的三个品类。取值与 purchase_orders.category 的 CHECK 逐字相同
//   (check-i18n 从那条 CHECK 读 poCategory.name.* 的后缀集合,所以这里多写或少写一个,构建会红)。
//   【品类 → 开单码】那一份定义【只在库里】(po_category_raise_code):页面向库要,不在这里抄第二份。
export const PO_CATEGORIES = ['consumables', 'equipment_goods', 'office'] as const
export type PoCategory = (typeof PO_CATEGORIES)[number]
