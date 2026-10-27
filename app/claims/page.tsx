// app/claims/page.tsx
// SYSTEM-MAP-1(Tim D2 · Q2,2026-10-27):「报销」—— 人事底下【一条】条目,两种:医疗与一般。只读。
//   【门】requireFunction(FN.claims) = 人事或财务查看码任一(lib/modules.ts 的 P_CLAIMS)。
//   【每一种的行由它自己那张视图裁决】医疗读 medical_claim_status(持 module.hr.view,或者那一笔说的就是你;金额要 data.view_health,
//     本人的除外 —— 没有就是 NULL,这里画「受限」,不画空、不画 0.00);一般读 expense_claim_status(持 module.finance.view,或者是你自己的)。
//     这一页不加任何自己的过滤,也不替视图判断谁看得见什么。
//   【去处】医疗 → /hr/claims/[id];一般:待决 / 驳回 / 撤回 → /finance/claims#claim-<id>(那一行滚进视野并标亮),
//     批准了的 → 那笔开支 /finance/expenses/[id]。两张原页的地址与审批规则一个字没动(Q2)。
//     读者进不去那一页(缺人事或财务查看码、只看得见自己那一笔)时,单号照印,不画成一条会被拒绝的链接,并说出缺哪个码。
//   【读多少】两种各读最新的 READ_ROW_LIMIT 行(线上 max_rows);读满了就说出来(真实总数来自同一张视图的 count)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { READ_ROW_LIMIT } from '@/lib/listSort'
import { formatDate } from '@/lib/dates'
import ClaimsAllTable, { type ClaimsAllRow } from './ClaimsAllTable'

type MedicalRow = {
    claim_id: string; code: string; employee_code: string; legal_name: string; claim_date: string | null
    amount_sgd: number | string | null; settlement_state: string | null
}
type GeneralRow = {
    claim_id: string; code: string; employee_code: string; employee_name: string; spend_date: string | null
    amount_ccy: number | string | null; currency: string; status: string; expense_id: string | null
    is_paid: boolean | null; is_owing: boolean | null; expense_reversed: boolean | null
}

export default async function ClaimsPage() {
    const denied = await requireFunction(FN.claims)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [medRes, medCountRes, genRes, genCountRes, canHr, canFinance] = await Promise.all([
        supabase.from('medical_claim_status')
            .select('claim_id, code, employee_code, legal_name, claim_date, amount_sgd, settlement_state')
            .order('claim_date', { ascending: false }).order('claim_id', { ascending: true })
            .range(0, READ_ROW_LIMIT - 1),
        supabase.from('medical_claim_status').select('claim_id', { count: 'exact', head: true }),
        supabase.from('expense_claim_status')
            .select('claim_id, code, employee_code, employee_name, spend_date, amount_ccy, currency, status, expense_id, is_paid, is_owing, expense_reversed')
            .order('spend_date', { ascending: false }).order('claim_id', { ascending: true })
            .range(0, READ_ROW_LIMIT - 1),
        supabase.from('expense_claim_status').select('claim_id', { count: 'exact', head: true }),
        can('module.hr.view'),
        can('module.finance.view'),
    ])
    const medical = mustRows(medRes, 'medical_claim_status') as unknown as MedicalRow[]
    const general = mustRows(genRes, 'expense_claim_status') as unknown as GeneralRow[]
    const medicalTotal = mustCount(medCountRes, 'medical_claim_status count')
    const generalTotal = mustCount(genCountRes, 'expense_claim_status count')

    const rows: ClaimsAllRow[] = [
        ...medical.map((r): ClaimsAllRow => ({
            key: `m-${r.claim_id}`,
            kind: 'medical',
            code: r.code,
            href: canHr ? `/hr/claims/${r.claim_id}` : null,
            linkCode: 'module.hr.view',
            employee: `${r.employee_code} — ${r.legal_name}`,
            date: r.claim_date ? formatDate(r.claim_date, locale) : '—',
            dateRaw: r.claim_date,
            // 医疗按新元记(列名就是 amount_sgd);NULL = 读者没有 data.view_health 且不是本人 —— 受限,不是没有
            amount: r.amount_sgd === null ? null : Number(r.amount_sgd),
            currency: 'SGD',
            state: t(`claims.state_${r.settlement_state ?? ''}`),
        })),
        ...general.map((r): ClaimsAllRow => {
            const approved = r.status === 'approved' && r.expense_id !== null
            const extra = !r.expense_reversed && r.is_owing ? t('expenseClaims.owingOther')
                : !r.expense_reversed && r.is_paid ? t('expenseClaims.paid') : null
            return {
                key: `g-${r.claim_id}`,
                kind: 'general',
                code: r.code,
                href: !canFinance ? null : approved ? `/finance/expenses/${r.expense_id}` : `/finance/claims#claim-${r.claim_id}`,
                linkCode: 'module.finance.view',
                employee: `${r.employee_code} — ${r.employee_name}`,
                date: r.spend_date ? formatDate(r.spend_date, locale) : '—',
                dateRaw: r.spend_date,
                amount: r.amount_ccy === null ? null : Number(r.amount_ccy),
                currency: r.currency,
                state: extra ? `${t('expenseClaims.status_' + r.status)} · ${extra}` : t('expenseClaims.status_' + r.status),
            }
        }),
    ].sort((a, b) => (b.dateRaw ?? '').localeCompare(a.dateRaw ?? '') || a.key.localeCompare(b.key))

    return (
        <ListPage title={t('claimsAll.title')} intro={t('claimsAll.intro')} state={{ kind: 'ok' }}>
            {medicalTotal > medical.length && (
                <p role="status" data-row-cap-notice="" className="mb-2 text-sm text-amber-800">
                    {t('claimsAll.capNotice', { kind: t('claimsAll.kindMedical'), shown: medical.length, total: medicalTotal })}
                </p>
            )}
            {generalTotal > general.length && (
                <p role="status" data-row-cap-notice="" className="mb-2 text-sm text-amber-800">
                    {t('claimsAll.capNotice', { kind: t('claimsAll.kindGeneral'), shown: general.length, total: generalTotal })}
                </p>
            )}
            <ClaimsAllTable rows={rows} empty={t('claimsAll.empty')} />
        </ListPage>
    )
}
