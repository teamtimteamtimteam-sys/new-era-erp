'use client'

// 作废发票:内联理由输入 + 确认对话框,再调 voidInvoice。
// 理由必填(DB 侧 REASON_REQUIRED 兜底);成功后 revalidate 让页面切到已作废状态。
//
// ★★【CONFIRM-1:这一处是十六处里唯一【没有】把理由搬进对话框的】★★
//   另外七处理由型只有【一个】必填项,搬进去搬得干净。这一处不是:
//   带分录的发票还要一个【冲销日】(void_invoice 的 REVERSAL_DATE_REQUIRED),
//   而对话框只放得下一个理由框。把两个必填项拆到两块屏幕上 ——
//   一个填在面板里、一个填在对话框里 —— 比两个都留在面板里更坏:
//   人会以为面板填完就齐了,然后在对话框里撞上第二个必填项。
//   所以这里【只加主语】,理由与冲销日原样留在面板里,一起管着那个禁用条件。
//   ☞ 这是刻意的不一致,写在这里是为了让下一个人不必再推一遍。
import { useState, useTransition } from 'react'
import { voidInvoice } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

// SO-3a:order 头的作废是一次【冲销】(借 2500 / 贷 1100)—— 冲销日必填,
// 它决定冲销分录落进哪个期间,永不默认(与手工冲销分录同一条);sale 头照旧。
export default function VoidInvoiceControl({
    invoiceId,
    subject,
    hasEntry,
}: {
    invoiceId: string
    /** CONFIRM-1:作废的是【哪一张发票】—— 发票代号,抬头里就印着它。 */
    subject: string
    hasEntry: boolean
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [open, setOpen] = useState(false)
    const [reason, setReason] = useState('')
    const [reversalDate, setReversalDate] = useState('')
    // ★【GST-3:判据从"是不是 order 型"改成"有没有分录要冲"】★
    // GST-2 让【带税的 sale 型发票】也过一张分录(借 1100 / 贷 2100),
    // 于是它作废时同样【要求冲销日】(void_invoice 的 REVERSAL_DATE_REQUIRED)。
    // 而这个控件当时只按 kind 决定显不显示日期栏 —— 结果是:一张带税的
    // sale 发票在屏幕上【根本作废不了】,因为没有任何地方能填那个日期。
    // 那条路又正好是关闭 GST 开关的必经之路(带税发票挡着关不掉),
    // 于是整个"关"的方向在界面上是断的。
    // 【新判据与数据库那一侧逐字同源】void_invoice 问的就是 entry_id 是否为空。
    const needsReversalDate = hasEntry

    function handleSubmit() {
        startTransition(async () => {
            const result = await voidInvoice(invoiceId, reason.trim(), needsReversalDate ? reversalDate : undefined)
            if (result?.error) {
                alert(result.error)
            } else {
                setOpen(false)
                setReason('')
            }
        })
    }

    if (!open) {
        return (
            <button
                type="button"
                onClick={() => setOpen(true)}
                className="border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50 text-sm"
            >
                {t('invoice.void')}
            </button>
        )
    }

    return (
        <span className="flex flex-wrap items-center gap-2">
            <input
                type="text"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder={t('invoice.voidReason')}
                className="border border-gray-300 px-3 py-1 rounded text-sm min-w-[16rem]"
            />
            {needsReversalDate && (
                <span className="flex items-center gap-1">
                    <input
                        type="date"
                        value={reversalDate}
                        onChange={(e) => setReversalDate(e.target.value)}
                        className="border border-gray-300 px-3 py-1 rounded text-sm"
                        title={t('invoice.voidReversalDateWhy')}
                    />
                    <span className="text-xs text-gray-500">{t('invoice.voidReversalDateWhy')}</span>
                </span>
            )}
            <ConfirmButton
                subject={subject}
                title={t('invoice.voidConfirm')}
                confirmLabel={t('invoice.void')}
                tier="destructive"
                disabled={!reason.trim() || (needsReversalDate && !reversalDate.trim()) || isPending}
                onConfirm={handleSubmit}
                className="bg-red-600 text-white px-3 py-1 rounded hover:bg-red-700 disabled:bg-gray-400 text-sm"
            >
                {t('invoice.void')}
            </ConfirmButton>
            <button type="button" onClick={() => setOpen(false)} className="text-gray-600 hover:underline text-sm">
                {t('common.cancel')}
            </button>
        </span>
    )
}
