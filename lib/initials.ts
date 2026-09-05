// lib/initials.ts
// ════════════════════════════════════════════════════════════════════════════
// 头像里印哪一两个字 —— UI-1a 的判据,**一个字都没改,只是搬了家**
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么搬】UI-1d 给 /me 加了换头像的那一段,而那一段的预览要回落到
//   【同一组首字母】。函数原本住在 app/components/nav/AvatarMenu.tsx 里,
//   那是一个 'use client' 模块 —— 服务端组件从那里 import 拿到的是一个
//   客户端引用,在服务端调不动。抄第二份是这棵树最不肯付的那种账
//   (scripts/check-near-duplicate.mjs 就是为它建的),所以搬,不抄。
//
// ★【搬家 ≠ 改判据】★ 函数体与下面这段抬头逐字来自 AvatarMenu.tsx,
//   包括"没有员工档案就取邮箱首字母"那条【刻意的】处置。UI-1d 的委托书
//   点名了这一条:「Do not change the initials logic. It is UI-1a's and it
//   handles the no-employee-record case deliberately.」

/**
 * 【头像里印什么】(Tim 的裁定,UI-1a Q7)
 *   有名字 → 取首字母,最多两个(「Sandra Yap」→「SY」)。
 *   没名字 → **邮箱的第一个字符**,并且菜单里【不画名字那一行】,只画邮箱。
 *
 * ★【为什么不能编一个占位名】★ 一个还没被 HR 建档的新人,账号是真的、邮箱是真的,
 *   名字是【还没有】。印「User」或者「—」就是把一处缺席画成一个答案 ——
 *   而"这个账号还没连上员工档案"是一件他应该看得出来的事。省掉那一行,
 *   剩下的邮箱就是他此刻【真实】的身份。
 */
export function initialsOf(name: string | null, email: string): string {
    if (name) {
        const parts = name.trim().split(/\s+/).filter(Boolean)
        if (parts.length > 0) {
            return parts.slice(0, 2).map((w) => [...w][0]).join('').toUpperCase()
        }
    }
    return ([...email][0] ?? '?').toUpperCase()
}

