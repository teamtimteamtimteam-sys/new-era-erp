// app/finance/freight/page.tsx
// 运费单据列表(FRT-1)。运费【资本化进批次成本】—— 借方进 1200/5000,
// 贷方记在【货代】名下,与材料供应商的应付是两笔账。
//
// CONV-4:套 CONV-1 的两文件模板。没有筛选工具栏,空态判据不必分层。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import FreightTable, { type FreightRow } from './FreightTable'

type FreightQueryRow = {
    id: string
    code: string
    doc_date: string
    amount_base: number
    allocation_basis: string
    payment_status: string
    status: string
    suppliers: { legal_name: string } | null
}

export default async function FreightListPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const baseCurrency = await getBaseCurrency()

    const rows = mustRows(
        await supabase
            .from('freight_documents')
            .select('id, code, doc_date, amount_base, allocation_basis, payment_status, status, suppliers ( legal_name )')
            .is('deleted_at', null)
            .order('doc_date', { ascending: false })
            .limit(200),
        'freight_documents'
    ) as unknown as FreightQueryRow[]

    const tableRows: FreightRow[] = rows.map((r) => ({
        id: r.id,
        code: r.code,
        docDate: r.doc_date,
        forwarder: r.suppliers?.legal_name ?? '—',
        amountBase: r.amount_base,
        baseCurrency,
        allocationBasis: r.allocation_basis,
        paymentStatus: r.payment_status,
        reversed: r.status === 'reversed',
    }))

    return (
        <ListPage
            title={t('finance.freight.listTitle')}
            actions={
                <Button asChild>
                    <Link href="/finance/freight/new">{t('finance.freight.addButton')}</Link>
                </Button>
            }
            // 资本化的代价,写在人看得见的地方:错的分摊藏在存货里,不显示在损益表上
            intro={t('finance.freight.intro')}
            state={tableRows.length === 0
                ? { kind: 'empty', noRows: t('finance.freight.empty') }
                : { kind: 'ok' }}
        >
            <FreightTable rows={tableRows} empty={t('finance.freight.empty')} />
        </ListPage>
    )
}
