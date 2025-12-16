// Simple table sorting and filtering
document.addEventListener('DOMContentLoaded', function() {
    const table = document.querySelector('.index-table');
    if (!table) return;

    const tbody = table.querySelector('tbody') || table;
    const headers = table.querySelectorAll('thead th');

    // Sorting
    headers.forEach((header, index) => {
        header.style.cursor = 'pointer';
        header.addEventListener('click', () => {
            const currentDir = header.getAttribute('data-sort-dir') || 'asc';
            const nextDir = currentDir === 'asc' ? 'desc' : 'asc';

            // Reset all headers
            headers.forEach(h => h.removeAttribute('data-sort-dir'));
            header.setAttribute('data-sort-dir', nextDir);

            sortTable(tbody, index, nextDir);
        });
    });

    // Filters
    const statusFilter = document.getElementById('statusFilter');
    const domainFilter = document.getElementById('domainFilter');

    function applyFilters() {
        const statusValue = (statusFilter?.value || 'all').toLowerCase();
        const domainValue = (domainFilter?.value || '').toLowerCase().trim();

        const rows = Array.from(tbody.querySelectorAll('tr'));
        rows.forEach(row => {
            const cells = row.cells;
            if (!cells || cells.length === 0) return;

            const domainText = (cells[0].textContent || '').toLowerCase();
            const statusClass = getStatusClass(cells[2]);

            const matchesStatus =
                statusValue === 'all' ||
                (statusValue === 'pass' && statusClass === 'status-ok') ||
                (statusValue === 'warn' && statusClass === 'status-warn') ||
                (statusValue === 'fail' && statusClass === 'status-fail');

            const matchesDomain =
                !domainValue || domainText.includes(domainValue);

            row.style.display = matchesStatus && matchesDomain ? '' : 'none';
        });
    }

    if (statusFilter) {
        statusFilter.addEventListener('change', applyFilters);
    }
    if (domainFilter) {
        domainFilter.addEventListener('input', applyFilters);
    }
});

function getStatusClass(cell) {
    if (!cell) return '';

    // Overall status column uses td.status-*
    if (cell.classList.contains('status-ok')) return 'status-ok';
    if (cell.classList.contains('status-warn')) return 'status-warn';
    if (cell.classList.contains('status-fail')) return 'status-fail';
    if (cell.classList.contains('status-info')) return 'status-info';

    // For other columns we might have a span.status-*
    const span = cell.querySelector('span.status-ok, span.status-warn, span.status-fail, span.status-info');
    if (!span) return '';

    if (span.classList.contains('status-ok')) return 'status-ok';
    if (span.classList.contains('status-warn')) return 'status-warn';
    if (span.classList.contains('status-fail')) return 'status-fail';
    if (span.classList.contains('status-info')) return 'status-info';

    return '';
}

function getStatusRank(cell) {
    const cls = getStatusClass(cell);
    switch (cls) {
        case 'status-fail': return 3;
        case 'status-warn': return 2;
        case 'status-ok': return 1;
        case 'status-info': return 0;
        default: return -1;
    }
}

function sortTable(tbody, columnIndex, direction) {
    const rows = Array.from(tbody.querySelectorAll('tr'));

    const sorted = rows.sort((a, b) => {
        const aCell = a.cells[columnIndex];
        const bCell = b.cells[columnIndex];

        // Prefer status-based ordering for status columns
        if (columnIndex >= 2 && columnIndex <= 7) {
            const aRank = getStatusRank(aCell);
            const bRank = getStatusRank(bCell);
            if (aRank !== bRank) {
                return direction === 'asc' ? aRank - bRank : bRank - aRank;
            }
        }

        // MX column: sort by numeric count at start of cell
        if (columnIndex === 1) {
            const aNum = parseInt((aCell?.textContent || '').trim().split(/\s+/)[0], 10) || 0;
            const bNum = parseInt((bCell?.textContent || '').trim().split(/\s+/)[0], 10) || 0;
            return direction === 'asc' ? aNum - bNum : bNum - aNum;
        }

        const aText = (aCell?.textContent || '').trim().toLowerCase();
        const bText = (bCell?.textContent || '').trim().toLowerCase();

        if (aText === bText) return 0;
        if (direction === 'asc') {
            return aText < bText ? -1 : 1;
        } else {
            return aText > bText ? -1 : 1;
        }
    });

    sorted.forEach(row => tbody.appendChild(row));
}

