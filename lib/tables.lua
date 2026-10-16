-- Inhalt und Tabellen vor dem Markdown-Writer prüfen. HTML-Regulärausdrücke können weder
-- verschachtelte Zellen noch Kommentare/Attribute zuverlässig unterscheiden.
local flattened_cells = 0
local strict = os.getenv('MD_CLIP_STRICT') == '1'

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

function Pandoc(doc)
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
