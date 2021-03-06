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
    msg_handlers = {},
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

if _G.luvlsp_config ~= nil then
  luvlsp.config = _G.luvlsp_config
else
  luvlsp.config  = {
    exepath = "clangd",
    --exepath = "/home/bjorn/dev/llvm-project/build/bin/clangd"
    args = {},
    vim_ft = "c",
    lsp_languageId = "c"
  }
end

function luvlsp.spawn()
  luvlsp.stdin = uv.new_pipe(false)
  luvlsp.stdout = uv.new_pipe(false)
  luvlsp.stderr = uv.new_pipe(false)

  local function exit_cb()
    luvlsp.d("very exit")
  end

  local stdio = {luvlsp.stdin,luvlsp.stdout,luvlsp.stderr}
  local opts = {args=luvlsp.config.args, stdio=stdio}
  luvlsp.handle, luvlsp.pid = uv.spawn(luvlsp.config.exepath, opts, exit_cb)

  uv.read_start(luvlsp.stdout, function (err, chunk)
    --luvlsp.d("stdout",chunk, err)
    if not err then
      luvlsp.on_stdout(chunk)
    end
  end)

  uv.read_start(luvlsp.stderr, function (err, chunk)
    luvlsp.d("stderr",chunk, err)
  end)
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
  elseif luvlsp.msg_handlers[msg.method] then
    luvlsp.msg_handlers[msg.method](msg)
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
    textDocument = require'luvlsp.feat'.textDocument_caps,
    offsetEncoding = {'utf-8', 'utf-16'},
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
    luvlsp.is_utf8 = (reply.result.offsetEncoding == "utf-8")
    if cb then cb() end
  end)
end

function luvlsp.do_change(_, bufnr, tick, start, stop, stopped, bytes, _, units)
  local uri = "file://"..a.nvim_buf_get_name(bufnr)
  local version = tick
  local textDocument = {uri=uri,version=version}
  local lines = a.nvim_buf_get_lines(bufnr, start, stopped, true)
  local text = table.concat(lines, "\n") .. ((stopped > start) and "\n" or "")
  local range = {start={line=start,character=0},["end"]={line=stop,character=0}}
  local length = (luvlsp.is_utf8 and bytes) or units
  local edit = {range=range, text=text, rangeLength=length}
  luvlsp.msg("textDocument/didChange", {textDocument=textDocument, contentChanges={edit}})
end

function luvlsp.do_open(bufnr)
  local uri = "file://"..a.nvim_buf_get_name(bufnr)
  luvlsp.bufmap[uri] = bufnr
  local text = table.concat(a.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
  if a.nvim_buf_get_option(bufnr, 'eol') then text = text..'\n' end
  luvlsp.shadow[bufnr] = true
  local version = a.nvim_buf_get_changedtick(bufnr)
  local params = {textDocument = {uri=uri,text=text,version=version,languageId=luvlsp.config.lsp_languageId}}
  luvlsp.d(params)
  luvlsp.msg("textDocument/didOpen", params)
  a.nvim_buf_attach(bufnr, false, {
    on_lines=function(...) luvlsp.do_change(...) end,
    utf_sizes=not luvlsp.is_utf8
  })
end


function luvlsp.start()
  luvlsp.init(function()
    a.nvim_command("au FileType "..luvlsp.config.vim_ft.." lua luvlsp.check_file()")
    a.nvim_command("au VimLeavePre * lua luvlsp.close()")
    local bufs = a.nvim_list_bufs()
    for _, b in ipairs(bufs) do
      if a.nvim_buf_get_option(b, "ft") == luvlsp.config.vim_ft then
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
  luvlsp.msg("exit", nil)
  uv.shutdown(luvlsp.stdin, function()
    -- TODO: if closing LSP before nvim exits, we should delay this
    -- to receive any final stdout/stderr
    uv.close(luvlsp.stdout)
    uv.close(luvlsp.stderr)
    uv.close(luvlsp.stdin)
    uv.close(luvlsp.handle)
  end)
end

return luvlsp
