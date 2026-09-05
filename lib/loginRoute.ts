// lib/loginRoute.ts
// ════════════════════════════════════════════════════════════════════════════
// LOGIN-1-fu1(2026-09-02)· 关于 /login 的两件事,各自【只定义一次】
//
// 这个文件存在的理由是:这两个判据此前【各有两份拷贝】,而它们都是安全判据。
//   · 「哪些路径不需要会话」—— 原本只在 lib/supabase/middleware.ts 里;
//     现在根布局也要用它(决定画不画顶栏),再抄一份就会有两份漂移的真相。
//   · 「?next= 收不收」—— 原本在 app/login/page.tsx 与 app/login/actions.ts 里
//     各写了一遍(注释还特地说明「两处逐字相同」)。**逐字相同要靠人守,
//     而这正是它迟早会不同的原因。** 现在中间件也要用它(登录着的人被送去哪儿),
//     第三份拷贝不该存在。
//
// 【这个文件必须保持极小】它被 middleware import,而中间件的包在【每一个请求】
// 上都要付账 —— 同一个文件的抬头为「两句话不值得拉进整个语言包」记过一次。
// 这里只有两个纯函数、零依赖。
// ════════════════════════════════════════════════════════════════════════════

/**
 * 【不需要会话就能看的路径】。**只有中间件用它放行。**
 *
 * ★★【FIX-1 item 1:它不再兼任"画不画外壳"那个判据 —— 那是两个问题】★★
 * 本文件原本让根布局也读这一个函数来决定外壳,而 FIX-1 的委托书顺着那条线
 * 写着「/set-password 用 /login 那套机制」。**照字面做,就是把 '/set-password'
 * 加进这个数组** —— 于是同一次改动顺手宣布【没有会话也能打开设密码页】。
 * 那不是复用,那是把一条安全判据改宽,而改宽的地方看起来只是排版。
 *
 * 所以两个问题各有一个名字:
 *   · `isPublicPath`      —— 可以【没有会话】。中间件放行用它。**只有 /login。**
 *   · `isBareChromePath`  —— 不画应用外壳。根布局用它。是前者的【超集】。
 * 一个路径可以"要会话、但不画外壳"(/set-password 正是),
 * 反过来"不要会话、却画外壳"没有意义 —— 所以后者必须包含前者,见下。
 */
export const PUBLIC_PATHS = ['/login'] as const

export function isPublicPath(pathname: string): boolean {
    return matches(PUBLIC_PATHS, pathname)
}

/**
 * 【不画应用外壳的路径】—— 顶栏、模块栏、面包屑、空闲监视器一个都不挂。
 *
 * 【为什么 /set-password 在这里】(FIX-1 item 1,2026-09-05,实测于线上第一批登录)
 * 一个还没换掉当面交出去的密码的人,中间件把他扣在这一页,而这一页此前画着整个
 * 应用外壳:模块栏还高亮着某一节(界面说他进来了,而他没有),通知铃带着未读数,
 * 「我的档案」「我的评估」「登出」都在,模块栏还逐条写着「销售 · 受限」——
 * **把这个账号缺哪些模块,告诉了一个还没完成设置的人。** 那一整条导航一个链接
 * 都点不动:中间件把每一条路由都弹回这一页。
 *
 * 【它与 PUBLIC_PATHS 的关系是【超集】,而这是用代码保证的,不是靠人记得】
 * 下面把 PUBLIC_PATHS 展开进来 —— 将来往公开清单里加一条(比如一个重置密码的
 * 落地页),它【自动】也不画外壳。反过来不成立,那正是本次拆分要防的方向。
 *
 * 【/welcome 【不】在这里 —— Tim 的裁定,不是漏了】那一页的人【已经】完成了设置:
 * 密码换过了、会话是好的,他只是还没有被授予任何模块。对他画一个诚实的空外壳
 * 是对的。模块栏上那些「· 受限」读起来怎么样,是 UI-1 那一刀的题目。
 */
export const BARE_CHROME_PATHS = [...PUBLIC_PATHS, '/set-password'] as const

export function isBareChromePath(pathname: string): boolean {
    return matches(BARE_CHROME_PATHS, pathname)
}

/** 两个判据【同一份】匹配规则:整条相等,或者是它下面的一层。 */
function matches(paths: readonly string[], pathname: string): boolean {
    return paths.some((p) => pathname === p || pathname.startsWith(p + '/'))
}

/**
 * 【只接内部路径】—— 收下 `?next=`,或者干脆不要。
 *
 * 判据是【白名单式】的:必须以单个 `/` 开头,而且第二个字符不能把它变成
 * 一个跳出本站的地址。不合格的一律返回 null —— **不修补、不猜、不退而求其次**,
 * 因为一个"尽量修好的重定向目标"正是开放重定向的经典成因。
 *
 * ★【这次补上了一个洞:反斜杠】★
 * 原来的判据是 `startsWith('/') && !startsWith('//')`。它漏掉了 `/\evil.com`:
 * **浏览器在解析 URL 时会把反斜杠当成斜杠**,于是那个串等价于 `//evil.com`,
 * 也就是一个协议相对的外站地址 —— 判据放行,浏览器跳出去。
 * 这一刀把这个判据【搬到了中间件里】(登录着的人按 next 送进应用),
 * 洞因此变得更好够得着,所以顺手堵上,而不是照抄一份带洞的。
 */
export function safeInternalPath(raw: unknown): string | null {
    if (typeof raw !== 'string') return null
    if (!raw.startsWith('/')) return null
    // `//host` 与 `/\host` 都是「跳出本站」
    if (raw.startsWith('//') || raw.startsWith('/\\')) return null
    return raw
}

/**
 * 【登录之后落在哪一页】—— 第三条判据,而它此前【也有两份拷贝】。
 *
 * ★【本文件抬头那句话,漏掉了这一条】★ 抬头写着「关于 /login 的两件事,各自只
 * 定义一次」,并且点名了另外两条判据此前各有两份。**而 '/suppliers' 当时就已经
 * 在两个地方写死着**,一份在 app/login/actions.ts(登录成功后送去哪儿),
 * 一份在 lib/supabase/middleware.ts(已经登录的人打开 /login 被送去哪儿)。
 * LOGIN-1-fu1 修了它看见的两条,没看见这一条 —— 一份"把重复收干净"的文件,
 * 自己身上还留着一处重复。UI-1a Step 6 把它收进来。
 *
 * ★【为什么从 /suppliers 改成 /me】(Tim 的裁定,UI-1a,2026-09-05)★
 * 【症状,线上实测】六个人登录之后【全部】落在采购模块的供应商列表上,
 * 而 **Fu Sheng 根本进不去采购** —— 他每天上班第一眼看见的是一张拒绝页。
 * 注意那个旧值甚至不是 /purchasing(模块落地页),是采购名下的【一条二级条目】。
 *
 * 【判据:落地页必须是【这个人】的,不是某一个部门的】
 *   · /me 【每一个账号都进得去】—— 它不看任何 module.* 权限(与 /my-reviews 同理,
 *     靠 current_user_employee() 限定到本人相关的行),所以它对六个人都成立,
 *     而不是对其中五个成立;
 *   · 它【今天就有内容】—— 假期、KPI 目标、档案。这是选它而不选首页的理由:
 *     **首页此刻近乎空白,而那上面唯一的东西是一个刻意不能用的搜索外壳**
 *     (app/page.tsx)。把六个人送到一张空页加一个死搜索框,比送去采购更糟。
 *   · 它满足「per-person, not one route for all」**不是靠分支,是靠选对了页**:
 *     一条对每个人都指向"他自己"的路由,天然是因人而异的。
 *
 * ★【这是【暂定】的,不是定局 —— 写在这里免得下一个人当成裁定】★
 * Tim 的原话:「Revisit once UI-1b gives home real content」。UI-1b 会给首页
 * 字标、问候语与节日机制;那之后首页可能才是对的落点。**改它的时候改这一个地方。**
 */
export const LANDING_PATH = '/me'

/** 登录成功、或已登录的人打开 /login 时,该去哪儿。`next` 优先,它兜底。 */
export function landingPath(next?: unknown): string {
    return safeInternalPath(next) ?? LANDING_PATH
}
