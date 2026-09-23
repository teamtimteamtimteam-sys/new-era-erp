// app/finance/payment-requests/requestSubject.ts
// ★ PAY-REQ-1 · Batch B:转账与代扣税两族申请【没有收款人】—— 列表与详情那一格
//   要说出它挪的是什么:转账写「转出户 → 转入户」,代扣税写「IRAS · 代扣月」。
//   两页共用这一份,免得各写一遍、各自漂开。付款两种返回 null,由调用方照旧印收款人名。
import { formatMonth } from '@/lib/dates'

type Translate = (key: string, values?: Record<string, string | number>) => string

export function requestSubjectLabel(
    t: Translate,
    locale: string,
    r: { kind: string; bank_account_code: string | null; to_account_code: string | null; period_month: string | null },
): string | null {
    if (r.kind === 'bank_transfer' || r.kind === 'bank_transfer_reversal') {
        if (!r.bank_account_code || !r.to_account_code) return '—'
        return `${t('finance.bank.' + r.bank_account_code)} → ${t('finance.bank.' + r.to_account_code)}`
    }
    if (r.kind === 'wht_remittance' || r.kind === 'wht_remittance_reversal') {
        return t('finance.paymentRequests.whtSubject', { month: r.period_month ? formatMonth(r.period_month, locale) : '—' })
    }
    return null
}
