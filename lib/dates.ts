// lib/dates.ts
// ════════════════════════════════════════════════════════════════════════════
// DATE-1(2026-09-20)· 这套系统里【唯一】一份日期显示格式化
// ════════════════════════════════════════════════════════════════════════════
// 【为什么它在 DATE-1 才出现】DATE-0 的勘察把这件事量清楚了:在这一刀之前,
// 树里**一份日期格式化函数都没有** —— 没有 `lib/dates.ts`,`package.json` 里
// 没有任何日期库,`formatDate` 是**五份逐字节相同的复制**(全在 CSV 导出路由里)
// 外加 `app/me/page.tsx` 里一份 `fmtDate`。而屏幕上最常见的日期长相是
// **一个字节都没格式化的库原值**。
//
// ☞ 所以这一份不是在【调和两份实现】,是在【从零立一份】——
//   本仓库为前者付过四次账(见 AGENTS.md 的预览规则那一节),这一次没有那笔账。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★★【Tim 的四条裁定,逐条写在这里,因为下一刀会来这里读它们】★★★
// ════════════════════════════════════════════════════════════════════════════
//
// ── D4 · 两种语言,两种写法 ─────────────────────────────────────────────────
//   英文  `01 Sep 2026`     —— 日、月名、年。日【补零】(Tim 的原话就是 `01`)。
//   中文  `2026年9月1日`    —— ★ **不补零**。Tim 明确裁的是这一个写法,
//                              不是 `2026年09月01日`。
//   理由是 Tim 的常设规矩:**界面是哪一种语言,就说哪一种语言的话**
//   (AGENTS.md「双语的列要【选一个】,不是拼起来」同源)。
//
// ── D2 · 单据日期 vs 审计戳,而【边界是一条规则,不是一张名单】────────────
//   **单据日期**(这份单据说自己是哪一天的:`order_date`、`issue_date`、
//   `arrival_date`、`due_date`、`expense_date` …)→ 走 formatDate / formatDateTime。
//
//   ★ **审计戳**(`created_at`、`deleted_at`、`posted_at` 那一族)
//     → 走 formatAuditStamp,**永远是 `YYYY-MM-DD HH:MM`,与界面语言无关**。
//
//   ☞ **判据(一句话,可以套在一个我从来没见过的列上):**
//     **这一列记的是【系统在哪一刻收到了这个动作】,还是【这份单据自己说它是哪一天的】?**
//     · 前者是审计戳 —— 它的读者是【查账的人和机器】,而 `YYYY-MM-DD HH:MM`
//       可排序、可复制、可粘回一条查询里。
//     · 后者是单据日期 —— 它的读者是【看单据的人】。
//   ☞ 机械形状(给扫描器用,**它是判据的【推论】,不是判据本身**):
//     列名是 `<动作的过去分词>_at`。`*_date` / `*_on` / `period_month` 一律是单据侧。
//   ⚠ 两者撞车时**以那句判据为准**,不以形状为准 —— AGENTS.md 记过一次
//     「按推论去套,遇到形状对不上的就会套错」(CLEANUP-A 那条 `RETURNS void`)。
//
// ── D3 · ★★ CSV 导出【不走这里】,而这条理由写在这里是为了不被重开 ★★ ──────
//
//   > **Excel 把 `2026-09-01` 认成【日期】(可排序、可算差);
//   > 把 `01 Sep 2026` 认成【一串文字】,而文字是按字母排的:Apr < Aug < Dec …**
//   >
//   > **导出的用途是【再算一次】,不是【读】。屏幕跟人走,导出跟机器走。**
//
//   ☞ 这不是一处疏漏,也不是"还没改到" —— 它是一条**裁定**(Tim,D3)。
//     同一句话另抄了一份在 `lib/csv.ts` 与那五条导出路由旁边,
//     因为**下一个人是在那里读到它的**,不是在这里。
//   ☞ 于是本文件导出 `formatCsvTimestamp()`:它是那五份复制合并成的**一份**,
//     **逐字节吐与从前相同的 `YYYY-MM-DD HH:MM`**。合并是为了只剩一份,
//     **不是为了顺手把它改好看**。
//
// ════════════════════════════════════════════════════════════════════════════
// 【三条实现上的决定,各自带着理由】
//
// ① ★ **`locale` 是一个 `string` 入参,本文件【不 import 任何东西】。**
//    理由是可验证性:`scripts/check-date-data-paths.mjs` 的四条断言
//    **真的把这个文件 import 进去跑一遍**(Node 的 TS type-stripping)。
//    只要这里 import 了 `lib/i18n/config`,那条 import 会连着整本文案目录一起来,
//    而一条跑不起来的断言等于没有断言。
//    ☞ 入参写成 `string` 而不是 `Locale`,换来的是**这四条断言跑得起来**。
//
// ② ★★ **一个 `YYYY-MM-DD` 的 `date` 列,在这里【一次 Date 都不构造】。**
//    `new Date('2026-09-01')` 按 UTC 午夜解析;再按某个时区渲染出来,
//    **在负时差的时区上会差一天**。业务时区是 +08,今天不会踩到 ——
//    **而"今天不会踩到"不是一个理由**(AGENTS.md:FIN-20 那次整个项目周期
//    都在用开发机的时区,没有人看)。所以 `date` 那一族**按字符串切**,
//    日期算术一个字都不参与,于是这一类错误【按构造】不存在。
//    ☞ 只有 `timestamptz`(要印时分的那一族)才构造 Date,而它**必须**带上
//      业务时区 —— 与 `lib/format.ts` 的 `BUSINESS_TIMEZONE` 是同一条决定的两半。
//
// ③ ★ **`toYmd()` 与显示那一族【住在同一个文件里,而且它们是两种东西】。**
//    §5.2 点名了四条会把「显示格式」当成「数据格式」读回去的路,
//    其中三条**失败是安静的**。把两者放在一起,是为了让下一个人在
//    伸手拿格式化函数的那一刻,就看见旁边那句「喂给控件的要用 toYmd」。
// ════════════════════════════════════════════════════════════════════════════

// ════════════════════════════════════════════════════════════════════════════
// ★★★【伸手拿这几支函数之前,先读这一段 —— 它是本刀差点带上线的那个缺陷】★★★
// ════════════════════════════════════════════════════════════════════════════
// 下面的 formatDate / formatDateTime / formatMonth / formatAuditStamp
// 对 `null` 返回 **`'—'`** —— 屏幕上要的正是这个。
// ★ 而 `'—'` 是一个**真值**。于是:
//
// > ### **把一个【可能是 null 的】日期【投影】成显示串,会把那个 null 消灭掉。**
//
// 实测的后果(DATE-1 自己的改动造出来的,被 `--mode=drift` 的一个荒谬读数抓到):
//   `inServiceDate: formatDate(a.in_service_date, locale)`
//   → `AssetActions` 里那句 `inServiceDate ? <已投用的拦阻信息> : …` 当场翻边,
//     ★ **「这台设备已经投用」的拦阻信息对【没有投用】的设备也显示了**;
//     (那条消息的键是 assets.blocked.alreadyInService。
//      ⚠ **这段注释刻意【不】把它写成一句翻译函数调用的样子** ——
//      `check-i18n` 会把注释里那种写法当成一个真的调用点去校验,
//      而本刀第一版就是这么把构建弄红了两次:第一次少了 {date} 实参,
//      第二次省略号被当成了键名。
//      ☞ 这是 AGENTS.md「一句注释可以污染将来对它自己的计数」的第四次,
//        而这一次它污染的**不是计数,是一道闸**。)
//   → `useState(plannedInServiceDate ?? '')` 拿到 `'—'`,而它喂的是一颗
//     `<input type="date">` —— ★★ 规范说值不合法就**当空值处理,不报错**。
//
// ☞ **判据是本仓库 CLEANUP-A 那一条:「这个值的 `null` 是不是【已经有主】了?」**
//   有主 = `null` 在表达一个**合法状态**(「还没投用」),而且**有人在读它**。
//
// **规矩:**
//   · **投影 / 传给组件当 prop**(下游会拿它去判断)→ **必须保 null**:
//         X: v ? formatDate(v, locale) : null
//     消费端类型非空时(作者已用 `as string` 断言过值一定在)用 `'—'`。
//   · **直接印在 JSX 里** → 不必保;那里 `'—'` 正是要的。
//
// ☞ 这条规矩有一道闸:`scripts/check-date-null-preserved.mjs`(在 `npm run build` 里,
//   ~2s,问 TypeScript 的类型检查器)。它**做过故障注入**:把上面那一处缺陷
//   原样装回去,它点名了文件与行。
//   ⚠ 而它够不着的那一半也写在它抬头上:**一句 `as string` 能让它闭嘴。**
// ════════════════════════════════════════════════════════════════════════════

/** 业务时区 —— 与 `lib/format.ts` 的 BUSINESS_TIMEZONE 同源。两处必须同改。 */
const BUSINESS_TIMEZONE = 'Asia/Singapore'

/** 空值统一印 `—`,与 `lib/format.ts` 的 formatAmount 同约定。 */
const EMPTY = '—'

const EN_MONTHS = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
] as const

function isZh(locale: string): boolean {
    return locale === 'zh' || locale.startsWith('zh-')
}

/**
 * 把任意一个日期值拆成业务时区的 { y, m, d, hh, mm }。
 *
 * ★ 两条路,而分岔的判据是【它带不带时刻】:
 *   · `2026-09-01` / `2026-09-01T…` 开头的 → **按字符串切**,不构造 Date(见决定 ②)。
 *     这一族的年月日是【库里那一行写的那一天】,没有任何时区能改变它。
 *   · 其余(Date 对象、别的写法的时间戳)→ 构造 Date 并按业务时区取分量。
 */
function parts(value: string | Date): { y: number; m: number; d: number; hh: string; mm: string } | null {
    if (value instanceof Date) {
        if (Number.isNaN(value.getTime())) return null
        return fromDate(value)
    }
    const s = String(value)
    const lex = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/.exec(s)
    if (lex) {
        // ★ 带时刻的那一支仍然要走时区:一个 `timestamptz` 的 UTC 表示,
        //   在业务时区里可能是**另一天**。只有【不带时刻】的才是纯日期。
        if (lex[4] !== undefined && /[Zz]|[+-]\d{2}:?\d{2}$/.test(s)) {
            const dt = new Date(s)
            return Number.isNaN(dt.getTime()) ? null : fromDate(dt)
        }
        return {
            y: Number(lex[1]), m: Number(lex[2]), d: Number(lex[3]),
            hh: lex[4] ?? '00', mm: lex[5] ?? '00',
        }
    }
    const dt = new Date(s)
    return Number.isNaN(dt.getTime()) ? null : fromDate(dt)
}

function fromDate(dt: Date) {
    // en-CA 给的正是 YYYY-MM-DD,不用自己拼 —— 与 lib/format.ts 的 businessToday 同一个手法。
    const f = new Intl.DateTimeFormat('en-CA', {
        timeZone: BUSINESS_TIMEZONE,
        year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', hour12: false,
    }).formatToParts(dt)
    const g = (t: string) => f.find((p) => p.type === t)?.value ?? '00'
    return {
        y: Number(g('year')), m: Number(g('month')), d: Number(g('day')),
        // hourCycle h23 下 24 点要读成 00 —— 不处理的话午夜会印成 `24:00`。
        hh: g('hour') === '24' ? '00' : g('hour'),
        mm: g('minute'),
    }
}

// ════════════════════════════════════════════════════════════════════════════
// ── 显示那一族(D2 的【单据日期】侧 · D4 的两种写法)────────────────────────
// ════════════════════════════════════════════════════════════════════════════

/**
 * 单据日期 → `01 Sep 2026`(en)/ `2026年9月1日`(zh)。
 *
 * ⚠ **这个函数的输出【永远不要】喂回给机器** —— 不要喂 `<input type="date">`
 *   的 value/min/max、不要放进 URL 的日期过滤、不要塞进 FormData。
 *   那四条路各自要的是 `toYmd()`,而其中三条失败时**一声不吭**。
 *   ☞ `scripts/check-date-data-paths.mjs` 就是为这四条路写的,它会变红。
 */
export function formatDate(value: string | Date | null | undefined, locale: string): string {
    if (value === null || value === undefined || value === '') return EMPTY
    const p = parts(value)
    if (!p) return String(value)          // 解析不了就把原值交出去,不要编一个日期
    return isZh(locale)
        // ★ D4:中文【不补零】—— Tim 裁的是 `2026年9月1日`。
        ? `${p.y}年${p.m}月${p.d}日`
        // ★ D4:英文的【日】补零 —— Tim 的原话就是 `01 Sep 2026`。
        : `${String(p.d).padStart(2, '0')} ${EN_MONTHS[p.m - 1]} ${p.y}`
}

/**
 * 带时刻的单据日期 → `01 Sep 2026 14:33`(en)/ `2026年9月1日 14:33`(zh)。
 *
 * ★ 这是 DATE-0 §1.2 Q2 那条建议的落地:`timestamptz` 列**改日期那一半、
 *   保留时分**。时分一律 24 小时制,两种语言相同 —— 一个时刻不需要被翻译。
 * ⚠ 审计戳**不走这里**,走 formatAuditStamp。
 */
export function formatDateTime(value: string | Date | null | undefined, locale: string): string {
    if (value === null || value === undefined || value === '') return EMPTY
    const p = parts(value)
    if (!p) return String(value)
    return `${formatDate(value, locale)} ${p.hh}:${p.mm}`
}

/**
 * 月份 → `Sep 2026`(en)/ `2026年9月`(zh)。接受 `YYYY-MM` 或 `YYYY-MM-DD`。
 *
 * ⚠ **这一条是我按 D4 的【原则】推的,不是 Tim 逐字裁过的形状** ——
 *   他裁的是日期。写在这里是为了让下一个读到的人知道它的身份:
 *   **一条推论,不是一条裁定。** 要改它不必推翻任何裁定。
 * ⚠ 月份**键**(URL 上的 `month=2026-09`)要用 `toYearMonth()`,不是这个。
 */
export function formatMonth(value: string | Date | null | undefined, locale: string): string {
    if (value === null || value === undefined || value === '') return EMPTY
    const p = parts(value)
    if (!p) return String(value)
    return isZh(locale) ? `${p.y}年${p.m}月` : `${EN_MONTHS[p.m - 1]} ${p.y}`
}

// ════════════════════════════════════════════════════════════════════════════
// ── 审计戳那一族(D2 的【不改】侧)──────────────────────────────────────────
// ════════════════════════════════════════════════════════════════════════════

/**
 * 审计戳 → `2026-09-01 14:33`。**与界面语言无关,而这是刻意的。**
 *
 * ★ Tim 的理由,照录:这些是**给查账的人和机器看的**,而
 *   `YYYY-MM-DD HH:MM` **可排序、可复制、可粘回一条查询里**。
 *   他的抱怨是「同一个日期读出三种样子」,而**审计戳与单据日期本来就不是
 *   同一种东西** —— 把它们统一成一种,才是把两件事弄混。
 *
 * ☞ 它取代的是 `lib/format.ts` 的 `formatTimestamp(iso, locale)`:
 *   那一支走 `toLocaleString(locale, …)`,于是**同一个审计戳在中英两种界面上
 *   长得不一样**,而且随浏览器 locale 变。一个"可粘回查询里"的格式不该会变。
 *   ☞ formatTimestamp 仍然在原地(它的调用点由本刀逐处搬过来),
 *     搬完之后它的去处登记在 docs/forward-queue.md。
 */
export function formatAuditStamp(value: string | Date | null | undefined): string {
    if (value === null || value === undefined || value === '') return EMPTY
    const p = parts(value)
    if (!p) return String(value)
    return `${p.y}-${String(p.m).padStart(2, '0')}-${String(p.d).padStart(2, '0')} ${p.hh}:${p.mm}`
}

// ════════════════════════════════════════════════════════════════════════════
// ── ★★★ 数据那一族 —— 这几个的输出【是给机器的】,一个字都不许变 ★★★
// ════════════════════════════════════════════════════════════════════════════
// DATE-0 §5.2 点名了四条会把一个日期【当数据读回去】的路,而**其中三条的
// 失败是安静的**:
//   ① `<input type="date">` 的 value/min/max —— HTML 规范【要求】 `YYYY-MM-DD`,
//      不合法**当空值处理,不报错**:控件什么都不显示。
//   ② URL 上的日期过滤 —— `lib/dateFilter.ts` 的 isYmd 不认就"不过滤",
//      于是**列表悄悄给出全部行**。★ 一个算得出来的错答案。
//   ③ `/hr/leave/calendar` 的 `month` 键(`YYYY-MM`)—— 同 ②。
//   ④ server action 从 FormData 里读日期 —— 库解析不了就拒(**这一条是响亮的**)。
// ☞ 所以这几支**不看 locale**,而且它们的输出格式是一条契约,不是一个选择。

/** `YYYY-MM-DD` —— 喂给 `<input type="date">`、URL 过滤、FormData 的那一个。 */
export function toYmd(value: string | Date | null | undefined): string {
    if (value === null || value === undefined || value === '') return ''
    const p = parts(value)
    if (!p) return ''
    return `${p.y}-${String(p.m).padStart(2, '0')}-${String(p.d).padStart(2, '0')}`
}

/** `YYYY-MM` —— 喂给 `<input type="month">` 与 `/hr/leave/calendar` 的 month 键。 */
export function toYearMonth(value: string | Date | null | undefined): string {
    if (value === null || value === undefined || value === '') return ''
    const p = parts(value)
    if (!p) return ''
    return `${p.y}-${String(p.m).padStart(2, '0')}`
}

// ════════════════════════════════════════════════════════════════════════════
// ── CSV 那一族(D3:**不改**)────────────────────────────────────────────────
// ════════════════════════════════════════════════════════════════════════════

/**
 * CSV 单元格里的时间戳 → `YYYY-MM-DD HH:MM`(**UTC**)。
 *
 * ★★ **这是那五份逐字节相同的 `formatDate` 合并成的一份**
 *    (inbound / materials / output / sales-customers / suppliers 各一份)。
 *    合并的全部目的是**只剩一份**;它**逐字节吐与从前相同的字符串**。
 *
 * ★★★【它用的是 UTC,而这【不是】本刀该修的东西 —— 照直记下来】★★★
 *    那五份复制写的是 `getUTCFullYear()` / `getUTCHours()` …,
 *    而 `lib/format.ts` 立过一条相反的规矩:**服务器时间戳一律按业务时区展示**。
 *    ☞ 也就是说**导出里的时刻比屏幕上的早 8 小时**,而且这件事
 *      从这五份复制写下来的那天起就是这样。
 *    ☞ **本刀不改它**,理由是 D3:**改它就是改导出的字节**,而 D3 裁的是
 *      导出不变。一次"顺手修好"会让今天导出的行与昨天导出的行对不上,
 *      而**没有任何人要求过这件事**。
 *    ☞ 立案在 `docs/known-issues.md` 的 `DATE1-CSV-UTC`,连着这段理由。
 *      要改它,是一次**关于导出口径的决定**,不是一次格式化改动。
 */
export function formatCsvTimestamp(value: string | null | undefined): string {
    if (!value) return ''
    const d = new Date(value)
    if (Number.isNaN(d.getTime())) return String(value)
    const pad = (n: number) => String(n).padStart(2, '0')
    return (
        `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}` +
        ` ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`
    )
}
