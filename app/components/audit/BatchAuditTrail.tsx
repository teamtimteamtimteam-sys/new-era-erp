// app/components/audit/BatchAuditTrail.tsx
// AUDIT-1:跨模块审计轨迹 —— 屏幕那一半。一个批次,【一条排好序的时间线】,
// 从收货一路到分录。
//
// 【它与可追溯报告不是一件事】/output/[id]/edit 上那一份是【交给客户的证书】,
// 没有血缘时具名拒绝(NOTHING_TO_REPORT)。这一条是【内部轨迹】:
// "这个批次身上什么都没发生"本身就是审计要的答案,所以它不拒绝,它就说空。
//
// ── 管着每一行的三条规矩 ────────────────────────────────────────────────
// ① **接缝画在行里**(Tim 的 R3)。轨迹跟不动的那一跳,当场用一句人话说出来,
//    并且【绝不省略那一行】。一条静默漏掉一段的轨迹,与一个意思是"不许看"的零
//    是同一种坏。
// ② **受限不是空**(Tim 的 R5 / AUD-1)。读者看不到的那一段仍然占着行,写
//    「受限」并点名是哪个模块 —— 而不是让那一段整段消失。整段消失读起来是
//    "没有分录",真相却是"你不能看",两者导向相反的结论。
// ③ **谁做的只有一种答法**:一律走 app/components/ActorName.tsx。它已经把
//    ①查得到 ②账号没关联档案 ③根本没记过 ④看不到人事 分成四句不同的话,
//    并且写死了【绝不裸印 uuid】。本刀不再造第二套词汇。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { createClient } from '@/lib/supabase/server'
import ActorName, { loadActorNames } from '@/app/components/ActorName'
import { UNREACHABLE_HISTORY_TABLES, type AuditTrailRow } from './auditTrailTypes'

export default async function BatchAuditTrail({ rows }: { rows: AuditTrailRow[] }) {
    const t = await getTranslations()
    // loadActorNames 要一个 supabase 客户端(它自己去查 employees 与权限)。
    const supabase = await createClient()
    const names = await loadActorNames(supabase, rows.map((r) => r.actor_id))

    // detail 里挑几个值印出来 —— 全量 jsonb 对读的人不是一个答案。
    const summarise = (r: AuditTrailRow): string => {
        if (!r.may_view || !r.detail) return ''
        const d = r.detail
        const pick = (k: string) => (d[k] === null || d[k] === undefined ? null : String(d[k]))
        const parts = [
            pick('movement_type') && t('movements.type.' + pick('movement_type')),
            pick('qty_delta') && `${Number(pick('qty_delta')) > 0 ? '+' : ''}${pick('qty_delta')}`,
            pick('quantity_consumed') && `−${pick('quantity_consumed')}`,
            pick('quantity_produced') && `+${pick('quantity_produced')}`,
            pick('amount_base'),
            pick('memo'),
            pick('change_type'),
            pick('decision'),
            pick('shipment_code'),
            pick('stocktake_code'),
        ].filter(Boolean)
        return parts.join(' · ')
    }

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-1">{t('auditTrail.title')}</h2>
            <p className="text-sm text-gray-600 mb-1">{t('auditTrail.intro')}</p>
            {/* 【脊柱是哪一份,说出来】(Tim 的 A4)。同一支被冲销的加工单有三份
                互相不一致的说法,轨迹挑了流水 —— 因为只有它把"冲销"记成了一件
                发生过的事。不说出来,下一个读者会以为轨迹对此是中立的。 */}
            <p className="text-xs text-gray-500 mb-4">{t('auditTrail.spineNote')}</p>

            {rows.length === 0 ? (
                // 【具名的空状态】。"什么都没发生过"是审计的一个合法答案,
                // 但它必须与"你不能看"分开说 —— 后者由每一行的「受限」承担。
                <p className="text-sm text-gray-500">{t('auditTrail.empty')}</p>
            ) : (
                <div className="overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('auditTrail.colWhen')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('auditTrail.colWhat')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('auditTrail.colDetail')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('auditTrail.colWho')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('auditTrail.colSource')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((r, i) => (
                                <tr key={`${r.source_table}-${r.source_id ?? i}`} className={r.may_view ? '' : 'bg-gray-50'}>
                                    <td className="border border-gray-300 px-3 py-2 whitespace-nowrap text-gray-600">
                                        <div className="font-mono text-xs">{r.occurred_at.slice(0, 16).replace('T', ' ')}</div>
                                        {/* 3b:业务日期与记账时刻【不同时】两个都印。
                                            相同就不印第二个 —— 重复一遍不是信息。 */}
                                        {r.business_date && r.business_date !== r.occurred_at.slice(0, 10) && (
                                            <div className="text-xs text-gray-500">
                                                {t('auditTrail.bizDate')}: {r.business_date}
                                            </div>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {t('auditTrail.kind.' + r.event_kind)}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {r.may_view ? (
                                            summarise(r) || '—'
                                        ) : (
                                            // ② 受限:点名是哪个模块,不是一格空白
                                            <span className="text-gray-500">
                                                {t('common.restricted')}
                                                <span className="ml-1 text-xs text-gray-400">
                                                    ({t('auditTrail.needsModule')}: {r.module_code})
                                                </span>
                                            </span>
                                        )}
                                        {/* ① 接缝:逐条画在这一行里 */}
                                        {r.seams.length > 0 && (
                                            <ul className="mt-1 space-y-0.5">
                                                {r.seams.map((s) => (
                                                    <li key={s} className="text-xs text-amber-700">
                                                        ⚠ {t('auditTrail.seam.' + s)}
                                                    </li>
                                                ))}
                                            </ul>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {r.may_view ? (
                                            <ActorName
                                                userId={r.actor_id}
                                                names={names}
                                                space={r.actor_space === 'employee' ? 'employee' : 'account'}
                                            />
                                        ) : (
                                            <span className="text-gray-500">{t('common.restricted')}</span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 font-mono text-xs">
                                        {r.may_view && r.href ? (
                                            <Link href={r.href} className="text-blue-600 hover:underline">
                                                {r.source_code ?? r.source_table}
                                            </Link>
                                        ) : r.may_view ? (
                                            (r.source_code ?? r.source_table)
                                        ) : (
                                            <span className="text-gray-400">{t('common.restricted')}</span>
                                        )}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}

            {/* 【具名脚注:够不到批次的六张历史表】——(Tim 的 A1)。
                它们在 schema 上没有任何一条路通向批次。建成永远空的臂会读成
                "这里什么都没发生过";省掉不提则读者无从知道轨迹的边界在哪。
                所以点名。 */}
            <p className="mt-3 text-xs text-gray-500">
                {t('auditTrail.footerUnreachable')}: {UNREACHABLE_HISTORY_TABLES.join(t('common.listSep'))}
            </p>
        </section>
    )
}
