// lib/passwordPolicy.ts
// 初始密码的下限 —— 【一处定义】。
//
// 【为什么它不住在 accountActions.ts 里(那是它最初待的地方)】
//   那个文件是 'use server' 模块,而 Next.js 只允许 'use server' 文件导出
//   **async 函数**。导出一个 `export const MIN_PASSWORD_LENGTH = 8` 会让整个
//   构建失败:「Only async functions are allowed to be exported in a "use server" file」。
//   ★ 而 `tsc --noEmit` 【看不见这条】—— 它是 RSC 的规矩,不是类型的规矩。
//     实测顺序:tsc EXIT 0 → 探针把 /settings 全部读成 HTTP 500 → next build EXIT 1
//     才点名到行。**类型检查绿,不等于这个应用编译得过。**
//
// 【为什么两处必须读同一个数】建账号那一屏用它校验初始密码,
//   /set-password 用它校验本人自己设的新密码。两边不一致的话,
//   建得出来的密码可能在那一页改不回去 —— 而那个人会被中间件一直扣在那一页。
export const MIN_PASSWORD_LENGTH = 8
