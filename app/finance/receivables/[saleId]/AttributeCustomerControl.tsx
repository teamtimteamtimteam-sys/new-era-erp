'use client'

// SAL-C:把一笔【无主】销售补挂到客户名下。
//
// 【这是记录一个已经成立的事实,不是新的承诺】—— 所以这里没有信用检查,也不该有:
// 因为"欠得太多"而拒绝把一笔已经欠下的债记进账,债不会消失,只会继续隐形。
// 补挂之后敞口自然上移;若因此越限,那是看板 credit_over_limit 支该说的话。
// 【单向】:只有原本无主的销售才看得到这个控件,挂上之后不可改投、不可退回。
//
// CONFIRM-1:那一句「单向、不可撤销」原来靠原生确认框的 `\n\n` 换行;
//   现在它是 details 里真正的两行,而【一个字没有改写】。
//   ★ 主语点的是【这一笔销售】(出库批号 · 销售日),不是金额 ——
//     主语无条件渲染,而钱是另一回事。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { attributeSaleCustomer } from './actions'

type CustomerOption = { id: string; code: string; legal_name: string }

export default function AttributeCustomerControl({
    saleId,
    subject,
    customers,
}: {
    saleId: string
    /** CONFIRM-1:补挂的是【哪一笔销售】—— 抬头那一格印的就是它。 */
    subject: string
    customers: CustomerOption[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [customerId, setCustomerId] = useState('')
    const [note, setNote] = useState('')
    const [error, setError] = useState('')
    const [done, setDone] = useState<string | null>(null)

    function onAttribute() {
        setError('')
        start(async () => {
            const res = await attributeSaleCustomer(saleId, customerId, note)
            if (res.error) setError(res.error)
            else {
                setDone(res.message ?? '')
                router.refresh()
            }
        })
    }

    // 那条消息原样取出来,按它自己的空行拆开 —— 词不动,只是不再被压平。
    const confirmBlocks = t('receivables.attribute.confirm').split('\n\n')

    if (done !== null) {
        return <p className="text-sm text-green-800 bg-green-50 border border-green-300 px-4 py-3 rounded">{done}</p>
    }

    return (
        <div className="border border-amber-300 bg-amber-50 rounded p-4 space-y-2">
            <p className="text-sm text-amber-900">{t('receivables.attribute.explain')}</p>
            <div className="flex flex-wrap items-end gap-2">
                <div>
                    <label className="block text-sm font-medium mb-1">{t('receivables.attribute.customer')}</label>
                    <select
                        value={customerId}
                        onChange={(e) => setCustomerId(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('receivables.attribute.pick')}</option>
                        {customers.map((c) => (
                            <option key={c.id} value={c.id}>
                                {c.code} - {c.legal_name}
                            </option>
                        ))}
                    </select>
                </div>
                <div className="flex-1 min-w-[12rem]">
                    <label className="block text-sm font-medium mb-1">{t('receivables.attribute.note')}</label>
                    <input
                        type="text"
                        value={note}
                        onChange={(e) => setNote(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                {/* 单向且不可撤销 —— 按下之前问一次 */}
                <ConfirmButton
                    subject={subject}
                    title={confirmBlocks[0]}
                    details={
                        confirmBlocks.length > 1 ? (
                            <div className="space-y-1 text-sm text-muted-foreground">
                                {confirmBlocks.slice(1).map((line, i) => (
                                    <p key={i}>{line}</p>
                                ))}
                            </div>
                        ) : undefined
                    }
                    confirmLabel={t('receivables.attribute.button')}
                    tier="destructive"
                    onConfirm={onAttribute}
                    disabled={pending || customerId === ''}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {pending ? t('common.saving') : t('receivables.attribute.button')}
                </ConfirmButton>
            </div>
            {/* 禁用必须说出为什么(CMP-2 的规矩) */}
            {customerId === '' && (
                <p className="text-sm text-amber-800">{t('receivables.attribute.blockedNoCustomer')}</p>
            )}
            {error && <p className="text-sm text-red-700">{error}</p>}
        </div>
    )
}
