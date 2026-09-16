---
title: Comprehensive source features
tags:
  - layout
  - regression
---

# Extended mixed document

A **bold introduction** before render-only features.

- [ ] Unchecked task
- [x] Completed task

## Equations

Inline formula $x_1 + x_2$ inside a paragraph.

$$
\int_0^1 x^2\,dx
$$

```math
E = mc^2
```

After equations.

> [!NOTE]
> Note body with **strong text**.

> [!TIP]
> Tip body.

> [!IMPORTANT]
> Important body.

> [!WARNING]
> Warning body.

> [!CAUTION]
> Caution body.

After alerts.

A referenced [reference link][destination] and an autolink <https://example.com/path>.

![Reference picture][picture]

After reference image.

A footnote marker[^first] and a repeated footnote[^first].

<details>
<summary>Expandable summary</summary>
<p>Expanded HTML body with <strong>HTML emphasis</strong>.</p>
</details>

<p align="center"><img src="{{IMAGE}}" width="120" alt="Centered HTML image"></p>

<div dir="rtl">نص عربي داخل عنصر HTML.</div>

After raw HTML.

| Formatting | Example |
| --- | --- |
| Inline table styles | **bold cell**, *italic cell*, `codeCell` |
| Escaped pipe | left\|right |

```javascript
const finalValue = 42;
```

Final extended paragraph.

[destination]: https://example.com/reference "Reference title"
[picture]: {{IMAGE}}
[^first]: Footnote definition with **footnote emphasis**.
