// app/suppliers/supplierTypes.ts
// 供应商【类型】的选项清单 —— 新建与编辑两张表单共用这一份。
//
// 【为什么抽出来:EQP-1c-b-fu 之前它在两个组件里各有一份】两份一样的清单,
// 加一种只改其中一处,就会得到一个【建得出来、改不掉】(或反过来)的类型。
// 这是本仓库反复付账的那个形状:一条规则,两个实现。
//
// 【这份清单是 UI 侧的,数据库那边【什么都不管】—— 查过了,不是假定的】
// suppliers.supplier_types 是 text[] NOT NULL DEFAULT '{}',**没有 CHECK、
// 也没有对应的查找表**(certificate_types / leave_types 那种 RUNTIME CONFIG
// 表只有那两张)。所以:
//   * 加一种类型【不需要迁移,也不是一行种子数据】—— 就是这里加一行;
//   * 反过来,数据库会接受任何字符串,这份清单是【建议】,不是【规则】。
//     那件事记在 docs/known-issues.md 里,不在这里顺手改成 CHECK ——
//     线上已有的四个取值要先确认没有别的写法在用。
export const SUPPLIER_TYPE_OPTIONS = [
    { value: 'dismantler', labelKey: 'suppliers.types.dismantler' },
    { value: 'battery_factory_scrap', labelKey: 'suppliers.types.batteryScrap' },
    { value: 'recycler', labelKey: 'suppliers.types.recycler' },
    { value: 'trader', labelKey: 'suppliers.types.trader' },
    // EQP-1c-b-fu(Tim 走查):卖机器的不是这条电池价值链上的任何一环。
    // 【它与"这一家是什么"(counterparty_type)不冲突,两者回答不同的问题】
    // 后者问的是能力(供货 / 货代 / 服务商),一个机器供应商是 goods_supplier ——
    // 那句话是真的,而且早就选得到。这一列问的是【他们做哪一行】。
    { value: 'equipment_vendor', labelKey: 'suppliers.types.equipmentVendor' },
] as const
