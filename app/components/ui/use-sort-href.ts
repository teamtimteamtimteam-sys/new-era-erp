'use client'

// TABLE-FEATURES-1(Tim 2026-10-25 Q9)· 在数据库里排序的表,表头链接指向哪里
// 保留当前地址上的每一个筛选参数,换掉 `<prefix>sort` / `<prefix>dir`,并去掉翻页的位置(`page`、`after`)——
// 换了顺序之后「第 3 页」指的是另一批行,留着它会把人带到一个他没要过的位置。
// 一页上有两张在数据库里排的表时给 prefix(与 lib/listSort.ts 的 parseListSort 同一个 prefix)。

import { usePathname, useSearchParams } from 'next/navigation'

export function useSortHref(prefix = '', pageParam = 'page'): (key: string, dir: 'asc' | 'desc') => string {
    const pathname = usePathname()
    const sp = useSearchParams()
    return (key, dir) => {
        const p = new URLSearchParams(sp.toString())
        p.delete(pageParam)
        p.delete('after')
        p.set(`${prefix}sort`, key)
        p.set(`${prefix}dir`, dir)
        return `${pathname}?${p.toString()}`
    }
}
