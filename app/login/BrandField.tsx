'use client'

// ════════════════════════════════════════════════════════════════════════════
// LOGIN-1 · 【底图 —— 一个可以整块换掉的层】(2026-09-02)
//
// ★★★ 换图只改下面那一个常量 PHOTO,别的一行都不用动。★★★
//
// 【它现在是 Tim 的授权原件,不再是占位渐变】(LOGIN-1-fu1,2026-09-02)
// R3 因此【达成】,不再是「明写的未达成」。原件由 Tim 提供,落地前逐项确认过:
//   · 尺寸 2279×1279、625 KB、md5 与 landing page PDF 里那份【不同】;
//   · 底边逐像素看过:**没有 Shutterstock 水印条,也没有对角平铺水印** ——
//     那份 comp 的底边是一条深色条(IMAGE ID 1725657385),这一份是树冠。
//   · **PDF 里那份一个字节都没有被用过。**
//
// 处理只有【裁剪】一件事,并且它是测量驱动的 —— 见 docs/login-page.md §2:
// 裁到原图上 950 行,是为了把字标带整个落在天空上,并把海与林都留在遮罩【下面】。
// 【没有降对比、没有去饱和、没有模糊】:字标的 3:1 全部由 .veil 那一层给。
//
// 【为什么整层是 client】视差要一个 pointermove 监听。除此之外这一层没有任何状态,
// 也不取任何数据 —— 它进客户端包的代价就是这几十行本身。
// ════════════════════════════════════════════════════════════════════════════

import { useEffect, useRef } from 'react'
import styles from './login.module.css'

/**
 * 底图的来源。**换图仍然只改这一处。**
 *
 * 两档尺寸,用 media 显式指定,【不用 srcset+sizes】:这一层是 object-fit:cover
 * 的满幅底图,在竖屏手机上会被放大到视口高度的 2.4 倍宽 —— 浏览器按 `sizes`
 * 估出来的宽度和真正渲染的宽度差了一个数量级,选出来必然偏小。media 是确定的。
 *
 * 每次登录只会下载【其中一个】。实测字节数在 docs/login-page.md §10。
 */
const PHOTO = {
    small: { avif: '/brand/login-field-1280.avif', webp: '/brand/login-field-1280.webp' },
    large: { avif: '/brand/login-field-1920.avif', webp: '/brand/login-field-1920.webp' },
    /** 连 WebP 都不认的浏览器兜底到它 */
    fallback: '/brand/login-field-1280.webp',
} as const

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
            <picture>
                <source type="image/avif" media="(max-width: 900px)" srcSet={PHOTO.small.avif} />
                <source type="image/avif" srcSet={PHOTO.large.avif} />
                <source type="image/webp" media="(max-width: 900px)" srcSet={PHOTO.small.webp} />
                <source type="image/webp" srcSet={PHOTO.large.webp} />
                {/* 静态本地图,尺寸是离线烤好的定值;next/image 在这里只多一层 loader,
                    而且它不认 <picture> 的 media 分档。
                    (no-img-element 对 <picture> 里的 <img> 不报 —— 这正是它认可的写法。) */}
                <img
                    src={PHOTO.fallback}
                    alt=""
                    className={`${styles.layer} ${styles.photo}`}
                />
            </picture>
            {/* veil 【不带 .layer】—— 它不动,见 login.module.css 抬头那段 ★ */}
            <div className={styles.veil} />
        </div>
    )
}
