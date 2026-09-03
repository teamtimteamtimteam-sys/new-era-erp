// app/logistics/forwarders/page.tsx
// LOG-1c:货代名单。
//
// CONV-5:套 CONV-1 的两文件模板。state 恒为 'ok' —— NewForwarderForm 是这一页
// 【建一家新货代】的唯一出口,走 empty 分支会把它藏起来。见 §⑩-3。
//
// 【这一页与供应商页【故意】不共用任何东西】。货代在账上是一行 suppliers
// (LOG-1a 的决定:一家公司一个 id,应付/账龄/重估整条链因此不用改),
// 但在屏幕上它不是供应商:没有物料类别、没有合规状态、没有采购单。
// 把那些搬过来,等于把"货代是不是供应商"这个已经裁定过的问题重新打开。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { formatAmount } from '@/lib/format'
import NewForwarderForm from './NewForwarderForm'
import { ListPage } from '@/app/components/ui/list-page'
import ForwardersTable, { type ForwarderRow } from './ForwardersTable'

export default async function ForwardersPage() {
    const denied = await requireModule(MOD.logistics)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const rows = mustRows(
        await supabase
            .from('suppliers')
            .select('id, code, legal_name, payment_terms')
            .eq('counterparty_type', 'forwarder')
            .is('deleted_at', null)
            .order('legal_name'),
        'forwarders'
    )

    const ids = rows.map((r) => r.id)
    const details = ids.length
        ? mustRows(
              await supabase.from('forwarder_details').select('supplier_id, main_routes').in('supplier_id', ids),
              'forwarder_details'
          )
        : []
    const routeOf = new Map(details.map((d) => [d.supplier_id as string, d.main_routes as string | null]))

    // 未结应付:与供应商欠款读的是【同一张视图】—— 共用 id 的全部意义就在这里。
    const open = ids.length
        ? mustRows(
              await supabase.from('ap_open_items').select('counterparty_id, open_base, currency').in('counterparty_id', ids),
              'ap_open_items'
          )
        : []
    // 未结余额按【本位币】汇总(open_base),所以这一栏的币种就是本位币。
    const owed = new Map<string, number>()
    for (const o of open) {
        const k = o.counterparty_id as string
        owed.set(k, (owed.get(k) ?? 0) + Number(o.open_base ?? 0))
    }
    const baseRow = mustRows(
        await supabase.from('currencies').select('code').eq('is_base', true).limit(1),
        'base currency'
    )
    const baseCcy = (baseRow[0]?.code as string) ?? null

    const tableRows: ForwarderRow[] = rows.map((r) => ({
        id: r.id,
        legalName: r.legal_name,
        code: r.code,
        mainRoutes: routeOf.get(r.id) ?? '—',
        paymentTerms: r.payment_terms ?? '—',
        // 【零不写成 0.00】—— 没有欠款给 null,由表说那句话
        owedLabel: owed.get(r.id) ? formatAmount(owed.get(r.id)!, baseCcy) : null,
    }))

    return (
        <ListPage title={t('logistics.forwardersTitle')} state={{ kind: 'ok' }}>
            <NewForwarderForm
                labels={{
                    heading: t('logistics.newForwarder'),
                    legalName: t('suppliers.form.legalName'),
                    country: t('suppliers.form.country'),
                    paymentTerms: t('suppliers.form.paymentTerms'),
                    submit: t('logistics.newForwarder'),
                }}
            />

            <div className="mt-6">
                <ForwardersTable rows={tableRows} empty={t('logistics.emptyForwarders')} />
            </div>
        </ListPage>
    )
}
