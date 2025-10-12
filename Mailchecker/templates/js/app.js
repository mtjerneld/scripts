// Simple table sorting and filtering
document.addEventListener('DOMContentLoaded', function() {
    // Add sorting to index table if it exists
    const table = document.querySelector('table');
    if (!table) return;
    
    const headers = table.querySelectorAll('th');
    headers.forEach((header, index) => {
        header.style.cursor = 'pointer';
        header.addEventListener('click', () => sortTable(index));
    });
});

function sortTable(columnIndex) {
    const table = document.querySelector('table');
    const tbody = table.querySelector('tbody') || table;
    const rows = Array.from(tbody.querySelectorAll('tr')).slice(1); // Skip header
    
    const sorted = rows.sort((a, b) => {
        const aText = a.cells[columnIndex]?.textContent.trim() || '';
        const bText = b.cells[columnIndex]?.textContent.trim() || '';
        return aText.localeCompare(bText);
    });
    
    sorted.forEach(row => tbody.appendChild(row));
}

function filterTable(status) {
    const table = document.querySelector('table');
    const rows = table.querySelectorAll('tr');
    
    rows.forEach((row, index) => {
        if (index === 0) return; // Skip header
        
        if (status === 'all') {
            row.style.display = '';
        } else {
            const statusCell = row.cells[1]?.textContent.trim();
            row.style.display = statusCell.includes(status.toUpperCase()) ? '' : 'none';
        }
    });
}

