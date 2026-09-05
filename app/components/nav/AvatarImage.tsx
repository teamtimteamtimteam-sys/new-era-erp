'use client'

// app/components/nav/AvatarImage.tsx
// ════════════════════════════════════════════════════════════════════════════
// UI-1d ③:画头像 —— 而【一处缺席不读成一个答案】就是这个文件的全部内容
// ════════════════════════════════════════════════════════════════════════════
//
// 【它接住的那件事】头像的对象可能【不在】(没传过 / 刚被自己删掉 / 桶出了事 /
//   缓存里那一张已经失效)。这三种情况在网络上长得都一样:一个 404。
//   而委托书对这一刀写下的判据是:
//     **「a missing, corrupt or unreachable avatar object degrades to the initials
//       that are there today — never a broken image, never an empty circle.」**
//
// ★★【所以这里【不】在服务端去问"这个对象在不在"】★★
//   问一次要一趟往返,而顶栏画在【每一页、每一个人、每一次加载】上 ——
//   为一件装饰品在每次加载上加一趟请求,是本刀一开始就不肯付的那笔钱
//   (公开桶的理由与它是同一条)。改成:**地址照给,画不出来就回落。**
//   于是"对象不在"这件事根本不需要被【知道】,它只需要被【接住】。
//
// 【为什么首字母永远在 DOM 里,而图盖在它上面】
//   首字母是底,`<img>` 是一层盖在上面的东西,加载成功之前 opacity-0。
//   换成"先画图、错了再换首字母"的话,没有头像的人每一页都会先闪一下
//   破图图标再变成首字母 —— 而那正是委托书点名不要的「broken image」。
//   现在:没有头像的人【什么都不闪】,有头像的人图到了就淡入。
//
// 【为什么是 <img> 而不是 next/image】这张图已经是服务端产出的 256×256 WebP,
//   几 KB。再送进图片优化器只会换来一个 remotePatterns 配置、一层代理往返,
//   以及一个【会把 404 包成 500】的中间层 —— 而 404 正是这里要接住的东西。
//
// ★【首字母本身【一个字都没动】】★ 它是 UI-1a 的 initialsOf,连同"没有员工
//   档案就取邮箱首字母"那条刻意的处置一起(AvatarMenu.tsx)。本文件只收一个
//   已经算好的字符串。
import { useEffect, useRef, useState } from 'react'

type Props = {
    /** 公开桶里的地址。**null = 这个人此刻没有登录态可算地址**,直接画首字母。 */
    src: string | null
    /** UI-1a 的 initialsOf 算出来的那一两个字。 */
    initials: string
    /** 圆的直径,由调用方给(顶栏按钮 h-8 w-8;下拉身份行 h-10 w-10)。 */
    className: string
    /** 首字母的字号 —— 32px 的圆与 40px 的圆不该用同一个。 */
    initialsClassName: string
    alt: string
}

export default function AvatarImage({ src, initials, className, initialsClassName, alt }: Props) {
    // ★★【状态记的是【哪一个地址】失败/加载过,不是一个光秃秃的布尔】★★
    //
    // 【这不是洁癖,是一个实测出来的缺陷】第一版写的是 useState(false) 两个布尔。
    //   于是:一个还没有头像的人打开 /me → 图 404 → failed = true → <img> 摘掉。
    //   **他接着上传了一张。** server action 重画这一页,avatarUrl 换成带 ?v= 的
    //   新地址 —— 但组件【没有卸载】(同一个位置、同一个组件),failed 仍然是 true,
    //   于是**上传成功了,屏幕上却还是首字母**。而这是每个人的【第一次】上传,
    //   也就是说这个缺陷 100% 会被 100% 的人撞到。
    //
    //   探针一开始也看不见它:它在上传后【整页跳转】了一次,那会重新挂载组件。
    //   改成"不跳转,只等原地重画"之后才量得到(P2.rendered-in-place)。
    //
    //   把状态从"失败过吗"改成"哪个地址失败过",地址一变,判据自己就失效了 ——
    //   不需要任何人记得去重置它。
    const [failedSrc, setFailedSrc] = useState<string | null>(null)
    const [loadedSrc, setLoadedSrc] = useState<string | null>(null)
    const showImage = src !== null && failedSrc !== src
    const loaded = src !== null && loadedSrc === src
    const imgRef = useRef<HTMLImageElement | null>(null)

    // ════════════════════════════════════════════════════════════════════════
    // ★★【onError 一个人守不住这条回落 —— 这是【对着线上】跑才量出来的】★★
    // ════════════════════════════════════════════════════════════════════════
    //
    // 【那一幕】服务端把 HTML 连同 <img src=…> 一起送到,浏览器【立刻】开始取图。
    //   而 onError 是一个 React 事件处理器 —— 它要等 JS 包下载、解析、水合完
    //   才挂得上去。**图 404 得比水合快时,那个 error 事件没有人接**,
    //   而 React【不会补发】它。于是 failedSrc 永远是 null,<img> 永远留在
    //   DOM 里,屏幕上是一个【破图图标】—— 正是委托书点名不许出现的那一个。
    //
    // 【为什么本地看不见它】localhost + 热缓存,水合几乎总是赢。
    //   探针对着 https://new-era-erp.vercel.app 跑的那一轮当场变红
    //   (P1.fallback-initials,imgInDom=true),而同一支探针在本地是绿的。
    //   **真实的网络才是那个判据成立的条件**,而六个人用的正是真实的网络。
    //
    // 【处置:挂载时【自己问一遍】,不等事件】img.complete 为真而
    //   naturalWidth 为 0,就是"已经失败过了"。两个方向都补:
    //   已经失败 → failedSrc;已经加载好 → loadedSrc(否则它会停在 opacity-0)。
    useEffect(() => {
        const img = imgRef.current
        if (!img || src === null) return
        if (!img.complete) return
        if (img.naturalWidth === 0) setFailedSrc(src)
        else setLoadedSrc(src)
    }, [src])

    return (
        <span className={'relative block shrink-0 overflow-hidden rounded-full ' + className}>
            {/* 底:首字母。**它一直在这里** —— 图没到、图坏了、图 404,
                屏幕上都是它,而不是一个空圆或者一个破图图标。 */}
            <span
                aria-hidden
                className={
                    'absolute inset-0 flex items-center justify-center font-medium ' +
                    'text-[color:var(--brand-muted-glass)] ' +
                    initialsClassName
                }
            >
                {initials}
            </span>
            {showImage && (
                /* eslint-disable-next-line @next/next/no-img-element */
                <img
                    ref={imgRef}
                    src={src}
                    alt={alt}
                    data-nav="avatar-image"
                    width={256}
                    height={256}
                    decoding="async"
                    onLoad={() => setLoadedSrc(src)}
                    onError={() => setFailedSrc(src)}
                    className={
                        'absolute inset-0 h-full w-full object-cover transition-opacity duration-150 ' +
                        (loaded ? 'opacity-100' : 'opacity-0')
                    }
                />
            )}
        </span>
    )
}
