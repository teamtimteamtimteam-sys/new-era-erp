# 发布说明(给测试者)· Release notes (for the people testing)

> **这份文件从 v1.4.4 开始记。** 在它之前的版本号消耗在各自的切次报告与提交信息里,
> 没有一份面向使用者的合并说明 —— 而 BTN-3 / BTN-3b 两刀干脆没有写、也没有消耗版本号。
> **写下来的理由:六个人不会去读提交信息。**
>
> **★ 2026-09-07:v1.4.4 / v1.4.5 / v1.4.6 三份【一份都没有发出去】。**
> 它们分若干刀讲了同一批改动,而没有人会经历若干次改动 —— 打开系统的是同一次。
> 所以它们**合并成下面这一份 v1.4.6**,版本号取其中最高的那个。
> **合并之后只讲【最后的样子】** —— 不讲某样东西曾经更淡、曾经被撤走、
> 或曾经被报上来而复现不出来:那些状态外面【没有人见过】,写出来只是噪音。
> 用英文写,因为它是要直接转发给人的那一份。

---

## v1.4.7 — A permission that could be ticked but did not exist, and an error that spoke in code

**2026-09-07.**

### ★ The two worth knowing before you test

* **On the screen where you give a role its permissions, the Logistics row offered an
  "Edit" tick that did not correspond to anything.** There is no separate edit permission
  for Logistics — being able to see it is the whole of it. You could set that tick, but
  saving was then refused, and the refusal threw away every *other* permission change you
  had made to that role in the same save, without saying why.

  > **Nothing was ever granted by mistake, and nothing you granted has quietly failed.**
  > The system refused the save outright rather than applying half of it, so no role has
  > ever held a permission that does not exist. If a permission change of yours did go
  > through, it went through properly.

  That cell now shows a dash instead of a tick, and says that this module has no separate
  edit permission.

* **When you lacked permission to issue a purchase order as a PDF, the screen printed an
  internal code instead of a sentence.** It now tells you what you cannot do, that nothing
  was issued and nothing reached the supplier, and what to ask for.

### Roles

* **Both role screens are now titled "Role".** They were titled "Permissions" — which is
  the name of the settings area they sit in, not of what they edit. The permissions section
  further down the role screen is still called Permissions, because that is what it is.
* **"Delete" on a role is now the red, destructive kind of button.** It used to look like an
  ordinary control standing next to Save. Deleting a role takes it away from everyone who
  holds it, and no screen anywhere can put it back.

### Menus

* **"KPI scoring" has moved off the HR menu and onto the KPI page.** It is a part of KPI
  rather than something separate standing beside it. Who can see it has not changed.

### Downloads

* **The output batch export writes the batch state in English.** The file used to carry the
  stored Chinese value while the screen showed English, so the file disagreed with the page
  it was downloaded from.

### Wording

* **The traceability report is now called "Customer audit report".** It was the one place in
  the system that called a customer a client — and it is the one that gets printed and sent
  outside the building.

---

## v1.4.6 — Buttons and headings, throughout, and one real change to how deleting works

**2026-09-07.**

> Almost nothing behaves differently here. Apart from the one item called out first,
> everything below is something you will *see*, not something you have to do differently.

---

### ★ The one thing that behaves differently

* **Removing a step inside a task now asks first.**
  It used to happen the instant you clicked. Now a dialog appears, names the step, and says
  plainly that this removal is permanent: the record leaves the database and no copy is kept.

  > **This is worth knowing once:** it is the only place in the system where "delete" really
  > destroys something. Everywhere else a deleted record is still there and simply marked as
  > deleted. That dialog is the only place you are told the difference.

---

### Confirmations

* Where the browser's own grey pop-up used to appear, you now get the system's own dialog —
  and it **names the thing you are about to act on**, instead of asking "Are you sure?"
  about nothing in particular.
* Where a reason is required, **the confirm button stays unavailable until you type one**,
  rather than letting you press it and then complaining. With a reason typed, Enter confirms.
* Deleting a rate on the exchange-rate page asks in the system's own dialog, and says which
  rate.

### What buttons look like

* **Buttons are the same throughout the system.** The blue "New …" at the top of a list,
  "Cancel" beside "Save" on a form, "Export" and the CSV / PDF links in report headers, the
  page arrows at the foot of a long list, and the "Edit" beside each row of a table — all of
  them are one set of buttons.
* **A button that destroys data carries a solid bar down its left edge. A button that undoes
  something carries a dashed bar.** Undo means the data stays and is only reversed or marked.
  You can tell the two apart without relying on colour, and the two bars are drawn at the
  same weight.
* Some buttons labelled "Delete", "Cancel" or "Remove" carry the **dashed** bar, because what
  they do is reversible — a leave request, a customer contact. **That is deliberate.**
* **"Cancel order" on a sales order is the red, destructive kind**, while "Confirm" and
  "Close" beside it are not.
* The GST correction, the inventory hold and the retention release are ordinary buttons. They
  neither destroy nor undo anything.
* **A button you cannot use is grey with dark text, not faded.** The intent is "clearly
  switched off" rather than "possibly still loading".
* At the ends of a list, **the greyed-out page arrow matches the live one** — same size, same
  shape.
* **"Add a licence" on the company licences panel looks like a button**, because that is what
  it is.
* **The file-picker button is the same on every screen that has one.** Choosing and uploading
  files works exactly as before.

### Page headings

* **On a narrow screen — a phone, or a small window — the buttons at the top of a page drop
  onto a second line instead of pushing the page sideways.**
* **The exchange-rates page has its heading buttons grouped together at the right-hand end**,
  in the same place and the same order as every other list page: the secondary action first,
  the main one last.
* **The supplier list has its two entry links** — the one for contracts and the one for
  commission agreements — and they look like the buttons they are.
* **On the receiving screens, the paragraph explaining how a storage location is checked
  reads as ordinary explanatory text.** It describes what the check does; it is not a
  warning. The real warnings on that screen stand out.

### These are still links

* Every one of those buttons is still a link wherever it always was. **Middle-click, "open in
  new tab", "copy link address" and the back button all work exactly as before.** If any of
  them has stopped working, that is a bug and worth reporting.

### Screen readers

* The arrows that move the calendar a month backwards or forwards say which one they are,
  instead of announcing a bare symbol.

### Where you will see a mix, on purpose

* **Some things look like buttons and are not**, so they were left alone: the coloured status
  chips beside assays and metal content; the row of tabs at the top of the leave, settings and
  deleted-records pages; the filter chips on the calendar; and the large clickable cards on
  the reports and pricing pages. Making them look like buttons would suggest they perform an
  action, and they do not — they show a state, or take you somewhere.
* The buttons that step a sales order through its stages are full-width, because each has a
  line underneath explaining what that step does, and the two are meant to line up.
* The large buttons at the end of the field-receiving flow are large, because they are sized
  to be tapped on a phone.
* On the metal-price forms, "Save" keeps its own look, because it turns amber when a price
  looks anomalous.
* On the finance settings page, the sentence about month-end close being the normal way to
  lock periods is blue because the whole sentence is a link to the Close page.

### What should NOT have changed

* **What any button does.** Nothing was rewired: same destination, same form, same submission.
  If a button does something different from before, that is a bug.
* **The phone layout.** Nothing here was meant to change how a page sits on a phone. If a page
  now needs dragging sideways to read, please report it.
