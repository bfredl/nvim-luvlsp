if _G.luvlsp_feat == nil then
  _G.luvlsp_feat = {
    diag_ns = a.nvim_create_namespace("luvlsp/diag"),
  }
end
local luvlsp_feat = _G.luvlsp_feat

local luvlsp = require'luvlsp'

luvlsp_feat.textDocument_caps = {
  publishDiagnostics={relatedInformation=true},
  -- TODO: signatureInformation
}

function luvlsp_feat.on_diag(msg)
  local ns = luvlsp_feat.diag_ns
  local MessageType = { Error = 1, Warning = 2, Info = 3, Log = 4 }
  local bufnr = luvlsp.bufmap[msg.params.uri]
  a.nvim_buf_clear_highlight(bufnr, ns, 0, -1)
  local last_line, last_severity = -1, -1
  for _, msg in ipairs(msg.params.diagnostics) do
    local range = msg.range
    range._end = range['end']
    if range._end.line ~= range.start.line then
      range._end.line = range.start.line
      range._end.character = -1
    end

    if last_line == range.start.line and msg.severity > last_severity then
      goto continue
    end
    last_line, last_severity = range.start.line, msg.severity

    local msg_hl
    if msg.severity == MessageType.Error then
      msg_hl = "LspError"
    elseif msg.severity == MessageType.Warning then
      msg_hl = "LspWarning"
    else
      msg_hl = "LspOtherMsg"
    end
    a.nvim_buf_set_virtual_text(bufnr, ns, range.start.line, {{'▶ '..msg.message, msg_hl}}, {})

    local loc_hl = "LspLocation"
    a.nvim_buf_add_highlight(bufnr, ns, loc_hl, range.start.line, range.start.character, range._end.character)
    ::continue::
  end
end
luvlsp.msg_handlers["textDocument/publishDiagnostics"] = luvlsp_feat.on_diag

function luvlsp_feat.do_signature()
end

return luvlsp_feat
