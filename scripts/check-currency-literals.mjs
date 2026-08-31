#!/usr/bin/env node
// scripts/check-currency-literals.mjs
//
// 【为什么有这个检查】币种写死在界面里,已经连着栽了三次:
//   * NewPaymentForm 用 `currency === 'USD' ? 1 : …` 判本位币 —— FIN-0 把本位币
//     改成 SGD 之后,这句就把"本位币付款"判成了无效,金额显示 0.00(FIN-12);
//   * 同一句的另一半让 USD 付款按 1:1 折算,1,000 USD 显示成 1,000.00 基准;
//   * messages 里 "Amount (SGD)" 之类的标签把本位币烤进了译文。
//     ★【CHECK-1(2026-08-31):而这道检查从来没有扫过 messages/】★
//       抬头从第一天起就把它列为三个成因之一,scan 目录却只有 app / lib / db。
//       FX-DISPLAY-1 那个「一个 USD 数字顶着 SGD 的名字」正是住在 messages/en.ts
//       的 colMarketValue 里 —— **在这道检查够不着的地方**。现在扫了(message-text 类)。
// 两轮人工扫已经各漏一处。人扫会漏第三处、第四处,所以改成【每次都跑】。
//
// 判据【两类】:
//   branch    —— 不允许把 'USD' / 'SGD' 当比较、分支、默认值、对照表键用;
//   jsx-text  —— 不允许把币种当【正文】印到 JSX 上(FIN-18 加)。
//   template-text —— 不允许在模板字符串里把币种贴在插值后面(CCY-1 加):
//     `${formatMoney(x)} USD` 里的 USD 被 stripLiterals 剥掉,jsx-text 看不见它。
//     两处线上实例(采购单定额腿、付款条款模板)就是这么躲过检查的。
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
// 【那两族已经收口 —— OPS-11(2026-08-07)】此处原本记着两个数过但没修的缺口:
// jsonb 分录负载里的 `'currency', 'SGD'`(54 处 / 17 个过账函数)与 `DEFAULT '<币种>'`
// (5 处)。两族现在都进了上面的模式表:
//   * 54 处负载字面量全部换成 base_currency_code();顺带删掉 28 处 `'fx_rate', 1`
//     —— post_journal_entry 对本位币行无条件覆盖 fx,那个 1 从来没被用过,
//     却会在某处币种改成外币时【静默】按 1:1 记账。删的是雷。
//   * 5 处 DEFAULT 只有 record_expense 的 'SGD' 是真的本位币假设(且唯一调用方
//     一直显式传值)—— 已删。另外 4 处【本来就不是本位币的意思】:采购单默认 USD
//     是商务选择、工资期间默认 SGD 是新加坡工资、两个金属计价参数默认 USD 是
//     市场惯例 —— 各自进 ALLOWLIST 并写明理由。
// 【顺带纠正一个当时的判断】"列默认值里写不出子查询"属实,但【函数调用写得出来】
// (实测:参数默认与列默认都接受),所以"表达不了"从来不是留着它们的理由 ——
// 留着的理由只能是"它真的就是那个币种"。
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
import { readdirSync, statSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname
const CODES = ['USD', 'SGD']

// 例外:path 是路径前缀,match(可选)是该行必须包含的片段 —— 【只豁免那一种写法】,
// 不是整个文件从此免检。reason 必填:名单是列出来的,不是记在谁脑子里的。
const ALLOWLIST = [
    // ── FIN-35:rate-default 类的合法例外 ────────────────────────────────────
    // 【百分比默认 0 与汇率默认 1 不是同一件事】0 是"没有",它加进去什么也不改变,
    // 屏幕上也看得见(税额一栏就是 0);1 是"等值",它乘进去什么也不改变,于是
    // 一个错的换算结果与一个对的换算结果长得一模一样。前者可留,后者不可。
    {
        path: 'db/tables/finance_settings.sql', match: 'gst_rate_pct',
        reason: 'GST 税率默认 0 = 【尚未配置,不计税】—— 加数不是乘数,0 在报表上是看得见的一行,'
            + '不会把一个错数伪装成对数。且 finance_settings 是 RUNTIME CONFIG,由操作员显式设定。',
    },
    {
        path: 'db/tables/invoices.sql', match: 'tax_rate_pct',
        reason: '同上 —— 发票上的税率是从 finance_settings 抄下来的副本,默认 0 意为不计税,'
            + '金额栏会如实显示 0.00。',
    },
    {
        path: 'lib/currencyMap.ts',
        reason: '币种在这里【只出现一次】:BANK_BY_CURRENCY 是银行账户与其本币的对照表,'
            + '对应 db/functions/bank_native_currency.sql。本位币本身仍从 currencies.is_base 读,'
            + '不写死。加银行账户时这里与那个 DB 函数必须同改。',
    },
    {
        path: 'app/pricing/calculator/CalculatorForm.tsx', match: 'USD`',
        reason: '计价器的【纯文本明细】(给人复制进邮件/微信的那一段)。金属计价全程 USD 进 USD 出 '
            + '(行情 USD/吨、加工费 USD/吨,FIN-15 已就同一理由把本文件列入例外),而复制出去的文本'
            + '离开了屏幕、没有列头可依 —— 每行必须自带单位,否则收件人手里就是一串没有币种的数。'
            + 'CCY-1 新增 template-text 类后单独记这一条:被剥字符串挡住看不见,不等于它不该被看见。',
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
    // ── OPS-11:剩下的四处 DEFAULT。【它们不是本位币假设】——
    //    "写不出来"不是留着它们的理由(DEFAULT 表达式接受函数调用,实测过),
    //    留着的理由是它们【真的就是那个币种】。第五处(record_expense 的 'SGD')
    //    确实是本位币假设,而且是死的(唯一调用方一直显式传值)—— 已删。
    {
        path: 'db/tables/purchase_orders.sql', match: "DEFAULT 'USD'",
        reason: '采购单默认币种 USD 是【商务选择】,不是本位币 —— 本位币是 SGD,'
            + '这个默认从来就不等于它。多数采购以美元报价,所以默认 USD;'
            + '换本位币【不该】动它。要改是商务决定,记在 currency-literals-audit.md 的'
            + '"换本位币要手改的地方"里,让它成为一次明写的判断而不是连带效果。',
    },
    {
        path: 'db/tables/payroll_periods.sql', match: "DEFAULT 'SGD'",
        reason: '新加坡工资就是以新元发的 —— 与 medical_claims 的 *_sgd 列同源,'
            + '是业务事实不是本位币化名。本位币若再变,这一行不该跟着变。',
    },
    {
        path: 'db/functions/set_inbound_unit_price.sql', match: "DEFAULT 'USD'",
        reason: '金属计价按市场惯例以美元报价(AGENTS.md 的 FX 规则里写明 USD/t)。'
            + 'calculate_metal_price 全程 USD 进 USD 出,换算发生在【路径上】'
            + '(computeLineEstimate)。这个默认是那条链的口径,不是本位币。',
    },
    {
        path: 'db/functions/reprice_inbound_batch.sql', match: "DEFAULT 'USD'",
        reason: '同 set_inbound_unit_price —— 它就是那个函数的内层实现,'
            + '进料计价的原币恒为 USD,折本位币在函数内按定价日 tt_sell 完成。',
    },
    {
        path: 'app/purchasing/orders/new/NewOrderForm.tsx', match: 'USD',
        reason: '金属报价【按市场惯例】以美元计价(AGENTS.md 的 FX 规则里写明:'
            + 'USD/t 这类标签留着)。calculate_metal_price 全程 USD 进 USD 出 ——'
            + '这不是缺口,是那条路的设计:换算发生在【路径上】,由 '
            + 'computeLineEstimate 在数字变成价格之前折进单据币种(FIN-15)。'
            + '所以这里的 USD 标签是【真的】,换成本位币反而会说谎。',
    },
    // ── METAL-3:报价【基准】是 USD,那不是本位币的化名 ──────────────────────
    {
        path: 'db/functions/metal_quote_to_usd.sql', match: "c_quote_basis constant text := 'USD'",
        reason: '这是金属计价函数族的【报价基准】,不是本位币(本位币是 SGD)。'
            + '金属按 USD/吨报价是市场惯例,AGENTS.md 的 FX 规则已把它记成一条决定,'
            + '而 calculate_metal_price 全程 USD 进 USD 出。本函数做的正是把以别的'
            + '货币发布的报价(SMM 按 CNY)折进这个基准 —— 所以这个 USD 是它的'
            + '【目标口径】,从 currencies.is_base 取反而会把它折成 SGD,当场错。',
    },
    {
        path: 'db/functions/calculate_metal_price_from_terms.sql', match: "COALESCE(v_index_ccy, 'USD')",
        reason: '未标注指数的老序列【一直是按 USD 记的】(METAL-2 之前只有一条序列,'
            + '列名就叫 price_usd_per_tonne)。所以这个回退是在陈述那条序列的既有口径,'
            + '不是在假设本位币。声明了指数的行各自带着自己的 quote_currency,'
            + '走的是另一条分支。',
    },
    {
        path: 'db/functions/calculate_metal_price_from_terms.sql', match: "'quote_currency', COALESCE(v_index_ccy, 'USD')",
        reason: '同上 —— 出处里记下这条报价是按什么币种发布的;未标注指数的老序列是 USD。',
    },
]

// 【比对整行,不是那截给人看的文本】h.text 是截到 110 字符的展示串;
// 用它来判豁免,会让"命中点落在第 110 字之后"的行【永远匹配不上】自己的
// ALLOWLIST 条目 —— 豁免写了却不生效,而屏幕上看不出区别。
// OPS-11 撞到过:set_inbound_unit_price 的 DEFAULT 'USD' 在第 120 字左右。
// 截断是展示,判断要用 h.full。
const allowed = (h) => ALLOWLIST.some((a) =>
    h.rel.startsWith(a.path) && (!a.match || h.full.includes(a.match)))

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
    // ── OPS-11:jsonb 键值对里的币种 ────────────────────────────────────────
    // 【最直接的谎法不经过判断,也不经过默认】—— 分录负载直接把币种当成一个值写死:
    //     jsonb_build_object('account_code','1200','side','debit','currency','SGD', …)
    // 一条也不匹配上面任何一条,于是 OPS-8 之后这一族(54 处 / 17 个过账函数)
    // 仍然安然坐在【法定记录】上。判据:'currency' 这个键后面跟着币种字面量。
    // 正确写法是 base_currency_code()(取自 currencies.is_base)。
    new RegExp(`'currency'\\s*,\\s*'${c}'`),             // 'currency', 'SGD'
    new RegExp(`"currency"\\s*:\\s*'${c}'`),             // "currency": 'SGD'
    // 参数与列的默认值。子查询在 DEFAULT 里写不出来,但【函数调用可以】
    // (实测:参数默认值与列默认值都接受函数调用),所以"写不出来"不是留着它的理由;
    // 留下的每一处都必须在 ALLOWLIST 里说明它【真的就是那个币种】。
    new RegExp(`\\bDEFAULT\\s+'${c}'`, 'i'),             // DEFAULT 'SGD'
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
// 标识符不算(price_usd_per_tonne、amount_base 是列名,大小写不同,天然不撞)。
// ════════════════════════════════════════════════════════════════════════════
const JSX_TEXT = new RegExp(`(?<![\\w_$])(${CODES.join('|')})(?![\\w_$])`)

// template-text(CCY-1 加):【模板字符串里紧挨着插值的币种】。
// stripLiterals 会把所有字符串内容剥掉,所以 `${formatMoney(x)} USD` 里的 USD
// jsx-text 永远看不见 —— 两处线上实例就是这么活下来的:采购单详情的定额腿
// 与付款条款模板列表,都把任意币种的金额后面缀了个写死的 USD。
// 判据收得很窄,只认"数字与币种贴在一起"这一形状:插值紧接币种,或币种紧接插值。
// 这样 'USD/t'(市场惯例)与错误码里的 |USD| 都不会被误伤。
const TEMPLATE_TEXT = new RegExp(`\\$\\{[^}]*\\}\\s*(${CODES.join('|')})(?![\\w_$/])|(?<![\\w_$/])(${CODES.join('|')})\\s*\\$\\{`)

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

// ── 第三类:【汇率形状的列带着数值默认值】(FIN-35)────────────────────────────
// 前两类都只看币种【代码】,而最贵的一次假设根本没有代码:
//     fx_rate numeric NOT NULL DEFAULT 1
// 那是 FX 规则花了几切次清掉的 `?? 1`,写成了 schema 的默认值 —— 一条非本位币单据
// 上的 1:1 永远是错的,而且四舍五入到分之后完全看不出来。
// 【为什么按列名而不是按类型】乘数与加数的区别全在名字里:一个叫 *rate 的列,
// 默认 1 意味着"当作等值",默认 0 意味着"当作没有" —— 两者都是替读者做了判断。
// 真正该留的默认值进 ALLOWLIST 并写理由(百分比默认 0 就是这么留下的)。
const RATE_DEFAULT = /^\s*(\w*rate\w*)\s+(numeric|real|double\s+precision)[^,]*\bDEFAULT\s+([0-9.]+)/i

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
                hits.push({ rel, line: i + 1, kind: 'branch', text: line.trim().slice(0, 110), full: line })
                return
            }
            if (rel.startsWith('db/tables/') && RATE_DEFAULT.test(line)) {
                hits.push({ rel, line: i + 1, kind: 'rate-default', text: line.trim().slice(0, 110), full: line })
                return
            }
            // 模板字符串里贴着数字的币种(stripLiterals 之前扫,它正是被剥掉的那部分)
            if ((rel.endsWith('.tsx') || rel.endsWith('.ts')) && line.includes('`') && TEMPLATE_TEXT.test(line)) {
                hits.push({ rel, line: i + 1, kind: 'template-text', text: line.trim().slice(0, 110), full: line })
                return
            }
            // 印到屏幕上的币种只可能出在 .tsx 的 JSX 正文里
            if (!rel.endsWith('.tsx')) return
            const m = JSX_TEXT.exec(stripLiterals(line))
            if (m && !isCurrencyOption(line, m[1])) {
                hits.push({ rel, line: i + 1, kind: 'jsx-text', text: line.trim().slice(0, 110), full: line })
            }
        })
    }
}

// ════════════════════════════════════════════════════════════════════════════
// ── 第四类:messages/ 里的币种(CHECK-1)────────────────────────────────────
// 【为什么单独一类、单独一条棘轮】前三类今天都是 0,可以一律拒。messages/ 不是:
// 实测【76 处】在册(en 40 / zh 36)。把 76 处一次判红,只会让人学会跳过这道门
// —— 与 check-masked-reads 落地时那 71 处是同一个局面,所以用同一种药:
// **基线在册,多一处就红。**
//
// 【它判什么】messages/*.ts 的非注释行里出现 USD / SGD。
// 【它【不】判什么 —— 这一条是本次切次最要紧的一句】
//   它**判断不了这个币种是不是真的**。见文件末尾那段 KNOWN LIMITATION。
const MSG_DIR = join(ROOT, 'messages')
const MSG_BASELINE = join(ROOT, 'scripts/currency-messages-baseline.json')

// 报告时按【形状】分组 —— Tim 的要求:后来的读者要能一眼分出
// "这是 FIN-0 那个病" 与 "这个币种是真的",而不必自己重新推一遍。
function messageShape(text) {
    // 【中文的单位也要认】第一版只认 t / kg / tonne,于是「价格 (USD/吨)」被
    // 归进了 label —— 也就是把一个【真的就是美元】的计量单位,报成了 FIN-0 那个病。
    // 分组报告的全部用处就是让人不必自己重推一遍,分错了它就没有用处。
    if (/(USD|SGD)\s*\/\s*(t\b|kg\b|tonne|吨|公斤|克)|USD per tonne/i.test(text)) return 'unit'
    if (/(Bank|银行)\s*[–—-]\s*(USD|SGD)/i.test(text)) return 'account-name'
    if (/[((]\s*(USD|SGD)[^))]*[))]/.test(text)) return 'label'
    return 'prose'
}
const SHAPE_NOTE = {
    label: '把币种烤进列头/标签 —— **FIN-0 那个病**。本位币一改,这些字就成了谎话。',
    unit: '计量单位(USD/t、USD/kg)—— 金属行情按市场惯例就是美元报价,**这些是真的**。',
    'account-name': '科目名 / 银行账户名 —— 专有名词,**这些是真的**。',
    prose: '正文句子里提到币种 —— 要逐句读,机器分不出真假。',
}

const msgHits = []
for (const name of readdirSync(MSG_DIR)) {
    if (!/\.ts$/.test(name)) continue
    const rel = `messages/${name}`
    blankBlockComments(readFileSync(join(MSG_DIR, name), 'utf8')).split('\n')
        .forEach((line, i) => {
            const t = line.trim()
            if (t.startsWith('//') || t.startsWith('*')) return
            if (!CODES.some((c) => line.includes(c))) return
            const km = /^([A-Za-z_$][\w$]*)\s*:/.exec(t) || /^'([^']+)'\s*:/.exec(t)
            msgHits.push({
                rel, line: i + 1, key: km ? km[1] : `<line ${i + 1}>`,
                text: t.slice(0, 120), shape: messageShape(t),
            })
        })
}

// 【解析出 0 个不是"messages 里没有币种"】—— 与本仓库对"零必须是测量"的一贯口径。
if (readdirSync(MSG_DIR).filter((n) => /\.ts$/.test(n)).length === 0) {
    console.error('✗ check-currency-literals:messages/ 下一个 .ts 都没有 —— 解析器坏了,不是没有文案。')
    process.exit(2)
}

const msgCounts = new Map()
for (const h of msgHits) {
    const k = `${h.rel} :: ${h.key}`
    msgCounts.set(k, (msgCounts.get(k) ?? 0) + 1)
}

if (process.argv.includes('--update-messages-baseline')) {
    writeFileSync(MSG_BASELINE,
        JSON.stringify(Object.fromEntries([...msgCounts].sort((a, b) => a[0].localeCompare(b[0]))), null, 2) + '\n')
    console.log(`✓ messages 基线已刷新:${msgCounts.size} 个〈文件 · 键〉,共 ${msgHits.length} 处。`)
    process.exit(0)
}

let msgBase
try {
    msgBase = JSON.parse(readFileSync(MSG_BASELINE, 'utf8'))
} catch {
    console.error('✗ check-currency-literals:读不到 scripts/currency-messages-baseline.json。')
    console.error('  读不到【不是】空基线 —— 那会把 76 处历史债当成 76 处新债。')
    console.error('  头一次生成:node scripts/check-currency-literals.mjs --update-messages-baseline')
    process.exit(2)
}

const msgAdded = []
for (const [k, n] of msgCounts) {
    const was = msgBase[k] ?? 0
    if (n > was) msgAdded.push({ k, was, now: n })
}
const msgGone = Object.keys(msgBase).filter((k) => (msgCounts.get(k) ?? 0) < msgBase[k])

const shapeCounts = {}
for (const h of msgHits) shapeCounts[h.shape] = (shapeCounts[h.shape] ?? 0) + 1

const bad = hits.filter((h) => !allowed(h))
for (const h of bad) console.log(`  [${h.kind}] ${h.rel}:${h.line}  ${h.text}`)
const allowedCount = hits.length - bad.length
console.log(`\ncurrency literals: ${bad.length} unallowed, ${allowedCount} allowlisted`)

// ── messages/ 那一类的判词 ─────────────────────────────────────────────────
console.log(`messages/:${msgHits.length} 处在册`
    + `(${Object.entries(shapeCounts).map(([k, v]) => `${k} ${v}`).join(' · ')})`)
if (msgGone.length) {
    console.log('· messages 少了几处 —— 有人改好了。基线可以收紧:')
    for (const k of msgGone) console.log(`     ${k}   ${msgBase[k]} → ${msgCounts.get(k) ?? 0}`)
    console.log('  刷新:node scripts/check-currency-literals.mjs --update-messages-baseline')
}
if (msgAdded.length) {
    console.log('')
    console.log('✗ messages/ 里【新增】了写死的币种:')
    for (const a of msgAdded) {
        const [rel, key] = a.k.split(' :: ')
        console.log(`     ${a.k}   (在册 ${a.was} 处,现在 ${a.now} 处)`)
        for (const h of msgHits.filter((x) => `${x.rel} :: ${x.key}` === a.k)) {
            console.log(`       第 ${h.line} 行 [${h.shape}]: ${h.text}`)
            console.log(`       ${SHAPE_NOTE[h.shape]}`)
        }
    }
    console.log('')
    console.log('【怎么改】把币种做成参数:`\'Amount ({ccy})\'`,由行上的币种或 currencies.is_base 填。')
    console.log('【确实就是那个币种】(计量单位、科目名)—— 那也要过一遍眼再进基线,')
    console.log('然后 node scripts/check-currency-literals.mjs --update-messages-baseline。')
    console.log('**不要**为了让门变绿而直接刷新基线。')
}

if (bad.length || msgAdded.length) {
    if (bad.length) {
        console.log('币种不能写死在判断里 —— 从数据行取,或问 currencies.is_base。')
        console.log('确有例外就加进 ALLOWLIST 并写明理由。')
    }
    process.exit(1)
}
console.log('✓ 没有把币种当常量用的判断,messages/ 也没有【新增】写死的币种')
// ════════════════════════════════════════════════════════════════════════════
// ★★【KNOWN LIMITATION —— 这道检查【永远】不会验证一个币种是不是真的】★★
//
// 它验证的是:**一个币种被【说出来了】**。它【没有】、也【不会】验证
// 那个数字真的是那个币种。
//
// **一次绿的构建【不】意味着币种被核过了;它意味着屏幕上每一个币种都有人写了出来。**
//
// 【为什么不做】CHECK-1 量过:要判断 colMarketValue: 'Market Value (USD)' 是不是
// 真的,得从这个键一路追到渲染它的组件、追到 marketValuePerKg()、追到
// metal_prices.price_usd_per_tonne —— 而 **metal_prices 根本没有币种列**:
// 单位烤在【列名】里。也就是说 schema 里【不存在一个事实】可以拿来与标签比对。
// 做一个近似出来,就是本仓库已经被咬过两次的那种【夸大自己的检查】
// (EQP-1c-c-fu 那个把嵌入名当列名的扫描器;check-currency-literals 自己
//  那句"扫 SQL"从加上到 OPS-8 一直是空的)。**一个声称得比实际多的检查,
// 比一个缺失的检查更坏** —— 它替人省掉了怀疑。
//
// 【那这件事靠什么】靠人读,靠 FX-DISPLAY-1 那种「去亲眼看一眼」。
// 记在 docs/known-issues.md 的 CCY-VERIFY 条。
// ════════════════════════════════════════════════════════════════════════════
