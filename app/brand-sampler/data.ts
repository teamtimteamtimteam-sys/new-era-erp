// BRAND-1 · sampler 用的样例数据。【临时文件,随 sampler 一起删】
//
// 【为什么不是 lorem ipsum,也不是编出来的商业名词】Tim 要判断的是
// 【他自己的系统】长什么样。一张陌生的表教不了他任何关于那件事的东西。
// 所以下面每一个字段的形状都取自真源:
//   * 批次号 IN-YYYY-NNNN —— db/tables/inbound_batches.sql:125 的取号触发器
//   * 物料号 MAT-YYYY-NNNN —— db/tables/materials.sql:26
//   * stage 三个值 —— inbound_batches 的 CHECK (stage IN ('待加工','加工中','已加工完'))
//   * pricing_status 三个值 —— CHECK (pricing_status IN ('unpriced','provisional','final'))
//   * 化学体系 NMC / NCA / LFP / LCO —— db/tables/battery_chemistries.sql 的字典
//   * 化学确定度 —— db/tables/inbound_chemistry_certainties.sql
//
// 【这里没有任何一行是线上数据】—— 全是照着上面那些形状现编的,
// 供应商与数字都是假的。sampler 不连库,也不该连:一个样式选择页
// 不需要、也不应该把真实客户与员工数据渲染到屏幕上(见 docs/pdpa.md)。
//
// 【没有币种】表里刻意不印金额与币种代码。两个理由,都成立:
//   ① 单价那一栏正是要用来演示【受限】的,印出数字反而失了重点;
//   ② scripts/check-currency-literals.mjs 的 jsx-text 判据禁止把
//      币种当正文印进 JSX —— 一个临时页不值得为此进 ALLOWLIST。

export type Refusal = 'restricted' | 'unrecorded' | 'unexplained' | 'outOfStock'

export type Batch = {
    code: string
    material: string
    materialCode: string
    chemistry: string
    certainty: string
    weightKg: string
    stage: '待加工' | '加工中' | '已加工完'
    pricing: 'unpriced' | 'provisional' | 'final'
    unitPrice: string | Refusal
    receivedBy: string | Refusal
}

export const BATCHES: Batch[] = [
    {
        code: 'IN-2026-0180', material: '动力电池模组(拆解件)', materialCode: 'MAT-2026-0007',
        chemistry: 'NMC', certainty: 'Single, known chemistry', weightKg: '12,400.00',
        stage: '待加工', pricing: 'provisional', unitPrice: 'restricted', receivedBy: '陈国伟',
    },
    {
        code: 'IN-2026-0181', material: '磷酸铁锂电芯', materialCode: 'MAT-2026-0012',
        chemistry: 'LFP', certainty: 'Single, known chemistry', weightKg: '8,150.50',
        stage: '加工中', pricing: 'final', unitPrice: 'restricted', receivedBy: 'Priya Raman',
    },
    {
        code: 'IN-2026-0182', material: '混合黑粉', materialCode: 'MAT-2026-0003',
        chemistry: 'Mixed', certainty: 'Mixed (known to be mixed)', weightKg: '3,020.00',
        stage: '加工中', pricing: 'provisional', unitPrice: 'restricted', receivedBy: 'unrecorded',
    },
    {
        code: 'IN-2026-0183', material: '钴酸锂电芯(消费类)', materialCode: 'MAT-2026-0019',
        chemistry: 'LCO', certainty: 'Unknown, pending identification', weightKg: '640.25',
        stage: '待加工', pricing: 'unpriced', unitPrice: 'unexplained', receivedBy: 'unrecorded',
    },
    {
        code: 'IN-2026-0184', material: '镍钴铝正极边角料', materialCode: 'MAT-2026-0022',
        chemistry: 'NCA', certainty: 'Single, known chemistry', weightKg: '1,875.00',
        stage: '已加工完', pricing: 'final', unitPrice: 'restricted', receivedBy: '林淑芬',
    },
    {
        code: 'IN-2026-0185', material: '退役储能电池包', materialCode: 'MAT-2026-0031',
        chemistry: 'LFP', certainty: 'Single, known chemistry', weightKg: '0.00',
        stage: '已加工完', pricing: 'final', unitPrice: 'restricted', receivedBy: 'Kaur Simran',
    },
]

// ★ 拒绝的词汇表 —— 【逐字取自 messages/】,不是我改写的 ★
// 这是本系统最有价值的前端资产(FE-0 PART C a),而它今天被印成 10 种不同的
// 样子。三个变体各自演示一种画法,正是要 Tim 挑的那件事。
export const REFUSALS: Record<Refusal, { en: string; zh: string; why: string }> = {
    restricted: {
        en: 'Restricted', zh: '受限',
        why: 'common.restricted —— 全站 42 处共用这一个键。'
            + '「你没有权限看这个值」,而不是「这个值是空的」。',
    },
    unrecorded: {
        en: 'not recorded', zh: '未记录',
        why: 'actor.unrecorded —— ActorName.tsx 独占。'
            + '「当时没有人记下是谁做的」,而不是「这个人不存在」。',
    },
    unexplained: {
        en: 'Unexplained', zh: '未说明',
        why: '这批货早于来源规则,既没有订单行也没有理由。'
            + '【刻意不回填:猜一个会伪造历史。】',
    },
    outOfStock: {
        en: 'out of stock', zh: '无库存',
        why: '余量为 0 —— 这是一个【事实】,不是一次拒绝。'
            + '把它和上面三个画成一样,就是在说系统不知道,而它知道。',
    },
}
