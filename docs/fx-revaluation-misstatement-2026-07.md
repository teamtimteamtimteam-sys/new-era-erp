# 2026-07 期末重估算错了 SGD 56,532.48 —— 发生了什么,以及它是怎么被更正的

> **这份文件为什么单独存在。** `docs/known-issues.md` 里那一条在缺陷修好的那一刻
> 就该被删掉(那份文件的规矩是「修掉一条就删一条」)。但**这一条不只是一个缺陷,
> 它是一次【真实总账被错记】的记录** —— 而那种记录不该随着修复一起消失。
> 缺陷没了,事情发生过这件事没有没。
>
> 读者可能是:一年后翻账的人、审计、或者下一个碰重估的人。
> 三者要的都是同一样东西:**当时的数字、错在哪、以及更正是怎么做的。**

## 一句话

期末重估的取数把分录过滤成 `status='posted'`,而冲销的形状是「原分录翻成
`reversed` + 另发一张等额反向的 `posted` 冲销分录」—— 于是**原分录被丢掉、
冲销分录被留下**,净额错成 −原分录。2026-07-31 那次重估因此把**未实现汇兑损失
多记了 SGD 56,532.48**。

## 数字

**错的那一版(`JE-2026-0024`,期末 2026-07-31,USD @ 1.255):**

| 科目 | 实际过账 | 本应是 | 误差 |
|---|---|---|---|
| `1010` Cash at Bank – USD | −8,301.19 | −7,587.19 | −714.00 |
| `1100` Accounts Receivable | +6,770.25 | +6,056.25 | +714.00 |
| `2000` Accounts Payable | **−61,121.54** | **−4,589.06** | **−56,532.48** |
| **合计**(对方科目 `7110` 未实现汇兑损益) | **−62,652.48** | **−6,120.00** | **−56,532.48** |

(负数 = 贷记该科目、借记 7110,也就是记了一笔损失。)

**误差几乎全在 `2000`。** `JE-2026-0003`(247,296.00 USD 借)与 `JE-2026-0001`
(25,600.00 USD 贷)两张原分录被冲销 —— 净 221,696.00 USD 的原分录行被丢掉,
而它们的冲销分录被留下。`1010` 与 `1100` 那 ±714.00 来自同一张 `JE-2026-0006`,
方向相反、正好抵消,所以净误差全部落在应付账款这一笔上。

## 这份重算凭什么可信:**它先把错的那一版精确复现了出来**

用「只数 posted」那一口径重算 2026-07-31,逐科目得到
**−8,301.19 / +6,770.25 / −61,121.54**,与 `JE-2026-0024` **逐行逐分相同**
(7110 借方 62,652.48 也对得上)。

> **能把错的那一版精确复现出来,才有资格说对的那一版是多少。**
> 一个"我算出来是别的数"不构成证据 —— 它同样可能是自己算错了。

复现用的 SQL 与两种口径的对照,见本文件末尾。

## 它是【当时就错的】,不是今天重算才错的

这一条要写清楚,因为两者的性质完全不同:

* 三张原分录的冲销 `JE-2026-0002` / `JE-2026-0004` / `JE-2026-0007`
  分别创建于 **2026-07-06** 与 **2026-07-30**;
* 那次重估创建于 **2026-08-05 01:58:44**。

**跑重估的那一刻,它们早已是 `reversed`。** 所以这不是"后来有人改了历史",
是这个函数在当时就算错了。

另已核对:**没有任何一张 `entry_date <= 2026-07-31` 的分录是在这次重估之后补记的**,
所以"本应是多少"那一列不受后来补记的干扰。

## 更正是怎么做的(2026-08-27,Tim 裁定)

**裁定:发一张更正分录,落在【当前开着的期间】;不重开七月,不碰 `JE-2026-0024`。**

**裁定的理由,原样记下来 ——** 这批都是测试数据,清库时本来就会消失;
**做这次更正是因为这是第一次有真实金额在总账里被错记,而"正确的做法"
(新事件、绝不编辑、绝不重开已锁期间)值得现在从容走一遍,
而不是上线之后在压力下第一次尝试。若这套做法走不通,那个发现比更正本身更值钱。**

### 为什么更正分录的 `source_type` 是 `'revaluation'` 而不是 `'manual'`

**这是个算术问题,不是分类问题** —— 而它是这次更正里最容易做错的一步。

承载额子查询只认 `source_type = 'revaluation'` 的既往调整行。于是:

| 更正分录的 source_type | 下一次重估看到的承载额 | 下一次的调整额 | 之后的承载余额 |
|---|---|---|---|
| **`'revaluation'`** | −22,585.36 | −809.83(正常的月度变动) | **−23,395.19 ✓ 对** |
| `'manual'` | −79,117.84 | **+55,722.65**(把七月又"更正"了一遍) | **33,137.29 ✗ 多出 56,532.48** |

(以 2026-08-31、假设中间价 1.30 模拟,科目 `2000`。)

**`'manual'` 那一支的失败方式是最坏的一种:下一次重估会【无声地把这次更正抵消掉】,
并且刚好多算出我们刚更正掉的那个金额 —— 一个看起来像是故意算出来的数字。**

### 更正分录

* **`JE-2026-0037`**,日期 **2026-08-27**,`source_type = 'revaluation'`
* 摘要(narration)—— **它要自己把话说完,因为它是两张分录之间唯一的桥**:

  > `Correction of JE-2026-0024 (FX revaluation as at 2026-07-31): that run counted only posted journal entries, so reversed originals were dropped while their reversals were kept, overstating the unrealised FX loss by SGD 56,532.48. This entry corrects the balances forward; July itself is closed and unchanged. See docs/fx-revaluation-misstatement-2026-07.md.`

| 科目 | 借 | 贷 |
|---|---|---|
| `1010` Cash at Bank – USD | 714.00 | |
| `1100` Accounts Receivable | | 714.00 |
| `2000` Accounts Payable | 56,532.48 | |
| `7110` FX Gain/Loss — Unrealised | | 56,532.48 |

### ★ 走这一遍方法,学到的那件事:**这条链子只有一个方向** ★

**Tim 做这次更正的理由是"先从容走一遍正确的做法,若走不通,那个发现比更正本身更值钱"。
走完了,而它确实交出了一个发现。**

* **正向可达:** 读到 `JE-2026-0070` 的人,从摘要里就能找到 `JE-2026-0024`
  —— 摘要点了它的名,说了错在哪、错多少、以及本文件在哪。
* **反向【不可达】:** 读到 `JE-2026-0024` 的人,看到的只有
  「FX revaluation as at 2026-07-31」。**没有任何东西告诉他这张分录后来被更正过。**

**而这【不是疏忽,是那条规矩自己的形状】:** 原分录不可改(`JOURNAL_IMMUTABLE`,
实测四种改法全被拒),而"更正是一个新事件、绝不是一次编辑"正是靠它成立的。
**能让原分录说出"我被更正了"的唯一办法,就是去改原分录 —— 那恰恰是被禁止的那件事。**

**结构上缺的是什么,说具体:** `journal_entries` 上只有 `reversed_by`
(冲销专用,本例为 NULL),**没有"这一张更正了哪一张"那个列**。
而这个仓库里【已经有】这个形状 —— `gst_periods.corrects_period_id`:
更正期指着被更正的那一期,原来那一份原样保留、状态不变。
分录这一侧没有对应物。

**要补的话,形状大概是:** `journal_entries` 加一列 `corrects_entry_id`,
**在 INSERT 时写入**(所以不违反不可改:被更正的那一张一个字节都没动),
再由分录详情页反查"有哪些分录更正了我"。
**本刀不建** —— 它是一次 schema 改动加一处界面改动,而这次更正本身已经完成;
把它塞进来会让一次"走一遍方法"的练习变成一刀 schema 工程。
**按名记进 `docs/known-issues.md`。**

> **在它建好之前,这份文件就是那条反向链子。** 谁在账上看见 `JE-2026-0024`
> 而觉得数字不对,要靠的是有人告诉他这份文件存在 —— 这句话本身就是那个缺口的大小。

### ★ 残留:**七月自己的数字仍然是错的** ★

**这一条必须写在最显眼的地方,免得有人以为七月被修好了。**

* **`JE-2026-0024` 原样留着,一个字节都没动** —— 七月的期末余额、七月的损益表、
  任何以 2026-07-31 为截止日的报表,**仍然带着那 56,532.48 的多记**。
* **更正落在八月**(2026-08-27)。这就是"向前更正"的含义:
  **资产负债表从八月起是对的,而七月那一期永远保持它当时的样子。**
* 想看"七月本应是多少",看本文件上面那张表 —— **那是它唯一的去处**,
  因为账上不会有第二个版本的七月。

这是刻意的,不是妥协:七月已锁(`locked_before = 2026-08-01`),
而重开一个已锁期间去改写历史,比留下一个说得清的残留坏得多。

## 附:复现用的对照 SQL

```sql
WITH b AS (SELECT code FROM currencies WHERE is_base),
rev AS (SELECT id FROM journal_entries
         WHERE source_type='revaluation' AND entry_date=DATE '2026-07-31'),
r AS (SELECT rate FROM fx_rate_asof('USD', DATE '2026-07-31','mid')),
agg AS (
  SELECT a.code AS account, l.currency,
    round(sum(CASE WHEN e.status='posted'
              THEN (CASE WHEN l.debit>0 THEN l.amount_ccy ELSE -l.amount_ccy END)
              ELSE 0 END),2) AS nat_old,          -- 只数 posted(错的那一版)
    round(sum(CASE WHEN l.debit>0 THEN l.amount_ccy ELSE -l.amount_ccy END),2) AS nat_new,
    round(sum(CASE WHEN e.status='posted' THEN l.debit-l.credit ELSE 0 END),2) AS car_old,
    round(sum(l.debit-l.credit),2) AS car_new
  FROM journal_lines l
  JOIN accounts a ON a.id=l.account_id
  JOIN journal_entries e ON e.id=l.entry_id
  WHERE e.entry_date <= DATE '2026-07-31' AND a.is_monetary
    AND l.currency <> (SELECT code FROM b)
    AND e.id NOT IN (SELECT id FROM rev)          -- 排除那张重估分录自身
  GROUP BY a.code, l.currency)
SELECT account, currency,
       round(nat_old*(SELECT rate FROM r),2)-car_old AS adjustment_as_posted,
       round(nat_new*(SELECT rate FROM r),2)-car_new AS adjustment_it_should_have_been
FROM agg ORDER BY account;
```

## 顺带发现,已按名queue:全库只有【一个】中间价

`fx_rates` 里 USD 的 `mid` 只有 **一行:2026-07-31 @ 1.255**。
也就是说**七月之后的任何一次期末重估今天都跑不起来**(会被 `FX_RATE_MISSING` 拒)。

**已核实:操作员【不会】只在按下去之后才撞见它。** 两处都在事前说了话 ——
`/finance/month-end` 把重估这一项标成 **blocked** 并给出理由;
`/finance/revaluation` 页面点名缺哪个币种、并把过账按钮置灰
(`canPost = rows.length > 0 && missing.length === 0`)。
`FX_RATE_MISSING` 是直连 RPC 的服务端兜底,不是操作员的第一道提示。

**但有一件事今天没有人被告知:** 上面那张更正分录会**一直躺在那里**,
直到有人载入第一个八月或更晚的中间价;而**那之后的第一次重估,
要么尊重这次更正、要么把它翻倍** —— 取决于承载额有没有把它算进去
(见上面那张 source_type 对照表)。**载入那个牌价的人应当先读这一节。**
