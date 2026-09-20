#!/usr/bin/env ruby
# Offline smoke test for sync_notion.rb's block-conversion and rendering
# logic, using synthetic Notion API shapes instead of a real workspace.
# Run with: ruby scripts/test_sync_notion.rb

require_relative 'sync_notion'

failures = []

def check(desc, failures)
  yield ? (print '.') : (failures << desc)
rescue StandardError => e
  failures << "#{desc} raised #{e.class}: #{e.message}"
end

def rt(text, opts = {})
  { 'plain_text' => text, 'href' => opts[:href], 'annotations' => { 'bold' => !!opts[:bold], 'italic' => !!opts[:italic] } }
end

# ---- rich_text_to_html ------------------------------------------------------

check('plain text passes through escaped', failures) do
  rich_text_to_html([rt('A & B')]) == 'A &amp; B'
end

check('italic wraps in <em>', failures) do
  rich_text_to_html([rt('word', italic: true)]) == '<em>word</em>'
end

check('link wraps in <a href>', failures) do
  rich_text_to_html([rt('click', href: 'https://x.com')]) == '<a href="https://x.com">click</a>'
end

# ---- slugify ----------------------------------------------------------------

check('slugify lowercases and hyphenates', failures) do
  slugify('A Self-Serve Color System!') == 'a-self-serve-color-system'
end

# ---- build_full_title --------------------------------------------------------

check('full title combines card title and meta with "for a"', failures) do
  build_full_title('A Character Illustration System', 'Tempo Software') ==
    'A Character Illustration System for a Tempo Software'
end

check('full title falls back to the plain name when meta is blank', failures) do
  build_full_title('Industrial Site Navigation', '') == 'Industrial Site Navigation' &&
    build_full_title('Industrial Site Navigation', nil) == 'Industrial Site Navigation'
end

# ---- build_case_structure ----------------------------------------------------

def block(type, data)
  { 'id' => "id-#{rand(1_000_000)}", 'type' => type, type => data }
end

# stub network image download so the test runs fully offline
def download_image(_url, stable_key)
  "/assets/images/notion-#{stable_key}.webp"
end

blocks = [
  block('paragraph', { 'rich_text' => [rt('Intro paragraph one.')] }),
  block('paragraph', { 'rich_text' => [rt('Intro paragraph two.')] }),
  block('heading_3', { 'rich_text' => [rt('Task')] }),
  block('paragraph', { 'rich_text' => [rt('Task body.')] }),
  block('image', { 'type' => 'external', 'external' => { 'url' => 'https://example.com/a.png' }, 'caption' => [rt('A caption')] }),
  block('heading_3', { 'rich_text' => [rt('Process')] }),
  block('paragraph', { 'rich_text' => [rt('Process body one.')] }),
  block('paragraph', { 'rich_text' => [rt('Process body two.')] }),
  block('image', { 'type' => 'external', 'external' => { 'url' => 'https://example.com/b.png' }, 'caption' => [] }),
  block('paragraph', { 'rich_text' => [rt('Untitled trailing section.')] })
]

structure = build_case_structure(blocks, 'test-slug')

check('intro has exactly the 2 leading paragraphs', failures) do
  structure[:intro] == ['Intro paragraph one.', 'Intro paragraph two.']
end

check('produces 5 body blocks in order: section, figure, section, figure, section', failures) do
  structure[:blocks].map { |b| b[:type] } == %i[section figure section figure section]
end

check('Task section has the right label and paragraph', failures) do
  s = structure[:blocks][0]
  s[:label] == 'Task' && s[:paragraphs] == ['Task body.']
end

check('first figure carries its caption', failures) do
  structure[:blocks][1][:caption] == 'A caption'
end

check('second figure with empty caption array yields empty string caption', failures) do
  structure[:blocks][3][:caption] == ''
end

check('Process section groups both paragraphs under one label', failures) do
  s = structure[:blocks][2]
  s[:label] == 'Process' && s[:paragraphs] == ['Process body one.', 'Process body two.']
end

check('trailing paragraph with no heading becomes an unlabeled section', failures) do
  s = structure[:blocks][4]
  s[:label].nil? && s[:paragraphs] == ['Untitled trailing section.']
end

# ---- template rendering (smoke test: no exceptions, key strings present) ---

check('index.html.erb renders without error and includes name/links/projects', failures) do
  html = render('index.html.erb', {
                   name: 'Test Person',
                   bio_paragraphs: ['Bio line one.'],
                   links: [{ label: 'Email', url: 'mailto:x@example.com', mailto: true },
                           { label: 'LinkedIn', url: 'https://linkedin.com/x', mailto: false }],
                   projects: [{ slug: 'proj-a', title: 'Project A', meta: 'Client A', thumb: '/assets/images/a.webp' }]
                 })
  html.include?('Test Person') &&
    html.include?('Bio line one.') &&
    html.include?('mailto:x@example.com') &&
    html.include?('target="_blank" rel="noopener"') && # on LinkedIn, not on mailto
    html.include?('/proj-a.html') &&
    html.include?('Project A')
end

check('project.html.erb renders full structure and more-projects list', failures) do
  html = render('project.html.erb', {
                   title: 'Project A',
                   description: 'A short description.',
                   intro_paragraphs: ['Intro text.'],
                   blocks: structure[:blocks],
                   other_projects: [{ slug: 'proj-b', title: 'Project B' }]
                 })
  html.include?('Project A') &&
    html.include?('A short description.') &&
    html.include?('Intro text.') &&
    html.include?('class="section-label">Task<') &&
    html.include?('class="case-caption">A caption<') &&
    html.include?('/proj-b.html') &&
    html.include?('Project B') &&
    html.include?('Back home') &&
    html.include?('Back to top')
end

check('project.html.erb omits the description meta tag when blank', failures) do
  html = render('project.html.erb', {
                   title: 'Project A', description: '', intro_paragraphs: [], blocks: [], other_projects: []
                 })
  !html.include?('name="description"')
end

puts
if failures.empty?
  puts "All checks passed."
else
  puts "#{failures.length} check(s) failed:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
