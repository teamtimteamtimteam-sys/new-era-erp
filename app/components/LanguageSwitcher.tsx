'use client'

// app/components/LanguageSwitcher.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1a ⑤:同一个机制,换一个控件 —— 按钮变成滑块
// ════════════════════════════════════════════════════════════════════════════
//
// ★【换掉的【只有控件】】★ 委托书原话:「Reuse the existing language mechanism;
// only its control changes.」所以 useLocale / setLocale / useTransition 三样
// 一个字没动 —— 切语言这件事怎么发生,与它长什么样是两回事。
//
// 【为什么从前那个按钮不合适了】它印的是【目标语言】(现在是英文就印「中」),
// 于是屏幕上那个字说的是"点我会变成什么",而不是"你现在在哪"。
// 单独挂在顶栏上时那还能读;**放进一张下拉菜单、和「通知」「登出」排在一起之后,
// 一个只印一个字的按钮读起来像一条菜单项,而不是一个开关。**
// 滑块把两个语言【同时画出来】,当前那个高亮 —— 状态与动作各归各位。
//
// 【role="switch" 而不是两个单选】它只有两个值,而且切换是【立刻生效】的动作,
// 不是一次待提交的选择。aria-checked 说的是"是不是中文",aria-label 说的是这是
// 什么开关 —— 读屏用户拿到的是一句完整的话,不是一个孤零零的「中」。
import { useTransition } from 'react'
import { useLocale } from '@/lib/i18n/client'
import { setLocale } from '@/lib/i18n/actions'

export default function LanguageSwitcher() {
    const locale = useLocale()
    const [isPending, startTransition] = useTransition()
    const isZh = locale === 'zh'

    function toggle() {
        startTransition(() => {
            setLocale(isZh ? 'en' : 'zh')
        })
    }

    return (
        <button
            type="button"
            role="switch"
            aria-checked={isZh}
            aria-label={isZh ? '切换到 English' : 'Switch to 中文'}
            title={isZh ? '切换到 English' : 'Switch to 中文'}
            onClick={toggle}
            disabled={isPending}
            data-nav="lang-slider"
            className="flex w-full items-center justify-between rounded px-3 py-1.5 text-sm text-[color:var(--brand-text)] hover:bg-[color:var(--brand-accent)] disabled:opacity-50"
        >
            <span>{isZh ? '中文 / English' : 'English / 中文'}</span>
            {/* 【轨道 + 滑块】两个语言同时在场,当前那个高亮。
                它不是一个图标 —— 是两段文字和一个背景块,Tim 那条"下拉里不要图标"
                说的是图标集,而这里一个字形都没有借。 */}
            <span
                aria-hidden
                className="relative ml-3 flex h-6 shrink-0 items-center rounded-full border border-[color:var(--brand-border)] bg-[color:var(--brand-accent)] p-0.5 text-[11px] font-medium"
            >
                <span
                    className={
                        'flex h-5 w-7 items-center justify-center rounded-full transition-colors ' +
                        (isZh ? 'bg-[color:var(--brand-ocean-fill)] text-white' : 'text-[color:var(--brand-muted-glass)]')
                    }
                >
                    中
                </span>
                <span
                    className={
                        'flex h-5 w-7 items-center justify-center rounded-full transition-colors ' +
                        (isZh ? 'text-[color:var(--brand-muted-glass)]' : 'bg-[color:var(--brand-ocean-fill)] text-white')
                    }
                >
                    EN
                </span>
            </span>
        </button>
    )
}
