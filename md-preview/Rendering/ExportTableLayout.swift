nonisolated enum ExportTableLayout {
    static let prepareScript = #"""
    window.__mdRestoreExportTables?.();
    const article = document.querySelector('article.markdown-body');
    if (!article) return;

    const tolerance = 0.5;
    const number = value => parseFloat(value) || 0;
    const styles = new Map();
    const remember = element => styles.set(element, element.getAttribute('style'));
    window.__mdRestoreExportTables = () => styles.forEach((style, element) => {
        if (style === null) element.removeAttribute('style');
        else element.setAttribute('style', style);
    });

    function contentWidth(element) {
        const style = getComputedStyle(element);
        return element.getBoundingClientRect().width
            - number(style.paddingLeft) - number(style.paddingRight)
            - number(style.borderLeftWidth) - number(style.borderRightWidth);
    }

    function columnCount(table) {
        let count = 0;
        let group;
        let occupied = [];
        Array.from(table.rows).forEach(row => {
            if (row.parentElement !== group) {
                group = row.parentElement;
                occupied = [];
            }
            let column = 0;
            for (const cell of row.cells) {
                while (occupied[column] > 0) column++;
                const rows = cell.rowSpan || group.rows.length;
                for (let offset = 0; offset < cell.colSpan; offset++) {
                    occupied[column + offset] = rows;
                }
                column += cell.colSpan;
                count = Math.max(count, column);
            }
            occupied = occupied.map(rows => rows - 1);
        });
        return count;
    }

    function minimumWidths(cells, overflowWrap) {
        const probes = cells.map(cell => {
            const measure = cell.cloneNode(true);
            Object.assign(measure.style, {
                position: 'absolute', display: 'inline-block', visibility: 'hidden',
                width: 'min-content', minWidth: '0', maxWidth: 'none', overflowWrap
            });
            cell.append(measure);
            return measure;
        });
        const widths = probes.map(measure => measure.getBoundingClientRect().width);
        probes.forEach(measure => measure.remove());
        return widths;
    }

    const articleWidth = contentWidth(article);
    Array.from(article.querySelectorAll('table')).reverse().forEach(table => {
        if (table.closest('.md-frontmatter')) return;
        const available = Math.min(contentWidth(table.parentElement), articleWidth);
        const columns = columnCount(table);
        if (available <= 0 || columns === 0) return;

        remember(table);
        Object.assign(table.style, {
            display: 'table', tableLayout: 'auto', width: 'min-content',
            maxWidth: 'none', alignSelf: 'flex-start', overflow: 'visible'
        });
        const cells = Array.from(table.rows).flatMap(row => Array.from(row.cells));
        cells.forEach(cell => {
            remember(cell);
            cell.style.overflowWrap = 'normal';
        });
        const widths = minimumWidths(cells, 'normal');
        const oversized = cells.filter((cell, index) => widths[index] > available + tolerance);
        const wrappedWidths = minimumWidths(oversized, 'anywhere');
        oversized.forEach((cell, index) => {
            cell.style.maxWidth = wrappedWidths[index] + 'px';
            cell.style.overflowWrap = 'break-word';
        });
        // Reserve the columns' minimum widths before sharing the remaining space.
        const minimumTableWidth = table.getBoundingClientRect().width;
        const minimumCellWidths = oversized.map(cell => cell.getBoundingClientRect().width);
        oversized.forEach((cell, index) => {
            const minimum = minimumCellWidths[index];
            const share = available * cell.colSpan / columns;
            const remaining = available - minimumTableWidth + minimum;
            cell.style.maxWidth = Math.max(minimum, Math.min(share, remaining)) + 'px';
        });

        table.style.width = 'auto';
        const rect = table.getBoundingClientRect();
        // Nested tables scale with their outer table.
        if (table.parentElement.closest('table') || rect.width <= available + tolerance) return;
        const scale = available / rect.width;
        const style = getComputedStyle(table);
        table.style.width = rect.width + 'px';
        table.style.transformOrigin = style.direction === 'rtl' ? 'top right' : 'top left';
        table.style.transform = 'scale(' + scale + ')';
        // Transforms leave the table's original height in normal flow.
        table.style.marginBottom = (number(style.marginBottom) + rect.height * (scale - 1)) + 'px';
    });
    """#
}
