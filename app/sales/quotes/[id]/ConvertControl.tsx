'use client'

// SO-4b:把报价转成订单。
//
// 【四条拒绝在按下【之前】就说出来】服务端各有名字(QT_NOT_ISSUED /
// QT_EXPIRED / QT_DECLINED / QT_ALREADY_CONVERTED),这里把同样四句话画在
// 控件旁边 —— 判据取自 quote_status 的 convertible / expired / status,
// 而那几列与服务端的拒绝读的是【同一处推导】(quote_is_expired)。
// 屏幕上禁用的理由与服务端拒绝的名字因此不会各说各话(CMP-2)。
//
// 【过期那一条要给补救办法】"过期了"是一句没有下一步的话;能做的事是
// 改有效期、再签发一版 —— 那句话必须写出来。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { convertQuote } from '../actions'
import { Button } from '@/app/components/ui/button'

export default function ConvertControl({
    quoteId, code, convertible, status, expired, validUntil, convertedOrderCode,
}: {
    quoteId: string; code: string; convertible: boolean; status: string
    expired: boolean; validUntil: string; convertedOrderCode: string | null
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [open, setOpen] = useState(false)
    const [orderDate, setOrderDate] = useState('')
    const [error, setError] = useState('')

    // 【每一种"转不了"指向一个不同的下一步】
    const blockedReason =
        status === 'converted' ? t('quotes.convert.blockedConverted', { code: convertedOrderCode ?? '—' })
        : status === 'declined' ? t('quotes.convert.blockedDeclined')
        : status === 'draft'    ? t('quotes.convert.blockedDraft')
        : expired               ? t('quotes.convert.blockedExpired', { date: validUntil })
        : ''

    if (!convertible) {
        return <p className="text-sm text-gray-600">{blockedReason}</p>
    }

    function go() {
        setError('')
        startTransition(async () => {
            // 【成功时 action 会 redirect,所以这里只处理失败】
            const res = await convertQuote(quoteId, orderDate)
            if (res?.error) setError(res.error)
        })
    }

    if (!open) {
        return (
            <Button variant="secondary" size="sm" className="text-sm" type="button" onClick={() => setOpen(true)}>
                {t('quotes.convert.action')}
            </Button>
        )
    }

    return (
        <div className="border border-gray-300 rounded p-3">
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            <div className="flex flex-wrap items-end gap-3">
                <div>
                    <label className="block text-xs text-gray-600 mb-1">
                        {t('quotes.convert.orderDate')} <span className="text-red-600">*</span>
                    </label>
                    <input type="date" value={orderDate} onChange={(e) => setOrderDate(e.target.value)}
                           className="border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
                <Button size="sm" type="button" onClick={go} disabled={isPending || orderDate.trim() === ''}>
                    {isPending ? t('common.saving') : t('quotes.convert.action')}
                </Button>
                <Button variant="secondary" size="sm" type="button" onClick={() => setOpen(false)}>
                    {t('common.cancel')}
                </Button>
            </div>
            {/* 【订单日不是报价日】它是客户接受的那一天,而且决定单号年份与汇率期间 */}
            <p className="text-xs text-gray-500 mt-2">{t('quotes.convert.orderDateWhy')}</p>
            {/* 【后果句在按下之前】 */}
            <p className="text-xs text-gray-600 mt-1">{t('quotes.convert.consequence', { code })}</p>
        </div>
    )
}
