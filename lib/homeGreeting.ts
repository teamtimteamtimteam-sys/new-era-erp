// lib/homeGreeting.ts
// ════════════════════════════════════════════════════════════════════════════
// UI-1b(2026-09-05)· 首页那一行问候语 —— 时段、选句、不重样
// ════════════════════════════════════════════════════════════════════════════
//
// Tim 给这一行写下的目的只有五个字:**给首页增加一些温度。**
// 所以它是【暖】不是【指令】—— 它不催人干活,也不报告任何状态。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【一、时钟:说"早上"就必须是【读的人】的早上】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 一行写着「Good morning」的字,在一台 TZ=UTC 的服务器上会在新加坡的下午四点
// 出现。**这与 CONV-7 ② 那次是同一个病**:那次是 `toISOString().slice(0,10)`
// 把 UTC 的今天当成了业务日期,于是新加坡每天 00:00–08:00 之间,财务 Overview
// 有两条腿画成「答不上来」——(见 lib/format.ts:67 那一整段)。
//
// **所以时区【显式传进来】,不读进程的 TZ。** 唯一的来源是同一个常量
// `BUSINESS_TIMEZONE`(lib/format.ts:65),节日窗口读的也是它派生的
// `businessToday()` —— **一个时钟服务两处**,不是两处各挑一个。
//
// ★【它是怎么被证明的,而不是被相信的】★ `slotFor()` 是一个【纯函数】,
//   两个入参都显式:一个瞬间、一个时区。于是它可以在【三个不同的进程 TZ 下】
//   跑同一句断言 —— scripts/assert-home-greeting.mjs 用 TZ=UTC、
//   TZ=America/Los_Angeles、TZ=Asia/Singapore 各跑一遍,断言
//   2026-09-06T15:00:00Z(= 新加坡 23:00)在三处都落到 LATE NIGHT。
//   **把 tz 参数换成系统默认,那支断言当场变红** —— 注伤验过。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【二、句子存在【库】里,不在 messages/*.ts 里】★★
// ════════════════════════════════════════════════════════════════════════════
//
// Tim 的判据:**改一句话不该需要一次部署。** messages/en.ts 有 7,393 行,
// 是编译进包里的;改它一个字就是一次构建 + 一次部署。所以 72 句住在
// `home_greetings` 表里,与 `public_holidays`、`kpi_score_rubric` 同一条先例。
//
// ★★【它只有英文,而这是【裁定】,不是漏了】★★
// **一个 zh 语言的读者会看到英文问候语 —— 那就是预期状态。**
// 先例在 `kpi_score_rubric`:`band_en`/`band_zh` 成对,而
// `evidence_standard_en` / `management_action_en` / `veto_rule_en` /
// `review_cadence_en` **只有英文**,因为原始文档就是英文的。
//
// > **★ 不许"顺手把它翻译了"。★** 也不许加一个空的 `line_zh` 列"留着以后填"——
// > Tim 的原话:**一个空列是一句 schema 替没人许下的承诺。**
// > 真要加中文,那是一次带着 72 句译文的裁定,不是一次列变更。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【三、名字从哪儿来 —— 而"推导不出来"这句话只对一个人成立】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 委托书写的是「THE NAME IS NOT DERIVABLE FROM THE EMPLOYEE RECORD」。
// **实测(线上,六个账号):六个里有五个推导得出来。**
//
//   legal_name          preferred_name   Tim 要的      推导得出?
//   Tim                 (null)           Tim           ✓ legal_name
//   Vince Goh           Vince            Vince         ✓
//   Sandra Yap          Sandra           **Sand**      ✗ ← 只有这一个
//   Cheng Siong Phua    Phua             Phua          ✓
//   Choo Er Teh         **Chooer**       Choo Er       ✗ 但那是个【错字】
//   Fu Sheng Wong       Fu Sheng         Fu Sheng      ✓
//
// 于是处置分成两件【不同】的事,而把它们混成一件会弄脏别处:
//   ① `employees.greeting_name`(可空)+ 取值顺序
//      **greeting_name ?? preferred_name ?? legal_name**。只种【一行】:Sandra → Sand。
//   ② Choo Er 的 `preferred_name` 从 `Chooer` 改成 `Choo Er` —— 那是一处
//      **数据录入错误**,与本刀无关也仍然是错的,而它在 ActorName、TopNav、
//      /me、组织架构图上到处都印着。修好它,她的问候语顺带就对了。
//
// ★【为什么不直接把 preferred_name 改成 "Sand" 就完事】★
//   `preferred_name` 是【全站显示名】(app/components/ActorName.tsx:79、
//   app/components/TopNav.tsx:161、app/me/page.tsx:202、app/hr/org/page.tsx:90)。
//   把它改成 "Sand",组织架构图与每一条审计留痕上她就都叫 Sand 了。
//   **一句问候语的昵称,不该改写一个人在系统里的名字。**
//
// ★【没有员工档案的账号:整行【不画】】★ 与 UI-1a 的 AvatarMenu.tsx:47-56 同一条:
//   一个还没建档的新人,名字是【还没有】,不是"User"、不是他的邮箱。
//   **一句「Good morning, admin@…」比没有问候语更冷。** 所以缺席就是缺席。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【四、每次都重挑,而且不许与上一句相同】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 一个时段十二句,若整个上午都定在同一句上,那与只有一句没有区别。
// 所以每次渲染重挑,并且**排除上一次那一句**。
//
// ★★【上一句记在【cookie】里,而 httpOnly 那半条【做不到】—— 照直说】★★
//   委托书写的是「an httpOnly COOKIE」。**在 Next 16 里,一个服务端组件
//   set 不了 cookie** —— `node_modules/next/dist/docs/01-app/03-api-reference/
//   04-functions/cookies.md:73` 逐字写着:「HTTP does not allow setting cookies
//   after streaming starts, so you must use `.set` in a Server Function or
//   Route Handler.」首页是一次普通的 GET 渲染,两者都不是。
//
//   **能设 httpOnly 的只剩中间件,而那条路要中间件自己【挑这一句】** ——
//   它得知道这个时段有几句、上一句是哪一句,也就是要在【每一个请求】上查一次库。
//   `lib/loginRoute.ts` 的抬头为这件事记过账:「它被 middleware import,而中间件
//   的包在【每一个请求】上都要付账」。**为一行问候语给全站每个请求加一次查询,
//   这笔买卖不划算。**
//
//   所以落地的是:**服务端读 cookie 决定排除谁,客户端一个 8 行的组件把新的那句
//   写回 cookie**(`document.cookie`,因此【不是】 httpOnly)。
//   ★ 而 httpOnly 在这里【本来也买不到东西】★:cookie 里存的是一句问候语的 id,
//   不是凭据、不是身份、也推不出任何别的东西。httpOnly 防的是 XSS 读取,
//   而这里没有值得读的东西。**这是一处偏离,写在这里而不是藏在实现里。**
//
//   【cookie 不在时会怎样】—— 退化成"可能重样一次",**永远不会退化成一片空白**。
//   这正是 FIX-2a 那条「一次缺席不许被渲染成一个答案」的正面写法:
//   排除项拿不到,就不排除,句子照出。
import { cookies } from 'next/headers'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { BUSINESS_TIMEZONE } from '@/lib/format'
// 【纯核住在隔壁,理由在 lib/homeGreetingCore.ts 抬头:它零 import,所以断言得了】
import { slotFor, pickGreeting, GREETING_COOKIE, type GreetingLine } from '@/lib/homeGreetingCore'

// 【转出,不是抄一份】调用方(app/components/home/RememberGreeting.tsx)只需要
// 认识一个模块;而定义仍然只有一处。
export { GREETING_SLOTS, GREETING_COOKIE, slotFor, pickGreeting } from '@/lib/homeGreetingCore'
export type { GreetingSlot, GreetingLine } from '@/lib/homeGreetingCore'


export type Greeting = { id: string; text: string } | null

/**
 * 【首页那一行】。**拿不到就返回 null,调用方整行不画。**
 *
 * 它读三样东西:这个人的问候名(my_profile)、当前时段的句子(home_greetings)、
 * 上一句的 id(cookie)。**任何一样缺席,结果都是"不画",不是"画一句坏的"。**
 */
export async function getHomeGreeting(now: Date = new Date()): Promise<Greeting> {
    const supabase = await createClient()

    // ── 名字 ────────────────────────────────────────────────────────────────
    // my_profile 是【这个人自己那一行】(current_user_employee() 限定),
    // 没有员工档案的账号在这里就是 0 行 —— 那不是错误,是一个合法的答案。
    const profiles = mustRows(
        await supabase.from('my_profile').select('greeting_name, preferred_name, legal_name').limit(1),
        'my_profile:greeting'
    ) as { greeting_name: string | null; preferred_name: string | null; legal_name: string | null }[]
    const p = profiles[0]
    const name = (p?.greeting_name || p?.preferred_name || p?.legal_name || '').trim()
    // ★ 没有档案 → 整行不画。不编占位名,不拿邮箱顶上(见抬头【三】)。
    if (!name) return null

    // ── 句子 ────────────────────────────────────────────────────────────────
    const slot = slotFor(now, BUSINESS_TIMEZONE)
    const lines = mustRows(
        await supabase
            .from('home_greetings')
            .select('id, line_en')
            .eq('slot', slot)
            .eq('is_active', true)
            .order('id'),
        'home_greetings'
    ) as GreetingLine[]

    const store = await cookies()
    const prevId = store.get(GREETING_COOKIE)?.value ?? null
    const picked = pickGreeting(lines, prevId, Math.random())
    if (!picked) return null

    return { id: picked.id, text: picked.line_en.replaceAll('{name}', name) }
}
