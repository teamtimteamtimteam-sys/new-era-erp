# 公共假期与工作日(C-2,2026-09-05)

> **这份文档的读者有两个,而那正是它存在的理由:** 工作日计算(今天)与
> UI-1 的节日 logo(排在发号之后)。**两个读者,一张表** ——
> 两份假期清单是两套系统开始对"今天是哪天"各执一词的方式。

**基线:** HEAD `8afa0b7`(C-1b),树干净。

---

## ★ 头条:这张表【本来就在】,C-2 只给它加了一个身份

委托书把第二步写成"建一张新加坡公共假期表"。**勘察发现它 2026-08-02 就建好了**
(`db/migrations/2026-08-02-hr2a-leave-and-claims.sql`),而且已经是委托书要求的样子:

| 委托要求 | 落地前的实况 |
|---|---|
| 是数据,不是代码 | **已经是** —— `public_holidays`,14 行 2026 年 |
| 不发版就能加下一年 | **已经可以** —— `/hr/leave/holidays`,写入策略 `module.hr.edit` |
| 逢周日顺延周一 | **已经处理** —— 作为【数据】的三行补假,不是逻辑 |
| 工作日计算读它 | **已经在读** —— `is_business_day` → `calculate_leave_days` |
| 少一年要有人被喊 | **已经有** —— `hr_alerts` 的两支告警 |

**所以 C-2 在这一步真正做的只有两件事:补 2027 年的 12 行,以及加一个
【跨年份稳定的身份】—— 而后者才是 UI-1 真正需要、而这张表此前没有的东西。**

---

## ① 这张表今天的形状

```sql
public.public_holidays (
    id, holiday_date, name_en, name_zh,
    holiday_key,   -- ★ C-2 新增:跨年份稳定的身份
    is_in_lieu,    -- ★ C-2 新增:这一行是不是补假
    country DEFAULT 'SG', is_active DEFAULT true, notes, …)
```

* **唯一索引** `(holiday_date, country) WHERE is_active` —— 同一天不会有两个生效行。
* **读** 任何登录用户(`USING (true)`)。每个人都需要知道哪天不上班。
* **写** `module.hr.edit`。今天持有它的角色:`admin`、`cco`、`gm`、`hr`。
  也就是 **Tim、Sandra、Vince** 三个人,加上将来任何拿到 hr 编辑权的人。
* **维护界面** `/hr/leave/holidays`,按年份筛选,可增可删可停用。**不需要发版。**

### ★ 为什么要 `holiday_key`,而 `name_en` 不够用

UI-1 要问的问题是**「今天是不是农历新年」**。它:

* **不能问日期** —— 农历新年每年都在动(2026-02-17,2027-02-06);
* **不能问显示名** —— `Vesak Day` 与 `Vesak Day (in lieu)` 已经不是同一串字;
  而明年那一行是**手打的**,可能写成 `Chinese New Year `(多一个空格)或 `CNY`。
  **字符串比较会安静地答错**,而答错的样子是"今年没有节日 logo",没有人会收到报错。

所以身份是一个**显式的键**,而不是一个碰巧稳定的显示名。今天在册的键:

```
new-year · chinese-new-year · hari-raya-puasa · good-friday · labour-day
hari-raya-haji · vesak-day · national-day · deepavali · christmas
```

约束是 `CHECK (holiday_key ~ '^[a-z][a-z0-9-]*$')` —— 小写、连字符,一种写法。

> **★ 新增假期的表单里,这个键是必填的,而且带一个 `datalist`。★**
> 那不是装饰:这个字段的全部价值就是「明年的农历新年要和今年用同一个键」,
> 而**让人从既有的键里挑,比让他重新打一遍字更可能得到同一个答案**。
> 一个打成 `chinese_new_year` 的键,对 UI-1 来说就是一个全新的节日。
> `datalist` 读的是**所有年份**的键,不只是当前筛选的那一年 ——
> 按年份筛过的清单恰好看不见去年用的是什么。

### `is_in_lieu` 与 `holiday_key` 是两件事

**补假与被补的那天【共用同一个 holiday_key】** —— 它们是同一个节日。
所以只看键分不出哪一行是补的,于是有了 `is_in_lieu`。

UI-1 将来大概率**不想**在补假那天也换 logo(那天不是农历新年,是农历新年的补假),
而这个判断由它自己做 —— 表把两个事实都说清楚,不替它决定。

---

## ② UI-1 将来读什么 —— ★ 只是记下来,C-2 一行都没建 ★

```sql
SELECT holiday_key, is_in_lieu, name_en, name_zh
  FROM public_holidays
 WHERE holiday_date = CURRENT_DATE
   AND country = 'SG'
   AND is_active;
```

* 零行 = 今天不是公共假期。
* 一行 = 换那个 `holiday_key` 对应的 logo(要不要为 `is_in_lieu` 换,由 UI-1 决定)。

> **★ C-2 【不】为 UI-1 建任何东西,这是刻意的。★**
> 为一个还没开工的刀留一个接口,会得到一个**没有人验证过**的接口 ——
> 而它看起来和一个验证过的接口一模一样。这里只写下那一句 SQL,代码里一行都不留。

**工作日计算继续读 `holiday_date`,与上面那条路互不相干。**

---

## ③ 工作日:五天,而且是【已经】五天

```sql
is_business_day(d) :=  ISODOW(d) < 6  AND  NOT EXISTS (生效的公共假期)
```

**周六本来就不是工作日** —— 这不是 C-2 的决定,它 2026-08-02 起就是这样,
`calculate_leave_days` 的抬头还写着【不建模轮班】。

### ★ Tim 的裁定(2026-09-05):保持五天工作周

Tim 说仓库**平时不上周六**,但**赶工时会有周末加班**。裁定:

> **周末加班是【加班】,不是"哪几天算工作日"的改变 —— 两者是两件事。**
> 把周六变成工作日,会让 Fu Sheng **每一次请假都被多扣一天**,
> 只为了模拟一件偶尔发生的事。

**C-2 因此在这一侧一个字都没改。** 加班的现状见下一节。

### 逢周日顺延周一:是【数据】,不是逻辑

2026 年有三行补假(卫塞节、国庆日、屠妖节),2027 年有一行(农历新年)。
**它们是官方公布哪天补就存哪天,系统不去推算。**

理由与"不计算农历/回历日期"是同一条:**顺延规则有例外**(连着两天的节日、
两个节日撞在一起),而一条推算出来的补假**看起来和一条真的补假一模一样**。

---

## ④ 数据来源与取用日期

| 年份 | 行数 | 来源 | 取用日期 |
|---|---:|---|---|
| 2026 | 14(11 法定 + 3 补假) | MOM 官方 | 2026-08(HR-2a 落地时) |
| **2027** | **12(11 法定 + 1 补假)** | [MOM 新闻稿《Public Holidays for 2027》,2026-06-18 发布](https://www.mom.gov.sg/newsroom/press-releases/2026/0618-public-holidays-for-2027) | **2026-09-05(C-2)** |

**2027 年的十二个日期:**

| 日期 | 星期 | 节日 | key |
|---|---|---|---|
| 2027-01-01 | 五 | New Year's Day | `new-year` |
| 2027-02-06 | 六 | Chinese New Year(第一天) | `chinese-new-year` |
| 2027-02-07 | **日** | Chinese New Year(第二天) | `chinese-new-year` |
| 2027-02-08 | 一 | **Chinese New Year(补假)** | `chinese-new-year` · `is_in_lieu` |
| 2027-03-10 | 三 | Hari Raya Puasa | `hari-raya-puasa` |
| 2027-03-26 | 五 | Good Friday | `good-friday` |
| 2027-05-01 | 六 | Labour Day | `labour-day` |
| 2027-05-17 | 一 | Hari Raya Haji | `hari-raya-haji` |
| 2027-05-20 | 四 | Vesak Day | `vesak-day` |
| 2027-08-09 | 一 | National Day | `national-day` |
| 2027-10-28 | 四 | Deepavali | `deepavali` |
| 2027-12-25 | 六 | Christmas Day | `christmas` |

> **★ 农历与回历日期【不去计算】★** 开斋节与哈芝节的日期由官方公布,
> 卫塞节、农历新年、屠妖节同理。C-2 一个日期都没有推算 —— 全部照抄 MOM 的公告。
> **2028 年及以后由 Tim 自己补**,而 `hr_alerts` 会从 2027 年 10 月起提醒他。

### 少了一年会有人被喊

`hr_alerts` 有两支,两支都在:

* **`holiday_calendar_missing`**(severity `expired`,任何月份,立刻)——
  当年一行假期都没有。它是为**全新安装**写的:2027 年 3 月装的库若只播了 2026 年,
  当年每个公共假期都会被当成工作日,请假天数**静默**算错。
* **`holiday_calendar_next_year`**(第四季度起,12 月转 `critical`)——
  明年还没排进来。

**载入 2027 之后,第二支在 2026-10-01 不会响** —— 那正是它该有的样子。

### ★★【UI-1b(2026-09-05):节日画【不】住在这张表里 —— 而理由必须留在这里】★★

C-2 当时被要求把这张表设计成"两个消费方共用"(工作日计算 + 首页节日 logo)。
**那条指示是错的,Tim 在 UI-1b 推翻了它。** 节日画住在 `public.festival_doodles`,
一张**另外的**表。

**为什么必须分开 —— 不写下这条,下一个读者会热心地把它们并回去:**

UI-1b 那 23 个节日里,**只有 10 个是新加坡公共假期**(世界电动车日、万圣节、
感恩节、情人节、母亲节、父亲节、中元节……都不是)。共用一张表意味着:

> **谁为了让首页出现一张万圣节的画而在 `public_holidays` 里加了一行,
> 就同时把 10 月 31 日变成了非工作日。**

于是每一个人的年假计算变了、每一张考勤表变了,连 `is_business_day()` 都变了 ——
而它还是 **FX 回溯那条规矩的判据**(`fx_rate_asof`,见 AGENTS.md 的 FX 规则)。
一次为了装饰而做的编辑,会安静地改掉一条汇率能不能回溯的判断。

> **一个公共假期是一件【工作日事实】;一张节日画是【装饰】。它们不该共用一行。**

**C-2 的 `holiday_key` 与 `is_in_lieu` 留着,一点没浪费** —— 跨年份稳定的身份
本来就有用(农历、回历日期年年在动)。某个节日碰巧也是公共假期(圣诞、屠妖节、
卫塞节……),**那是一次巧合,两张表各记各的,不交叉引用。**

节日画那张表也有自己的"快用完了"告警,复用**同一条通道**:
`hr_alerts` 的 `festival_doodles_exhausted`(最后一个窗口 ≤60 天 warning、
≤14 天 critical,**过期之后继续响**)。机制与理由见
`docs/information-architecture.md` §20.3。

---

## ⑤ RUNTIME CONFIG:引导种子的正确性声明

`public_holidays` 在 `check_mirrors.py` 的 `RUNTIME_CONFIG_TABLES` 里,
所以**它不与线上逐行比对** —— 线上多一行 2028 年的假期是系统在正常工作,不是漂移。

> **AGENTS.md 要求:一支动了 RUNTIME CONFIG 表的迁移,必须在同一次提交里
> 说明它的引导默认值【是否仍然正确】。**
>
> **声明(C-2):`db/tables/public_holidays.sql` 的引导种子仍然正确,
> 而且它的含义没有变。** C-2 给它加了两列并**逐行填上了值** ——
> 14 行 2026 + 12 行 2027,每一行都带 `holiday_key` 与 `is_in_lieu`。
> 没有任何一列改变了既有列的含义:`holiday_date` 仍然是那一天,
> `name_en` / `name_zh` 仍然是显示名。**一次全新安装会得到两年的假期,
> 每一行都带着 UI-1 需要的身份。**

---

## ⑥ 加班:今天建模到什么程度 —— ★ 只报告,不设计 ★

Tim 在 C-2 里说明周末加班是真实需求,并明确**不在这一刀里建**。
勘察出来的现状,逐条:

### 记了什么

**加班【小时数】是记的**,三个桶,住在 `attendance_lines`(一人一月一行):

| 列 | 含义 |
|---|---|
| `ot_normal_hours` | 平日加班 |
| `ot_rest_day_hours` | **休息日加班** —— 周六加班会落在这里 |
| `ot_public_holiday_hours` | 公共假期加班 |

写入口 `record_attendance`(`module.hr.edit`),界面 `/hr/attendance/[id]`,
按期间汇总到 `attendance_period_status`,员工在 `/me` 上看得见自己的三个数。

### 没记什么

* **加班【工资】哪儿都不算。** 工资是外包的:`payroll_lines` 的表注写着
  「数字**全部来自外包服务商**;本系统记录并过账,**从不自己算 CPF 或个税**」,
  而 `employees.monthly_salary` 的列注明写着它 **EXCLUDES overtime**。
  所以三个小时数是**每月告诉服务商的那些数**,不喂任何一次计算。
* **调休(time off in lieu)完全不存在。** 全库零命中 —— 没有表、没有列、没有函数。
* **★ 没有任何东西定义"哪天是休息日"。★** `ot_rest_day_hours` 是一个桶,
  而**把小时数放进哪个桶,靠录入的人自己判断** —— 没有任何校验把桶和日期对起来。
  一个周六的加班被录进 `ot_normal_hours`,系统不会说话。

### 具名的缺口(留给将来的一刀)

> **Tim 已经说明:仓库平时不上周六,但赶工时会有周末加班。
> 这件事今天【记得下小时数,算不出任何后果】,而且【没有调休】。**
>
> 要补的话,它是一整刀:休息日的定义(按人?按部门?按周?)、
> 调休的产生与消耗(它是一种假期余额,要接进 `leave_*` 那一套)、
> 以及加班费率(而工资是外包的,所以这一半可能根本不该进这个系统)。
> **C-2 不碰它,也不留坑** —— 见 `docs/known-issues.md` 的 C-2-OT。

---

## ⑦ 落地清单(C-2 实际改了什么)

| 文件 | 改动 |
|---|---|
| `db/migrations/2026-09-05-c2-…sql` | 加两列 · 回填 2026 · 置 NOT NULL + CHECK · 载入 2027 十二行 |
| `db/tables/public_holidays.sql` | 镜像:两列 + 两年的种子 + 两条列注 |
| `app/hr/leave/types/actions.ts` | `saveHoliday` 收下 `holiday_key` / `is_in_lieu` |
| `app/hr/leave/holidays/HolidaysEditor.tsx` | 两个输入 + `datalist`(键必填才可保存) |
| `app/hr/leave/holidays/HolidaysTable.tsx` | 键列 + 补假标记 |
| `app/hr/leave/holidays/page.tsx` | 取全部年份的键喂给 `datalist` |
| `messages/{en,zh}.ts` | `leave.holidayKey` · `leave.isInLieu` · `leave.inLieuTag` |

> **★ 为什么必须同时改表单 ★** `holiday_key` 是 `NOT NULL`,而
> **`/hr/leave/holidays` 是这张表唯一的新增入口**。不改表单就等于:
> 加了一列、它对每一个将来的行都是空的、而 UI-1 会安静地看不见 2028 年的农历新年。
> **一个只有迁移填得上的必填列,不是一个必填列,是一个坏掉的表单。**
