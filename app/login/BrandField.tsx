'use client'

// ════════════════════════════════════════════════════════════════════════════
// LOGIN-1 · 【底图 —— 一个可以整块换掉的层】(2026-09-02)
//
// ★★★ 换图只改下面那一个常量 PHOTO,别的一行都不用动。★★★
//
// 【底图是【品牌渐变】,而这是一个【已经做出的决定】,不是等照片回来的临时状态】
// (LOGIN-1-fu2,2026-09-02)
//
// ★★★ 不要「把照片补回来」把这一页「做完」—— 照片是【被否掉的】,不是【欠着的】。★★★
// fu1 曾经用过一张授权的森林与海航拍。Tim 看过真页面之后撤掉了它,两条理由:
//   ① **颜色打架** —— 照片压倒性地绿,而卡片与主按钮是 Hawaiian Ocean 蓝,
//      两个主色都不肯让步;
//   ② **它没有铺满** —— 上下露出浅色带(那是一个真的缺陷,根因写在 login.module.css
//      的 .layer 抬头:给过扫层写了 width/height,`right`/`bottom` 因此被忽略)。
// 加上渐变【更快】:照片实测桌面 +101 KB、手机 +52 KB,渐变 0 字节。
//
// 【可替换的那层结构留着】—— 它仍然有用:底图是什么,只由这一个文件决定。
// 但它现在的内容就是渐变,**后面没有一张待办的照片**。
//
// 【为什么整层是 client】视差要一个 pointermove 监听。除此之外这一层没有任何状态,
// 也不取任何数据 —— 它进客户端包的代价就是这几十行本身。
// ════════════════════════════════════════════════════════════════════════════

import { useEffect, useRef } from 'react'
import styles from './login.module.css'

/*
 * 【这里曾经有一个 PHOTO 常量】fu2 把它删了,而不是设成 null ——
 * 一个 `const PHOTO = null` 读起来像「等着被填」,而这正是本刀要排除的误解。
 * 底图现在由 login.module.css 里的 .wash / .glow / .veil 三层给,
 * 换底图 = 改那三条渐变,仍然只动这一处附近的东西。
 */

export default function BrandField() {
    const ref = useRef<HTMLDivElement>(null)

    useEffect(() => {
        const el = ref.current
        if (!el) return
        // .page 是写 --px/--py 的那个元素(field 的父节点)。
        const page = el.parentElement
        if (!page) return

        // 【两道闸,含义不同,都要】
        //   fine  —— 没有精确指针就【根本没有鼠标位置这回事】。手机上不是「视差很小」,
        //            是这个交互不存在;连监听都不该挂。
        //   calm  —— 人明说了要少动效。R7 的硬要求。
        const fine = window.matchMedia('(hover: hover) and (pointer: fine)')
        const calm = window.matchMedia('(prefers-reduced-motion: reduce)')

        let raf = 0
        const onMove = (e: PointerEvent) => {
            // 【节流:一帧最多算一次】pointermove 在高刷屏上一秒能来 120+ 次,
            // 而屏幕一帧只画一次 —— 多算的那些是纯浪费。
            if (raf) return
            raf = requestAnimationFrame(() => {
                raf = 0
                const x = (e.clientX / window.innerWidth - 0.5) * 2  // -1 … 1
                const y = (e.clientY / window.innerHeight - 0.5) * 2
                page.style.setProperty('--px', x.toFixed(3))
                page.style.setProperty('--py', y.toFixed(3))
            })
        }

        let attached = false
        const sync = () => {
            const want = fine.matches && !calm.matches
            if (want === attached) return
            if (want) {
                window.addEventListener('pointermove', onMove, { passive: true })
            } else {
                window.removeEventListener('pointermove', onMove)
                // 【停下来时要归零】否则会停在最后一次鼠标位置上 —— 那是一个
                // 「冻住的偏移」,比不动更奇怪。人中途打开减少动效,画面要回到正中。
                if (raf) { cancelAnimationFrame(raf); raf = 0 }
                page.style.setProperty('--px', '0')
                page.style.setProperty('--py', '0')
            }
            attached = want
        }

        sync()
        fine.addEventListener('change', sync)
        calm.addEventListener('change', sync)
        return () => {
            fine.removeEventListener('change', sync)
            calm.removeEventListener('change', sync)
            window.removeEventListener('pointermove', onMove)
            if (raf) cancelAnimationFrame(raf)
        }
    }, [])

    return (
        // aria-hidden:整层是装饰。读屏软件不该念一块底色。
        <div ref={ref} className={styles.field} aria-hidden="true">
            {/* 两层会动的渐变 + 一层不动的 veil。
                ★【不许给这两层写 width/height】★ 见 login.module.css 的 .layer 抬头:
                那正是 fu1 露出浅色带的原因。过扫靠 inset:-10% 给,盒子自己算。 */}
            <div className={`${styles.layer} ${styles.wash}`} />
            <div className={`${styles.layer} ${styles.glow}`} />
            {/* veil 【不带 .layer】—— 它不动,见 login.module.css 抬头那段 ★ */}
            <div className={styles.veil} />
        </div>
    )
}
