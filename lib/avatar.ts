// lib/avatar.ts
// ════════════════════════════════════════════════════════════════════════════
// UI-1d:头像的那几个数,收在【一处】
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么是一个文件而不是两处常量】写入的一侧(app/me/avatarActions.ts)与
//   读出的一侧(app/components/TopNav.tsx)必须对同一件事说同一句话:桶叫什么、
//   对象叫什么、缓存多久。这三样各写一份的话,改其中一处而另一处没改时,
//   屏幕上【看不出来】—— 读的一侧会去取一个写的一侧根本没写过的地址,
//   而那个地址 404,于是回落成首字母:**一处错配长得和"这个人没传过头像"
//   一模一样。** 那正是本仓库反复说的「一处缺席不该读成一个答案」。
//
// 【★ 这里【没有】任何数据库列 ★】(Tim 的裁定,UI-1d Q4)
//   对象【存在与否】就是状态本身,不另存一份指针:
//     · 一张 user_id → avatar_updated_at 的表是第二份真源,两份必然漂开;
//     · 而漂开的那一刻,屏幕上仍然只是"回落成首字母"。
//   代价是【没有版本号可用】,于是缓存靠下面那两样东西撑(见 AVATAR_CACHE_SECONDS)。

/**
 * 桶名。【一个桶一件事】—— 与 company-assets / so-documents / po-documents 同一个习惯。
 *
 * ★★【这是个 PUBLIC 桶,而那件事有后果 —— 写在这里,不只写在迁移里】★★
 *   任何人【猜中一个 user_id】就能不登录取到那个人的脸,而地址本身也把
 *   auth uid 说了出去。收下这两件事的理由:头像不含机密,而私有桶会给
 *   【每一次页面加载】加一趟签名 URL 往返 —— 为一件装饰品付这个。
 *   完整的权衡与被否掉的替代方案写在迁移文件里(Tim 的裁定,UI-1d Q8),
 *   好让将来人更多的那一刀重开这个决定时,知道自己在重开什么。
 */
export const AVATAR_BUCKET = 'avatars'

/** 接受的上限。与 company logo 的 MAX_LOGO_BYTES 逐字节相同 —— 同一类东西同一个数。 */
export const AVATAR_MAX_BYTES = 2 * 1024 * 1024

/** 接受的三种。webp 比 logo 那一处多一个:这里的出口本来就是 webp。 */
export const AVATAR_ALLOWED_MIME: readonly string[] = ['image/png', 'image/jpeg', 'image/webp']

/**
 * ★【输入的像素上限 —— 它挡的不是大小,是解码本身】★
 *   2MB 的闸挡不住压缩炸弹:实测一张 9000×9000 的纯色 PNG 只有 231KB,
 *   过得了大小闸,而解码它要 81 兆像素的内存。sharp 的 metadata() 【只读文件头,
 *   不解码像素】—— 所以这一条闸落在攻击面【打开之前】。
 *   8000 收得下任何一台相机直出的竖幅(实测 8000×8000 = 64MP > 目前市面最大的单张)。
 */
export const AVATAR_MAX_INPUT_DIMENSION = 8000

/** 同一个数交给 sharp 自己再兜一层:两条闸算的是同一件事,而第二条在库里。 */
export const AVATAR_LIMIT_INPUT_PIXELS =
    AVATAR_MAX_INPUT_DIMENSION * AVATAR_MAX_INPUT_DIMENSION

/**
 * 出图的边长。
 *
 * 【为什么是 256 而不是 128】顶栏那个按钮是 h-8 w-8 = 32 CSS px
 * (ROUND_BUTTON_CLASS,MenuPanel.tsx),下拉身份行画到 40px。
 * 128 在今天【够】—— DPR 3 的手机上 32px 要 96 个物理像素。
 * 但"今天刚好够"意味着下一次有人把头像画大一点就得重新编码所有人的图,
 * 而那时旧图已经在桶里了。256 把顶栏撑到 DPR 8,把身份行撑到 DPR 6,
 * 实测代价是【几 KB】(一张纯色 256×256 q82 = 188 字节)。
 */
export const AVATAR_EDGE_PX = 256

/** WebP 质量。82 是 sharp 的常用甜点,实测 256×256 的照片在 3–6KB。 */
export const AVATAR_WEBP_QUALITY = 82

/**
 * ★★【缓存:60 秒,而不是 Supabase 默认的 3600】★★(Tim 的裁定,UI-1d Q4)
 *
 * 地址是【固定的】(avatars/<uid>.webp),所以换头像会落在同一个 URL 上。
 * 没有版本列可用(见文件抬头),于是陈旧期靠 max-age 自己封顶:
 *   · 默认 3600 → 换了头像的人,别人最长一小时看的还是旧的那张;
 *   · 60 → 封顶一分钟,而重新验证是一个 304(对象只有几 KB)。
 * 【换头像的本人】不等这 60 秒 —— 那由下面的 cookie 解决。
 */
export const AVATAR_CACHE_SECONDS = 60

/**
 * ★【本人立刻看见新图,靠的是一个会自己过期的 cookie】★
 *
 * 上传/移除成功时写下一个时间戳,TopNav 读它并挂成 `?v=<ts>`,于是【这个浏览器】
 * 下一次取的是一个没被缓存过的地址。它【不是】一份状态:
 *   · 只活 120 秒(> 60 的 max-age),过期之后所有人自然收敛到同一个规范地址;
 *   · 丢了也只是"最多等 60 秒",不会把任何东西画错。
 * 移除头像时它同样有用:不刷新的话,浏览器还会拿缓存里那张已经被删掉的图。
 */
export const AVATAR_VERSION_COOKIE = 'avatar_v'
export const AVATAR_VERSION_COOKIE_MAX_AGE = 120

/**
 * 对象名。**桶里是平的**:avatars/<uid>.webp 里的 `avatars` 是桶,不是文件夹。
 *
 * ★【策略比的是这个字符串的【全等】,不是前缀】★(Tim 的裁定,UI-1d Q2 —— 委托书原文
 *   写的是 "starts with",被推翻)。前缀判据会把 <uid>-evil.webp、<uid>.html、
 *   <uid>/任意路径 一并放进一个【全世界可读】的桶,而它们没有任何读者、
 *   也没有任何东西会去清。全等判据没有这个尾巴,而且不更难写。
 *   判据本身在迁移里:name = auth.uid()::text || '.webp'。
 */
export function avatarObjectName(userId: string): string {
    return `${userId}.webp`
}
