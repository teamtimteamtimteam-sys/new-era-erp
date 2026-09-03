// PARTY-1:同一家公司在两侧各有一行吗 —— 一份【报告】。
//
// ★★【这一页【故意】不给出一个合计,而它自己说出为什么】★★
//   读到这一页的人,就是会想去轧差的那个人。所以那句理由画在数字【旁边】,
//   不是躺在某份文档里:轧差是一次法律行为,不是一次算术。
//
// ★★【它也【不是】一方两身那个结构】★★
//   两张表之间今天没有任何指针。这一页只是把两侧【摆在一起看】。
//   真正的结构(parties 主表)是单独一刀,返回条件见 known-issues。
//
// 【整页服务端渲染】没有客户端开关 —— 昨天记下的第三条冒烟盲区说的就是这个:
// 藏在开关后面的话,fetch 冒烟永远看不见。这一页的每一句都在初次 HTML 里。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { formatAmount } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import Link from 'next/link'
import { ListPage } from '@/app/components/ui/list-page'
import { ByTaxTable, ByNameTable, type ByTaxRow, type ByNameRow } from './OverlapTables'

type Match = {
    tax_id?: string
    customer_id: string; customer_code: string; customer_name: string
    supplier_id: string; supplier_code: string; supplier_name: string
    counterparty_type: string
    ar_open_base?: number; ap_open_base?: number
}
type Report = {
    by_tax_id: Match[]
    by_name: Match[]
    coverage: {
        customers_total: number; customers_with_tax_id: number
        suppliers_total: number; suppliers_with_tax_id: number
    }
    why_not_netted: string
}

export default async function CounterpartyOverlapPage() {
    const denied = await requireModule(MOD.customers)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const base = await getBaseCurrency()
    const report = mustOne(await supabase.rpc('counterparty_overlap_report')) as unknown as Report
    const cov = report.coverage

    // CONV-5:两段都是真正的行登记簿,两张表都换;不轧差那句话与覆盖率分母
    // 是报告体,留在 notices(它们必须【无条件】出现 —— 「让『0 条』说得出
    // 它是哪一种 0」正是这一页最要紧的一段)。state 恒为 'ok'。
    const byTaxRows: ByTaxRow[] = report.by_tax_id.map((m) => ({
        key: `${m.customer_id}-${m.supplier_id}`,
        taxId: m.tax_id ?? '—',
        customerId: m.customer_id,
        customerCode: m.customer_code,
        customerName: m.customer_name,
        supplierId: m.supplier_id,
        supplierCode: m.supplier_code,
        supplierName: m.supplier_name,
        arOpen: formatAmount(Number(m.ar_open_base ?? 0), base),
        apOpen: formatAmount(Number(m.ap_open_base ?? 0), base),
    }))
    const byNameRows: ByNameRow[] = report.by_name.map((m) => ({
        key: `${m.customer_id}-${m.supplier_id}`,
        customerLabel: `${m.customer_code} · ${m.customer_name}`,
        supplierLabel: `${m.supplier_code} · ${m.supplier_name}`,
    }))

    return (
        <ListPage
            title={t('overlap.title')}
            notices={
                <>
                    <div className="border-l-4 border-amber-500 bg-amber-50 p-3 mb-6 max-w-3xl">
                        <p className="text-sm font-medium">{t('overlap.notNettedTitle')}</p>
                        <p className="text-sm text-gray-800 mt-1">{t('overlap.notNettedWhy')}</p>
                    </div>

                    {/* ★【分母:让"0 条"说得出它是哪一种 0】★
                        没有这一段,"没有重叠"与"没有可比的东西"在屏幕上长得一模一样。 */}
                    <div className="border border-gray-300 rounded p-3 mb-6 max-w-3xl">
                        <h2 className="font-medium mb-1">{t('overlap.coverageTitle')}</h2>
                        <p className="text-sm text-gray-800">
                            {t('overlap.coverageLine', {
                                cwith: String(cov.customers_with_tax_id), ctotal: String(cov.customers_total),
                                swith: String(cov.suppliers_with_tax_id), stotal: String(cov.suppliers_total),
                            })}
                        </p>
                        {cov.customers_with_tax_id === 0 || cov.suppliers_with_tax_id === 0 ? (
                            /* 【具名的缺席】这才是今天线上的真实情况,而它不是"没有重叠" */
                            <p className="text-sm text-amber-800 mt-2">{t('overlap.coverageBlind')}</p>
                        ) : null}
                    </div>
                </>
            }
            state={{ kind: 'ok' }}
        >
            <h2 className="text-lg font-semibold mb-2">{t('overlap.byTaxTitle')}</h2>
            <p className="text-xs text-gray-600 mb-2 max-w-3xl">{t('overlap.byTaxWhat')}</p>
            {report.by_tax_id.length === 0 ? (
                <p className="text-sm text-gray-600 mb-6">{t('overlap.byTaxNone')}</p>
            ) : (
                <ByTaxTable rows={byTaxRows} />
            )}

            <h2 className="text-lg font-semibold mb-2">{t('overlap.byNameTitle')}</h2>
            <p className="text-xs text-gray-600 mb-2 max-w-3xl">{t('overlap.byNameWhat')}</p>
            {report.by_name.length === 0 ? (
                <p className="text-sm text-gray-600">{t('overlap.byNameNone')}</p>
            ) : (
                <ByNameTable rows={byNameRows} />
            )}

            {/* 【结构上的那件事还没有做,说出来 —— 免得读者以为已经做了】 */}
            <p className="text-xs text-gray-500 mt-8 max-w-3xl">{t('overlap.notStructure')}</p>
        </ListPage>
    )
}
