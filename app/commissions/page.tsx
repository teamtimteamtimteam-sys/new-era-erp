// COMM-1:佣金协议登记簿。
//
// ★【整页服务端渲染,没有客户端开关】★ 藏在开关后面的话,fetch 冒烟永远看不见
//   (那条盲区记在 AGENTS.md)。本页每一句都在初次 HTML 里。
//
// ★★【这一页上两句话是【无条件】渲染的,而那不是排版偏好】★★
//   · notPosted —— 「它只记条款,不过账、不算钱」。
//     把"佣金上线了"读成"佣金会进总账",代价是有人以为账上已经有这笔支出。
//   · noAccrual —— 「算出某一笔欠多少那一半没有建(COMM-ACCRUAL-1)」。
//   两句都【与有没有数据无关】,所以它们不放在任何 length 判断里面 ——
//   一条只在有数据时才出现的警告,等于没有警告。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { formatAmount } from '@/lib/format'
import Link from 'next/link'

type Agreement = {
    id: string
    agent_supplier_id: string
    side: string
    basis: string
    rate_pct: number | null
    amount_ccy: number | null
    currency: string | null
    recognition_trigger: string
    valid_from: string
    valid_to: string
    remarks: string | null
    suppliers: { code: string; legal_name: string } | null
}

export default async function CommissionsPage() {
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const rows = mustRows(
        await supabase
            .from('commission_agreements')
            .select('id, agent_supplier_id, side, basis, rate_pct, amount_ccy, currency, recognition_trigger, valid_from, valid_to, remarks, suppliers!commission_agreements_agent_supplier_id_fkey(code, legal_name)')
            .is('deleted_at', null)
            .order('valid_from', { ascending: false }),
        'commission_agreements') as unknown as Agreement[]

    return (
        <div className="p-8">
            <div className="flex items-baseline justify-between mb-1">
                <h1 className="text-2xl font-bold">{t('commissions.title')}</h1>
                <Link href="/commissions/new" className="text-sm text-blue-600 hover:underline">
                    {t('commissions.newTitle')}
                </Link>
            </div>
            <p className="text-sm text-gray-700 max-w-3xl mb-4">{t('commissions.what')}</p>

            {/* ★★【它不过账】—— 无条件渲染,见抬头 ★★ */}
            <div className="border-l-4 border-amber-500 bg-amber-50 p-3 mb-3 max-w-3xl">
                <p className="text-sm text-gray-800">{t('commissions.notPosted')}</p>
            </div>

            {/* ★★【计提那一半没有建,而它有名字】—— 无条件渲染 ★★ */}
            <div className="border-l-4 border-gray-400 bg-gray-50 p-3 mb-6 max-w-3xl">
                <p className="text-sm text-gray-800">{t('commissions.noAccrual')}</p>
            </div>

            {rows.length === 0 ? (
                /* 【具名的缺席,不是一片空白】「还没有人写下来」与「我们不付佣金」不是一回事 */
                <p className="text-sm text-gray-600">{t('commissions.none')}</p>
            ) : (
                <table className="w-full border-collapse">
                    <thead>
                        <tr className="bg-gray-100">
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('commissions.colAgent')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('commissions.colSide')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('commissions.colBasis')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right text-sm">{t('commissions.colRate')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('commissions.colTrigger')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('commissions.colValidity')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('commissions.colRemarks')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-3 py-2 text-sm">
                                    <Link href={`/commissions/${r.id}/edit`} className="text-blue-600 hover:underline">
                                        {r.suppliers?.code}
                                    </Link>
                                    {r.suppliers ? ` · ${r.suppliers.legal_name}` : null}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{t('commissions.side.' + r.side)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{t('commissions.basis.' + r.basis)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right text-sm">
                                    {r.rate_pct !== null
                                        ? `${r.rate_pct}%`
                                        : r.amount_ccy !== null && r.currency
                                          ? formatAmount(Number(r.amount_ccy), r.currency)
                                          : null}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{t('commissions.trigger.' + r.recognition_trigger)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{r.valid_from} → {r.valid_to}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{r.remarks}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </div>
    )
}
