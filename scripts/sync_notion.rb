#!/usr/bin/env ruby
# Pulls content from Notion and regenerates the static site (index.html, one
# HTML file per project, and an /about redirect) from templates/*.erb. Run with:
#   NOTION_TOKEN=... NOTION_HOME_PAGE_ID=... NOTION_PROJECTS_DB_ID=... \
#   NOTION_ABOUT_DB_ID=... [NOTION_ABOUT_PAGE_ID=...] ruby scripts/sync_notion.rb
#
# The HOME PAGE of the site (index.html) is a Linktree-style list of link
# buttons behind an 18+ confirmation screen (assets/js/age-gate.js). The project
# case pages are still generated but are no longer linked from the home page.
# /about only redirects to the home page, so old shared links keep working.
#
# Notion schema this script expects:
#
#   Link-buttons database (NOTION_ABOUT_DB_ID -- the name predates it becoming
#   the home page): Name (title -- the button label), Link (rich text -- not
#   Notion's native "URL" property type, which can mangle mailto: links),
#   Order (number), and optionally
#     Color (rich text: a HEX such as "#ff6600", or HEXes separated by ";" for
#       a left-to-right gradient; blank = the default gray),
#     White (checkbox: label is white when ticked, black otherwise; the label
#       color is never auto-picked),
#     "файл" (files & media; "Image"/"File" work too): the first file is set into
#       the button as a 4:3 picture with a 0.5rem inset, the label below it.
#
#   Heading + description of the home page: the title and body paragraphs of the
#   optional page NOTION_ABOUT_PAGE_ID; when it is unset they fall back to the
#   name and bio of the Home page below. There is no avatar.
#
#   Home page (NOTION_HOME_PAGE_ID; a regular page, not a database row): only
#   the fallback source of the heading and description described above.
#
#   Projects database (these pages are no longer linked from the home page, so
#   the grid-only columns Meta and Thumbnail are ignored now):
#     Name (title -- the slug source when Slug is blank, and the page heading
#     when Title is blank), Title (rich text, optional -- the project page's
#     own <h1>/<title>), Description (rich text, optional), Slug (rich text,
#     optional -> auto-generated from Name), Order (number), Published
#     (checkbox)
#     Page body = intro paragraphs, then any mix of Heading (section label:
#     Task/Process/Result/...), paragraph, and image blocks, in the order
#     they should render.

require 'net/http'
require 'uri'
require 'json'
require 'digest'
require 'erb'
require 'fileutils'
require 'cgi'

ROOT = File.expand_path('..', __dir__)
NOTION_VERSION = '2022-06-28'
API_ROOT = 'https://api.notion.com/v1'

# ---- low-level Notion API client -------------------------------------------

def notion_request(method, path, body = nil)
  uri = URI("#{API_ROOT}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  attempt = 0
  loop do
    attempt += 1
    req = case method
          when :get then Net::HTTP::Get.new(uri)
          when :post then Net::HTTP::Post.new(uri)
          end
    req['Authorization'] = "Bearer #{ENV.fetch('NOTION_TOKEN')}"
    req['Notion-Version'] = NOTION_VERSION
    req['Content-Type'] = 'application/json'
    req.body = body.to_json if body

    res = http.request(req)

    if res.code == '429' && attempt < 5
      wait = (res['Retry-After'] || '1').to_f
      sleep(wait + 0.5)
      next
    end

    if res.code.to_i >= 500 && attempt < 5
      sleep(1.5 * attempt)
      next
    end

    unless res.code.to_i.between?(200, 299)
      raise "Notion API #{method.upcase} #{path} failed: #{res.code} #{res.body}"
    end

    return JSON.parse(res.body)
  end
end

def notion_get(path)
  notion_request(:get, path)
end

def notion_post(path, body)
  notion_request(:post, path, body)
end

def get_page(page_id)
  notion_get("/pages/#{page_id}")
end

def get_block_children(block_id)
  results = []
  cursor = nil
  loop do
    q = cursor ? "?start_cursor=#{cursor}&page_size=100" : '?page_size=100'
    resp = notion_get("/blocks/#{block_id}/children#{q}")
    results.concat(resp['results'])
    break unless resp['has_more']

    cursor = resp['next_cursor']
  end
  results
end

def query_database(db_id, filter: nil, sorts: nil)
  results = []
  cursor = nil
  loop do
    body = {}
    body[:filter] = filter if filter
    body[:sorts] = sorts if sorts
    body[:start_cursor] = cursor if cursor
    body[:page_size] = 100
    resp = notion_post("/databases/#{db_id}/query", body)
    results.concat(resp['results'])
    break unless resp['has_more']

    cursor = resp['next_cursor']
  end
  results
end

# ---- rich text / property helpers ------------------------------------------

def html_escape(text)
  CGI.escapeHTML(text)
end

# Converts a Notion rich_text array into an inline HTML string, honoring
# bold/italic and links.
def rich_text_to_html(rich_text)
  (rich_text || []).map do |seg|
    text = html_escape(seg['plain_text'].to_s)
    text = text.gsub("\n", '<br/>')
    ann = seg['annotations'] || {}
    text = "<em>#{text}</em>" if ann['italic']
    text = "<strong>#{text}</strong>" if ann['bold']
    href = seg.dig('href') || seg.dig('text', 'link', 'url')
    text = %(<a href="#{html_escape(href)}">#{text}</a>) if href
    text
  end.join
end

def rich_text_to_plain(rich_text)
  (rich_text || []).map { |seg| seg['plain_text'].to_s }.join
end

def prop_title(page, name)
  prop = page.dig('properties', name)
  rich_text_to_plain(prop && prop['title'])
end

def prop_rich_text(page, name)
  prop = page.dig('properties', name)
  rich_text_to_plain(prop && prop['rich_text'])
end

def prop_number(page, name)
  page.dig('properties', name, 'number')
end

def prop_checkbox(page, name)
  page.dig('properties', name, 'checkbox') == true
end

def prop_file_url(page, name)
  files = page.dig('properties', name, 'files')
  return nil unless files && files[0]

  f = files[0]
  f['type'] == 'external' ? f.dig('external', 'url') : f.dig('file', 'url')
end

def page_title_text(page)
  # For a plain (non-database) page, the title lives under the "title" key.
  props = page['properties'] || {}
  title_prop = props.values.find { |p| p['type'] == 'title' }
  rich_text_to_plain(title_prop && title_prop['title'])
end

def build_full_title(name, explicit_title)
  explicit_title.to_s.strip.empty? ? name : explicit_title
end

def slugify(text)
  text.downcase
      .gsub(/[^a-z0-9]+/, '-')
      .gsub(/\A-+|-+\z/, '')
end

# ---- image downloading -----------------------------------------------------

EXT_FROM_CONTENT_TYPE = {
  'image/jpeg' => 'jpg',
  'image/png' => 'png',
  'image/webp' => 'webp',
  'image/gif' => 'gif',
  'image/svg+xml' => 'svg'
}.freeze

# Downloads a Notion-hosted (or external) image to assets/images, named by a
# stable key (usually the source block id) so re-running the sync overwrites
# the same file in place instead of piling up duplicates. Returns the site-
# relative path to use in an <img src>.
def download_image(url, stable_key)
  uri = URI(url)
  res = Net::HTTP.get_response(uri)
  raise "image download failed (#{res.code}): #{url}" unless res.code.to_i.between?(200, 299)

  ext = EXT_FROM_CONTENT_TYPE[res['Content-Type']&.split(';')&.first]
  ext ||= File.extname(uri.path).delete_prefix('.').downcase
  ext = 'jpg' if ext.nil? || ext.empty?

  filename = "notion-#{stable_key}.#{ext}"
  dest = File.join(ROOT, 'assets', 'images', filename)
  FileUtils.mkdir_p(File.dirname(dest))
  File.binwrite(dest, res.body)
  "/assets/images/#{filename}"
end

def image_block_url(block)
  img = block['image']
  img['type'] == 'external' ? img.dig('external', 'url') : img.dig('file', 'url')
end

# ---- block-sequence -> page structure --------------------------------------

HEADING_TYPES = %w[heading_1 heading_2 heading_3].freeze

# Turns a flat list of top-level Notion blocks into:
#   { intro: [html, ...], blocks: [ {type: :figure, src:, caption:} |
#                                    {type: :section, label:, paragraphs: [html,...]} ] }
# Leading paragraphs (before the first heading/image) become the intro.
# A heading starts a new labeled section; consecutive paragraphs accumulate
# into the current section until the next heading or image.
def build_case_structure(blocks, slug)
  intro = []
  out = []
  current = nil # { label:, paragraphs: [] } while accumulating a text section
  in_intro = true
  image_index = 0

  flush_current = lambda {
    if current && (current[:label] || current[:paragraphs].any?)
      out << { type: :section, label: current[:label], paragraphs: current[:paragraphs] }
    end
    current = nil
  }

  blocks.each do |block|
    type = block['type']

    if type == 'paragraph'
      text = rich_text_to_html(block.dig('paragraph', 'rich_text'))
      next if text.strip.empty?

      if in_intro
        intro << text
      else
        current ||= { label: nil, paragraphs: [] }
        current[:paragraphs] << text
      end
    elsif HEADING_TYPES.include?(type)
      in_intro = false
      flush_current.call
      label = rich_text_to_plain(block.dig(type, 'rich_text'))
      current = { label: label, paragraphs: [] }
    elsif type == 'image'
      in_intro = false
      flush_current.call
      image_index += 1
      url = image_block_url(block)
      src = download_image(url, "#{slug}-img#{image_index}-#{block['id'].delete('-')[0, 8]}")
      caption = rich_text_to_plain(block.dig('image', 'caption'))
      out << { type: :figure, src: src, caption: caption }
    end
    # other block types (bulleted lists, quotes, etc.) are out of scope for v1
  end
  flush_current.call

  { intro: intro, blocks: out }
end

def paragraphs_html(blocks)
  blocks.select { |b| b['type'] == 'paragraph' }
        .map { |b| rich_text_to_html(b.dig('paragraph', 'rich_text')) }
        .reject { |t| t.strip.empty? }
end

HEX_COLOR = /\A#?(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/.freeze

# Parses the Notion "Color" cell: one HEX ("#ff6600", "f60") or several
# separated by ";" ("#ff6600; #0033ff" = left-to-right gradient). Returns
# normalized "#rrggbb" strings, or nil when the cell is blank or any entry is
# not a valid 3/6-digit HEX (the whole cell is ignored rather than guessed at).
def parse_pill_colors(text)
  entries = text.to_s.split(';').map(&:strip).reject(&:empty?)
  return nil if entries.empty? || !entries.all? { |e| e.match?(HEX_COLOR) }

  entries.map do |e|
    hex = e.delete_prefix('#').downcase
    hex = hex.chars.map { |c| c * 2 }.join if hex.length == 3
    "##{hex}"
  end
end

# Inline custom properties for one card, or nil when it keeps the default look
# (gray fill, black label). The label color is the editor's choice (the White
# checkbox in Notion), never guessed from the fill.
def pill_style(colors, white)
  fg = white ? '#ffffff' : '#000000'
  return (white ? "--pill-fg: #{fg}" : nil) if colors.nil?

  bg = colors.length == 1 ? colors.first : "linear-gradient(to right, #{colors.join(', ')})"
  "--pill-bg: #{bg}; --pill-fg: #{fg}"
end

IMAGE_COLUMN_NAMES = %w[файл image file].freeze

# URL of the first file in a row's image column: a files-type property whose name
# is "файл", "image" or "file", ignoring case and surrounding spaces ("Файл" works
# too). Other files columns are left alone.
def row_image_url(row)
  props = row['properties'] || {}
  key = props.keys.find do |k|
    IMAGE_COLUMN_NAMES.include?(k.strip.downcase) && props[k]['type'] == 'files'
  end
  key && prop_file_url(row, key)
end

# Link buttons of the home page (Name = label, Link = url) plus the optional
# Color (fill), White (checkbox: white label instead of black) and the image
# column (files: the first file is downloaded and set into the button). Rows
# missing a label or url are skipped so a half-filled draft row never renders as
# a dead button.
def about_cards_from_rows(rows)
  cards = rows.reject do |row|
    prop_title(row, 'Name').strip.empty? || prop_rich_text(row, 'Link').strip.empty?
  end

  cards.map do |row|
    url = prop_rich_text(row, 'Link').strip
    label = prop_title(row, 'Name').strip
    color_text = prop_rich_text(row, 'Color')
    colors = parse_pill_colors(color_text)
    if colors.nil? && !color_text.strip.empty?
      warn "    warning: ignoring invalid Color #{color_text.inspect} on \"#{label}\""
    end

    image_url = row_image_url(row)
    # Keyed on the tail of the row id: the leading characters of Notion ids are
    # shared across the workspace, and a row keeps its id when reordered.
    row_key = row['id'].to_s.delete('-')
    image = image_url && download_image(image_url, "link-#{row_key[-12..] || row_key}")

    { label: label, url: url, mailto: url.start_with?('mailto:'), image: image,
      style: pill_style(colors, prop_checkbox(row, 'White')) }
  end
end

# Tiny page that sends visitors of a moved URL to its new home.
def redirect_html(target)
  <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8"/>
    <title>Redirecting&hellip;</title>
    <meta http-equiv="refresh" content="0; url=#{target}"/>
    <link rel="canonical" href="#{target}"/>
    <script>location.replace(#{target.to_json});</script>
    </head>
    <body><a href="#{target}">Continue</a></body>
    </html>
  HTML
end

# Content-versioned URL for a local asset ("assets/css/style.css" ->
# "/assets/css/style.css?v=1a2b3c4d"). Cloudflare tells browsers to cache
# static files for hours, so a changed stylesheet only reaches returning
# visitors if its URL changes with its content.
def asset_url(path)
  "/#{path}?v=#{Digest::MD5.file(File.join(ROOT, path)).hexdigest[0, 8]}"
end

# ---- render -----------------------------------------------------------------

def render(template_name, locals)
  path = File.join(ROOT, 'templates', template_name)
  erb = ERB.new(File.read(path), trim_mode: '-')
  b = binding
  locals.each { |k, v| b.local_variable_set(k, v) }
  erb.result(b)
end

# ---- fetch content from Notion ---------------------------------------------
# Everything below only runs when this file is executed directly (not when
# it's `require`d, e.g. by scripts/test_sync_notion.rb).
if __FILE__ == $PROGRAM_NAME

HOME_PAGE_ID = ENV.fetch('NOTION_HOME_PAGE_ID')
PROJECTS_DB_ID = ENV.fetch('NOTION_PROJECTS_DB_ID')
# The link buttons ARE the home page now, so a missing database fails the sync
# loudly instead of publishing an empty home page.
ABOUT_DB_ID = ENV.fetch('NOTION_ABOUT_DB_ID')
# Optional: a Notion page whose title and paragraphs become the home page's
# heading and description. Without it they fall back to the Home page's.
ABOUT_PAGE_ID = ENV['NOTION_ABOUT_PAGE_ID'].to_s.strip

puts '==> Fetching home page (name + bio)'
home_page = get_page(HOME_PAGE_ID)
site_name = page_title_text(home_page)
home_blocks = get_block_children(HOME_PAGE_ID)
bio_paragraphs = home_blocks
                 .select { |b| b['type'] == 'paragraph' }
                 .map { |b| rich_text_to_html(b.dig('paragraph', 'rich_text')) }
                 .reject { |t| t.strip.empty? }

puts '==> Fetching projects'
project_rows = query_database(
  PROJECTS_DB_ID,
  filter: { property: 'Published', checkbox: { equals: true } },
  sorts: [{ property: 'Order', direction: 'ascending' }]
)

projects = project_rows.map do |row|
  name = prop_title(row, 'Name')
  slug = prop_rich_text(row, 'Slug')
  slug = slugify(name) if slug.nil? || slug.empty?
  puts "    - #{name} (#{slug})"

  page_blocks = get_block_children(row['id'])
  structure = build_case_structure(page_blocks, slug)

  full_title = build_full_title(name, prop_rich_text(row, 'Title'))

  {
    slug: slug,
    title: name,
    full_title: full_title,
    description: prop_rich_text(row, 'Description'),
    order: prop_number(row, 'Order') || 0,
    intro: structure[:intro],
    blocks: structure[:blocks]
  }
end

puts '==> Fetching link buttons'
home_cards = about_cards_from_rows(
  query_database(ABOUT_DB_ID, sorts: [{ property: 'Order', direction: 'ascending' }])
)
puts "    #{home_cards.length} buttons, #{home_cards.count { |c| c[:image] }} with an image"

home_heading = site_name
home_bio = bio_paragraphs
unless ABOUT_PAGE_ID.empty?
  puts '==> Fetching home heading + description'
  notion_heading = page_title_text(get_page(ABOUT_PAGE_ID)).strip
  home_heading = notion_heading unless notion_heading.empty?
  home_bio = paragraphs_html(get_block_children(ABOUT_PAGE_ID))
end

puts '==> Rendering index.html'
File.write(File.join(ROOT, 'index.html'), render('home.html.erb', {
                                                    heading: home_heading,
                                                    bio_paragraphs: home_bio,
                                                    cards: home_cards
                                                  }))

generated_files = ['index.html']

projects.each do |proj|
  other_projects = projects.reject { |p| p[:slug] == proj[:slug] }
                            .map { |p| { slug: p[:slug], title: p[:full_title] } }

  html = render('project.html.erb', {
                  title: proj[:full_title],
                  description: proj[:description],
                  intro_paragraphs: proj[:intro],
                  blocks: proj[:blocks],
                  other_projects: other_projects
                })
  filename = "#{proj[:slug]}.html"
  File.write(File.join(ROOT, filename), html)
  generated_files << filename
  puts "    wrote #{filename}"
end

File.write(File.join(ROOT, 'about.html'), redirect_html('/'))
generated_files << 'about.html'
puts '    wrote about.html (redirect to /)'

# ---- clean up pages that are no longer published ---------------------------

manifest_path = File.join(ROOT, '.notion-manifest.json')
if File.exist?(manifest_path)
  previous = JSON.parse(File.read(manifest_path))['files'] || []
  stale = previous - generated_files
  stale.each do |f|
    full = File.join(ROOT, f)
    if File.exist?(full)
      puts "    removing stale page #{f}"
      File.delete(full)
    end
  end
end
File.write(manifest_path, JSON.pretty_generate({ files: generated_files }))

puts '==> Done'

end # __FILE__ == $PROGRAM_NAME
