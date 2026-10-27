'use client'

// app/components/ui/hash-target.tsx
// SYSTEM-MAP-1(Tim Q2,2026-10-27):「submitted or rejected general claims → /finance/claims#claim-<id> (the row must actually
// scroll into view and be highlighted)」。
//
// 【为什么不是一句 CSS :target】Next 的软导航走 history.pushState,而 pushState【不更新】:target —— 从 /claims 点过来,
//   地址栏里有 #claim-…,样式表却认为没有目标。于是这里自己读 location.hash:挂载时一次(从别的页面点过来 = 一次新挂载),
//   以及 hashchange / popstate 时各一次。找到那个 id 就滚到视野中央、标亮,并写一个 data-hash-target 记号(探针读它)。
// 【只认一个前缀】页面说它的锚点长什么样(prefix),别的 # 不碰 —— 一个页面上的目录锚点不该被它抢走。
import * as React from 'react'

const HIGHLIGHT = ['bg-amber-100', 'ring-2', 'ring-inset', 'ring-amber-400']

export function HashTarget({ prefix }: { prefix: string }) {
    React.useEffect(() => {
        let cancelled = false
        let last: Element | null = null
        const apply = () => {
            const id = decodeURIComponent(window.location.hash.slice(1))
            if (last) { last.classList.remove(...HIGHLIGHT); last.removeAttribute('data-hash-target'); last = null }
            if (!id.startsWith(prefix)) return
            // 行由客户端表格渲染,第一帧可能还不在 —— 最多等 30 帧(约半秒),找不到就算了(不报错:那一笔可能已经不在这张表里)
            let tries = 0
            const find = () => {
                if (cancelled) return
                const el = document.getElementById(id)
                if (!el) { if (++tries < 30) requestAnimationFrame(find); return }
                el.classList.add(...HIGHLIGHT)
                el.setAttribute('data-hash-target', 'true')
                el.scrollIntoView({ block: 'center' })
                last = el
            }
            find()
        }
        apply()
        window.addEventListener('hashchange', apply)
        window.addEventListener('popstate', apply)
        return () => {
            cancelled = true
            window.removeEventListener('hashchange', apply)
            window.removeEventListener('popstate', apply)
        }
    }, [prefix])
    return null
}
