'use client'

// app/components/ReasonPrompt.tsx
// AUDEL-2:【一句"为什么"要在动手之前问出来】—— 一份实现,五个消费者。
//
// AUDEL-1b 把理由做成了必填,而当时【还没有输入框】,于是五个控件全部被数据库
// 按名拒:删进料批、删产出批、回滚加工单、取消盘点、取消采购单。
// 本组件是那一刀留下的缺口的修补,不是一个新功能。
//
// ── 三层,而且【第三层才是权威】────────────────────────────────────────────
// ① 展开之后先说清这个动作会做什么(destructive 动作尤其:回滚会还原投入、
//    作废产出,那句话必须在按下之前就摆在眼前,不是按下之后才知道);
// ② 理由为空时【提交钮不可按】—— AGENTS.md:永远不要为服务端必然拒绝的动作
//    渲染一个可提交的控件;
// ③ 而服务端仍然是权威。客户端这一层只是不让人白跑一趟 —— 绕过界面
//    (直接调 RPC)照样会撞上 DELETE_REASON_REQUIRED 那一族。
//    **两层不是重复**:一层管体验,一层管事实。
//
// 【为什么不是 window.prompt】它拿不到本地化的说明文字、没法禁用提交、
// 在部分环境里被浏览器直接屏蔽 —— 而这五个动作里有三个是不可逆的。
// 形状取自既有的 CancelOrderControl(内联输入 + 确认 + 就地报错)。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'

export default function ReasonPrompt({
    triggerLabel,
    title,
    /** 这个动作会做什么 —— 不可逆的必须在这里说清楚 */
    consequence,
    confirmLabel,
    placeholder,
    /** 服务端动作。返回 { error } 就地显示,不跳转;成功由调用方决定去哪 */
    action,
    onDone,
    /** 触发钮的样式:行内文字(表格里)或描边按钮(详情页) */
    variant = 'button',
    disabled = false,
}: {
    triggerLabel: string
    title: string
    consequence?: string
    confirmLabel: string
    placeholder: string
    action: (reason: string) => Promise<{ error?: string } | void>
    onDone?: () => void
    variant?: 'button' | 'link'
    disabled?: boolean
}) {
    const t = useTranslations()
    const [open, setOpen] = useState(false)
    const [reason, setReason] = useState('')
    const [error, setError] = useState('')
    const [isPending, startTransition] = useTransition()

    // 【判据与服务端同一条】btrim 之后为空就是没给 —— 与 db 里那句
    // `p_reason IS NULL OR btrim(p_reason) = ''` 逐字对应,不是另一条规矩。
    const blank = reason.trim() === ''

    function submit() {
        setError('')
        startTransition(async () => {
            const res = await action(reason)
            if (res && 'error' in res && res.error) {
                // 【服务端拒了就把服务端那句话原样显示】它已经按名翻译过。
                setError(res.error)
                return
            }
            setOpen(false)
            setReason('')
            onDone?.()
        })
    }

    if (!open) {
        return (
            <div className={variant === 'link' ? '' : 'flex flex-col items-end gap-2'}>
                <button
                    type="button"
                    onClick={() => { setError(''); setOpen(true) }}
                    disabled={disabled || isPending}
                    className={
                        variant === 'link'
                            ? 'text-red-600 hover:underline disabled:text-gray-400'
                            : 'text-sm border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50 disabled:opacity-50'
                    }
                >
                    {triggerLabel}
                </button>
                {error && <p className="text-sm text-red-600 max-w-md">{error}</p>}
            </div>
        )
    }

    return (
        <div className="border border-red-300 bg-red-50 rounded px-3 py-3 text-sm max-w-md">
            <p className="font-medium text-red-900 mb-1">{title}</p>
            {/* 【不可逆的动作,后果写在按下之前】 */}
            {consequence && <p className="text-red-900 mb-2">{consequence}</p>}
            <label className="block mb-2">
                <span className="block text-xs text-red-900 mb-1">
                    {t('common.reasonRequired')}
                </span>
                <input
                    type="text"
                    autoFocus
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    placeholder={placeholder}
                    className="w-full border border-gray-300 px-2 py-1 rounded"
                />
            </label>
            <div className="flex items-center gap-2">
                {/* 【空理由时不可按】—— 服务端必然拒绝的动作不该有可提交的控件 */}
                <button
                    type="button"
                    onClick={submit}
                    disabled={blank || isPending}
                    className="border border-red-400 bg-white text-red-700 px-3 py-1 rounded hover:bg-red-100 disabled:opacity-40 disabled:cursor-not-allowed"
                >
                    {isPending ? t('common.saving') : confirmLabel}
                </button>
                <button
                    type="button"
                    onClick={() => { setOpen(false); setReason(''); setError('') }}
                    disabled={isPending}
                    className="text-gray-600 hover:underline"
                >
                    {t('common.cancel')}
                </button>
                {blank && (
                    <span className="text-xs text-red-700">{t('common.reasonBlankHint')}</span>
                )}
            </div>
            {error && <p className="text-red-700 mt-2">{error}</p>}
        </div>
    )
}
