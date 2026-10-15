# Math in edit mode

Click a formula to edit its LaTeX source, then move the caret outside it to render it again. Try deleting and restoring a closing delimiter, undo/redo, Find, and copying source.

## Inline

Energy is $E = mc^2$, and a fraction is $\frac{a_1 + b_2}{c^2}$. Text before and after a formula should remain editable.

## Display

$$ \sum_{i=1}^{n} i = \frac{n(n+1)}{2} $$

$$
\begin{aligned}
a &= b + c \\

x &= y^2
\end{aligned}
$$

## Fenced math

```math
\int_0^1 x^2\,dx = \frac{1}{3}
```

## Lists, quotes, and tables

- Inline formula: $a^2 + b^2 = c^2$.

> $$
> x = \sqrt{y}
> $$

| Name | Formula |
| --- | --- |
| Area | $\pi r^2$ |

## Literal text and errors

Prices: $5 and $10. Escaped dollar: \$x$.

Inline code: `$x^2$` and `$$x^2$$`.

```text
$x^2$
$$x^2$$
```

An invalid command should show an error without changing the saved source: $\notARealCommand{x}$.

An unfinished inline expression remains source: $x_1 + x_2

## RTL

משוואות Inline צריכות לעבוד גם ב-`RTL`: $f(x)=x^2$.

## Unfinished display block

The final block deliberately has no closing delimiter. Its source and all following text must stay visible and editable. Add a closing delimiter on its own line to finish it.



$$
x^2 + y^2 = z^2
