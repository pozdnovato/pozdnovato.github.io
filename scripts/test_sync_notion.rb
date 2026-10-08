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

def about_row(name, link, color = nil)
  props = {
    'Name' => { 'type' => 'title', 'title' => [{ 'plain_text' => name }] },
    'Link' => { 'type' => 'rich_text', 'rich_text' => link ? [{ 'plain_text' => link }] : [] }
  }
  props['Color'] = { 'type' => 'rich_text', 'rich_text' => [{ 'plain_text' => color }] } if color
  { 'properties' => props }
end

# ---- card colors ------------------------------------------------------------

require 'stringio'

# Runs the block with $stdout/$stderr captured; returns [stdout, stderr].
def capture_streams
  old_out = $stdout
  old_err = $stderr
  $stdout = StringIO.new
  $stderr = StringIO.new
  yield
  [$stdout.string, $stderr.string]
ensure
  $stdout = old_out
  $stderr = old_err
end

check('parse_pill_colors normalizes one HEX (with/without #, 3 or 6 digits, any case)', failures) do
  parse_pill_colors('#FF6600') == ['#ff6600'] &&
    parse_pill_colors('ff6600') == ['#ff6600'] &&
    parse_pill_colors('#f60') == ['#ff6600']
end

check('parse_pill_colors splits ";" lists, tolerating spaces and a trailing ";"', failures) do
  parse_pill_colors('#FF0000; #0000ff;') == ['#ff0000', '#0000ff']
end

check('parse_pill_colors rejects blank cells and any invalid entry (whole cell ignored)', failures) do
  parse_pill_colors('').nil? && parse_pill_colors(nil).nil? &&
    parse_pill_colors('red').nil? && parse_pill_colors('#12').nil? &&
    parse_pill_colors('#ff0000;banana').nil? && parse_pill_colors('#ff0000; url(x)').nil?
end

check('pill_style: dark fill gets white text, light fill gets black text', failures) do
  pill_style(['#111111']).include?('--pill-fg: #ffffff') &&
    pill_style(['#ffd400']).include?('--pill-fg: #000000')
end

check('pill_style: a single color is a plain fill, several make a left-to-right gradient', failures) do
  pill_style(['#ffd400']).start_with?('--pill-bg: #ffd400;') &&
    pill_style(['#ff0000', '#0000ff']).start_with?('--pill-bg: linear-gradient(to right, #ff0000, #0000ff);')
end

check('pill_style: text color is chosen against the whole gradient, not just the first stop', failures) do
  # white on the left, near-black on the right: neither label color works
  # everywhere, so the pick must be whichever is least bad (never raises)
  %w[#000000 #ffffff].include?(pill_style(['#ffffff', '#111111'])[/--pill-fg: (#\h{6})/, 1]) &&
    # dark on both ends of a gradient -> white
    pill_style(['#001a66', '#330066']).include?('--pill-fg: #ffffff')
end

check('pill_style: hover label turns accent blue only where it stays legible', failures) do
  pill_style(['#ffd400']).include?('--pill-hover-fg: var(--accent)') &&
    pill_style(['#000000']).include?('--pill-hover-fg: #ffffff') &&
    pill_style(['#0a2a8a']).include?('--pill-hover-fg: #ffffff')
end

check('about_cards_from_rows attaches a style only to rows with a valid Color', failures) do
  rows = [
    about_row('Plain', 'https://a.example/'),
    about_row('Solid', 'https://b.example/', '#ff6600'),
    about_row('Gradient', 'https://c.example/', '#ff0000;#0000ff'),
    about_row('Broken', 'https://d.example/', 'orange')
  ]
  result = nil
  capture_streams { result = about_cards_from_rows(rows) }
  result.map { |c| !c[:style].nil? } == [false, true, true, false]
end

check('an invalid Color is reported on stderr instead of failing', failures) do
  _out, err = capture_streams { about_cards_from_rows([about_row('Broken', 'https://d.example/', 'orange')]) }
  err.include?('ignoring invalid Color') && err.include?('Broken')
end

check('about.html.erb writes a card style only when one is given, and scopes the hero spacing', failures) do
  html = render('about.html.erb', {
                   heading: 'T', bio_paragraphs: ['d'],
                   cards: [{ label: 'Plain', url: 'https://a.example/', mailto: false, style: nil },
                           { label: 'Tinted', url: 'https://b.example/', mailto: false, style: pill_style(['#ffd400']) }]
                 })
  html.scan(' style="').length == 1 &&
    html.include?('style="--pill-bg: #ffd400; --pill-fg: #000000;') &&
    html.include?('<header class="hero about-hero">')
end

check('the home page header keeps its own spacing class (about-hero is not on index)', failures) do
  !render('index.html.erb', { name: 'T', bio_paragraphs: [], links: [], projects: [] }).include?('about-hero')
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
                   heading: 'Test Person',
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
  html = render('about.html.erb', { heading: 'T', bio_paragraphs: ['d'], cards: [] })
  html.include?('class="has-age-gate"') &&
    html.include?('src="/assets/js/age-gate.js?v=') &&
    html.include?('id="age-gate"') &&
    html.include?('data-age-yes') && html.include?('data-age-no') &&
    html.include?('data-age-denied hidden')
end

check('about page shows the Notion heading as <h1> and tab title, with no avatar', failures) do
  html = render('about.html.erb', { heading: 'All my <links>', bio_paragraphs: [], cards: [] })
  html.include?('<title>All my &lt;links&gt;</title>') &&
    html.include?('<h1 class="name">All my &lt;links&gt;</h1>') &&
    !html.include?('avatar')
end

check('about page loads CSS and JS through content-versioned URLs', failures) do
  html = render('about.html.erb', { heading: 'T', bio_paragraphs: [], cards: [] })
  html =~ %r{href="/assets/css/style\.css\?v=[0-9a-f]{8}"} &&
    html =~ %r{src="/assets/js/age-gate\.js\?v=[0-9a-f]{8}"} &&
    html =~ %r{src="/assets/js/main\.js\?v=[0-9a-f]{8}"}
end

check('asset_url changes when the file content changes', failures) do
  path = 'assets/.asset_url_probe.tmp'
  full = File.join(ROOT, path)
  File.write(full, 'one')
  first = asset_url(path)
  File.write(full, 'two')
  second = asset_url(path)
  File.delete(full)
  first != second
end

check('about page omits the description block when there is no description', failures) do
  html = render('about.html.erb', { heading: 'T', bio_paragraphs: [], cards: [] })
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
