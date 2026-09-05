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
import { can } from '@/lib/permissions'
import { formatAmount } from '@/lib/format'
import NewForwarderForm from './NewForwarderForm'
import { ListPage } from '@/app/components/ui/list-page'
import ForwardersTable, { type ForwarderRow } from './ForwardersTable'

export default async function ForwardersPage() {
    const denied = await requireModule(MOD.logistics)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    // ★★【FIX-2a:这一页此前对三个角色整张是空的,而它说的不是"空"】★★
    // 守卫是 module.logistics.view,operations / sales / warehouse 三个角色都持有它,
    // 于是这一页【打得开】。但 suppliers 基表挂的是 module.suppliers.view ——
    // 他们读到零行,屏幕上写着「还没有货代」,而线上有四家。
    // 名字走 supplier_lookup(FIX-1 建的那张查名视图,本刀把 logistics.view 加进它的
    // 体内谓词);付款条件与未结应付【不跟着来】,见下面两处。
    const rows = mustRows(
        await supabase
            .from('supplier_lookup')
            .select('id, code, legal_name')
            .eq('counterparty_type', 'forwarder')
            .is('deleted_at', null)
            .order('legal_name'),
        'forwarders'
    ) as unknown as { id: string; code: string; legal_name: string }[]

    // 【付款条件是商务数据 —— 它不在查名视图里,而这是一次判断不是一次遗漏】
    // supplier_lookup 刻意没有 payment_terms(FIX-1 抬头列的那六列之一)。
    // 持 suppliers.view 的人照旧读得到;其余的人这一栏画【具名受限】,
    // 不画一根横杠 —— 「没填付款条件」与「你不能看付款条件」不是一回事。
    const canCommercial = await can('module.suppliers.view')
    const termsById = new Map<string, string | null>()
    if (canCommercial && rows.length) {
        for (const s of mustRows(
            await supabase
                .from('suppliers')
                .select('id, payment_terms')
                .in('id', rows.map((r) => r.id)),
            'forwarder payment terms'
        )) {
            termsById.set(s.id as string, s.payment_terms as string | null)
        }
    }

    const ids = rows.map((r) => r.id)
    const details = ids.length
        ? mustRows(
              await supabase.from('forwarder_details').select('supplier_id, main_routes').in('supplier_id', ids),
              'forwarder_details'
          )
        : []
    const routeOf = new Map(details.map((d) => [d.supplier_id as string, d.main_routes as string | null]))

    // 未结应付:与供应商欠款读的是【同一张视图】—— 共用 id 的全部意义就在这里。
    //
    // ★★【FIX-2a(b):欠了多少钱是【商务数据】,而扣下它【就是对的】】★★
    // ap_open_items 的体内谓词是 module.finance.view。operations / sales /
    // warehouse / procurement 都没有它,于是这一支读回零行 —— 而下面那句
    // `owed.get(r.id) ? … : null` 会把零行翻译成【每一家货代都不欠钱】。
    // 那不是"少一栏",那是一个自信的、错的、会被抄进决策的答案。
    // Tim 的裁定:现场的人不接触任何商务数据 —— 所以【不放宽】,让屏幕说出来。
    // 判据先问权限,再决定读不读:拒绝必须是一句权限答复,不能从空结果倒推。
    const canMoney = await can('module.finance.view')
    const open = canMoney && ids.length
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
        paymentTerms: termsById.get(r.id) ?? '—',
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
                <ForwardersTable
                    rows={tableRows}
                    empty={t('logistics.emptyForwarders')}
                    moneyRestricted={!canMoney}
                    termsRestricted={!canCommercial}
                />
            </div>
        </ListPage>
    )
}
