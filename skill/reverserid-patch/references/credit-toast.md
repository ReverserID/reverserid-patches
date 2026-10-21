# Styled "Patched by ReverserID" credit toast

Every reverser.id patch MUST add a launch credit toast — and it must be
**styled**, never a plain `Toast.makeText(...)`. Build the toast view
**programmatically** (no layout/resource files): on-device builds have no aapt2,
so a rule that references a new `R.layout`/`R.drawable` cannot be packaged. A
code-built `TextView` + `GradientDrawable` needs zero resources and survives the
no-aapt2 pipeline.

## Where to inject

The first `onCreate` of the launcher Activity (see the manifest's
`category.LAUNCHER`), right after `super.onCreate`. Anchor on the method
signature, bump `.locals`, and use free registers.

## Recipe (self-contained, no resources)

A rounded dark pill with accent text, bottom-center, ~1.2s. Adjust register
numbers to free ones in the target method and raise `.locals` to cover them.

```smali
# p0 = Activity (Context). vN below are scratch registers you must free up.
    new-instance v0, Landroid/widget/TextView;
    invoke-direct {v0, p0}, Landroid/widget/TextView;-><init>(Landroid/content/Context;)V

    const-string v1, "\u2726  Patched by ReverserID"
    invoke-virtual {v0, v1}, Landroid/widget/TextView;->setText(Ljava/lang/CharSequence;)V

    const v1, -0x50506       # #FFFAFAFA near-white text
    invoke-virtual {v0, v1}, Landroid/widget/TextView;->setTextColor(I)V

    const/high16 v1, 0x41600000    # 14f text size (sp-ish)
    const/4 v2, 0x2                # TypedValue.COMPLEX_UNIT_SP
    invoke-virtual {v0, v2, v1}, Landroid/widget/TextView;->setTextSize(IF)V

    const/16 v1, 0x2c             # ~44px horizontal padding
    const/16 v2, 0x18             # ~24px vertical padding
    invoke-virtual {v0, v1, v2, v1, v2}, Landroid/widget/TextView;->setPadding(IIII)V

    # rounded dark background
    new-instance v3, Landroid/graphics/drawable/GradientDrawable;
    invoke-direct {v3}, Landroid/graphics/drawable/GradientDrawable;-><init>()V
    const v1, -0xd9d9da           # #FF262626 dark pill
    invoke-virtual {v3, v1}, Landroid/graphics/drawable/GradientDrawable;->setColor(I)V
    const/high16 v1, 0x42200000   # 40f corner radius
    invoke-virtual {v3, v1}, Landroid/graphics/drawable/GradientDrawable;->setCornerRadius(F)V
    const/4 v1, 0x2
    const v2, -0xa73f01           # accent stroke (reverser.id red-ish)
    invoke-virtual {v3, v1, v2}, Landroid/graphics/drawable/GradientDrawable;->setStroke(II)V
    invoke-virtual {v0, v3}, Landroid/widget/TextView;->setBackground(Landroid/graphics/drawable/Drawable;)V

    # toast with the custom view
    new-instance v1, Landroid/widget/Toast;
    invoke-direct {v1, p0}, Landroid/widget/Toast;-><init>(Landroid/content/Context;)V
    invoke-virtual {v1, v0}, Landroid/widget/Toast;->setView(Landroid/view/View;)V
    const/4 v2, 0x1               # Toast.LENGTH_LONG
    invoke-virtual {v1, v2}, Landroid/widget/Toast;->setDuration(I)V
    const/16 v2, 0x51             # Gravity.BOTTOM | CENTER_HORIZONTAL
    const/4 v3, 0x0
    const/16 v4, 0x60             # ~96px y-offset
    invoke-virtual {v1, v2, v3, v4}, Landroid/widget/Toast;->setGravity(III)V
    invoke-virtual {v1}, Landroid/widget/Toast;->show()V
```

## As a `.rid` rule

Anchor on the onCreate prologue and inject the block after it, plus a second
rule that raises `.locals` to cover the scratch registers (e.g. 9 -> 14). Add a
`must: Patched by ReverserID` guard.

```
rule credit toast (styled)
file: smali/<launcher activity>.smali
count: 1
must: Patched by ReverserID
find <<<
(\.method public (?:final )?onCreate\(Landroid/os/Bundle;\)V\n    \.locals \d+\n\n    \.line 1\n)
<<<
replace <<<
$1    <the styled-toast block above>
<<<

rule credit toast locals
file: smali/<launcher activity>.smali
count: 1
find <<<
(\.method public (?:final )?onCreate\(Landroid/os/Bundle;\)V\n)    \.locals 9
<<<
replace <<<
$1    .locals 14
<<<
```

## Caveats

- `setView`/custom-view toasts are deprecated on API 30+ but still render for a
  foreground app launched from its own Activity (our case); if a target is API
  30+ and the toast does not show, fall back to `Toast.makeText` with a
  `SpannableString` (bold + color) — still styled, not plain text.
- Registers are the #1 failure: a wrong `vN` or too-low `.locals` is a
  `VerifyError` at launch. Verify per `references/verify.md` (launch, see the
  styled toast, no crash).
