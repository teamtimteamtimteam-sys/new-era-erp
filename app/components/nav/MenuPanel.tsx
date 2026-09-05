'use client'

// app/components/nav/MenuPanel.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1a ④⑤:一级模块菜单的那一套画法,搬出来给三个调用方共用
// ════════════════════════════════════════════════════════════════════════════
//
// 【这不是一个新组件,是一次【搬家】】下面每一行都是从 ModuleBar.tsx 里原样搬来的
// (useMoreBelow / MoreBelow / ScrollPanel,连同它们的注释)。委托书那一条写的是
// 「Reuse the module dropdown's existing markup and styles. Find it; do not write
// a second dropdown implementation.」—— 工具下拉与头像下拉要用的正是这一套,
// 而它当时长在 ModuleBar 内部,导出不了。**搬出来 = 三个调用方共用一份实现;
// 留在原地 = 抄两份。** 这个仓库为"两份漂移的真相"付过账,不再付第四次。
//
// 【搬家【没有】改任何行为】滚动、"还有 N 条"、sticky 底边、data-menu-row 的语义,
// 逐字不变。ModuleBar 现在从这里 import,它自己那三份定义删掉了。
//
// 【唯一新增的一件事:对齐方向】模块菜单挂在按钮左边缘(left-0),而工具与头像
// 在顶栏最右侧,菜单必须挂右边缘(right-0),否则它会伸出视口。所以面板的类名
// 由一支函数产出,方向是参数 —— **不是复制一份类名再改一个词**。
import { useCallback, useEffect, useRef, useState } from 'react'

/**
 * ★【CHART-0 ③:一条被截断的菜单必须【自己说】它还有下文】★
 * ────────────────────────────────────────────────────────────────────────────
 * Tim 以为财务没有应付账款那一段 —— 它在,只是在下面,而他不知道菜单能滚。
 * 实测(稳定别名,admin,1440×900):财务菜单 1227px 内容装在 628px 里,
 * **599px 在视野之外,而屏幕上没有任何东西说这件事。**
 *
 * ★【为什么不能只靠滚动条】★ 第一版就是只靠它,而实测证明那不够:
 * macOS 的滚动条是【覆盖式】的,不滚就不显示 —— 量到的宽度是 0px。
 * globals.css 里的 ::-webkit-scrollbar 把 Chrome/Safari 掰回常驻式,
 * 但 Firefox 掰不动。**一个只在某些浏览器上出现的信号,不是一个信号。**
 * 所以真正的判据是这一条:我们【自己画】一行字,它不看操作系统的脸色。
 *
 * 【它说的是条数,不是"往下滚"】"还有 4 条"与"下面还有内容"是两句话:
 * 前者可核对,后者只是一个手势。条数是数出来的 —— 数【完全在视野外】的那些,
 * 半露的那一条不算(它已经在说自己存在了)。
 * 【滚到底就消失】—— 一条永远挂着的"还有"会变成背景噪音,而它此刻是【假的】。
 */
function useMoreBelow(ref: React.RefObject<HTMLDivElement | null>, deps: unknown[]) {
    const [more, setMore] = useState(0)
    const measure = useCallback(() => {
        const el = ref.current
        if (!el) return
        // 【数的是完全落在视野外的条目】—— 逐个量,不按平均行高估算:
        // 分组标题、缩进项与普通项的高度并不相同,估算会给出一个对不上的数字。
        const bottom = el.scrollTop + el.clientHeight
        let n = 0
        for (const row of el.querySelectorAll<HTMLElement>('[data-menu-row]')) {
            if (row.offsetTop >= bottom) n++
        }
        setMore(n)
    }, [ref])
    useEffect(() => {
        measure()
        const el = ref.current
        if (!el) return
        el.addEventListener('scroll', measure, { passive: true })
        const ro = new ResizeObserver(measure)
        ro.observe(el)
        return () => { el.removeEventListener('scroll', measure); ro.disconnect() }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [measure, ...deps])
    return more
}

/** 菜单底下那条【贴着底边】的提示。它在滚动容器【之内】,所以它跟着菜单走。 */
function MoreBelow({ n, label }: { n: number; label: string }) {
    if (n <= 0) return null
    return (
        <p
            data-menu-more={n}
            aria-hidden
            className="sticky bottom-0 -mx-1 -mb-1 mt-1 border-t border-[color:var(--brand-border)] bg-[color:var(--brand-accent)] px-3 py-1 text-[11px] font-medium text-[color:var(--brand-text)]"
        >
            {label}
        </p>
    )
}

/**
 * 一个【会滚动的菜单面板】+ 它自己那条「还有 N 条」。
 * 桌面的下拉、手机的抽屉、工具下拉与头像下拉共用它 ——
 * 它们是同一个缺陷,不该有四份修法。
 */
export function ScrollPanel({
    className, role, moreLabel, children,
}: {
    className: string
    role?: string
    moreLabel: (n: number) => string
    children: React.ReactNode
}) {
    const ref = useRef<HTMLDivElement>(null)
    const more = useMoreBelow(ref, [children])
    return (
        <div ref={ref} className={className} role={role}>
            {children}
            <MoreBelow n={more} label={moreLabel(more)} />
        </div>
    )
}

/**
 * 下拉面板的类名。**一份定义,方向是参数。**
 * 模块菜单挂按钮的左边缘;工具与头像在最右侧,必须挂右边缘,否则伸出视口。
 * 【玻璃只给浮动层】R2:表格永远不磨砂,理由见 app/globals.css。
 */
export function menuPanelClass(align: 'left' | 'right', width = 'w-64') {
    return (
        'nav-glass menu-scroll absolute top-full z-50 mt-1 max-h-[70vh] overflow-y-auto ' +
        'rounded-md border border-[color:var(--brand-border)] p-1 shadow-lg ' +
        (align === 'left' ? 'left-0 ' : 'right-0 ') + width
    )
}

/**
 * Esc 关闭 + 点外面关闭。**【键盘要能出得来】,不然打开的菜单是一个陷阱。**
 *
 * 【也是搬来的】ModuleBar 里原本有一份一模一样的 useEffect。工具与头像两个菜单
 * 各需要同样的行为,而"再抄两遍"就是三处将来各自漂移的地方 ——
 * 尤其是 Esc 那一条:漏掉它,菜单就只能用鼠标关。
 */
export function useMenuDismiss(
    ref: React.RefObject<HTMLElement | null>,
    close: () => void,
) {
    useEffect(() => {
        const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') close() }
        const onDown = (e: MouseEvent) => {
            if (ref.current && !ref.current.contains(e.target as Node)) close()
        }
        document.addEventListener('keydown', onKey)
        document.addEventListener('mousedown', onDown)
        return () => {
            document.removeEventListener('keydown', onKey)
            document.removeEventListener('mousedown', onDown)
        }
    }, [ref, close])
}

/**
 * 顶栏右侧那两个圆按钮共用的形状。
 *
 * ★【为什么是这个形状,而不是一个图标】★(Tim 的裁定:两个下拉里【一个图标都不要】)
 * 委托书要求「a shape a person can read as "tools" without an icon set」。
 * 这里用的是:**一个圆、一圈描边、里面一个短标签**(工具是 "T" 的位置上放
 * 三个点的替代 —— 见 ToolsMenu 的说明)。圆形把它与左边那一串方角的模块按钮分开,
 * 描边把两个圆与背景分开,而【尺寸与头像一致】让它们读成"右边这一组"。
 */
export const ROUND_BUTTON_CLASS =
    'relative flex h-8 w-8 shrink-0 items-center justify-center rounded-full ' +
    'border border-[color:var(--brand-border)] text-[color:var(--brand-text)] ' +
    'hover:bg-[color:var(--brand-accent)]'
