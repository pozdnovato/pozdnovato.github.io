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

check('full title uses the explicit Title field when set', failures) do
  build_full_title('Character Illustration System', 'Character Illustration System for Tempo Software') ==
    'Character Illustration System for Tempo Software'
end

check('full title falls back to the plain name when Title is blank', failures) do
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

# ---- /about page -------------------------------------------------------------

def about_row(name, link)
  {
    'properties' => {
      'Name' => { 'type' => 'title', 'title' => [{ 'plain_text' => name }] },
      'Link' => { 'type' => 'rich_text', 'rich_text' => link ? [{ 'plain_text' => link }] : [] }
    }
  }
end

cards = about_cards_from_rows([
                                about_row('Portfolio', 'https://pozdnovato.com/'),
                                about_row('Email', 'mailto:me@example.com'),
                                about_row('Draft with no link', nil),
                                about_row('', 'https://example.com/no-label')
                              ])

check('about cards keep complete rows in order and skip half-filled drafts', failures) do
  cards.map { |c| c[:label] } == %w[Portfolio Email]
end

check('about cards flag mailto links so they skip target=_blank', failures) do
  cards.map { |c| c[:mailto] } == [false, true]
end

check('about.html.erb renders cards, escapes text, and has no home-page links', failures) do
  html = render('about.html.erb', {
                   name: 'Test Person',
                   bio_paragraphs: ['Bio line.'],
                   cards: [{ label: 'Q&A <live>', url: 'https://x.com/?a=1&b=2', mailto: false },
                           { label: 'Email', url: 'mailto:x@example.com', mailto: true }]
                 })
  html.include?('class="about-link reveal"') &&
    html.include?('Q&amp;A &lt;live&gt;') &&
    html.include?('href="https://x.com/?a=1&amp;b=2"') &&
    html.include?('Bio line.') &&
    html.scan('target="_blank" rel="noopener"').length == 1 &&
    !html.include?('project-card')
end

check('index template output is unchanged by the about feature (no link to /about, no age gate)', failures) do
  html = render('index.html.erb', { name: 'T', bio_paragraphs: [], links: [], projects: [] })
  !html.include?('about') && !html.include?('age-gate')
end

check('paragraphs_html keeps only non-empty paragraphs, with inline formatting', failures) do
  blocks = [
    block('paragraph', { 'rich_text' => [rt('First '), rt('bold', bold: true)] }),
    block('heading_3', { 'rich_text' => [rt('ignored')] }),
    block('paragraph', { 'rich_text' => [] }),
    block('paragraph', { 'rich_text' => [rt('Second')] })
  ]
  paragraphs_html(blocks) == ['First <strong>bold</strong>', 'Second']
end

check('about page carries the 18+ gate wired to its script', failures) do
  html = render('about.html.erb', { name: 'T', bio_paragraphs: ['d'], cards: [] })
  html.include?('class="has-age-gate"') &&
    html.include?('src="/assets/js/age-gate.js"') &&
    html.include?('id="age-gate"') &&
    html.include?('data-age-yes') && html.include?('data-age-no') &&
    html.include?('data-age-denied hidden')
end

check('about page omits the description block when there is no description', failures) do
  html = render('about.html.erb', { name: 'T', bio_paragraphs: [], cards: [] })
  !html.include?('class="bio')
end

puts
if failures.empty?
  puts "All checks passed."
else
  puts "#{failures.length} check(s) failed:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
