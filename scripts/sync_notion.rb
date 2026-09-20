#!/usr/bin/env ruby
# Pulls content from Notion and regenerates the static site (index.html + one
# HTML file per project) from templates/*.erb. Run with:
#   NOTION_TOKEN=... NOTION_HOME_PAGE_ID=... NOTION_PROJECTS_DB_ID=... NOTION_LINKS_DB_ID=... ruby scripts/sync_notion.rb
#
# Notion schema this script expects:
#
#   Home page (a regular page, not a database row):
#     - page title = site owner's name, shown as <h1 class="name">
#     - page body  = bio paragraphs, in order (plain paragraph blocks)
#
#   Links database: Label (title), URL (rich text -- not Notion's native
#   "URL" property type, which can mangle mailto: links), Order (number)
#
#   Projects database:
#     Name (title), Meta (rich text), Description (rich text, optional),
#     Thumbnail (files, optional -> falls back to the first image block on
#     the page), Slug (rich text, optional -> auto-generated from Name),
#     Order (number), Published (checkbox)
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

def build_full_title(name, meta)
  meta.to_s.strip.empty? ? name : "#{name} for a #{meta}"
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
      puts "      [debug] image ##{image_index} block_id=#{block['id']} url=#{url&.slice(0, 80)}"
      src = download_image(url, "#{slug}-img#{image_index}-#{block['id'].delete('-')[0, 8]}")
      caption = rich_text_to_plain(block.dig('image', 'caption'))
      out << { type: :figure, src: src, caption: caption }
    end
    # other block types (bulleted lists, quotes, etc.) are out of scope for v1
  end
  flush_current.call

  { intro: intro, blocks: out }
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
LINKS_DB_ID = ENV.fetch('NOTION_LINKS_DB_ID')

puts '==> Fetching home page (name + bio)'
home_page = get_page(HOME_PAGE_ID)
site_name = page_title_text(home_page)
home_blocks = get_block_children(HOME_PAGE_ID)
bio_paragraphs = home_blocks
                 .select { |b| b['type'] == 'paragraph' }
                 .map { |b| rich_text_to_html(b.dig('paragraph', 'rich_text')) }
                 .reject { |t| t.strip.empty? }

puts '==> Fetching links'
link_rows = query_database(LINKS_DB_ID, sorts: [{ property: 'Order', direction: 'ascending' }])
links = link_rows.map do |row|
  label = prop_title(row, 'Label')
  url = prop_rich_text(row, 'URL')
  { label: label, url: url, mailto: url.to_s.start_with?('mailto:') }
end

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

  thumb = prop_file_url(row, 'Thumbnail')
  thumb_src = if thumb
                download_image(thumb, "#{slug}-thumb")
              else
                first_figure = structure[:blocks].find { |b| b[:type] == :figure }
                first_figure ? first_figure[:src] : nil
              end

  meta = prop_rich_text(row, 'Meta')
  full_title = build_full_title(name, meta)

  {
    slug: slug,
    title: name,
    full_title: full_title,
    meta: meta,
    description: prop_rich_text(row, 'Description'),
    order: prop_number(row, 'Order') || 0,
    thumb: thumb_src,
    intro: structure[:intro],
    blocks: structure[:blocks]
  }
end

puts '==> Rendering index.html'
index_html = render('index.html.erb', {
                       name: site_name,
                       bio_paragraphs: bio_paragraphs,
                       links: links,
                       projects: projects.map { |p| { slug: p[:slug], title: p[:title], meta: p[:meta], thumb: p[:thumb] } }
                     })
File.write(File.join(ROOT, 'index.html'), index_html)

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
