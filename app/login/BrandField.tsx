'use client'

// ════════════════════════════════════════════════════════════════════════════
// LOGIN-1 · 【底图 —— 一个可以整块换掉的层】(2026-09-02)
//
// ★★★ 换图只改下面那一个常量 PHOTO,别的一行都不用动。★★★
//
// 【今天它是渐变,不是照片 —— 这是【明写的未达成】,不是设计意图】
// R3 要的是「一张处理过的照片,字标压在上面」。本刀落地时仓库里【没有】那张照片:
// Tim 会另外提供授权原件(landing page PDF 里那一份被压缩过两次、且带预览水印,
// 不能用)。所以这里先画一块【同构的】渐变场 —— 同样的构图、同样的品牌蓝与绿、
// 同样的 veil 与视差 —— 好让照片到位那天是【换一个常量】,不是重做一页。
// **不要把这块渐变读成最终设计。** 见 docs/login-page.md §2。
//
// 【为什么整层是 client】视差要一个 pointermove 监听。除此之外这一层没有任何状态,
// 也不取任何数据 —— 它进客户端包的代价就是这几十行本身。
// ════════════════════════════════════════════════════════════════════════════

import { useEffect, useRef } from 'react'
import styles from './login.module.css'

/**
 * ★ 授权照片到位后:把 null 换成 { src, ... }。
 *
 * 【怎么准备那个文件】用 sharp 离线烤好再放进 public/brand/,**不要**丢原图进来:
 * LOGIN-1 实测过,把对比度压下去之后 JPEG 的熵也跟着塌了 —— 1280px 宽的处理版
 * 是 2–5 KB(AVIF),而同尺寸的未处理版是 186 KB。**处理这一步是省流量的,不是费流量的。**
 * 具体参数与实测数字在 docs/login-page.md §2。
 *
 * .photo 上那条 CSS filter 是兜底,不是替代:就算有人直接把未处理的原图丢进来,
 * veil 加 filter 也能保住对比度地板 —— 但文件还是 186 KB,而那是每一次登录都要付的。
 */
const PHOTO: { src: string; alt: '' } | null = null

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
            {PHOTO ? (
                // 静态本地图:next/image 在这里只多一层 loader,而这张图是
                // 离线烤好的定尺寸文件(见 docs/login-page.md §2)。
                // eslint-disable-next-line @next/next/no-img-element
                <img src={PHOTO.src} alt="" className={`${styles.layer} ${styles.photo}`} style={{ ['--d' as string]: '14px' }} />
            ) : (
                <div className={`${styles.layer} ${styles.wash}`} />
            )}
            <div className={`${styles.layer} ${styles.glow}`} />
            {/* veil 【不带 .layer】—— 它不动,见 login.module.css 抬头那段 ★ */}
            <div className={styles.veil} />
        </div>
    )
}
