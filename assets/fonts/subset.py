#!/usr/bin/env python3
# assets/fonts/subset.py
#
# 把对外单据 PDF 用到的【两个字体家族】各裁成真正用得到的那一小块,并顺带产出
# coverage.json(字符覆盖清单,**逐家族记录**)。仓库里【只提交裁剪后的
# .subset.ttf 和 coverage.json】—— 完整字重 Noto 每个 10 MB、Google Sans 每个
# 1.9 MB,进了 git history 就是每次 clone 都要拖、每次冷启动都要解析,不可接受。
#
# ─────────────────────────────────────────────────────────────────────────────
# ★ 两个家族,一个字体栈(PDF-1,2026-09-02)★
# ─────────────────────────────────────────────────────────────────────────────
# Tim 的 R2:正文与数字用 Google Sans,中文用既有的中文字体,**按字符选**。
# 落地成 react-pdf 的一个字体栈:fontFamily: ['Google Sans', 'Noto Sans SC']。
# 排版引擎(@react-pdf/textkit 的 pickFontFromFontStack)对【每一个码位】依次问
# hasGlyphForCodePoint,取第一个画得出来的 —— 所以拉丁与数字落在 Google Sans,
# 汉字落在 Noto Sans SC,同一行里混排也成立(实测见 docs/pdf-documents.md)。
#
# 【Google Sans 没有中文】实测它服务端下发的 TTF:3281 个码位,CJK 统一表意文字
# 一个都没有。这不是"暂时没配",是这个家族的覆盖范围。所以中文字体不是可选项。
#
# 【许可】Google Sans 是 OFL-1.1、OS/2.fsType = 0(Installable Embedding)、
# 且【没有保留字体名】(googlefonts/googlesans 的 TRADEMARKS.txt 明说)——
# 所以既可以内嵌进对外分发的 PDF,也可以像这里一样裁剪后沿用原名。
# 四份出处写在 docs/pdf-documents.md,不要凭印象复述。
#
# ★【Noto 这一侧的覆盖范围【刻意一个码位都没动】】★
# 于是【字体栈能印的字符集合 = 改造前 Noto 单独能印的集合】,一个字符都没多、
# 没少 —— 变的只是【哪个字体来画】。这条性质让本次改造对"这份单据印得出什么"
# 是中性的,而那正是 R3(不许改变单据说了什么)要的。
#
# ─────────────────────────────────────────────────────────────────────────────
# 覆盖范围(要扩就改下面 FAMILIES 里对应的 ranges,然后重跑本脚本)
# ─────────────────────────────────────────────────────────────────────────────
# 【Google Sans】只要拉丁那一段 —— 它另外还带 25 个书写系统(亚美尼亚、孟加拉、
#   天城体…),这套系统一个都不印,白占体积:
#   U+0020–007E   Basic Latin(可打印)—— 英文正文、数字、$、单据编号
#   U+00A0–00FF   Latin-1 Supplement —— é/ü 之类的人名地名,以及 £ ¢ ¥
#   U+2000–206F   General Punctuation —— 破折号 —(U+2014,PDF 里的空值占位符)
#
# 【Noto Sans SC】上面三段【照留】(见上文那条中性性质),再加中文:
#   U+3000–303F   CJK Symbols and Punctuation —— 全角句号、顿号、书名号
#   U+FF00–FFEF   Halfwidth and Fullwidth Forms —— 全角逗号/冒号/括号/数字
#   GB2312 一级+二级汉字(6763 字)—— 简体常用字全集
#
# 【刻意不含】U+20A0–20CF Currency Symbols(€ 在这里)。单据金额只印币种代码
# ("1,234.56 USD"),不印符号;真要支持备注里手打的 €,把 (0x20A0, 0x20CF)
# 加进【两个家族】的 ranges 重跑即可 —— 只加一边会让那个字符换个字体画,
# 而那正是本文件要人看得见的东西。
#
# 【刻意不含】繁体字。新加坡和大陆的交易对手都用简体。哪天真出现繁体交易对手,
# 换成 Noto Sans HK 或 Noto Sans TC —— 是【换源文件 + 重跑本脚本】,不是改代码:
# 把 FAMILIES 里的文件名换掉,并把 gb2312 那段换成 Big5 或直接放宽成整个
# CJK 统一表意文字区。字体家族名和注册逻辑都不用动。
#
# ─────────────────────────────────────────────────────────────────────────────
# 怎么重跑
# ─────────────────────────────────────────────────────────────────────────────
#   1) 拿到完整字重(仓库里没有,故意的,见 .gitignore):
#        Noto Sans SC → https://fonts.google.com/noto/specimen/Noto+Sans+SC
#          取 NotoSansSC-Regular.ttf 与 NotoSansSC-Bold.ttf
#          (本次裁剪用的是 Version 2.004-H2,30890 个码位 / 30796 个字形)
#        Google Sans  → https://fonts.google.com/specimen/Google+Sans
#          取 400 与 700 两个静态字重,存成 GoogleSans-Regular.ttf /
#          GoogleSans-Bold.ttf(本次用的是 Version 13.002,3281 个码位)
#   2) 放到本目录(assets/fonts/),或用 --src-dir 指到别处
#   3) pip install fonttools
#   4) python3 assets/fonts/subset.py
#
# 产出(这五个才是提交进仓库的东西):
#   GoogleSans-Regular.subset.ttf   GoogleSans-Bold.subset.ttf
#   NotoSansSC-Regular.subset.ttf   NotoSansSC-Bold.subset.ttf
#   coverage.json
#
# coverage.json 是【从裁剪结果的 cmap 反读出来的】,不是从上面的意图清单生成的
# —— 源字体里没有的码位不会被算进覆盖范围,免得清单比字体本身还乐观。运行时的
# 守卫读这份清单来判断"这个字这个栈印不印得出来",所以它必须和 .subset.ttf
# 同一次生成。**这正是对账单那个缺陷的反面**:那里守卫查的是 Noto 的覆盖,
# 文档嵌的却是 Helvetica —— 两份各自维护的东西迟早说的不是同一件事。

import argparse
import json
import sys
import unicodedata
from pathlib import Path

try:
    from fontTools.subset import Subsetter, Options
    from fontTools.ttLib import TTFont
except ImportError:
    sys.exit("需要 fonttools:  pip install fonttools")

HERE = Path(__file__).resolve().parent

# 拉丁那三段是【两个家族共有】的 —— 见抬头那条"中性性质"。
LATIN_RANGES = [
    (0x0020, 0x007E),  # Basic Latin(可打印)
    (0x00A0, 0x00FF),  # Latin-1 Supplement
    (0x2000, 0x206F),  # General Punctuation
]

# 见上方"覆盖范围"注释。改这里 = 扩大/缩小覆盖,改完重跑本脚本。
#
# ★ 顺序【就是字体栈的顺序】★ —— 排版引擎按这个次序逐字问"你画得出来吗",
#   所以 Google Sans 必须排在前面,否则拉丁字母会被中文字体画走。
#   app/components/pdf/fonts.ts 从 coverage.json 读这个顺序注册,两边不可能不一致。
FAMILIES = [
    {
        "family": "Google Sans",
        "role": "latin",
        "source": "Google Sans Version 13.002",
        "weights": [
            ("GoogleSans-Regular.ttf", "GoogleSans-Regular.subset.ttf", "normal"),
            ("GoogleSans-Bold.ttf", "GoogleSans-Bold.subset.ttf", "bold"),
        ],
        "ranges": LATIN_RANGES,
        "hanzi": False,
    },
    {
        "family": "Noto Sans SC",
        "role": "cjk",
        "source": "Noto Sans SC Version 2.004-H2",
        "weights": [
            ("NotoSansSC-Regular.ttf", "NotoSansSC-Regular.subset.ttf", "normal"),
            ("NotoSansSC-Bold.ttf", "NotoSansSC-Bold.subset.ttf", "bold"),
        ],
        "ranges": LATIN_RANGES + [
            (0x3000, 0x303F),  # CJK Symbols and Punctuation
            (0xFF00, 0xFFEF),  # Halfwidth and Fullwidth Forms
        ],
        "hanzi": True,
    },
]


def gb2312_hanzi() -> set:
    """GB2312 一级(区 16–55)+ 二级(区 56–87)汉字,共 6763 字。

    用 Python 自带的 gb2312 编解码器【算】出来,而不是硬编码一份 6763 字的表 ——
    表会抄错、会腐烂,而这段代码任何人都能一眼验证。区 55(高位 0xD7)末尾有 5 个
    空位,解码失败直接跳过,所以是 6763 而不是 40*94 + 32*94 = 6768。
    """
    out = set()
    for hi in range(0xB0, 0xF8):  # 区 16–87
        for lo in range(0xA1, 0xFF):  # 位 1–94
            try:
                ch = bytes([hi, lo]).decode("gb2312")
            except UnicodeDecodeError:
                continue  # 空位
            out.add(ord(ch))
    return out


def wanted_codepoints(fam: dict) -> set:
    """这个家族【打算】覆盖哪些码位。实际覆盖以裁剪结果的 cmap 为准(见 main)。"""
    cps = set()
    for lo, hi in fam["ranges"]:
        cps.update(range(lo, hi + 1))
    if fam["hanzi"]:
        cps |= gb2312_hanzi()
    return cps - FORMAT_CONTROLS


def format_controls() -> set:
    """Unicode 类别 Cf(格式控制字符)—— 【一律不收进任何一个家族】。

    ★ 为什么单独排除,而不是让区间自然带进来(PDF-1,2026-09-02)★
    加进 Google Sans 之后,栈的可印字符集比改造前【多了 28 个】,而那 28 个全在
    U+2000–206F 里 —— Noto 的裁剪结果碰巧没有它们,Google Sans 有。其中 14 个是
    看不见的格式控制符,包括:

        U+200B–200F  零宽空格 / 零宽连接符 / 左右向标记
        U+202A–202E  双向嵌入与【覆盖】(RIGHT-TO-LEFT OVERRIDE 在这里)
        U+2066–2069  双向隔离

    **U+202E 能让一段文字在阅读器里【反着显示】。** 一张寄给客户的发票、一份交给
    审计师的报告,不该因为本刀换了字体就多出这个能力 —— 改造前守卫会拒掉带这种
    字符的单据,改造后就不会了,而那是一个【没有人要求过的放宽】。

    所以两个家族都不收 Cf。于是这一栏的实际结果是:
      * 改造前印得出来的字符,**一个不少**(Noto 那 7276 个原样保留);
      * 新增的只有 14 个【看得见的】空格与标点(各种宽度的空格、‱ ⁃ ⁄ ⁎ ⁕);
      * 看不见的控制符,守卫继续拒绝 —— 与改造前一致。

    用 unicodedata 【算】出来,不硬编码一张表:表会抄错、会随 Unicode 版本腐烂,
    而这三行任何人都能一眼验证(与 gb2312_hanzi() 同一条理由)。
    """
    out = set()
    for lo, hi in LATIN_RANGES + [(0x3000, 0x303F), (0xFF00, 0xFFEF)]:
        for cp in range(lo, hi + 1):
            if unicodedata.category(chr(cp)) == "Cf":
                out.add(cp)
    # ★【U+00AD SOFT HYPHEN 是这条规则的例外,而它是量出来的,不是想出来的】★
    # 排除 Cf 的第一版把它一起排掉了,于是覆盖清单从 7276 掉到 7275 —— 一个
    # 【改造前印得出来、改造后被守卫拒掉】的字符。那是本刀造成的收窄,不是清理。
    # 两条理由让它必须留下:
    #   ① react-pdf 的排版引擎【本来就不给它取字形】—— @react-pdf/textkit 的
    #      pickFontFromFontStack 里 IGNORED_CODE_POINTS = [173],遇到它直接沿用
    #      上一个字体。也就是说它有没有字形对渲染毫无影响;
    #   ② 它今天就在覆盖清单里,含它的单据今天渲染正常。守卫拒掉一份能正常渲染的
    #      单据,是"一个永远不可能被满足的判据"的另一种形状。
    # 它也不是双向控制符,印不出反向文字 —— 排除 Cf 要防的是那一类。
    out.discard(0x00AD)
    return out


FORMAT_CONTROLS = format_controls()


def to_ranges(codepoints) -> list:
    """把码位集合压成 [[start, end], ...],让 coverage.json 小一点、也好读一点。"""
    ranges = []
    for cp in sorted(codepoints):
        if ranges and cp == ranges[-1][1] + 1:
            ranges[-1][1] = cp
        else:
            ranges.append([cp, cp])
    return ranges


def main() -> int:
    ap = argparse.ArgumentParser(description="裁剪对外单据 PDF 用的两个字体家族")
    ap.add_argument(
        "--src-dir",
        type=Path,
        default=HERE,
        help="完整字重所在目录(默认:本脚本所在目录)",
    )
    ap.add_argument("--out-dir", type=Path, default=HERE, help="输出目录(默认:同上)")
    args = ap.parse_args()

    # 先把【所有】家族的源文件查一遍再动手 —— 裁到一半才发现缺文件,留下的是一组
    # 半新半旧的 .subset.ttf 配一份说的是新范围的 coverage.json,而那正是本脚本
    # 存在的理由(清单必须和字节同一次产出)。
    missing = [
        str(args.src_dir / src)
        for fam in FAMILIES
        for src, _, _ in fam["weights"]
        if not (args.src_dir / src).is_file()
    ]
    if missing:
        print("\n找不到源字体:", file=sys.stderr)
        for m in missing:
            print(f"  {m}", file=sys.stderr)
        print("下载方式见本文件头部注释。", file=sys.stderr)
        return 1

    args.out_dir.mkdir(parents=True, exist_ok=True)
    hanzi_count = len(gb2312_hanzi())
    manifest_families = []

    for fam in FAMILIES:
        wanted = wanted_codepoints(fam)
        extra = f",其中 GB2312 一级+二级汉字 {hanzi_count} 字" if fam["hanzi"] else ""
        print(f'{fam["family"]}(目标 {len(wanted)} 个码位{extra})')

        per_weight_cmaps = []
        for src_name, out_name, _weight in fam["weights"]:
            src = args.src_dir / src_name
            out = args.out_dir / out_name

            opts = Options()
            opts.drop_tables += ["DSIG"]
            # 保留 .notdef 的方框轮廓:万一守卫哪天被绕过去了,印出"豆腐块"也好过
            # 印出一片空白 —— 至少人眼能看见出事了。
            opts.notdef_outline = True
            # PDF 是矢量输出、由阅读器自己栅格化,hinting 数据用不上,白占体积。
            opts.hinting = False
            opts.desubroutinize = False
            opts.recalc_bounds = True
            opts.name_IDs = ["*"]  # 留住字体名,PDF 里的字体标识才是可读的
            opts.name_legacy = True
            opts.legacy_kern = False

            font = TTFont(src)
            before = src.stat().st_size

            subsetter = Subsetter(options=opts)
            subsetter.populate(unicodes=wanted)
            subsetter.subset(font)
            font.save(out)
            font.close()

            after = out.stat().st_size
            with TTFont(out, lazy=True) as check:
                cmap = set(check.getBestCmap().keys())
                glyphs = check["maxp"].numGlyphs
                # ★ 许可与内嵌位随字节一起复核 ★ —— 这两个数决定"这份字体能不能
                #   内嵌进一份【对外分发】的 PDF"。裁剪会重写字体文件,所以在裁剪
                #   结果上再读一遍,而不是相信源文件读到的那次。
                #   fsType 0 = Installable Embedding(无限制);2 = 禁止内嵌。
                fs_type = check["OS/2"].fsType
            if fs_type not in (0, 8):  # 0 无限制;8 = Editable(仍允许内嵌)
                print(
                    f"\n  ✗ {out_name} 的 OS/2.fsType = {fs_type} —— 【不允许内嵌】。"
                    f"\n    这些 PDF 会寄给客户与审计师,属于分发。停下来,不要换字体蒙混过去。",
                    file=sys.stderr,
                )
                return 2
            per_weight_cmaps.append(cmap)

            pct = 100.0 * after / before
            print(
                f"  {src_name:26s} {before / 1e6:6.2f} MB  →  "
                f"{out_name:33s} {after / 1e6:5.2f} MB  ({pct:.1f}%)  "
                f"{glyphs} 字形 / {len(cmap)} 码位  fsType={fs_type}"
            )

        # 覆盖清单取【这个家族两个字重的交集】—— 只有正常体和粗体都画得出来的字,
        # 才算这个家族能印。任何一个字重缺字,那个字就该落到栈里的下一个家族去。
        covered = set.intersection(*per_weight_cmaps)
        only_one = set.union(*per_weight_cmaps) - covered
        if only_one:
            print(f"  注意:{len(only_one)} 个码位只有单个字重有,已排除在本家族覆盖外")

        manifest_families.append(
            {
                "family": fam["family"],
                "role": fam["role"],
                "source": fam["source"],
                "files": [out for _, out, _ in fam["weights"]],
                "weights": [w for _, _, w in fam["weights"]],
                "codepointCount": len(covered),
                "ranges": to_ranges(covered),
            }
        )

    # ★ 栈的覆盖 = 各家族的【并集】★
    # 守卫要回答的是"这份文档【嵌进去的这一组字体】画得出这个字吗",而文档嵌的
    # 是整个栈 —— 所以判据是并集,不是某一个家族。
    union = set()
    for f, mf in zip(FAMILIES, manifest_families):
        for lo, hi in mf["ranges"]:
            union.update(range(lo, hi + 1))

    manifest = {
        "_comment": (
            "自动生成,请勿手改。由 assets/fonts/subset.py 在裁剪字体的同一次运行中"
            "从裁剪结果的 cmap 反读产出。stack 的顺序就是 react-pdf 字体栈的顺序;"
            "顶层 ranges 是各家族的并集,即【这个栈】印得出来的字符集合,"
            "守卫查的就是它。要扩大覆盖:改脚本里的 FAMILIES[].ranges 后重跑。"
        ),
        "stack": [f["family"] for f in FAMILIES],
        "families": manifest_families,
        "codepointCount": len(union),
        # [start, end] 闭区间,按起点升序 —— 运行时用二分查找
        "ranges": to_ranges(union),
    }
    manifest_path = args.out_dir / "coverage.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(
        f"  coverage.json  {manifest_path.stat().st_size / 1024:5.1f} KB  "
        f"(栈共 {len(union)} 码位 / {len(manifest['ranges'])} 个区间;"
        + " + ".join(f'{m["family"]} {m["codepointCount"]}' for m in manifest_families)
        + ")"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
