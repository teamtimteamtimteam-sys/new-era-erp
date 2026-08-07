#!/usr/bin/env node
// scripts/check-currency-literals.mjs
//
// 【为什么有这个检查】币种写死在界面里,已经连着栽了三次:
//   * NewPaymentForm 用 `currency === 'USD' ? 1 : …` 判本位币 —— FIN-0 把本位币
//     改成 SGD 之后,这句就把"本位币付款"判成了无效,金额显示 0.00(FIN-12);
//   * 同一句的另一半让 USD 付款按 1:1 折算,1,000 USD 显示成 1,000.00 基准;
//   * messages 里 "Amount (SGD)" 之类的标签把本位币烤进了译文。
// 两轮人工扫已经各漏一处。人扫会漏第三处、第四处,所以改成【每次都跑】。
//
// 判据【两类】:
//   branch    —— 不允许把 'USD' / 'SGD' 当比较、分支、默认值、对照表键用;
//   jsx-text  —— 不允许把币种当【正文】印到 JSX 上(FIN-18 加)。
// 币种要么来自数据行,要么来自 currencies 表(is_base),不是常量。
//
// ════════════════════════════════════════════════════════════════════════════
// 【OPS-8:扫 SQL 这件事,从加上的那天到今天一直是空的】
// 这个文件此前的抬头写着:扩展到扫 SQL,是【因为】fx_rate_gaps 里那句
//     l.currency <> 'SGD'
// —— 而 branch 的比较模式当时只有 `[=!]==?`,它认得 ==、!=、===、!==,
// 【单个 = 和 <> 一个都不认】。SQL 的判断恰恰只用这两个。也就是说:它举出的
// 那个例子,正是它匹配不了的形状。门于是一路报"币种无写死",底下压着 23 处,
// 其中 record_payment 的三处在分支上、preview_revalue_foreign_balances 的两处
// 决定"哪些余额算外币"。【报绿的瞎子比没有检查更坏】——它替人省掉了怀疑。
// 补上单 =、<>、IN、= ANY、LIKE、COALESCE、:= 之后,十二处改成读
// currencies.is_base(db/migrations/2026-08-07-ops8-currency-is-base.sql),
// 十一处是真的就是那个币种,进了下面的 ALLOWLIST 并各自写了理由。
//
// 【还没盖住的两族,数过、记下来,不假装没有】——
//   * jsonb 分录行里的 `'currency', 'SGD', … 'fx_rate', 1`:约 50 处、17 个文件
//     (allocate_processing_costs 11、dispose_fixed_asset 5、record_payment 4…)。
//     它们是"这条分录行按本位币记账"的意思,和 v_doc_ccy := 'SGD' 同一类,
//     但形状是 jsonb 的键值对,不是比较。改起来是自己一切,要连着 fixture 走。
//   * SQL 的参数/列默认值 `DEFAULT 'SGD'`:5 处(set_inbound_unit_price、
//     reprice_inbound_batch、record_expense 三个函数参数;purchase_orders.currency、
//     payroll_periods.currency 两个列默认)。列默认值里同样写不出子查询。
// 【写在这里,是为了让"✓ 没有把币种当常量用的判断"这句话有确切的边界】——
// 上一次这个边界没写出来,结果就是本次 OPS-8。
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么补第二类】第一类只看判断,而最直接的谎法根本不经过判断:
//     {payment.currency !== baseCurrency && <>= {formatMoney(amount_base)} USD</>}
// 这一行【自己知道本位币是什么】(左边刚拿它比过),右边照样印死 "USD"。
// FIN-0 之后本位币是 SGD,于是屏幕上写着 "= 1,736.00 USD"。一条判断模式都不匹配,
// 这道检查报"币种无写死",db/gate.py 跟着报绿。补上之后一次扫出【六处】同一个写法
// (收付款列表/详情、开支列表/详情、应付批次、应收单据)—— 人扫两轮都没扫到。
// 合法例外写进下面的 ALLOWLIST,并且【必须写理由】—— 与 check_mirrors 的科目码
// 扫描、check-i18n 的后缀清单同一个做法:名单是列出来的,不是记在谁脑子里的。
//
// 用法:node scripts/check-currency-literals.mjs   (退出码 0 = 干净)
import { readdirSync, statSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname
const CODES = ['USD', 'SGD']

// 例外:path 是路径前缀,match(可选)是该行必须包含的片段 —— 【只豁免那一种写法】,
// 不是整个文件从此免检。reason 必填:名单是列出来的,不是记在谁脑子里的。
const ALLOWLIST = [
    {
        path: 'lib/currencyMap.ts',
        reason: '币种在这里【只出现一次】:BANK_BY_CURRENCY 是银行账户与其本币的对照表,'
            + '对应 db/functions/bank_native_currency.sql。本位币本身仍从 currencies.is_base 读,'
            + '不写死。加银行账户时这里与那个 DB 函数必须同改。',
    },
    // ── 以下两族是【真的就是那个币种】,不是把本位币烤进界面 ────────────────
    {
        path: 'app/hr/claims/', match: 'SGD',
        reason: '医疗报销按【决策】以新元计:限额来自 hr_settings 的新元政策数字,'
            + '列名本身就是 amount_sgd / claimed_sgd / remaining_sgd(不是 FIN-1a 那种'
            + '名不副实的旧名 —— medical_claims.amount_sgd 存的确实是新元)。'
            + '这里的 SGD 不随本位币变;真要改成多币种报销,是先改表再改这里。',
    },
    {
        path: 'app/me/MyClaimsPanel.tsx', match: 'SGD',
        reason: '同 app/hr/claims/:同一组 *_sgd 列的自助视图。',
    },
    // ── OPS-8:SQL 侧。判断类的已经改成问 currencies.is_base(见
    //    db/migrations/2026-08-07-ops8-currency-is-base.sql);留下的是【真的就是
    //    那个币种】的四族 ──────────────────────────────────────────────────
    {
        path: 'db/fixtures/',
        reason: 'fixture 自带数据:它插了哪个币种的牌价/付款,就按哪个币种清理与断言。'
            + '这里的 USD/SGD 不是"本位币"的化名,是这个用例自己造出来的那一行 ——'
            + '与 db/fixtures/README.md 第 5 条(前提要显式设定)是同一件事。'
            + '真换了本位币,这些用例会【当场报错】而不是悄悄算错:一笔本位币付款'
            + '走到外币分支就会要牌价。',
    },
    {
        path: 'db/functions/pay_medical_claim.sql', match: 'SGD',
        reason: '医疗报销【按决策】以新元计,与 app/hr/claims/ 那条同源:'
            + 'medical_claims.amount_sgd 存的确实是新元,限额也是新元政策数字。'
            + '这一句把 SGD 递给 record_expense,是在说"这笔就是新元",不是在说'
            + '"这笔是本位币"。要改成多币种报销,先改表。',
    },
    {
        path: 'db/tables/currencies.sql', match: 'IN (',
        reason: '这是【币种集合本身的定义】—— 定义一样东西的地方不算引用它,'
            + '与 check_mirrors 把 accounts.sql 排除在科目码扫描之外同一条道理。'
            + '加币种时本来就要改这一行。',
    },
    {
        path: 'db/tables/fx_rates.sql', match: "<> 'SGD'",
        reason: '【这确实是一句本位币测试,但 CHECK 约束里写不出来】—— 本位币对自己'
            + '没有牌价,判据应当是 currencies.is_base;而 PostgreSQL 的 CHECK 约束'
            + '不允许子查询,所以这里没有第二种写法(换触发器是改语义,不在 OPS-8'
            + '的搬家范围内)。【本位币若再变一次,这一行必须手改】—— 它会反过来'
            + '拦住新本位币的牌价、放行旧本位币的牌价。记在 '
            + 'docs/currency-literals-audit.md 的"换本位币要动哪些地方"里。',
    },
    {
        path: 'app/purchasing/orders/new/NewOrderForm.tsx', match: 'USD',
        reason: '金属报价【按市场惯例】以美元计价(AGENTS.md 的 FX 规则里写明:'
            + 'USD/t 这类标签留着)。calculate_metal_price 全程 USD 进 USD 出 ——'
            + '这不是缺口,是那条路的设计:换算发生在【路径上】,由 '
            + 'computeLineEstimate 在数字变成价格之前折进单据币种(FIN-15)。'
            + '所以这里的 USD 标签是【真的】,换成本位币反而会说谎。',
    },
]

const allowed = (h) => ALLOWLIST.some((a) =>
    h.rel.startsWith(a.path) && (!a.match || h.text.includes(a.match)))

// 只抓【比较/分支】里的币种字面量 —— 单纯出现在字符串或数组里(例如下拉选项、
// 类型联合)不算,那些是数据,不是规则。
//
// 【OPS-8:SQL 的比较运算符与 JS 的不是一套】原先这一组只有 [=!]==?,它认得
// ==、!=、===、!==,而【单个 = 和 <> 一个都不认】。SQL 里的判断恰恰只用这两个,
// 于是"扫 SQL"这件事从加上的那天起就是空的:七处活的判断压在下面,其中三处在
// record_payment 的分支上,而门一路报绿。下面 sql 那一组补的就是这个。
const BRANCH_PATTERNS = CODES.flatMap((c) => [
    new RegExp(`[=!]==?\\s*['"\`]${c}['"\`]`),          // === 'USD'
    new RegExp(`['"\`]${c}['"\`]\\s*[=!]==?`),          // 'USD' ===
    new RegExp(`case\\s+['"\`]${c}['"\`]\\s*:`),        // case 'USD':
    new RegExp(`\\?\\?\\s*['"\`]${c}['"\`]`),           // ?? 'USD'   (默认成某币种)
    new RegExp(`\\|\\|\\s*['"\`]${c}['"\`]`),           // || 'USD'
    // { USD: … } 对照表(排除 'USD'::text 这类【类型转换】—— 那是数据不是分支)
    new RegExp(`(^|[{,\\s])['"\`]?${c}['"\`]?\\s*:(?!:)`),
    // SQL 里把币种当【投影出来的值】:'SGD'::text AS currency —— 那是在替所有行断言币种
    new RegExp(`['"\`]${c}['"\`](::\\w+)?\\s+AS\\s`, 'i'),
    // ── SQL 的比较与默认(OPS-8)────────────────────────────────────────────
    // 单个 = :前面不能是 = ! < > :(排除 ==、!=、<=、>=、:= —— := 是赋值,
    // 不是比较,单列在下面,免得把两件事混成一条)
    new RegExp(`(?<![=!<>:])=(?!=)\\s*'${c}'`),           // WHERE currency = 'SGD'
    new RegExp(`'${c}'\\s*=(?!=)`),                      // 'SGD' = currency
    new RegExp(`<>\\s*'${c}'|'${c}'\\s*<>`),            // currency <> 'SGD'
    new RegExp(`\\bIN\\s*\\([^)]*'${c}'`, 'i'),          // currency IN ('SGD', …)
    new RegExp(`\\bANY\\s*\\([^)]*'${c}'`, 'i'),         // = ANY(ARRAY['SGD', …])
    new RegExp(`\\bLIKE\\s*'${c}`, 'i'),                // currency LIKE 'SGD%'
    // 默认成某币种。比较之外的另一半 —— TypeScript 那边的 ?? 'USD' 就是这个形状,
    // 它不判断任何东西,只是在没人说话的时候【替所有行认了一个币种】。
    new RegExp(`\\bCOALESCE\\s*\\([^)]*'${c}'`, 'i'),    // COALESCE(x, 'SGD')
    new RegExp(`:=\\s*'${c}'`),                          // v_ccy := 'SGD'
])

// ════════════════════════════════════════════════════════════════════════════
// 【第二类:印到屏幕上的币种】上面那组只认【判断】里的字面量。可是币种最直接的
// 谎法根本不是判断 —— 是把币种当【正文】写进 JSX:
//     = {formatMoney(r.amount_base)} USD
// 这不是比较、不是分支、不是默认值、不是对照表,一条也不匹配,于是这道检查
// 报"币种无写死",而操作员的屏幕上,本位币 SGD 的金额后面跟着 "USD"。
// 这正是 FIN-0 之后本该被这道检查拦下的那一类,只是它当时只学会了看判断。
//
// 判据:.tsx 里【剥掉字符串与注释之后】仍然出现的裸 USD / SGD。剥掉字符串是
// 关键 —— 'USD' 作为下拉选项的 value、类型联合、对照表的键都是【数据】,留着;
// 剥完还在的,就只能是 JSX 正文,也就是会被人读到的那一份。
// 标识符不算(estimated_total_usd、amount_usd 是列名,大小写不同,天然不撞)。
// ════════════════════════════════════════════════════════════════════════════
const JSX_TEXT = new RegExp(`(?<![\\w_$])(${CODES.join('|')})(?![\\w_$])`)

// 剥掉行内注释与字符串/模板字面量,只留下"结构性"的代码与 JSX 正文
function stripLiterals(line) {
    let out = ''
    let quote = null
    for (let i = 0; i < line.length; i++) {
        const ch = line[i]
        if (quote) {
            if (ch === '\\') { i++; continue }
            if (ch === quote) quote = null
            continue
        }
        if (ch === "'" || ch === '"' || ch === '`') { quote = ch; out += ' '; continue }
        if (ch === '/' && line[i + 1] === '/') break
        out += ch
    }
    return out
}

// 块注释 /* … */ 与 JSX 注释 {/* … */} 【跨行】—— 逐行剥是不够的:
// NewPaymentForm 里那段解释"标签说 SGD、数字后面跟着 USD"的注释就横跨两行,
// 第二行单看不像注释。整文件先把块注释抹成空格(保留换行,行号不动)。
function blankBlockComments(src) {
    return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
}

// 币种下拉的选项【本来就该写出币种】—— <option value="USD">USD</option> 是在
// 让人选币种,不是在替某个金额断言币种。只在 value 与文字是同一个码时豁免:
// <option value="1000">1000 · SGD</option> 不算(那是银行账户名,仍要过检查)。
function isCurrencyOption(line, code) {
    return new RegExp(`<option[^>]*value=["']${code}["'][^>]*>\\s*${code}\\s*<`).test(line)
}

function* walk(dir) {
    for (const name of readdirSync(dir)) {
        if (name === 'node_modules' || name === '.next') continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if ((/\.tsx?$/.test(name) && !name.endsWith('.d.ts')) || /\.sql$/.test(name)) yield p
    }
}

const hits = []
// db/ 下的 SQL 也扫。SQL 里判本位币要问 currencies.is_base,不要写字面量。
// (这几行原先写着"fx_rate_gaps 里那句 l.currency <> 'SGD'"——【那句话两头都过期了】:
//  fx_rate_gaps 早已改成读 is_base,而 <> 这个形状当时根本不在模式表里。见抬头 OPS-8。)
for (const dir of ['app', 'lib', 'db']) {
    for (const file of walk(join(ROOT, dir))) {
        const rel = file.slice(ROOT.length)
        if (rel.includes('database.types')) continue
        // db/migrations 是【历史记录】:当时写下的字面量不该被今天的规矩追认
        if (rel.startsWith('db/migrations/')) continue
        const lines = blankBlockComments(readFileSync(file, 'utf8')).split('\n')
        lines.forEach((line, i) => {
            if (line.trim().startsWith('//') || line.trim().startsWith('*')
                || line.trim().startsWith('--')) return
            if (BRANCH_PATTERNS.some((re) => re.test(line))) {
                hits.push({ rel, line: i + 1, kind: 'branch', text: line.trim().slice(0, 110) })
                return
            }
            // 印到屏幕上的币种只可能出在 .tsx 的 JSX 正文里
            if (!rel.endsWith('.tsx')) return
            const m = JSX_TEXT.exec(stripLiterals(line))
            if (m && !isCurrencyOption(line, m[1])) {
                hits.push({ rel, line: i + 1, kind: 'jsx-text', text: line.trim().slice(0, 110) })
            }
        })
    }
}

const bad = hits.filter((h) => !allowed(h))
for (const h of bad) console.log(`  [${h.kind}] ${h.rel}:${h.line}  ${h.text}`)
const allowedCount = hits.length - bad.length
console.log(`\ncurrency literals: ${bad.length} unallowed, ${allowedCount} allowlisted`)
if (bad.length) {
    console.log('币种不能写死在判断里 —— 从数据行取,或问 currencies.is_base。')
    console.log('确有例外就加进 ALLOWLIST 并写明理由。')
    process.exit(1)
}
console.log('✓ 没有把币种当常量用的判断')
