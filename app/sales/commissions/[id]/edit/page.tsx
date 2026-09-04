// COMM-1:编辑一份佣金协议。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { notFound } from 'next/navigation'
import CommissionForm, { type Agent, type Currency } from '../../CommissionForm'

type Row = {
    id: string; agent_supplier_id: string; side: string; basis: string
    rate_pct: number | null; amount_ccy: number | null; currency: string | null
    recognition_trigger: string; valid_from: string; valid_to: string
    remarks: string | null; deleted_at: string | null
}

export default async function EditCommissionPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const row = mustOne(
        await supabase.from('commission_agreements')
            .select('id, agent_supplier_id, side, basis, rate_pct, amount_ccy, currency, recognition_trigger, valid_from, valid_to, remarks, deleted_at')
            .eq('id', id).maybeSingle()) as unknown as Row | null
    if (!row) notFound()
    // 【一份已删的协议不给编辑,而且说出来 —— 不是 404】它存在过,那是一个不同的答案。
    if (row.deleted_at) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-2">{t('commissions.editTitle')}</h1>
                <p className="text-sm text-gray-700">{t('commissions.deleted')}</p>
            </div>
        )
    }

    const agents = mustRows(
        await supabase.from('suppliers')
            .select('id, code, legal_name')
            .eq('counterparty_type', 'service_vendor')
            .is('deleted_at', null)
            .order('code'),
        'suppliers') as Agent[]
    const currencies = mustRows(
        await supabase.from('currencies').select('code').order('code'),
        'currencies') as Currency[]

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('commissions.editTitle')}</h1>
            <CommissionForm
                agents={agents}
                currencies={currencies}
                initial={{
                    id: row.id,
                    agent_supplier_id: row.agent_supplier_id,
                    side: row.side,
                    basis: row.basis,
                    rate_pct: row.rate_pct === null ? '' : String(row.rate_pct),
                    amount_ccy: row.amount_ccy === null ? '' : String(row.amount_ccy),
                    currency: row.currency ?? '',
                    recognition_trigger: row.recognition_trigger,
                    valid_from: row.valid_from,
                    valid_to: row.valid_to,
                    remarks: row.remarks ?? '',
                }}
            />
        </div>
    )
}
