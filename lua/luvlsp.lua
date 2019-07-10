do local s, l = pcall(require,'luadev') if s then luadev = l end end

if _G.luvlsp == nil then
  _G.luvlsp = {
    theid = 0,
    buffered = '',
    pending = {},
  }
end
local luvlsp = _G.luvlsp

_G.a = vim.api
_G.uv = vim.loop
local a = vim.api
local uv = vim.loop

luvlsp.d = vim.schedule_wrap((luadev and luadev.print) or print)

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
    vim.schedule(function() luvlsp.on_msg(msg) end)
    -- check again, very tailcall
    return luvlsp.on_stdout('')
  end
end

function luvlsp.on_msg(bytes)
  local msg = a.nvim_call_function('json_decode', {bytes})
  luvlsp.d(vim.inspect(msg))
  if msg.id ~= nil then
    local mycb = luvlsp.pending[msg.id]
    luvlsp.pending[msg.id] = nil
    return mycb(msg)
  end
end

function luvlsp.req(method, params, cb)
  local my_id = luvlsp.theid
  luvlsp.theid = luvlsp.theid + 1
  luvlsp.pending[my_id] = cb
  luvlsp.msg(method, params, my_id)
  --luvlsp.d("REQ " ..my_id.. " "..method)
end

function luvlsp.init()
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
    _G.init_status = reply.result
  end)
end

function luvlsp.do_change(_, bufnr, tick, start, stop, stopped)
  local uri = "file://"..a.nvim_buf_get_name(bufnr)
  local version = tick
  local textDocument = {uri=uri,version=version}
  local text = table.concat(a.nvim_buf_get_lines(bufnr, start, stopped, true), "\n") .. "\n"
  local range = {start={line=start,character=0},["end"]={line=stop,character=0}}
  -- what is rangeLength ???
  local edit = {range=range, text=text}
  luvlsp.msg("textDocument/didChange", {textDocument=textDocument, contentChanges={edit}})
end

function luvlsp.do_open(bufnr)
  local uri = "file://"..a.nvim_buf_get_name(bufnr)
  local text = table.concat(a.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
  if a.nvim_buf_get_option(bufnr, 'eol') then text = text..'\n' end
  local version = a.nvim_buf_get_changedtick(bufnr)
  local languageId = "c"
  local params = {textDocument = {uri=uri,text=text,version=version,languageId=languageId}}
  luvlsp.d(params)
  luvlsp.msg("textDocument/didOpen", params)
  a.nvim_buf_attach(bufnr, false, {on_lines=function(...) luvlsp.do_change(...) end})
end

if false then
luvlsp.init()
luvlsp.do_open(2)

luvlsp.req("blååååøg", {3}, function(r) luvlsp.d(r.error.message) end)
--print(vim.inspect(uv))
--uv.flush
end

