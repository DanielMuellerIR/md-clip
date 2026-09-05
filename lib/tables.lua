-- Tabellen vor dem Markdown-Writer prüfen. HTML-Regulärausdrücke können weder
-- verschachtelte Zellen noch Kommentare/Attribute zuverlässig unterscheiden.
local simplified = false

function Table(tbl)
  local nested = false
  tbl:walk { Table = function() nested = true end }
  if nested then
    error('Verschachtelte Tabellen sind nicht verlustfrei darstellbar.')
  end
  local function cell(c)
    if c.row_span > 1 or c.col_span > 1 then
      error('Verbundene Tabellenzellen sind nicht verlustfrei darstellbar.')
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
    if complex then simplified = true end
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
  if simplified then
    local path = os.getenv('MD_CLIP_RESULT_FILE')
    if path and path ~= '' then
      local file = assert(io.open(path, 'w'))
      file:write('simplified\n')
      file:close()
    end
  end
  return doc
end
