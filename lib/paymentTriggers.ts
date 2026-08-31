// lib/paymentTriggers.ts
// EQP-PAY-1:付款里程碑的【单一真源】是数据库里的 payment_trigger_events 表。
//
// 【这个文件存在的理由】在它之前,那五个里程碑值住在【六个地方、零行数据】里:
//   ① purchase_order_payment_terms 上的一条 CHECK;
//   ② payment_term_template_lines 上的另一条 CHECK(同一份清单,抄了第二遍);
//   ③ app/purchasing/orders/new/actions.ts 的 TRIGGERS 集合;
//   ④ app/purchasing/orders/new/NewOrderForm.tsx 的 TRIGGER_OPTIONS 数组;
//   ⑤ messages/en.ts + messages/zh.ts 的 purchasing.trigger.* 标签;
//   ⑥ .../pdf/PurchaseOrderDocument.tsx 的 TRIGGER_PHRASE。
// 加第七种里程碑当时要改六处,而漏掉一处的后果是一个值在一处存在、在另一处不存在。
//
// ★【标签也来自字典,这不是顺手】★ 若标签留在 messages/ 里,加一种里程碑就【仍然】
// 要改代码 —— R4b 说"第七种里程碑必须是一行数据",那就包括它叫什么。
// 所以 name_en / name_zh 在表上,按界面语言【选一个】(与 tax_codes 同一个惯用法;
// 不许拼成「中文 / English」—— scripts/check-bilingual-concat.mjs 盯着这一条)。
//
// 【适用性是两个布尔量,不是两张表】on_order 与 fixed_date 对材料和设备是【同一个
// 概念】;拆成两份清单就是把同一个概念写成两行,而两行会漂。

export type PaymentTriggerEvent = {
    code: string
    name_en: string
    name_zh: string
    phrase_en: string
    applies_to_material: boolean
    applies_to_equipment: boolean
    can_anchor_retention: boolean
    sort_order: number
}

export type OrderKind = 'material' | 'equipment'

/** 这张单的种类下,哪些里程碑用得上。屏幕与服务端【问的是同一个问题】。 */
export function applicableTriggers(
    all: PaymentTriggerEvent[],
    kind: OrderKind
): PaymentTriggerEvent[] {
    return all
        .filter((e) => (kind === 'equipment' ? e.applies_to_equipment : e.applies_to_material))
        .sort((a, b) => a.sort_order - b.sort_order)
}

/** 按界面语言选一个名字 —— 不拼接(GST-FIX-3 那一课)。 */
export function triggerLabel(e: PaymentTriggerEvent, locale: string): string {
    return locale.startsWith('zh') ? e.name_zh : e.name_en
}

/**
 * 服务端读取字典。**每一处需要这份清单的地方都走这一支** —— 那正是本文件存在的
 * 理由:此前同一份清单被抄了四遍(两处表单常量 + 两处服务端校验集合),
 * 而没有任何东西保证它们一起改。
 *
 * 【只取 is_active】停用一种里程碑就不再出现在任何下拉里,而历史行照旧读得出来
 * (外键指着 code,不指着 is_active)。
 */
export async function loadPaymentTriggerEvents(
    supabase: { from: (t: string) => any }
): Promise<PaymentTriggerEvent[]> {
    const { data, error } = await supabase
        .from('payment_trigger_events')
        .select('code, name_en, name_zh, phrase_en, applies_to_material, applies_to_equipment, can_anchor_retention, sort_order')
        .eq('is_active', true)
        .order('sort_order')
    // 一次失败不是一个空集(mustRows 那条规矩)—— 空清单会让下拉变空,
    // 而一个空下拉看起来像"没有里程碑可选",不像"读不出来"。
    if (error) throw new Error(`payment_trigger_events: ${error.message}`)
    // 【null 也要按名喊,不要 ?? [] 】一份空的里程碑清单会让每一个下拉都变空,
    // 而一个空下拉看起来像"没有里程碑可选",不像"这份字典读不出来"。
    // 一次失败不是一个空集(mustRows 那条规矩的同一句话)。
    if (!data) throw new Error('payment_trigger_events: 读到 null —— 字典读不出来,不是没有里程碑')
    return data as PaymentTriggerEvent[]
}
