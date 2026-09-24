// app/finance/list-vs-ledger/page.tsx
// AP-RECON-1 Batch B:清单 ↔ 总账的常设勾稽 —— 应付清单 ↔ 2000,应收清单 ↔ 1100。
//
// 【它不自己算一分钱】整页只渲染 list_ledger_reconciliation() 的返回值(本仓库那条
// "预览要问数据库"的规矩:两份实现在写下来那天一致、之后悄悄分开)。
// 每一边:清单合计、总账余额、差,然后是【允许的三种差】—— 登记的残留(逐单据,
// 带理由与 known-wrong 引用)、重估(算出来的一行)、挂账的收付款(算出来的一行)——
// 最后是未解释。未解释不是 0 就是一件没有人解释过的事,而它没有兜底桶可躲。
//
// 【答不上来不是对不上】没有 data.view_prices 的读者,清单的价格列是遮蔽的;函数对这一边
// 按名拒(refusal = PRICES_RESTRICTED,数字为 NULL),这里照直说出来,不渲染成 0。
//
// 表用组件库的 DataTable(ListVsLedgerTable):每边固定七行,行在这里从函数的返回值压平。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ListVsLedgerTable from './ListVsLedgerTable'
import { formatAmount } from '@/lib/format'

type Residue = {
    doc_code: string
    amount_base: number
    residue_class: string
    reason: string
    known_wrong_ref: string
}
type OnAccount = { code: string; amount_base: number }
type Side = {
    side: 'ap' | 'ar'
    control_account: string
    refusal: string | null
    list_base: number | null
    list_rows: number | null
    ledger_base: number | null
    gap_base: number | null
    residue: Residue[]
    residue_base: number | null
    revaluation_base: number | null
    on_account: OnAccount[]
    on_account_base: number | null
    unexplained_base: number | null
    agrees: boolean | null
}
type Recon = { base_currency: string; sides: Side[] }

export default async function ListVsLedgerPage() {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const recon = mustOne(await supabase.rpc('list_ledger_reconciliation'),
        'list_ledger_reconciliation') as unknown as Recon | null
    if (!recon) throw new Error('list_ledger_reconciliation returned nothing')
    const ccy = recon.base_currency
    const money = (v: number | null) => (v === null ? '—' : formatAmount(Number(v), ccy))

    return (
        <ListPage title={t('finance.listVsLedger.title')} maxWidth="max-w-5xl" state={{ kind: 'ok' }}>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('finance.listVsLedger.intro')}</p>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-6">{t('finance.listVsLedger.signNote')}</p>
            {recon.sides.map((s) => (
                <section key={s.side} className="mb-8" data-side={s.side}>
                    <h2 className="text-base font-semibold mb-2">
                        {t(s.side === 'ap' ? 'finance.listVsLedger.sideAp' : 'finance.listVsLedger.sideAr',
                            { acct: s.control_account })}
                    </h2>
                    {s.refusal ? (
                        <p className="text-sm text-amber-800 bg-amber-50 rounded px-3 py-2">
                            {t('finance.listVsLedger.pricesRestricted')}
                        </p>
                    ) : (
                        <ListVsLedgerTable
                            lineHeader={t('finance.listVsLedger.colLine')}
                            amountHeader={t('finance.listVsLedger.colAmount', { ccy })}
                            rows={[
                                { id: s.side + '-list', label: t('finance.listVsLedger.lineList', { n: s.list_rows ?? 0 }),
                                  href: s.side === 'ap' ? '/finance/payables' : '/finance/receivables',
                                  details: [], amountText: money(s.list_base), tone: null },
                                { id: s.side + '-ledger', label: t('finance.listVsLedger.lineLedger', { acct: s.control_account }),
                                  href: `/finance/ledger/${s.control_account}`, details: [], amountText: money(s.ledger_base), tone: null },
                                { id: s.side + '-gap', label: t('finance.listVsLedger.lineGap'), href: null,
                                  details: [], amountText: money(s.gap_base), tone: 'strong' },
                                { id: s.side + '-residue', label: t('finance.listVsLedger.lineResidue', { n: s.residue.length }), href: null,
                                  details: s.residue.map((r) => `${r.doc_code} · ${t('finance.listVsLedger.residueClass.' + r.residue_class)} · ${money(r.amount_base)} — ${r.reason} (${t('finance.listVsLedger.knownWrong', { ref: r.known_wrong_ref })})`),
                                  amountText: money(s.residue_base), tone: null },
                                { id: s.side + '-reval', label: t('finance.listVsLedger.lineRevaluation'), href: '/finance/revaluation',
                                  details: [], amountText: money(s.revaluation_base), tone: null },
                                { id: s.side + '-onaccount', label: t('finance.listVsLedger.lineOnAccount', { n: s.on_account.length }), href: null,
                                  details: s.on_account.map((p) => `${p.code} · ${money(p.amount_base)}`),
                                  amountText: money(s.on_account_base), tone: null },
                                { id: s.side, label: t('finance.listVsLedger.lineUnexplained'), href: null,
                                  details: [], amountText: money(s.unexplained_base), tone: s.agrees ? 'ok' : 'bad' },
                            ]}
                        />
                    )}
                </section>
            ))}
        </ListPage>
    )
}
