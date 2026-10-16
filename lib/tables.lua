-- Inhalt und Tabellen vor dem Markdown-Writer prüfen. HTML-Regulärausdrücke können weder
-- verschachtelte Zellen noch Kommentare/Attribute zuverlässig unterscheiden.
local flattened_cells = 0
local strict = os.getenv('MD_CLIP_STRICT') == '1'
local image_mode = os.getenv('MD_CLIP_IMAGES') or 'keep'
if image_mode ~= 'keep' and image_mode ~= 'alt' and image_mode ~= 'omit' then
  error('Unbekannte Bildbehandlung: keep|alt|omit erwartet.')
end
local table_mode = os.getenv('MD_CLIP_TABLES') or 'reject'
if table_mode ~= 'reject' and table_mode ~= 'text' then
  error('Unbekannte Tabellenbehandlung: reject|text erwartet.')
end
local images_alt, images_omitted, tables_text = 0, 0, 0

local function report(code, count)
  local path = os.getenv('MD_CLIP_RESULT_FILE')
  if path and path ~= '' then
    local file = assert(io.open(path, 'a'))
    file:write(code, '\t', tostring(count), '\n')
    file:close()
  end
end

local function reject(code, message)
  report(code, 1)
  error(message)
end

function Image(image)
  if image_mode == 'alt' then
    images_alt = images_alt + 1
    return image.caption
  elseif image_mode == 'omit' then
    images_omitted = images_omitted + 1
    return {}
  end
  return image
end

function Span(span)
  local has_break = false
  span:walk { LineBreak = function() has_break = true end }
  if has_break then
    -- Ein anonymer Span erhält pandocs bisherige Maskierung getippter Listen
    -- hinter <br>. Aufgelöst würde der Writer zusätzliche Escapes erzeugen,
    -- die tidy_markdown als echten Absatzumbruch behandeln müsste.
    span.attr = pandoc.Attr()
    return span
  end
  return span.content
end

function Div(div)
  return div.content
end

local function preserve_container_code(container)
  if PANDOC_VERSION ~= pandoc.types.Version('3.9.0.2') then return nil end
  return container:walk {
    CodeBlock = function(code)
      -- pandoc 3.9.0.2 verliert bei Code in Zitaten oder Listen Einrückung
      -- und damit teils den Codeblock selbst. Die leere Klasse erzwingt
      -- sprachlose Zäune ohne erfundene Sprache oder zusätzliche Attribute.
      if #code.classes == 0 and code.identifier == '' and #code.attributes == 0 then
        code.classes = { '' }
      end
      return code
    end
  }
end

function Link(link)
  local has_image = false
  pandoc.Span(link.content):walk { Image = function() has_image = true end }
  local text = pandoc.utils.stringify(link.content):gsub('%s', ''):gsub('\194\160', '')
  if text == '' and not has_image then
    -- Der Span verhindert, dass der Writer einen Autolink daraus macht und
    -- dabei dessen Titel verwirft. URL und Titel kommen bereits dekodiert an.
    link.content = { pandoc.Span { pandoc.Str(link.target) } }
  end
  return link
end

local function row_groups(tbl)
  local groups = { { label = 'Tabellenkopf', rows = tbl.head.rows } }
  for i, body in ipairs(tbl.bodies) do
    local rows = pandoc.List()
    rows:extend(body.head)
    rows:extend(body.body)
    groups[#groups + 1] = { label = 'Tabellenkörper ' .. i, rows = rows,
                           head_count = #body.head, row_head_columns = body.row_head_columns }
  end
  groups[#groups + 1] = { label = 'Tabellenfuß', rows = tbl.foot.rows }
  return groups
end

local function complex_table(tbl)
  local nested = false
  tbl:walk { Table = function() nested = true end }
  if nested then return true end
  for _, group in ipairs(row_groups(tbl)) do
    for _, row in ipairs(group.rows) do
      for _, cell in ipairs(row.cells) do
        if cell.row_span ~= 1 or cell.col_span ~= 1 then return true end
      end
    end
  end
  return false
end

local function label(text)
  return pandoc.Para { pandoc.Strong { pandoc.Str(text) } }
end

local function interval(first, last)
  return first == last and tostring(first) or (first .. '–' .. last)
end

local render_table
local function render_nested(blocks)
  return pandoc.Pandoc(blocks):walk {
    traverse = 'topdown',
    Table = function(tbl) return render_table(tbl), false end
  }.blocks
end

render_table = function(tbl)
  tables_text = tables_text + 1
  local number, columns = tables_text, #tbl.colspecs
  if columns == 0 then reject('table-ambiguous', 'Tabelle hat keine zuordenbaren Spalten.') end
  local out = pandoc.List { label('Tabelle ' .. number .. ' — Textdarstellung (' .. columns .. (columns == 1 and ' Spalte)' or ' Spalten)')) }
  if #tbl.caption.long > 0 then
    out:extend(render_nested(tbl.caption.long))
  elseif tbl.caption.short and #tbl.caption.short > 0 then
    out:insert(pandoc.Para(tbl.caption.short))
  end
  local offset = 0
  for _, group in ipairs(row_groups(tbl)) do
    -- Pandocs normalisierte Zellen belegen das erste freie Feld ihrer Zeile.
    -- Ein Raster verhindert, dass Rowspan-Fortsetzungen als neue Zellen gelten.
    local grid = {}
    for r = 1, #group.rows do grid[r] = {} end
    for r, row in ipairs(group.rows) do
      local column = 1
      for _, cell in ipairs(row.cells) do
        while column <= columns and grid[r][column] do column = column + 1 end
        local rs, cs = cell.row_span, cell.col_span
        if rs < 1 or cs < 1 or rs % 1 ~= 0 or cs % 1 ~= 0
          or r + rs - 1 > #group.rows or column + cs - 1 > columns then
          reject('table-ambiguous', 'Tabellenspannweite ist nicht eindeutig zuordenbar.')
        end
        local origin = { row = r, column = column, cell = cell }
        for rr = r, r + rs - 1 do
          for cc = column, column + cs - 1 do
            if grid[rr][cc] then
              reject('table-ambiguous', 'Tabellenspannweiten überlappen sich.')
            end
            grid[rr][cc] = origin
          end
        end
        column = column + cs
      end
    end
    for r, _ in ipairs(group.rows) do
      local kind = group.label
      if group.head_count and r <= group.head_count then kind = kind .. ', Zwischenkopf' end
      out:insert(label('Zeile ' .. (offset + r) .. ' (' .. kind .. ')'))
      local column = 1
      while column <= columns do
        local origin = grid[r][column]
        if not origin then
          reject('table-ambiguous', 'Tabellenraster enthält eine nicht zugeordnete Position.')
        end
        local cell = origin.cell
        local last = origin.column + cell.col_span - 1
        local heading = (column == last and 'Spalte ' or 'Spalten ') .. interval(column, last)
        if origin.row == r then
          if cell.row_span > 1 then
            heading = heading .. '; Zeilen ' .. interval(offset + r, offset + r + cell.row_span - 1)
          end
          if group.row_head_columns and column <= group.row_head_columns then
            heading = heading .. ' (Zeilenkopf)'
          end
          out:insert(label(heading))
          if #cell.contents == 0 then
            out:insert(pandoc.Para { pandoc.Emph { pandoc.Str('(leere Zelle)') } })
          else
            out:extend(render_nested(cell.contents))
          end
        else
          out:insert(label(heading .. ': Fortsetzung aus Zeile ' .. (offset + origin.row)
            .. ', Spalte ' .. origin.column))
        end
        column = last + 1
      end
    end
    offset = offset + #group.rows
  end
  return pandoc.BlockQuote(out)
end

function Table(tbl)
  local nested = false
  tbl:walk { Table = function() nested = true end }
  if nested then
    reject('table-nested', 'Verschachtelte Tabellen sind nicht verlustfrei darstellbar.')
  end
  local function cell(c)
    if c.row_span > 1 or c.col_span > 1 then
      reject('table-spanned', 'Verbundene Tabellenzellen sind nicht verlustfrei darstellbar.')
    end
    if FORMAT:match('^markdown') then return c end
    local complex = #c.contents > 1
    for _, block in ipairs(c.contents) do
      if block.t ~= 'Plain' and block.t ~= 'Para' then complex = true end
    end
    -- Blockgrenzen rekursiv als Leerzeichen abbilden. blocks_to_inlines
    -- erzeugt in Zitaten erneut LineBreaks und klebt Listenpunkte zusammen.
    local function flatten(blocks)
      local out = pandoc.List()
      local function append(inlines)
        if #out > 0 and #inlines > 0 then out:insert(pandoc.Space()) end
        out:extend(inlines)
      end
      for _, block in ipairs(blocks) do
        if block.t == 'Plain' or block.t == 'Para' or block.t == 'Header' then
          append(block.content)
        elseif block.t == 'CodeBlock' then
          append { pandoc.Code((block.text:gsub('[\r\n]+', ' '))) }
        elseif block.t == 'Div' or block.t == 'BlockQuote' then
          append(flatten(block.content))
        elseif block.t == 'BulletList' or block.t == 'OrderedList' then
          for _, item in ipairs(block.content) do append(flatten(item)) end
        elseif block.t == 'DefinitionList' then
          for _, item in ipairs(block.content) do
            append(item[1])
            for _, definition in ipairs(item[2]) do append(flatten(definition)) end
          end
        elseif block.t == 'LineBlock' then
          for _, line in ipairs(block.content) do append(line) end
        elseif block.t ~= 'HorizontalRule' then
          error('Tabellenzelle enthält nicht darstellbaren Block: ' .. block.t)
        end
      end
      return out
    end
    local plain = pandoc.Plain(flatten(c.contents)):walk {
      LineBreak = function() complex = true; return pandoc.Space() end,
      SoftBreak = function() complex = true; return pandoc.Space() end,
      Code = function(code)
        if code.text:find('[\r\n]') then complex = true end
        code.text = code.text:gsub('[\r\n]+', ' ')
        return code
      end
    }
    c.contents = { plain }
    if complex then flattened_cells = flattened_cells + 1 end
    return c
  end
  local function rows(rs)
    for i, row in ipairs(rs) do
      local cells = row.cells
      for j, c in ipairs(cells) do cells[j] = cell(c) end
      row.cells = cells
      rs[i] = row
    end
    return rs
  end
  local head = tbl.head
  head.rows = rows(head.rows)
  tbl.head = head
  local bodies = tbl.bodies
  for i, body in ipairs(bodies) do
    body.head = rows(body.head); body.body = rows(body.body)
    bodies[i] = body
  end
  tbl.bodies = bodies
  local foot = tbl.foot
  foot.rows = rows(foot.rows)
  tbl.foot = foot
  return tbl
end

local function finalize_document(doc)
  if tables_text > 0 then report('tables-text', tables_text) end
  if images_alt > 0 then report('images-alt', images_alt) end
  if images_omitted > 0 then report('images-omitted', images_omitted) end
  if strict and (images_alt > 0 or images_omitted > 0) then
    error('Strenger Modus: Bildinhalte müssten vereinfacht werden.')
  end
  -- Nur Nutzinhalt sammeln: Strong/Emph, Listenmarker, Linkziele und
  -- Codezäune dürfen einen unsichtbaren Text nicht als sichtbar ausweisen.
  local content = {}
  local function text(node) content[#content + 1] = node.text end
  local function visible() content[#content + 1] = 'visible' end
  -- Metadaten (etwa der HTML-Titel) erscheinen nicht im Markdown-Body.
  pandoc.Pandoc(doc.blocks):walk {
    Str = text, Code = text, CodeBlock = text, Math = text,
    Image = visible, HorizontalRule = visible, Table = visible
  }
  -- Perl bringt die Unicode-Eigenschaften bereits als Kernbordmittel mit.
  -- pandoc.pipe übergibt Text über stdin, ohne Shell oder temporäre Datei.
  local verdict = pandoc.pipe('perl', { '-0e', [[
    my $text = do { local $/; <STDIN> } // q{};
    utf8::decode($text);
    print $text =~ /[^\s\p{White_Space}\p{Default_Ignorable_Code_Point}]/ ? 'yes' : 'no';
  ]] }, table.concat(content, '\n'))
  if verdict ~= 'yes' then
    reject('empty-document', 'Dokument enthält keinen sichtbaren Inhalt.')
  end
  if flattened_cells > 0 then
    report('table-cells-flattened', flattened_cells)
    if strict then
      error('Strenger Modus: Tabellenzellen müssten strukturell vereinfacht werden.')
    end
  end
  return doc
end

local function preserve_heading_braces(heading)
  if FORMAT ~= 'markdown' and FORMAT ~= 'gfm' and FORMAT ~= 'commonmark' then return nil end
  -- Der Markdown-Writer maskiert getippte {#id}/Klassen am Überschriftsende
  -- nicht. Beim erneuten Lesen würden sie als Attribute statt Text verschwinden.
  -- Ältere GFM-/CommonMark-Writer verlieren die Klammer zudem hinter einem
  -- getippten Backslash. Die Maskierung erhält in allen drei Zielen den Text.
  return heading:walk { Str = function(str)
    if not str.text:find('{', 1, true) then return nil end
    local out = pandoc.List()
    local start = 1
    while true do
      local opening = str.text:find('{', start, true)
      if not opening then
        if start <= #str.text then out:insert(pandoc.Str(str.text:sub(start))) end
        return out
      end
      if opening > start then out:insert(pandoc.Str(str.text:sub(start, opening - 1))) end
      out:insert(pandoc.RawInline('markdown', '\\{'))
      start = opening + 1
    end
  end }
end

-- Komplexe Außentabellen vor dem üblichen Bottom-up-Lauf umwandeln. Sonst
-- verschwände die verschachtelte Tabelle, bevor ihr Container sie erkennen kann.
return { { Pandoc = function(doc)
  if table_mode == 'text' then
    doc = doc:walk {
      traverse = 'topdown',
      Table = function(tbl)
        if not complex_table(tbl) then return nil end
        if strict then
          report('tables-text', 1)
          error('Strenger Modus: Komplexe Tabelle müsste als Text vereinfacht werden.')
        end
        return render_table(tbl), false
      end
    }
  end
  doc = doc:walk { Span = Span, Div = Div, Image = Image, Link = Link, Table = Table,
                   BlockQuote = preserve_container_code,
                   BulletList = preserve_container_code, OrderedList = preserve_container_code }
  return finalize_document(doc):walk { Header = preserve_heading_braces }
end } }
