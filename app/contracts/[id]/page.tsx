// TERMS-EDIT-1(Tim 2026-09-27,grilling Q1–Q6):合同详情页 —— 表头、七张条款表、这份合同的申请、申请生效 / 暂停。
//
// ★【谁能做什么,由库定,这里只把它说出来】★
//   · 写:action.contract_terms(cco · admin)—— 没有的人每个控件都看得见、按不动、说出那个码(DBLOCK-1);
//   · 冻结:APR-8 的守卫(生效中 / 在等 CFO)+ TERMS-EDIT-1 Q4(到期 / 终止)。理由从 contract_terms_lock_reason 读 ——
//     与守卫按名拒时用的是【同一支】判据,屏幕不另写一份;
//   · 卖方条款(计价 / 结算 / 精炼费 / 惩罚)在买方合同上画出来、按不动、说出理由(Q6);
//   · 申请生效之前缺什么:contract_activation_missing —— 与提交那一支(CONTRACT_TERMS_INCOMPLETE)同一支函数;
//   · 批 / 驳:CFO 在下面那块申请面板上(与 /contracts 同一个组件、同一份门码)。
// ★【看不见的合同是 404】★ 读的是基表、受 RLS:只看得见供应商那一侧的人(仓库)读不到一份卖方合同 ——
//   对他而言那份合同不存在,与登记簿上看不见它是同一个答案。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { formatDate } from '@/lib/dates'
import { RecordHeader } from '@/app/components/ui/record-header'
import TermsRequestsPanel from '@/app/components/pricing/TermsRequestsPanel'
import { firstMissingDecideCode, loadTermsRequests } from '@/app/components/pricing/termsRequestsData'
import { missingTermLabel } from '@/app/components/pricing/termsRequestErrorCodes'
import { loadSubstanceLabels, substanceLabeller } from '@/app/tools/pricing/metal-prices/substanceQuery'
import ContractActivationPanel, { type ActivationRow } from '../ContractActivationPanel'
import TermSection, { type TermFieldView, type TermRowView } from './TermSection'
import HeaderForm from './HeaderForm'
import { SECTIONS, SELL_ONLY, type SectionSpec } from './termSpecs'

type Contract = {
    id: string; code: string; side: 'buy' | 'sell'; kind: string; title: string; status: string
    effective_from: string; effective_to: string | null; signed_on: string | null
    currency: string | null; incoterm: string | null; payment_terms_days: number | null
    document_ref: string | null; notes: string | null
    customer_id: string | null; supplier_id: string | null
}

type Dict = { value: string; label: string }[]

export default async function ContractDetailPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const found = mustRows(
        await supabase.from('contracts')
            .select('id, code, side, kind, title, status, effective_from, effective_to, signed_on, currency, incoterm, payment_terms_days, document_ref, notes, customer_id, supplier_id')
            .eq('id', id).is('deleted_at', null),
        'contracts') as Contract[]
    const c = found[0]
    if (!c) notFound()

    // ── 对手方的显示名(名字跟着单据走 —— AGENTS.md 常设决定 3)──────────────
    const party = c.customer_id
        ? mustRows(await supabase.from('customer_lookup').select('legal_name').eq('id', c.customer_id), 'customer_lookup')
        : mustRows(await supabase.from('supplier_lookup').select('legal_name').eq('id', c.supplier_id ?? ''), 'supplier_lookup')
    const partyName = (party[0] as { legal_name: string | null } | undefined)?.legal_name ?? '—'

    // ── 七张条款表:这份合同的行,按 termSpecs 的列读 ─────────────────────────
    const termRows = await Promise.all(SECTIONS.map(async (s) =>
        mustRows(
            await supabase.from(s.dbTable as 'contract_grade_specs')
                .select(['id', ...s.fields.map((f) => f.name)].join(', '))
                .eq('contract_id', c.id)
                .order('created_at'),
            s.dbTable) as unknown as Record<string, unknown>[]))

    // ── 字典 ───────────────────────────────────────────────────────────────
    const [substances, materials, currencies, indices] = await Promise.all([
        loadSubstanceLabels(supabase),
        supabase.from('materials').select('id, code, name').is('deleted_at', null).order('code'),
        supabase.from('currencies').select('code').order('code'),
        supabase.from('metal_price_indices').select('code, name_en, name_zh, is_active').order('sort_order'),
    ])
    const substanceName = substanceLabeller(substances, locale)
    const matRows = mustRows(materials, 'materials') as { id: string; code: string; name: string }[]
    const ccyRows = (mustRows(currencies, 'currencies') as { code: string }[]).map((r) => r.code)
    const idxRows = mustRows(indices, 'metal_price_indices') as { code: string; name_en: string; name_zh: string; is_active: boolean }[]
    const dicts: Record<string, Dict> = {
        // 可新选的只给启用的;显示时停用的也要读得出名字(substanceLabeller 读的是全部)
        substances: substances.filter((x) => x.is_active).map((x) => ({ value: x.code, label: substanceName(x.code) })),
        materials: matRows.map((m) => ({ value: m.id, label: `${m.code} — ${m.name}` })),
        currencies: ccyRows.map((x) => ({ value: x, label: x })),
        indices: idxRows.filter((x) => x.is_active).map((x) => ({ value: x.code, label: x.code })),
    }
    const dictLabel: Record<string, (v: string) => string> = {
        substances: (v) => substanceName(v),
        materials: (v) => { const m = matRows.find((x) => x.id === v); return m ? `${m.code} — ${m.name}` : v },
        currencies: (v) => v,
        indices: (v) => v,
    }

    // ── 冻结的理由、清单、权限、申请 ────────────────────────────────────────
    const [lockRes, missingRes, canWrite, missingDecideCode, requests] = await Promise.all([
        supabase.rpc('contract_terms_lock_reason', { p_contract_id: c.id }),
        supabase.rpc('contract_activation_missing', { p_contract_id: c.id }),
        can('action.contract_terms'),
        firstMissingDecideCode(can),
        loadTermsRequests(supabase, t, { which: 'contract', contractId: c.id, recent: 50 }),
    ])
    const lock = mustOne(lockRes, 'contract_terms_lock_reason') as string | null
    const missingItems = (mustOne(missingRes, 'contract_activation_missing') as string[] | null) ?? []
    const missing = await Promise.all(missingItems.map(missingTermLabel))

    const statusLabel = t(`contracts.status.${c.status}`)
    const lockReason: string | null =
        lock === null ? null
            : lock === 'active' ? t('contractDetail.lock.active')
            : lock === 'expired' || lock === 'terminated' ? t('contractDetail.lock.ended', { status: statusLabel })
            : lock.startsWith('request:') ? t('contractDetail.lock.request', { label: lock.slice('request:'.length) })
            : t('contractDetail.lock.other', { reason: lock })

    // ── 每一段摊平成客户端要的形状 ──────────────────────────────────────────
    const fieldView = (s: SectionSpec): TermFieldView[] => s.fields.map((f) => ({
        name: f.name,
        label: t(`contractDetail.field.${s.table}.${f.name}`),
        type: f.type,
        required: Boolean(f.required),
        min: f.min,
        max: f.max,
        defaultValue: f.defaultValue,
        options: f.options?.kind === 'enum'
            ? f.options.values.map((v) => ({ value: v, label: t(`contractDetail.opt.${f.name}.${v}`) }))
            : f.options?.kind === 'dict' ? dicts[f.options.dict] : undefined,
    }))
    const rowView = (s: SectionSpec, r: Record<string, unknown>): TermRowView => {
        const shown: Record<string, string> = {}
        const values: Record<string, string> = {}
        for (const f of s.fields) {
            const v = r[f.name]
            values[f.name] = v === null || v === undefined ? '' : String(v)
            if (v === null || v === undefined || v === '') shown[f.name] = ''
            else if (f.type === 'boolean') shown[f.name] = v ? t('contractDetail.yes') : t('contractDetail.no')
            else if (f.options?.kind === 'enum') shown[f.name] = t(`contractDetail.opt.${f.name}.${String(v)}`)
            else if (f.options?.kind === 'dict') shown[f.name] = dictLabel[f.options.dict](String(v))
            else shown[f.name] = String(v)
        }
        return { id: String(r.id), shown, values }
    }

    const activationRow: ActivationRow[] =
        c.status === 'draft' || c.status === 'suspended' || c.status === 'active'
            ? [{
                id: c.id, code: c.code, title: c.title,
                status: c.status as ActivationRow['status'], statusLabel,
                openLabel: requests.open[0]?.label ?? null,
                missing,
            }]
            : []

    return (
        <div className="p-8 max-w-6xl space-y-8">
            <div>
                <Link href="/contracts" className="hover:underline text-sm app-link">{t('contractDetail.back')}</Link>
            </div>
            <div>
                <h1 className="mb-2"><span className="font-mono">{c.code}</span> · {c.title}</h1>
                <RecordHeader fields={[
                    { label: t('contracts.colSide'), value: t(`contracts.side.${c.side}`) },
                    { label: t('contracts.form.counterparty'), value: partyName },
                    { label: t('contracts.colStatus'), value: statusLabel },
                    { label: t('contracts.colPeriod'), value: `${formatDate(c.effective_from, locale)} → ${c.effective_to ? formatDate(c.effective_to, locale) : t('contracts.openEnded')}` },
                    { label: t('contracts.form.kind'), value: t(`contracts.kind.${c.kind}`) },
                ]} />
                <p className="text-sm text-[color:var(--brand-muted-text)] max-w-4xl">{t('contractDetail.intro')}</p>
            </div>

            {/* ── 让合同生效(APR-8)+ 申请生效之前的清单(Q3)───────────────────── */}
            <ContractActivationPanel rows={activationRow} canWrite={canWrite} />
            {activationRow.length === 0 && (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('contractDetail.endedNoActivation', { status: statusLabel })}</p>
            )}
            {c.side === 'sell' && missing.length === 0 && activationRow.length > 0 && c.status !== 'active' && (
                <p className="text-sm text-[color:var(--brand-text)]" data-activation-complete={c.code}>{t('contractDetail.checklistComplete')}</p>
            )}
            {c.side === 'buy' && (
                <p className="text-xs text-[color:var(--brand-muted-text)] max-w-4xl">{t('contractDetail.buyNoChecklist')}</p>
            )}

            {/* ── 这份合同的申请:CFO 在这里批 / 驳,看得见与上一次批准时的差别 ──────────── */}
            <TermsRequestsPanel
                open={requests.open}
                history={requests.history}
                missingDecideCode={missingDecideCode}
                withdrawCode="action.contract_terms"
                canWithdrawByCode={canWrite}
            />

            <HeaderForm
                contractId={c.id}
                currencies={ccyRows}
                canWrite={canWrite}
                blockedReason={lockReason}
                values={{
                    counterpartyLabel: partyName,
                    sideLabel: t(`contracts.side.${c.side}`),
                    kind: c.kind, title: c.title,
                    effective_from: c.effective_from, effective_to: c.effective_to ?? '',
                    signed_on: c.signed_on ?? '', currency: c.currency ?? '', incoterm: c.incoterm ?? '',
                    payment_terms_days: c.payment_terms_days === null ? '' : String(c.payment_terms_days),
                    document_ref: c.document_ref ?? '', notes: c.notes ?? '',
                }}
            />

            {SECTIONS.map((s, i) => (
                <TermSection
                    key={s.table}
                    contractId={c.id}
                    contractCode={c.code}
                    table={s.table}
                    title={t(`contractDetail.section.${s.table}.title`)}
                    hint={t(`contractDetail.section.${s.table}.hint`)}
                    fields={fieldView(s)}
                    rows={termRows[i].map((r) => rowView(s, r))}
                    canWrite={canWrite}
                    blockedReason={lockReason ?? (c.side === 'buy' && SELL_ONLY.has(s.table) ? t('contractDetail.sellOnly') : null)}
                    onePerContract={Boolean(s.onePerContract)}
                />
            ))}
        </div>
    )
}
