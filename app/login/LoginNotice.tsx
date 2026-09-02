'use client'

// ════════════════════════════════════════════════════════════════════════════
// LOGIN-1 · 登录页上的两类话(2026-09-02)
//
// 【为什么是 client:因为「被念出来」这件事要靠焦点,而焦点要在挂载后才动】
// 登录失败在本系统里是一次【重定向】—— 浏览器加载的是一份新文档。
// 而 aria-live 区域【在文档加载时就已经存在】的内容,读屏软件通常【不会念】:
// live region 播报的是「后来变化的东西」。
// 所以光挂 role="alert" 是不够的 —— 那是这一类页面最常见的一个假绿。
// 这里用 GOV.UK 的 error-summary 做法:**把焦点移到这段话上**,于是它必然被念到。
//
// 【两类话画法不同,因为它们不是一回事】
//   refusal —— 系统【拒绝】了这一次登录。role="alert",并且抢焦点。
//   info    —— 说明「你为什么在这里」(会话结束)。role="status",【不抢焦点】:
//              它是背景交代,不是要人立刻处置的东西。
//
// 【颜色不是唯一的信号 —— R7 明写的那一条】判词写在【标题的字面】里,
// 填充色只是第二重提示。于是在灰度屏、在色觉障碍、在读屏软件里,
// 这段话说的都是同一件事。正文一律用 --brand-text,对比度因此不依赖语气色。
// 这也正是 variant C 的「浅色填充片」放大到一整块横幅的写法。
// ════════════════════════════════════════════════════════════════════════════

import { useEffect, useRef } from 'react'

export default function LoginNotice({
    tone,
    title,
    hint,
    extra,
    id,
}: {
    tone: 'refusal' | 'info'
    title: string
    hint?: string
    extra?: string
    id?: string
}) {
    const ref = useRef<HTMLDivElement>(null)
    const isRefusal = tone === 'refusal'

    useEffect(() => {
        if (isRefusal) ref.current?.focus()
    }, [isRefusal])

    // 填充与描边都由 token 现算(color-mix),【不写手挑的十六进制】——
    // 那是 BRAND-1 定下的规矩:值要么是指南给的,要么是推导出来的,没有第三类。
    const fill = isRefusal
        ? 'color-mix(in srgb, var(--brand-destructive) 12%, var(--brand-surface))'
        : 'color-mix(in srgb, var(--brand-ocean) 10%, var(--brand-surface))'
    const edge = isRefusal
        ? 'color-mix(in srgb, var(--brand-destructive) 38%, var(--brand-surface))'
        : 'color-mix(in srgb, var(--brand-ocean) 34%, var(--brand-surface))'

    return (
        <div
            ref={ref}
            id={id}
            role={isRefusal ? 'alert' : 'status'}
            // tabIndex -1:能被 focus() 移进去,但【不进 Tab 顺序】——
            // 键盘用户不该为了走到邮箱框而先按过一条通知。
            tabIndex={-1}
            data-login-notice={tone}
            className="mb-5 rounded-lg border px-3.5 py-3 text-[15px] outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--brand-ocean)]"
            style={{ background: fill, borderColor: edge, color: 'var(--brand-text)' }}
        >
            <p className="font-semibold">{title}</p>
            {hint && <p className="mt-1 leading-relaxed">{hint}</p>}
            {extra && (
                <p className="mt-1.5 text-[13px]" style={{ color: 'var(--brand-muted-text)' }}>
                    {extra}
                </p>
            )}
        </div>
    )
}
