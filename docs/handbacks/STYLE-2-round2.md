# STYLE-2 交回报告 —— 按钮尺寸档收敛、表头字号,以及一次【我说错了、量出来才发现】的更正

> **一句话:两处改动都做完了,而委托书 §3 担心的那件事【实测没有发生】——
> 28 张表的【行高一个像素都没动】,0 处新的横向溢出。**
> **而我在过程里说错过两件事,两件都是量出来才知道的,都写在下面,没有抹掉。**

* 刀:**STYLE-2**(2026-09-09)
* 量具:`scripts/survey-variant-c.mjs --mode=drift`,chrome-headless-shell + CDP,
  `getComputedStyle` 解析值 —— **三跑**:改动前 / 只改按钮后 / 两处都改后
* 改动:**248 个按钮调用点**(243 `sm` + 5 `lg`)收敛成 `default`;
  **`<DataTable>` 表头字号 14px → 15px**

---

## 1 · HEAD、树、与 `08131bb` 的差别

| | |
|---|---|
| **开工前 HEAD** | `8621fe939e7c30184f96aee3a12b0926c60a9448` |
| **`origin/main`** | 同上 —— **相等** |
| **树** | `git status --porcelain` **空** |
| **与委托书写的 `08131bb` 的差别** | **`08131bb` 是 `8621fe9` 的祖先**,中间**只有一个提交** |
| 那一个提交 | `8621fe9`「STYLE-1 交回报告 §12:补齐闸、构建、推送与部署的实测记录…」 |
| 它改了什么 | **`docs/handbacks/STYLE-1-round2.md` 一个文件,+81 / −2 ——【纯文档】** |

> ☞ **委托书预告的那个形状这次【回来了】:** 「或其文档补充提交」。
> 树干净、`HEAD == origin/main`、差别只是一个纯文档提交 —— **照 §0 的规矩,继续。**

**收工后 HEAD:** 见 §12。

---

## 2 · 按钮总体:重新量过,**与 STYLE-1 的 248 逐个吻合**

委托书说「那是一个声明,这一族交接下来的数反复落错」。所以本刀**没有沿用**,重新量了,
而且**用三种互相独立的量法**,因为第一种量法自己错过一次(见 §2.2)。

### 2.1 三种量法,同一个数

| 量法 | 怎么量 | `sm` | `lg` | `xs` | `inline` |
|---|---|---:|---:|---:|---:|
| ① JSX 开标签解析 | 逐个 `<Button>`/`<ConfirmButton>` 开标签取 `size=`/`triggerSize=` | 243 | 5 | 45 | 73 |
| ② 裸字符串计数 | `size="sm"` 234 + `triggerSize="sm"` 9 | **243** | **5** | **45** | 65+8=**73** |
| ③ 最近前驱标签归属 | 每个属性往前找最近的 `<Tag`(JSX 里这是精确的) | 243 | 5 | 45 | 73 |

> ### ★★ **243 `sm` + 5 `lg` = 248。与 STYLE-1 完全一致。** ★★

**组件总数也独立钉住了:** `<Button>` **547** · `<ConfirmButton>` **67** · `<LinkButton>` **0**
= **614** —— 547 与 STYLE-0、STYLE-1 各自数出的 547 三方吻合。
按档合计:243 + 232(隐式 default)+ 73 + 45 + 16(显式 default)+ 5 = **614**。✔

### 2.2 ⚠ 我的第一种量法错过一次,而是【它自己的数对不上】把它抓出来的

量法 ① 第一版报出 `ListPage size="sm"` **17 处**、`AddRowPanel size="sm"` **2 处** ——
**看起来像是"有别的组件也吃 size 属性,不能一律删"**。

**但总数对不上:** 裸字符串数出全仓库(不含 `ui/`)只有 **234** 个 `size="sm"`,
而量法 ① 却把 234 个记在 `<Button>` 头上、**另外再记 19 个给别人** = 253。
**多出来的 19 个只能是重复计数。**

查下去,机制是明确的:我的开标签切片按 `{}` 配对找结尾,而

```jsx
<ListPage
    actions={ … <Button size="sm"> … </Button> … }   ← 嵌在 prop 里
>
```

里嵌套 `<Button>` 的 `>` 在花括号内、深度不为 0,于是 `<ListPage …>` 这一片
**一路吞到自己的 `>`,把里面那个 `size="sm"` 也吞了进去**。
**核实:`ListPage` 与 `AddRowPanel` 都【没有】`size` 这个 prop。**

☞ 于是换成量法 ③(最近前驱 `<Tag`,在 JSX 里是精确的),
**248 个目标里【只有 1 个】不归 Button 家族** —— 而那 1 个查下去也是假象:

```jsx
<ConfirmButton  details={<p …>…</p>}  triggerSize="sm" >   ← 最近的 <Tag 是 <p
```

**它是 `ConfirmButton`。所以 248 个目标【全部】是 Button 家族,一个都不是别人的。**

> ★ **这一条值得单独记:一个"发现了 19 个例外"的读数,是被【它自己的总数对不上】
> 抓住的,不是被评审抓住的。** 如果我只看那 19 行、不看总账,
> 这一刀会漏掉 19 个调用点,并且理直气壮。

### 2.3 转换后的总体(实测复核)

| | 前 | 后 |
|---|---:|---:|
| 隐式 `default`(不写 `size=`) | 232 | **480**(= 232 + 248) |
| 显式 `size="default"` | 16 | 16 |
| `inline` | 73 | **73** ← 没动 |
| `xs` | 45 | **45** ← 没动 |
| `sm` / `lg` | 243 / 5 | **0 / 0** |
| **合计** | 614 | **614** ✔ |

**写法用【隐式】** —— 把 `size=` 整个删掉,而不是写 `size="default"`。
理由:仓库里本来的多数派就是隐式(232 : 16),隐式不引入一种新写法。
**这是我自己定的,属于细节,记在 §8。**

---

## 3 · ★★ 那个 48px 的 `lg` 是什么 —— 而它不是一处孤例,是【五处】★★

委托书问的是「一个 `lg` 调用点实测 48px,而 `size="lg"` 定义是 36px。找出来,说它是什么,
说它会怎样」。

**它是 `app/inbound/receive/ReceiveForm.tsx:343` —— `/inbound/receive` 的收货提交钮。**
它是五个 `lg` 里**唯一住在静态路由上的那个**,所以 STYLE-1 只看见一个;
另外四个都在 `[id]` 动态路由上,而 STYLE-1 一条动态路由都没走。

### ★ 而真正的发现是:**五个 `lg`【全部】自带同一个 className**

```
app/inbound/receive/ReceiveForm.tsx:343         w-full  min-h-[48px] text-base
app/inbound/receive/done/[id]/page.tsx:95       w-full  min-h-[48px] text-base
app/inbound/receive/done/[id]/page.tsx:98       w-full  min-h-[48px] text-base
app/stocktakes/CountList.tsx:83                 w-full  min-h-[48px] text-base
app/stocktakes/[id]/page.tsx:216                flex-1  min-h-[48px] text-base
```

**`min-height` 压过 `height`。所以这五颗今天渲染的既不是 36px 也不是 32px,是 48px。**

> ### ★★ 于是 STYLE-1 §5.1 那句「这 5 处会从 36px 降到 32px」是【错的】★★
> **把 `size="lg"` 换成 `default` 之后,它们仍然是 48px —— 这一改在屏幕上是零变化。**
> 我已经把规格文档 §5.1 那一段**当场改正**了,没有留着。
>
> ☞ 这和 §7.1「表头线写 2px 渲染成 1px」是**同一课的第二次**:
> **只读 `size=` 档位,会读出一个从来没有在屏幕上出现过的 36px。**

### ★ 它会怎样 —— 我没有拿掉那个 override,理由写在这里

**这五颗是收货与盘点的主操作钮** —— 站在仓库里、多半拿着手机或扫码枪在按的那几颗。
**48px > 44px,和 Tim 自己裁的例外 E1(`/login` 保持 44px)是同一条理由。**

* **拿掉 override** → 五颗降到 32px,**低于 E1 所依据的那条触控建议**。那是一次无障碍上的退步,而且没有人要求过。
* **留着 override** → 它们成为标准之外的一处偏离,而偏离必须写下来。

**我选了留着,并把它写进规格 §2A.1 作为【一条还没有人裁过的候选例外】。**
**我没有替 Tim 把它写成 E5 —— 那是形状,不是细节。**
☞ **要么裁成 E5(与 E1 同理由),要么裁掉这个 override。两条都要 Tim 说。**

---

## 4 · ★★ 行高:委托书担心的那件事【没有发生】,而这是量出来的 ★★

### 4.1 我走了哪 28 条路由,以及为什么是这些

委托书说「挑表格-手机那一族真正转换过的路由,并说明为什么挑它们」。
**我挑了两组,因为风险其实在两个不同的地方:**

| 组 | 为什么 | 路由 |
|---|---|---|
| **A · 表格-手机族转换过的静态路由** | **390px 上「哪几列放得下」的判断就是在这些页上做的** —— 一旦行/列变大,先崩的是它们 | `/finance/receivables` `/finance/assets` `/inventory` `/me` `/finance/close` `/finance/trial-balance` `/finance/packs` `/purchasing/orders/new` |
| **A′ · 校准行** | TABLE-PHONE-3 自己指定的**未改动参照** | `/finance/payables` |
| **B · 单元格里按钮最多的静态路由** | **一颗按钮长 4px,要长也是在这里长** —— 按「DataTable + 单元格内按钮数」排出来的前六 | `/settings/dictionaries`(10)`/purchasing/licences`(9)`/finance/fx`(7)`/hr/departments`(7)`/settings/roles`(7)`/output`(6) |

前缀匹配把这 15 条展开成 **28 条**(如 `/inventory` 带出 `/inventory/reports/*`)。
**28 / 141 条静态路由,两个视口各一遍,三跑全部 0 失败。**

### 4.2 ★ 结果:**28 张表,行高一个都没变** ★

| | phone 390px | desktop 1440px |
|---|---|---|
| 比较的表 | **28** | **28** |
| **表体行高中位数变化的表** | **0** | **0** |
| 表头行高变化的表 | 18 | 19 |
| **横向溢出的页(前 / 后)** | **0 / 0** | **0 / 0** |
| **新增溢出** | **无** | **无** |

> ### ★★ **没有任何一张表被推进溢出。所以【不需要】按 §3 那条停手交回。** ★★

**表体行高:三跑逐张对照(前 → 只改按钮 → 两处都改),28 张全部三个数相同。**
完整表见 §4.5。

### 4.3 ★ 为什么没变 —— 三件互相独立的仪器给了同一个答案

委托书 §3 的推理是「sm 28px → default 32px,**每一颗在表格单元格里的按钮都长 4px**」。
**那一步推理在这套系统上不成立,而这是量出来的:**

| 仪器 | 覆盖 | **表格里的 `sm`/`lg` 按钮** |
|---|---|---|
| ① 运行期普查 | 28 条路由 × 2 视口 | **0** |
| ② 源码词法归属 | **全部 248 个目标**(含动态路由) | **0** |
| ③ 源码间接归属 | 被渲染进单元格的组件,其文件是否带目标 | **0** |

**实测:单元格里的按钮是 `xs` 46 颗 · `inline` 55 颗 · 裸按钮 196 颗。**
**`sm` 那 31 颗全部在表格【外面】**(页抬头、工具条、表单页脚)。

> ☞ **而 `xs` 与 `inline` 恰好就是 Tim 裁定【不动】的那两档(例外 E4)。**
> **也就是说:这一刀会长大的按钮,和坐在表格行里的按钮,是两组不相交的按钮。**

### 4.4 按钮那一改确实生效了 —— 零结果只有在这一步之后才算数

一个「什么都没变」的读数,必须先证明**改动真的到了屏幕上**,否则它和"量了个寂寞"长得一样:

| `data-size` | 前 | 只改按钮后 |
|---|---|---|
| `sm` | **31 颗,全部 28px** | **一颗都没有了** |
| `default` | 26 颗,32px | **57 颗(26+31),全部 32px** |
| `xs` | 46 | 46 ← 逐字节未变 |
| `inline` | 59 | 59 ← 逐字节未变 |
| 裸 `<button>` | 476 | 476 ← 逐字节未变 |

**31 颗按钮确实从 28px 长到了 32px。而 28 张表的行高一个像素都没动。**

### 4.5 逐张表:行高(phone 390px)

| 路由 | 表 | 表头(文字起头) | 行高 前 | 行高 按钮后 | 行高 最终 | 表头 前 | 表头 最终 |
|---|---|---|---:|---:|---:|---:|---:|
| `/finance/assets` | t0 | CodeDescriptionCategoryAcq | 425 | 425 | 425 | 65 | 65 |
| `/finance/close` | t0 | Period endClosed atEntries | 155 | 155 | 155 | 41 | 41 |
| `/finance/fx` | t0 | Currency↕Side↕Rate (1 unit | 41 | 41 | 41 | 61 | 63.84 |
| `/finance/fx/bulk` | t0 | Rate DateTT buy (bank buys | 39 | 39 | 39 | 97 | 97 |
| `/finance/packs` | t0 | SideControl accountPer the | 299 | 299 | 299 | 29 | 29 |
| `/finance/packs` | t1 | EntryDateCounterpartCounte | 83 | 83 | 83 | 29 | 29 |
| `/finance/packs` | t2 | PackMonthProducedLocked be | 85 | 85 | 85 | 41 | 42.42 |
| `/finance/payables` | t0 | CounterpartyDocumentDateDu | 161 | 161 | 161 | 41 | 41 |
| `/finance/receivables` | t0 | CounterpartyDocumentInvoic | 181 | 181 | 181 | 41 | 41 |
| `/finance/trial-balance` | t0 | CodeAccountDebitsCreditsNe | 123 | 123 | 123 | 41 | 41 |
| `/hr/departments` | t0 | CodeName (EN)Name (ZH)Pare | 61.5 | 61.5 | 61.5 | 41 | 42.42 |
| `/inventory` | t0 | MaterialCategoryRaw stockA | 237 | 237 | 237 | 65 | 65 |
| `/inventory/locations` | t0 | CodeNameZoneAllowed classe | 41.5 | 41.5 | 41.5 | 41 | 42.42 |
| `/inventory/reports/ledger` | t0 | DateBatchMaterialLocationM | 41 | 41 | 41 | 41 | 42.42 |
| `/inventory/reports/snapshot` | t0 | MaterialLegStatusQuantityV | 61.5 | 61.5 | 61.5 | 41 | 42.42 |
| `/inventory/reports/snapshot` | t1 | MaterialLegStatusQuantityV | 61.5 | 61.5 | 61.5 | 41 | 42.42 |
| `/inventory/reports/snapshot` | t2 | Ageing bandBatchesQuantity | 41 | 41 | 41 | 41 | 42.42 |
| `/inventory/reports/violations` | t0 | LocationMaterialClassQuant | 85 | 85 | 85 | 37 | 37 |
| `/inventory/reports/violations` | t1 | MaterialLocationQuantity›Z | 61.5 | 61.5 | 61.5 | 41 | 42.42 |
| `/output` | t0 | Code↕MaterialCustomerQuant | 41 | 41 | 41 | 41 | 42.42 |
| `/purchasing/licences` | t0 | KindLicence no.StandingVal | 41.5 | 41.5 | 41.5 | 41 | 42.42 |
| `/settings/dictionaries` | t0 | CodeNameOrderRows using it | 41 | 41 | 41 | 41 | 42.42 |
| `/settings/dictionaries` | t1 | CodeNameOrderRows using it | 41 | 41 | 41 | 41 | 42.42 |
| `/settings/dictionaries` | t2 | CodeNameOrderRows using it | 41 | 41 | 41 | 41 | 42.42 |
| `/settings/dictionaries` | t3 | CodeNameOrderRows using it | 61 | 61 | 61 | 41 | 42.42 |
| `/settings/dictionaries` | t4 | CodeNameOrderRows using it | 41.5 | 41.5 | 41.5 | 41 | 42.42 |
| `/settings/dictionaries` | t5 | CodeNameOrderRows using it | 41 | 41 | 41 | 41 | 42.42 |
| `/settings/roles` | t0 | CodeNameDescriptionPermiss | 41 | 41 | 41 | 41 | 42.42 |

> **读法:** 表体行高三跑相同,所以只列一栏——**「行高 前 / 按钮后 / 最终」三列在每一张表上都是同一个数**。
> 变的只有最后两列(表头),而那是 §5 的字号改动,不是按钮。

### 4.6 ⚠ 这一节量不到的东西,逐条

1. **`/me` 实测 `tables=0`。** 表格-手机族在这一页上转过**三张**表(年假余额 · 工资条 · 考勤/报销/假期)。
   **它们没有被量到,因为普查用的那个临时管理员账号在这些表上【没有行】** ——
   那几张表都写着「没有行就整个不画表」。**这是【未测量】,不是【没有表】。**
2. **`/purchasing/orders/new` 同样 `tables=0`** —— 分期表要先选一张付款条款模板才会画。
3. **展开区没量。** DataTable 在手机上把非 priority 列折进展开块,而普查**从不点开它**。
   **动作列上的按钮多半就住在那里** —— 首屏读数对它们不成立。
   ☞ 不过 §4.3 的仪器 ②③ 是**源码层**的,它们不受首屏限制,而它们给的也是 0。
4. **58 条动态路由一条都没走** —— 见 §9。

---

## 5 · 表头字号:14px → 15px,**内边距一个字节没碰**

### 5.1 改了哪一行

`app/components/ui/data-table.tsx`,表头格的 className:

```diff
- 'px-3 py-2.5 align-middle font-medium text-[color:var(--brand-text)]',
+ 'px-3 py-2.5 align-middle text-[15px] font-medium text-[color:var(--brand-text)]',
```

**`px-3 py-2.5` 在改动前后是逐字节相同的同一个串。** `<td>` 那一行**没有碰**(仍是 14px)。

### 5.2 ★ 我在这里推断错了一次,而读数把它纠正了

**我先写下的判断是:** 「`<table>` 上的 `text-sm` 同时定了 font-size 与 line-height:20px,
而 `text-[15px]` 只设字号,所以行高会停在 20px,与 spec 的 21.43px 差 1.43px,这个残差要记着。」

**量出来不是这样:**

| | 前 | 后 | spec §4.3 |
|---|---|---|---|
| 字号 | 14px | **15px** | 15px ✔ |
| 行高 | 20px | **21.4286px** | 21.43px ✔ |
| 字重 | 500 | 500 | 500 ✔ |
| 内边距 | 10/12 | 10/12 | 10/12 ✔ |

**Tailwind v4 的任意值字号会把 line-height 一并重置。** 于是表头四项**全部合规**,
**没有残差。我把规格文档与代码注释里那句错的话都改掉了,没有留着。**

### 5.3 ⚠⚠ 而「一处改动推动全部 409 个」是【过头的说法】—— 实测

`c.className` 排在 `cn()` 的**最后**,所以**调用方在列上写了字号的,调用方赢**。

**实测(desktop,28 条路由):本组件的 102 个表头里 —— 92 个到了 15px,10 个仍是 14px。**
那 10 个全部来自这种列定义:

```js
{ key: 'code', header: …, className: 'font-mono text-sm' }   // ← text-sm 压过 text-[15px]
```

出现在 `/finance/fx`(4)· `/hr/departments`(4)· `/output`(2)。

**源码层数得到:全仓库有 293 个列定义钉了字号 —— 248 个 `text-sm` + 45 个 `text-xs`。**
其中 `text-xs` 那些本来就渲染 12px,**根本不在 STYLE-1 那 409 个(14px)里面**;
会被挡住的是 `text-sm` 那一族。

> ☞ **确切的全仓库分账我没有量到 —— 我只走了 141 条静态路由里的 28 条。**
> **能说的是:改这一处推动了【绝大多数】,不是【全部】,而挡住它的是调用点自己写的字号。**
> **这和 §3 那五颗 `min-h-[48px]` 是同一个形状:调用点的 className 压过档位。**

### 5.4 表头行高的代价:**+1.42px**

| 视口 | 表头变高的表 | 每张 |
|---|---:|---|
| phone 390px | 18 | **+1.42px**(41 → 42.42) |
| desktop | 19 | **+1.42px** |

**唯一的例外:`/finance/fx` 在 phone 上是 61 → 63.84(+2.84)** ——
因为那一页的表头在 390px 上**折成两行**,于是 +1.42 乘以 2。**这不是别的机制。**

**表体行高:0 张表变化。** 表头长 1.42px,没有把任何一页推进溢出(§4.2)。

---

## 6 · 规格文档现在的例外清单(§2A,新增)

`docs/variant-c-spec.md` 新增 **§2A「例外清单」**,并进了目录。四条逐条带理由:

| # | 例外 | 标准说 | 例外定成 | 理由 |
|---|---|---|---|---|
| **E1** | `/login` 输入框与按钮 | 32px | **44px** | 触控可达;44px 是 Apple HIG 与 WCAG 2.5.5 都点名的数;`brand-tokens.md` §5.4 明写 Tim 在手机上用这套系统 |
| **E2** | `/login` 焦点环 | `ring-ring/50` 半透明 | **实心 + offset** | **无障碍合规**:半透明 1.6:1,实心 3.75:1,WCAG 1.4.11 要 3:1。回退会掉到 AA 以下 |
| **E3** | `<h1>` | 30px | **24px** | 139 个页面标题已经一致(127 个逐字节相同);取样页那 30px 是**那一页自己的大标题**,不是页面标题规格 |
| **E4** | `xs`(45)与 `inline`(73) | 收敛成 default | **原样不动** | `inline` **不是盒子**(`h-auto p-0 align-baseline`);转过去会把 73 处句中/单元格内的一段字变成 32px 的盒子,行高当场改 |

**另外新增 §2A.1** —— 一条**还没有人裁过**的候选例外:§3 那五颗 `min-h-[48px]`。

> ⚠ **一件必须点名的事:** 规格 §8 记的 `/login` **三处**刻意偏离里,
> **① 卡片 `shadow-lg` 对取样页的 `shadow-md`【不在】Tim 裁的这四条里。**
> **它至今没有人裁过,仍然是一处没有记载的偏离。** 我没有替它补一个理由,
> 只在 §8 就地标注了这件事。

---

## 7 · 新增或改动的用户可见字符串

**一个都没有。**

* 没有新增/改动/删除任何 i18n key —— `messages/` **零改动**。
* 248 处改的是 `size=` 属性,**按钮上的文字一个字都没碰**。
* 表头改的是字号,**表头文字来自 `c.header`,一个字都没碰**。
* 权限、动作、列、迁移:**零**。**没有迁移。**

---

## 8 · 我自己决定了的事(都是细节,不是形状)

1. **`default` 写成隐式(删掉 `size=`),不是显式 `size="default"`。**
   仓库本来的多数派就是隐式(232 : 16);显式会引入第二种写法。
2. **保留调用点上原有的 `className`**(`text-xs` / `text-sm` / `min-h-[48px]` 等一律没动)。
   委托书要的是"档位收敛",不是"清理 className"。**其中 `min-h-[48px]` 那一条我特意留着,理由见 §3。**
3. **给量具的 `--only` 加了【逗号分隔多前缀】。**
   本刀要的路由横跨 `/finance` `/settings` `/hr` `/inventory` …,一个前缀圈不出来;
   而为了圈它去跑满 141 条,**正是上一刀卡死的那个跑法**。
   ☞ 它只改**走哪几条路由**,不改**量什么**;单前缀的老写法逐字不变。
4. **给量具的读数加了两样东西:每一行带【属于第几张表】,以及页面的 `scrollWidth`/`clientWidth`。**
   **理由是没有它们就答不出委托书问的题:** STYLE-1 的读数把一页上所有 `tbody tr`
   混在一个池子里,「**每张表**的行高变了多少」问不出来,而 `/settings/dictionaries`
   一页上就有 6 张表。**它只加归属编号与两个页面级读数,不改任何被测量的值。**
5. **量具改完之后,BEFORE 那一跑【重跑了一遍】。**
   我是在 BEFORE 跑到一半时才意识到缺 per-table 归属的 —— **当场杀掉重来**,
   **好让前后两次读数出自同一把尺子。** 半跑的那次一个数都没用。
6. **三跑而不是两跑**(前 / 只改按钮 / 两处都改)。委托书要求的是前后两跑;
   我加了中间那一跑,**好把"按钮"与"字号"各自的影响分开** —— 否则表头 +1.42px
   会说不清是谁干的。

---

## 9 · 我没能核实的

1. ★ **58 条动态路由(`[id]` 详情页与编辑页)一条都没走** —— 与 STYLE-1 同一个盲区。
   ★★ **而这一次它更要紧,因为数出来了:248 个目标里【有 78 个】住在动态路由的文件里,
   分布在 45 个文件上**,其中就有表格-手机族改过的
   `app/logistics/containers/[id]/ContainerPanels.tsx`(5 个目标)。
   **委托书点名的「录入表单的行编辑表」正是这一族,而我确实没有量到它们。**
   ☞ 能说的是:§4.3 的仪器 ②③ 是**源码层**的,它们**覆盖了这 78 个**,给的是 0 ——
   也就是**这 78 个目标没有一个在词法上坐在单元格里**。ContainerPanels 那 5 个逐个看过,
   全部是表单页脚的「保存 / 附加 / 加里程碑 / 实例化 / 加单据」。
   **但"源码上不在单元格里"不等于"屏幕上那一页没被推宽",后者我没量。**
2. **`/me` 与 `/purchasing/orders/new` 上的表没有量到**(账号没有行 / 没选模板)——
   见 §4.6。**表格-手机族在 `/me` 上转过三张表,这一刀一张都没看见。**
3. **首屏之外一概没量** —— 展开区、对话框、下拉、Tab。
   **手机上的动作列按钮多半就在展开区里。**
4. **软导航没验** —— 我走硬导航,人点链接。根布局在客户端换页时不重画。
5. **表头字号的全仓库分账没量** —— 293 个钉了字号的列定义里,有多少落在 STYLE-1
   那 409 个表头上,要跑满 141 条才知道。**我只走了 28 条。**
6. **`npm run build` 之外没有跑单元测试** —— 这个仓库的判据是闸与构建。
7. ⚠ **一处过程瑕疵,照直说:** 第三跑(两处都改)的 **phone 那一半跑着的时候,
   我在改 `data-table.tsx` 的注释**。**改的全部是注释,不进 DOM,所以读数有效**;
   而且 §5 引用的 15px 那组 desktop 读数是在我动注释**之前**就落盘的。
   **但这是运气不是纪律 —— 正确的做法是等它跑完。**

---

## 10 · 队列与记录

**本刀往队列里留下的:**

* ★ **§3 那五颗 `min-h-[48px]` 要不要写成 E5** —— 规格 §2A.1 已登记,**等 Tim 裁**。
* ★ **规格 §8 的偏离 ①(`/login` 的 `shadow-lg`)至今没有人裁过** —— 已就地标注。
* **293 个钉了字号的列定义**(248 `text-sm` + 45 `text-xs`)会挡住表头字号 —— 已记入规格 §4.3。
* **`<td>` 仍是 14px,spec 说 15px** —— 本刀只动表头,这一格仍然欠着。
* **276 个手搓表头**仍在 66 个文件里,棘轮压着只减不增 —— 不在本刀。

**仍然原样、本刀一个字节都没碰的:** `button.tsx` 的档位定义 · `table.tsx` 与 `card.tsx`
(仍 `GUARDED`,§7.1 那条 1px 表头线**没有**去修)· 1929 个裸 `<button>` ·
输入/下拉/多行框/标签 · 九张包起来的表 · 月末筛选键 · 31 文件错误码普查 ·
日记账导出 JS 排序 · 拼音字段 · NARROW-COVERAGE-2 · 孤儿脚本 · CONSEQ-2 三项。

---

## 11 · Tim 该去哪里走 —— **两种改动长得很不一样,两种都要看**

### ★ 怎么看手机档:**设备模拟 390px,不是把窗口拖窄**
Chrome DevTools → **Toggle device toolbar(⌘⇧M)** → **iPhone 12 Pro(390 × 844)**。
断点是 640px,拖窄窗口**也会**切换,但字号与点按目标不是手机的。

### 11.1 ★ 按钮明显变大的地方(28px → 32px)—— 这几页是实测有 `sm` 的

| 页 | 那颗钮 | 看什么 |
|---|---|---|
| **`/settings/dictionaries`** | **「Add a value」×6** | ★ **一页上六处同时变大,最看得出来** |
| `/output` | 「Export」等 3 处 | 抬头那一排 |
| `/finance/fx` | 「Enter a week」等 3 处 | 抬头 |
| `/inventory/reports/ledger` | 「CSV」×3 | 抬头 |
| `/finance/close` | 「View P&L for this month」 | |
| `/purchasing/licences` | 「Add a licence」 | |

> ☞ **这几颗全都在表格【外面】(抬头 / 工具条)** —— 那正是 §4.3 的读数:
> 会长大的按钮和坐在表格行里的按钮是两组不相交的按钮。
> **所以走查时请留意「抬头的钮变大了」,而不是「表格的行变高了」——** 行没有变。

### 11.2 ★ 表头字号变大的地方(14px → 15px,行高 20 → 21.43px)

| 页 | 看什么 |
|---|---|
| **`/settings/dictionaries`** | ★ **一页六张表的表头一起变** —— 和 11.1 是同一页,**两种改动可以一次看完** |
| `/inventory/reports/snapshot` | 三张表的表头 |
| `/settings/roles` · `/hr/departments` · `/purchasing/licences` · `/output` | 表头 |
| **`/finance/fx`** | ★ **390px 上表头折成两行,所以这一页长 2.84px 而不是 1.42px** |

### 11.3 ★★ 一处**故意没有一起变**的地方,值得专门看一眼

**`/finance/fx` · `/hr/departments` · `/output`** 这三页上,**有几列的表头【没有】变成 15px**
—— 它们是 `className: 'font-mono text-sm'` 的等宽列(单据号 / 代码那一类)。

> ☞ **同一张表里现在会有 15px 与 14px 两种表头并排。**
> **这不是漏改,是调用点自己写死了字号(§5.3),而本刀没有去动调用点的 className。**
> **要不要把这 293 个列定义的字号统一收掉,是下一刀 / Tim 的事。**

### 11.4 桌面上

同样看 `/settings/dictionaries`(按钮 + 表头一次看完)与 `/finance/fx`(那几列 14px 的等宽表头)。
**桌面上表头也是 +1.42px,按钮同样 28 → 32px。**

### 11.5 ★ 而这两页请**特意去看一眼,因为我没能量到**

* **`/inbound/receive`** —— 那颗 48px 的收货提交钮。**它应当【一模一样】,没有任何变化**(§3)。
* **`/stocktakes/<id>` 与 `/inbound/receive/done/<id>`** —— 另外四颗 48px 的钮,**动态路由,我一条都没走**。
  它们也应当没有变化,**但那是推断,不是读数**。

---

## 12 · 收尾:闸、构建、推送、部署(全部实测)

### 12.1 `db/gate.py` —— ★ 跑了两次,第一次是【环境故障】,照它自己说的原样重跑

**第一跑:**

| | |
|---|---|
| **它自己的退出码** | **`GATE_OWN_EXIT=5`** |
| **wall-clock** | **306 秒** |
| 发生了什么 | `psql: SSL connection has been closed unexpectedly` / `connection to server was lost` |
| 它自己的判词 | 「判词【无法作出】:✗ 够不到线上目录 —— 这是【环境故障】,不是仓库的毛病。…原样重跑。」 |

> ☞ **5 是这支工具明写的一档:**「够不到线上,本工具自身的环境故障 —— 不是仓库的毛病,
> 原样重跑即可」(`db/gate.py` 抬头)。**而它同一跑里已经印了 `REBUILD OK`** ——
> 重建那一半是好的,断掉的只是"拿线上目录来比"那一半。
> **所以我按它自己的指示原样重跑,没有改任何参数、没有绕过它。**

**第二跑(采信的那一次):**

| | |
|---|---|
| **它自己的退出码** | **`GATE_OWN_EXIT=0`** |
| **wall-clock(我的计时)** | **611 秒** |
| **它自己报的 wall-clock** | **465 秒**(判词那一行括号里的数) |
| **180–700s 这个区间** | **611 在区间内 —— 不需要放宽** |

**四条判词,逐字照抄:**

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

**同跑里另外两行值得留底:**

```
NO DIFFERENCES — the rebuild matches live ✓
live     B1 anon-executable: 0   B2 definer-unchecked-and-callable: 0
rebuild  B1 anon-executable: 0   B2 definer-unchecked-and-callable: 0
```

> ⚠ **一个我差点报错的地方,记下来:** 判断"闸跑完了没有"我一开始用的是
> `pgrep -f "gate.py"`,**而它一直报"还在跑" —— 那是假的**:
> 它匹配到的是**我自己那几个等待用的 shell**,它们的命令行里就写着 `gate.py`。
> 改用 **PID** 判断之后才是对的。**一件仪器把自己算了进去。**

### 12.2 `npm run build`

| | |
|---|---|
| **它自己的退出码** | **`BUILD_OWN_EXIT=0`** |
| **wall-clock** | **37 秒** |
| 编译 | `✓ Compiled successfully in 10.6s`(Next.js 16.2.6 / Turbopack) |

**eslint 冻结闸,逐字:**

```
── eslint 冻结闸 ─────────────────────────────────────────────
基线  error 42 · warning 88
现在  error 42 · warning 88

✓ 没有新增的 eslint 问题。
```

> ★ **42 / 88 一个都没动。** 本刀改了 132 个文件,其中两个不是调用点
> (`data-table.tsx` 与量具本身)—— 开工前我单独对这两个跑过 eslint:
> 量具 **0 个问题**(它在基线里本来就是 0 条),`data-table.tsx` **2 条 warning**,
> 而基线里给它记的正是 `@typescript-eslint/no-unused-expressions` **0 error / 2 warning**,
> 且那两条在 329 / 358 行,**不是我改的那一段**(我改的在 419 附近)。

**meta-check(量具自证)那一行,逐字:**

```
✓ check-instrument-selfproof:33 支量具都写了瞄准线;其中 22 支(构建链里的,含本支)都带着覆盖断言。
```

> ☞ **33 支没有变** —— 我改的是一支**已经在册**的量具(`survey-variant-c.mjs`),
> 没有新增量具,它的瞄准线与覆盖断言原样都在。

**同跑里另外几条值得留底的判词:**

```
swallowed query errors: 0 unallowed, 0 queued(真缺陷,在册), 9 allowlisted(不是缺陷)
✓ 没有【新增】丢掉 auth error 的地方。
✓ check-enum-mirrors:1 处转录,全部与真源逐字相同
check-confirm-subject: 57 处 subject / 57 个 JSX 开标签,来自 51 个文件 —— EXIT 0
```

