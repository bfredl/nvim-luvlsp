-- luacheck: globals vim

do local s, l = pcall(require,'luadev') if s then _G.luadev = l end end
local luadev = _G.luadev

_G.a = vim.api
_G.uv = vim.loop
local a = vim.api
local uv = vim.loop

if _G.luvlsp == nil then
  _G.luvlsp = {
    theid = 0,
    buffered = '',
    pending = {},
    shadow = {},
    bufmap = {},
    ns = a.nvim_create_namespace("luvlsp"),
  }
end
local luvlsp = _G.luvlsp

if luadev then
  luadev.create_buf()
  luvlsp.d = vim.schedule_wrap(luadev.print)
  luvlsp.schedule = function(cb) vim.schedule(luadev.err_wrap(cb)) end
else
  luvlsp.d = vim.schedule_wrap(print)
  luvlsp.schedule = vim.schedule
end

luvlsp.vim_ft = "c"
luvlsp.lsp_languageId = "c"

function luvlsp.spawn()
  local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)

  local function exit_cb()
    luvlsp.d("very exit")
  end

  local exepath = "clangd"
  local args = {}

  local opts = {args=args, stdio={stdin,stdout,stderr}}
  luvlsp.handle, luvlsp.pid = uv.spawn(exepath, opts, exit_cb)

  uv.read_start(stdout, function (err, chunk)
    --luvlsp.d("stdout",chunk, err)
    if not err then
      luvlsp.on_stdout(chunk)
    end
  end)

  uv.read_start(stderr, function (err, chunk)
    luvlsp.d("stderr",chunk, err)
  end)

  luvlsp.stdin = stdin
  luvlsp.stdout = stdout
  luvlsp.stderr = stderr
end

function luvlsp.msg(method,params,id)
  local msg = {jsonrpc = "2.0", method = method, params = params, id = id}
  local bytes = a.nvim_call_function('json_encode', {msg})
  local packet = 'Content-Length: ' .. bytes:len() ..'\r\n\r\n' ..bytes
  uv.write(luvlsp.stdin, packet)
end

function luvlsp.on_stdout(chunk)
  luvlsp.buffered = luvlsp.buffered..chunk
  local eol = string.find(luvlsp.buffered, '\r\n')
  if not eol then return end
  local line = string.sub(luvlsp.buffered,1,eol-1)
  local space = string.find(line, " ")
  local length = tonumber(string.sub(line,space+1))
  -- TODO: can has Content-Type??
  if string.len(luvlsp.buffered) >= eol + 3 + length then
    local msg = luvlsp.buffered:sub(eol+2,eol+3+length)
    luvlsp.buffered = luvlsp.buffered:sub(eol+3+length+1)
    luvlsp.schedule(function() luvlsp.on_msg(msg) end)
    -- check again, very tailcall
    return luvlsp.on_stdout('')
  end
end

function luvlsp.on_msg(bytes)
  local msg = a.nvim_call_function('json_decode', {bytes})
  if msg.id ~= nil then
    luvlsp.d(vim.inspect(msg))
    local mycb = luvlsp.pending[msg.id]
    luvlsp.pending[msg.id] = nil
    return mycb(msg)
  elseif msg.method == "textDocument/publishDiagnostics" then
    luvlsp.on_diag(msg.params)
  else
    luvlsp.d(vim.inspect(msg))
  end
end


function luvlsp.req(method, params, cb)
  local my_id = luvlsp.theid
  luvlsp.theid = luvlsp.theid + 1
  luvlsp.pending[my_id] = cb
  luvlsp.msg(method, params, my_id)
  --luvlsp.d("REQ " ..my_id.. " "..method)
end

function luvlsp.init(cb)
  luvlsp.spawn()
  local capabilities = {
    textDocument = {
      publishDiagnostics={relatedInformation=true},
      -- TODO: signatureInformation
    },
    offsetEncoding = {'utf-8'}, -- what is WCHAR?
  }
  local p = {
    processId = uv.getpid(),
    rootUri = 'file://' .. uv.cwd(),
    capabilities = capabilities,
  }
  luvlsp.req("initialize", p, function(reply)
    if reply.error then
      error(reply.error.message)
    end
    luvlsp.init_result = reply.result
    if cb then cb() end
  end)
end

function luvlsp.do_change(_, bufnr, tick, start, stop, stopped)
  local uri = "file://"..a.nvim_buf_get_name(bufnr)
  local version = tick
  local textDocument = {uri=uri,version=version}
  local lines = a.nvim_buf_get_lines(bufnr, start, stopped, true)
  local text = table.concat(lines, "\n") .. ((stopped > start) and "\n" or "")
  local range = {start={line=start,character=0},["end"]={line=stop,character=0}}
  local shadowlen = a.nvim_buf_get_offset(bufnr,a.nvim_buf_line_count(bufnr))
  -- TODO: this is not recessary for clangd? check also with some other server.
  local rangeLength = string.len(text) + (luvlsp.shadow[bufnr] - shadowlen)
  luvlsp.shadow[bufnr] = shadowlen
  local edit = {range=range, text=text, rangeLength=rangeLength}
  luvlsp.msg("textDocument/didChange", {textDocument=textDocument, contentChanges={edit}})
end

function luvlsp.do_open(bufnr)
  local uri = "file://"..a.nvim_buf_get_name(bufnr)
  luvlsp.bufmap[uri] = bufnr
  local text = table.concat(a.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
  if a.nvim_buf_get_option(bufnr, 'eol') then text = text..'\n' end
  luvlsp.shadow[bufnr] = a.nvim_buf_get_offset(bufnr,a.nvim_buf_line_count(bufnr))
  local version = a.nvim_buf_get_changedtick(bufnr)
  local params = {textDocument = {uri=uri,text=text,version=version,languageId=luvlsp.lsp_languageId}}
  luvlsp.d(params)
  luvlsp.msg("textDocument/didOpen", params)
  a.nvim_buf_attach(bufnr, false, {on_lines=function(...) luvlsp.do_change(...) end})
end


function luvlsp.on_diag(params)
  local MessageType = { Error = 1, Warning = 2, Info = 3, Log = 4 }
  local bufnr = luvlsp.bufmap[params.uri]
  a.nvim_buf_clear_highlight(bufnr, luvlsp.ns, 0, -1)
  local last_line, last_severity = -1, -1
  for _, msg in ipairs(params.diagnostics) do
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
    a.nvim_buf_set_virtual_text(bufnr, luvlsp.ns, range.start.line, {{'▶ '..msg.message, msg_hl}}, {})

    local loc_hl = "LspLocation"
    a.nvim_buf_add_highlight(bufnr, luvlsp.ns, loc_hl, range.start.line, range.start.character, range._end.character)
    ::continue::
  end
end

function luvlsp.start()
  luvlsp.init(function()
    a.nvim_command("au FileType "..luvlsp.vim_ft.." lua luvlsp.check_file()")
    a.nvim_command("au VimLeavePre "..luvlsp.vim_ft.." lua luvlsp.close()")
    local bufs = a.nvim_list_bufs()
    for _, b in ipairs(bufs) do
      if a.nvim_buf_get_option(b, "ft") == luvlsp.vim_ft then
        luvlsp.check_file(b)
      end
    end
  end)
end

function luvlsp.check_file(bufnr)
  if bufnr == nil then
    bufnr = a.nvim_get_current_buf()
  end
  if luvlsp.shadow[bufnr] == nil then
    luvlsp.do_open(bufnr)
  end
end

function luvlsp.close()
  luvlsp.req("shutdown", nil, function() end)
  uv.read_stop(luvlsp.stdout)
  uv.read_stop(luvlsp.stderr)
  uv.shutdown(luvlsp.stdin, uv.close(luvlsp.handle, luvlsp.d("close")))
end

return luvlsp
