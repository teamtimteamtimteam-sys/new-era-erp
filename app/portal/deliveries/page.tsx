// app/portal/deliveries/page.tsx
// MES-9b(2026-10-19,MES-9 Step 0 Q14 · Q15 · §4,Tim):【门户的交货】—— 调用者自己那一家的收货记录与记在上面的地磅单,
//   【按今天记着的样子】(页面写明读取的时刻,"as recorded today")。它们是记录,不是签发过的单据,所以没有 PDF、没有下载。
//   读的只有 portal_deliveries()(只授 supplier_portal;先过 portal_require_link)。没有一个价钱(Q15),没有任何内部的东西(§4):
//   不画单价、计价状态、估值、安全状态、库位、加工阶段、备注、车牌、照片、毛重皮重、员工的名字 —— 函数本来就不回它们。
//   一张两家共用的地磅单只画分给自己那几张收货的那几份公斤数。
//   门户函数按名拒的三种(撤销了 · 会话结束了 · 令牌不是门户角色)各说一句人话;别的失败照常抛(失败不是空集)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { localizePortalError } from '../portalErrorCodes'

type PortalDeliveries = {
    supplier_code: string
    as_of: string
    receipts: { code: string; arrival_date: string | null; material: string; quantity: number; unit: string;
                purchase_order_code: string | null; tickets: string[] }[]
    tickets: { code: string; direction: 'inbound' | 'outbound'; completed_at: string | null; voided: boolean;
               shares: { receipt_code: string; kg: number }[] | null }[]
}

export default async function PortalDeliveriesPage() {
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('portal_deliveries')
    if (error) {
        const { code, text } = await localizePortalError(error.message)
        if (code === 'PORTAL_ACCESS_REVOKED' || code === 'PORTAL_SESSION_ENDED' || code === 'PORTAL_ROLE_REQUIRED') {
            return (
                <div className="p-6 max-w-2xl" data-portal-refused={code}>
                    <h1 className="mb-3">{t('portal.deliveries.title')}</h1>
                    <p className="text-sm">{text}</p>
                </div>
            )
        }
        throw new Error(`查询失败(portal_deliveries): ${error.code ?? ''} ${error.message}`.trim())
    }
    const d = data as unknown as PortalDeliveries
    const number = new Intl.NumberFormat(locale === 'zh' ? 'zh-CN' : 'en-GB', { maximumFractionDigits: 3 })

    return (
        <div className="p-6 max-w-4xl space-y-6" data-portal-deliveries={d.supplier_code}>
            <div>
                <p className="text-sm mb-2"><Link href="/portal" className="app-link hover:underline">{t('portal.backHome')}</Link></p>
                <h1 className="mb-2">{t('portal.deliveries.title')}</h1>
                <p className="text-sm text-[color:var(--brand-muted-text)] max-w-3xl">{t('portal.deliveries.intro')}</p>
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-1" data-as-of="1">
                    {t('portal.deliveries.asOf', { at: formatAuditStamp(d.as_of) })}
                </p>
            </div>

            <section data-delivery-section="receipts">
                <h2 className="mb-2">{t('portal.deliveries.receiptsTitle')}</h2>
                {d.receipts.length === 0 ? <p className="text-sm">{t('portal.deliveries.none')}</p> : (
                    <ul className="divide-y divide-gray-200 border-y border-gray-200 text-sm">
                        {d.receipts.map((r) => (
                            <li key={r.code} className="py-2 flex flex-wrap gap-x-6 gap-y-1" data-receipt={r.code}>
                                <span className="font-medium min-w-[9rem]">{r.code}</span>
                                <span className="min-w-[7rem]" title={t('portal.deliveries.colArrival')}>{r.arrival_date ? formatDate(r.arrival_date, locale) : '—'}</span>
                                <span className="min-w-[10rem] break-words" title={t('portal.deliveries.colMaterial')}>{r.material}</span>
                                <span className="min-w-[7rem] tabular-nums" title={t('portal.deliveries.colQuantity')}>{number.format(r.quantity)} {r.unit}</span>
                                {r.purchase_order_code && (
                                    <span className="min-w-[8rem]" title={t('portal.deliveries.colOrder')}>{r.purchase_order_code}</span>
                                )}
                                {r.tickets.length > 0 && (
                                    <span className="text-[color:var(--brand-muted-text)]" title={t('portal.deliveries.colTickets')}>{r.tickets.join(' · ')}</span>
                                )}
                            </li>
                        ))}
                    </ul>
                )}
            </section>

            <section data-delivery-section="tickets">
                <h2 className="mb-2">{t('portal.deliveries.ticketsTitle')}</h2>
                {d.tickets.length === 0 ? <p className="text-sm">{t('portal.deliveries.none')}</p> : (
                    <ul className="divide-y divide-gray-200 border-y border-gray-200 text-sm">
                        {d.tickets.map((tk) => (
                            <li key={tk.code} className="py-2 flex flex-wrap gap-x-6 gap-y-1" data-ticket={tk.code}>
                                <span className="font-medium min-w-[9rem]">{tk.code}</span>
                                <span className="min-w-[5rem]" title={t('portal.deliveries.colDirection')}>
                                    {tk.direction === 'inbound' ? t('portal.deliveries.directionInbound') : t('portal.deliveries.directionOutbound')}
                                </span>
                                <span className="min-w-[9rem]" title={t('portal.deliveries.colCompleted')}>
                                    {tk.completed_at ? formatAuditStamp(tk.completed_at) : t('portal.deliveries.notCompleted')}
                                </span>
                                <span className="min-w-[5rem]" data-ticket-state={tk.voided ? 'void' : 'valid'}>
                                    {tk.voided ? t('portal.deliveries.voided') : t('portal.deliveries.valid')}
                                </span>
                                <span className="tabular-nums" title={t('portal.deliveries.colShare')}>
                                    {(tk.shares ?? []).map((s) => t('portal.deliveries.shareLine', { receipt: s.receipt_code, kg: number.format(s.kg) })).join(' · ')}
                                </span>
                            </li>
                        ))}
                    </ul>
                )}
            </section>
        </div>
    )
}
