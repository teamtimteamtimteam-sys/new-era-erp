// app/components/receiving/DiscrepancyKinds.tsx
// GRN-1b:把 grn_discrepancies 的一行渲染成【人话】—— 一份实现,三个调用方
// (批次详情、采购单详情、差异清单)。
//
// 【为什么必须只有一处】这一族要说的是"哪里不对、差多少、按什么判的"。三处各写
// 一遍,迟早三处给出三种说法,而其中两处会先过期 —— ActorName 那一课逐字重演。
//
// ── 每一种 kind 都必须说出【两个数 + 判它的那个阈值】────────────────────────
// 一句"短交"本身不可行动:少了多少?按什么算少?没有这两样,操作员既不知道要不要
// 打电话给供应商,也不知道这条提示是不是有人把阈值调松了才没出现过。
//   short              订量 vs 累计实收,阈值 grn_short_pct
//   over               同上,阈值 grn_over_pct
//   declared_vs_actual 申报量 vs 这一条的实收,两个方向各用一个阈值
//   material_mismatch  订的料 vs 收的料,【没有阈值 —— 它不是一个程度问题】
//   assay_beyond_tolerance 比了几种金属,阈值 grn_assay_tolerance_pct
//
// 【assay 这一条说得比别的浅,而这是刻意的,不是偷懒】
// 视图返回的是【一个】判词(bool_or)加【比过几种】,它不返回是哪一种金属、
// 各自差了多少。要把那个明细印出来,页面就得自己去 join expected_assay 与
// 已应用化验的 content_pct —— 而"哪一份化验算已应用"是视图用 DISTINCT ON
// (applied_at DESC) 挑的,页面再挑一次就是第二份会漂开的判断:页面挑中另一份时,
// 印出来的数字【不是产生这个判词的那些数字】,而屏幕上看不出来。
// 所以这里只说视图说得出的,并把人送到化验页去看明细。要在行上直接看到"是镍差了
// 200%",正确的做法是让【视图】把明细带出来(那是一支迁移,GRN-1c)。
//
// 【material_mismatch 的措辞是这块屏最要紧的一句】它是告警,不是拒绝 ——
// 而"告警"在屏幕上极容易被读成"这批货被卡住了"。所以文案必须【明说收货已经入账】,
// 否则操作员会去找一个并不存在的放行按钮(或者更坏:重收一次)。
import { getTranslations } from '@/lib/i18n/server'

/** grn_discrepancies 的一行(只取本组件用得到的列)。 */
export type DiscrepancyRow = {
    batch_id: string
    batch_code: string
    po_code: string
    po_status: string
    line_no: number
    ordered_material_code: string
    received_material_code: string
    ordered_qty: number
    ordered_unit: string
    received_qty: number
    received_unit: string
    declared_qty: number | null
    line_received_qty: number
    line_receipt_count: number
    line_delta_qty: number
    line_delta_pct: number
    declared_delta_qty: number | null
    assay_beyond_tolerance: boolean | null
    assay_metals_compared: number | null
    // PROC-1B-iii:两侧的【原始码】。**它们不是装饰** —— 「没设」(null)与
    // 「未评估」(not_assessed)的 contradicted 都是 NULL,分辨力只在这两列上。
    deep_discharge_judged: string | null
    deep_discharge_actual: string | null
    deep_discharge_contradicted: boolean | null
    kinds: string[]
}

/** receiving_settings 的三个阈值 —— 判词是【它们】做的,所以它们必须一起显示。 */
export type ReceivingThresholds = {
    grn_short_pct: number
    grn_over_pct: number
    grn_assay_tolerance_pct: number
}

const TONE: Record<string, string> = {
    short: 'border-amber-300 bg-amber-50 text-amber-900',
    over: 'border-amber-300 bg-amber-50 text-amber-900',
    declared_vs_actual: 'border-amber-300 bg-amber-50 text-amber-900',
    // 收错料用【蓝】而不是红:红在这套界面里意味着"被拒了",而它恰恰没有被拒。
    material_mismatch: 'border-blue-300 bg-blue-50 text-blue-900',
    assay_beyond_tolerance: 'border-amber-300 bg-amber-50 text-amber-900',
    // PROC-1B-iii:与 material_mismatch 同一套【蓝】—— 红在这套界面里意味着
    // "被拒了",而 R3 明令这一条【不拦收货】。用红会让操作员去找一个
    // 并不存在的放行按钮。
    deep_discharge_contradicted: 'border-blue-300 bg-blue-50 text-blue-900',
}

/**
 * 一行差异的全部 kinds,逐条渲染成一段话。
 * kinds 为空时【返回 null】—— 由调用方决定"没有差异"该说什么,
 * 因为"这一条没差异"与"这一条不在视图里"是两句不同的话(后者调用方才知道)。
 */
export default async function DiscrepancyKinds({
    row, thresholds, assayHref,
}: {
    row: DiscrepancyRow
    thresholds: ReceivingThresholds
    /** 化验明细的去处;给了就在 assay 那一条后面挂一个链接。 */
    assayHref?: string
}) {
    const t = await getTranslations()
    if (!row.kinds || row.kinds.length === 0) return null

    return (
        <ul className="space-y-2">
            {row.kinds.map((kind) => (
                <li key={kind}
                    className={'rounded border px-3 py-2 text-sm ' + (TONE[kind] ?? 'border-gray-300 bg-gray-50')}>
                    <span className="font-medium">{t('grn.kind.' + kind)}</span>
                    <span className="mx-2">·</span>
                    {kind === 'short' && t('grn.detail.short', {
                        ordered: row.ordered_qty, unit: row.ordered_unit,
                        received: row.line_received_qty, delta: Math.abs(row.line_delta_qty),
                        pct: Math.abs(row.line_delta_pct), threshold: thresholds.grn_short_pct,
                        receipts: row.line_receipt_count,
                    })}
                    {kind === 'over' && t('grn.detail.over', {
                        ordered: row.ordered_qty, unit: row.ordered_unit,
                        received: row.line_received_qty, delta: row.line_delta_qty,
                        pct: row.line_delta_pct, threshold: thresholds.grn_over_pct,
                        receipts: row.line_receipt_count,
                    })}
                    {kind === 'declared_vs_actual' && t('grn.detail.declared', {
                        declared: row.declared_qty ?? 0, actual: row.received_qty,
                        unit: row.received_unit, delta: row.declared_delta_qty ?? 0,
                        shortPct: thresholds.grn_short_pct, overPct: thresholds.grn_over_pct,
                    })}
                    {kind === 'material_mismatch' && (
                        <>
                            {t('grn.detail.material', {
                                ordered: row.ordered_material_code,
                                received: row.received_material_code,
                            })}
                            {/* 【最要紧的一句:这批货已经入账了】 */}
                            <span className="block mt-1 font-medium">{t('grn.detail.materialAccepted')}</span>
                        </>
                    )}
                    {kind === 'deep_discharge_contradicted' && (
                        <>
                            {/* 【两个值都印出来 —— 这一条差异的全部内容就是那两个值不一样】
                                印成人话而不是码:字典的名字由页面翻不了(组件拿不到字典),
                                所以走 i18n 的 grn.deepDischarge.<code>。字典是 RUNTIME
                                CONFIG,线上后加的取值这里没有键 —— 那时 t() 会把整个
                                key 原样印出来(lib/i18n 的"方便发现漏翻"),难看但
                                【看得见】;而一片空白会被读成"没有值"。 */}
                            {t('grn.detail.deepDischarge', {
                                judged: row.deep_discharge_judged
                                    ? t('grn.deepDischarge.' + row.deep_discharge_judged)
                                    : '—',
                                actual: row.deep_discharge_actual
                                    ? t('grn.deepDischarge.' + row.deep_discharge_actual)
                                    : '—',
                            })}
                            {/* 【与收错料同一句最要紧的话:这批货已经入账了】 */}
                            <span className="block mt-1 font-medium">
                                {t('grn.detail.deepDischargeAccepted')}
                            </span>
                        </>
                    )}
                    {kind === 'assay_beyond_tolerance' && (
                        <>
                            {t('grn.detail.assay', {
                                metals: row.assay_metals_compared ?? 0,
                                threshold: thresholds.grn_assay_tolerance_pct,
                            })}
                            {/* 视图说不出是哪一种金属 —— 说明白,并把人送到看得见的地方 */}
                            <span className="block mt-1 text-xs opacity-80">
                                {t('grn.detail.assayWhichMetal')}
                                {assayHref && (
                                    <a href={assayHref} className="ml-1 underline">
                                        {t('grn.detail.assayLink')}
                                    </a>
                                )}
                            </span>
                        </>
                    )}
                </li>
            ))}
        </ul>
    )
}
