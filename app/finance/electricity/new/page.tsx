// app/finance/electricity/new/page.tsx
// MES-5a-2(2026-10-08,MES-5a Step 0 Q24 · Q27 · Q28,Tim):新建一张电费单的分摊 —— 先预览(库里算),再过账(同一支算)。
//   门:requireModule(MOD.finance) 进得来;过账按钮要 module.finance.edit(看得见、按不下去、说出码)。
//   供应商名单走名字视图(supplier_lookup,财务的门读得到)—— 货代不进(与加工成本冲抵那一页同一条)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { getBaseCurrency } from '@/lib/currency'
import { ListPage } from '@/app/components/ui/list-page'
import NewAllocationForm from './NewAllocationForm'

export default async function NewElectricityAllocationPage() {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const t = await getTranslations()
    const supabase = await createClient()
    const [canEdit, baseCurrency, supRes] = await Promise.all([
        can('module.finance.edit'), getBaseCurrency(),
        supabase.from('supplier_lookup').select('id, legal_name').is('deleted_at', null).neq('counterparty_type', 'forwarder').order('legal_name'),
    ])
    const suppliers = (mustRows(supRes, 'supplier_lookup') as { id: string; legal_name: string }[])
        .map((s) => ({ value: s.id, label: s.legal_name }))
    return (
        <ListPage title={t('energy.newTitle')} maxWidth="max-w-5xl" state={{ kind: 'ok' }}
                  breadcrumb={<Link href="/finance/electricity" className="app-link hover:underline text-sm">← {t('energy.listTitle')}</Link>}
                  intro={t('energy.newIntro')}>
            <NewAllocationForm canEdit={canEdit} baseCurrency={baseCurrency} suppliers={suppliers} />
        </ListPage>
    )
}
