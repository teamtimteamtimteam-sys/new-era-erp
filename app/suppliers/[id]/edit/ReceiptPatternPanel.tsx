// app/suppliers/[id]/edit/ReceiptPatternPanel.tsx
// GRN-2:这家供应商的收货模式 —— 【一次短交是行情,一直短交是供应商问题】。
//
// 【为什么长在供应商页上,而不是看板上】看板是"发现有问题"的地方,
// 供应商页是"决定要不要再下单"的地方 —— 而这份记录要服务的正是后一个决定。
// 而且一家供应商的历史是一个【状态】,不是一件待办:看板上的东西应该能被做完,
// 这块记录做不完,它只是一直在那里。放上看板会让它天天亮着,而没有人能"处理"它。
//
// ── 三个计数是三件不同的事,屏幕上必须分三行说 ──────────────────────────────
//   可比对(comparable) —— 分母。有订量可比、有日期、在窗口内。
//   比不了(excluded)   —— 有日期,但没有订量可比。**不是合规,是没法评判。**
//   没日期(undated)    —— 放不进任何窗口。第三类。
// 把后两类折进分母,等于把"不知道"算成"没问题" —— 而那正好会让一家
// 「1 次可比对、9 次比不了」的供应商看起来和一家真正干净的供应商一模一样。
//
// 【undated_with_discrepancy 是这块面板最要紧的一行】它回答"补上日期会不会改变
// 结论"。实测线上:全库唯一一条 short 的收货【没有到货日】,于是它不在任何窗口里。
// 不把这一行印出来,屏幕就会对着 Acme 说"0 次短交",而事实是"有一次,但它没日期"。
//
// 【不印百分比,不印"一贯短交"的红灯】
// 43% 藏起了分母,而 1 次里 1 次也是 100%;红灯则需要一个没有人选过的阈值。
// 这块面板印原始计数,把判断留给看它的人 —— "5 次里 4 次"和"5 次里 1 次"之间的
// 区别,人一眼就看得出来。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'

export type PatternRow = {
    window_days: number
    window_from: string
    comparable_receipts: number
    short_receipts: number
    over_receipts: number
    declared_vs_actual_receipts: number
    material_mismatch_receipts: number
    assay_beyond_receipts: number
    receipts_with_any_discrepancy: number
    short_lines: number
    over_lines: number
    short_qty: number
    over_qty: number
    excluded_receipts: number
    undated_receipts: number
    undated_with_discrepancy: number
    earliest_receipt: string | null
    latest_receipt: string | null
    grn_short_pct: number
    grn_over_pct: number
    grn_assay_tolerance_pct: number
}

export type ContributingReceipt = {
    batch_id: string
    batch_code: string
    arrival_date: string | null
    kinds: string[]
}

export default async function ReceiptPatternPanel({
    row, receipts, canSee,
}: {
    /** 视图那一行;canSee 为 false 时【不查询、不传】—— null 在这里没有第二种含义 */
    row: PatternRow | null
    receipts: ContributingReceipt[]
    /** 读者持不持 module.purchasing.view。**不是从 row 是否为 null 倒推的。** */
    canSee: boolean
}) {
    const t = await getTranslations()

    return (
        <div className="border border-gray-300 rounded-lg p-4 mb-6">
            <p className="font-medium mb-1">{t('grn.pattern.title')}</p>

            {/* 【受限 ≠ 没有差异】这一页的门是 module.suppliers.view,
                数据的门是 module.purchasing.view —— 不是同一道。
                留白会被读成"这家供应商记录干净",而那是这块面板最不能撒的谎。
                (GRN-1b 在批次详情上栽过同一处,这里从一开始就分开。) */}
            {!canSee ? (
                <p className="text-sm text-gray-600 border border-gray-300 rounded px-3 py-2">
                    {t('grn.pattern.restricted')}
                </p>
            ) : !row ? (
                /* 视图对每一家在册供应商都返回一行(左连接)。没有行 = 不该发生,
                   不猜成"没有记录"。 */
                <p className="text-sm text-amber-700 border border-amber-300 bg-amber-50 rounded px-3 py-2">
                    {t('grn.pattern.notInView')}
                </p>
            ) : (
                <>
                    <p className="text-sm text-gray-600 mb-3">
                        {t('grn.pattern.window', {
                            days: row.window_days,
                            from: row.window_from,
                        })}
                    </p>

                    {row.comparable_receipts === 0 ? (
                        /* 【具名的空状态】—— 绝不是"0 次差异"。
                           一家从来没有可比对收货的供应商,不是一家记录干净的供应商:
                           它是一家【没有人能评判】的供应商。这两句话在采购决定面前
                           完全不同,而"0 discrepancies"会被读成前者。 */
                        <p className="text-sm text-gray-700 border border-gray-300 rounded px-3 py-2 mb-3">
                            {t('grn.pattern.noComparable', { days: row.window_days })}
                        </p>
                    ) : (
                        <>
                            {/* 分母摆在最前面,而且是一句话不是一个数 */}
                            <p className="text-sm mb-2">
                                {t('grn.pattern.denominator', {
                                    total: row.comparable_receipts,
                                    withAny: row.receipts_with_any_discrepancy,
                                })}
                            </p>
                            <ul className="text-sm space-y-1 mb-3">
                                <li>{t('grn.pattern.shortLine', {
                                    n: row.short_receipts, total: row.comparable_receipts,
                                    lines: row.short_lines, qty: row.short_qty,
                                    threshold: row.grn_short_pct,
                                })}</li>
                                <li>{t('grn.pattern.overLine', {
                                    n: row.over_receipts, total: row.comparable_receipts,
                                    lines: row.over_lines, qty: row.over_qty,
                                    threshold: row.grn_over_pct,
                                })}</li>
                                <li>{t('grn.pattern.declaredLine', {
                                    n: row.declared_vs_actual_receipts, total: row.comparable_receipts,
                                })}</li>
                                <li>{t('grn.pattern.materialLine', {
                                    n: row.material_mismatch_receipts, total: row.comparable_receipts,
                                })}</li>
                                <li>{t('grn.pattern.assayLine', {
                                    n: row.assay_beyond_receipts, total: row.comparable_receipts,
                                    threshold: row.grn_assay_tolerance_pct,
                                })}</li>
                            </ul>
                        </>
                    )}

                    {/* ── 没能评判的那些 ── 【永远印出来,哪怕是 0】
                        只在非零时才印,会让读者无从分辨"这里没有这一类"与
                        "这块面板不谈这件事"。 */}
                    <div className="border-t border-gray-200 pt-3 space-y-1">
                        <p className="text-sm text-gray-700">
                            {t('grn.pattern.excluded', { n: row.excluded_receipts })}
                        </p>
                        <p className="text-sm text-gray-700">
                            {t('grn.pattern.undated', { n: row.undated_receipts })}
                        </p>
                        {row.undated_with_discrepancy > 0 && (
                            /* 【这一行是这块面板的要害】上面那些计数是"窗口内的事实",
                               而这一行说的是"窗口外还压着几条【已经查出问题】的收货"。
                               它把"补上到货日会改变结论"这件事直说出来。 */
                            <p className="text-sm text-amber-800 border border-amber-300 bg-amber-50 rounded px-3 py-2">
                                {t('grn.pattern.undatedWithDiscrepancy', {
                                    n: row.undated_with_discrepancy,
                                })}
                            </p>
                        )}
                    </div>

                    {/* 逐条点名 —— 一个计数不可行动,一条能点开的收货才可行动 */}
                    {receipts.length > 0 && (
                        <div className="mt-3">
                            <p className="text-sm font-medium mb-1">{t('grn.pattern.contributing')}</p>
                            <ul className="text-sm space-y-1">
                                {receipts.map((r) => (
                                    <li key={r.batch_id}>
                                        <Link href={`/inbound/${r.batch_id}/edit`}
                                              className="font-mono text-blue-600 hover:underline">
                                            {r.batch_code}
                                        </Link>
                                        {r.arrival_date && (
                                            <span className="text-gray-500 ml-2">{r.arrival_date}</span>
                                        )}
                                        <span className="ml-2">
                                            {r.kinds.map((k) => t('grn.kind.' + k)).join('、')}
                                        </span>
                                    </li>
                                ))}
                            </ul>
                        </div>
                    )}
                </>
            )}
        </div>
    )
}
