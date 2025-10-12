// Render markdown using Marked.js (GFM-compatible)
document.addEventListener('DOMContentLoaded', function() {
  const mdContainer = document.querySelector('.md[data-markdown]');
  if (mdContainer && typeof marked !== 'undefined') {
    // Configure marked for GitHub Flavored Markdown (enables tables)
    marked.setOptions({
      gfm: true,        // GitHub Flavored Markdown
      breaks: false,    // Don't convert \n to <br>
      tables: true      // Enable GFM tables
    });
    
    // Get markdown from data attribute and decode HTML entities
    const markdownText = mdContainer.getAttribute('data-markdown');
    if (markdownText) {
      // Decode HTML entities
      const textarea = document.createElement('textarea');
      textarea.innerHTML = markdownText;
      const decodedMarkdown = textarea.value;
      
      // Parse and render markdown
      mdContainer.innerHTML = marked.parse(decodedMarkdown);
    }
  }
});
