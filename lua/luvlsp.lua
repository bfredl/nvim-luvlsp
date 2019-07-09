do local s, l = pcall(require,'luadev') if s then luadev = l end end

if _G.theid == nil then
  _G.theid = 0
end

local a = vim.api
a = vim.api

uv = vim.loop

safe_print = vim.schedule_wrap((luadev and luadev.print) or print)

exepath = "clangd"
args = {}

stdin = uv.new_pipe(false)
stdout = uv.new_pipe(false)
stderr = uv.new_pipe(false)

function lsp_exit_cb()
  safe_print("very exit")
end

handle, pid = uv.spawn(exepath,
                       {args=args,
                        stdio={stdin,stdout,stderr}},
                       exit_cb)

uv.read_start(stdout, function (err, chunk)
  --safe_print("stdout",chunk, err)
  if not err then
    on_stdout(chunk)
  end
end)

uv.read_start(stderr, function (err, chunk)
  safe_print("stderr",chunk, err)
end)

function wmsg(method,params,id)
  local msg = {jsonrpc = "2.0", method = method, params = params, id = id}
  local bytes = a.nvim_call_function('json_encode', {msg})
  return 'Content-Length: ' .. bytes:len() ..'\r\n\r\n' ..bytes
end

buffered = ''
function on_stdout(chunk)
  state, err = pcall(function()
  buffered = buffered..chunk
  local eol = string.find(buffered, '\r\n')
  if not eol then return end
  line = string.sub(buffered,1,eol-1)
  space = string.find(line, " ")
  length = tonumber(string.sub(line,space+1))
  -- TODO: can has Content-Type??
  if string.len(buffered) >= eol + 3 + length then
    local msg = buffered:sub(eol+2,eol+3+length)
    buffered = buffered:sub(eol+3+length+1)
    vim.schedule(function() on_msg(msg) end)
    -- check again, very tailcall
    return on_stdout('')
  end
  end)
  if not state then safe_print(err) end
end

pending = {}
function on_msg(bytes)
  msg = a.nvim_call_function('json_decode', {bytes})
  safe_print(vim.inspect(msg))
  if msg.id ~= nil then
    mycb = pending[msg.id]
    pending[msg.id] = nil
    return mycb(msg)
  end
end

function do_req(method, params,cb)
  my_id = _G.theid
  _G.theid = _G.theid + 1
  uv.write(stdin, wmsg(method, params, my_id))
  --safe_print("REQ " ..my_id.. " "..method)
  pending[my_id] = cb
end

function do_notify(method, params)
  uv.write(stdin, wmsg(method, params))
end

function do_init()
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
  do_req("initialize", p, function(reply)
    if reply.error then
      error(reply.error.message)
    end
    _G.init_status = reply.result
  end)
end

function do_change(bufnr, tick, start, stop, stopped)
  local uri = "file://"..a.nvim_buf_get_name(bufnr)
  local version = tick
  local textDocument = {uri=uri,version=version}
  local text = table.concat(a.nvim_buf_get_lines(bufnr, start, stopped, true), "\n") .. "\n"
  local range = {start={line=start,character=0},["end"]={line=stop+1,character=0}}
  -- what is rangeLength ???
  local edit = {range=range, text=text}
  do_notify("textDocument/didChange", {textDocument=textDocument, contentChanges={edit}})
end

function do_open(bufnr)
  local uri = "file://"..a.nvim_buf_get_name(bufnr)
  local text = table.concat(a.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
  if a.nvim_buf_get_option(bufnr, 'eol') then text = text..'\n' end
  local version = a.nvim_buf_get_changedtick(bufnr)
  local languageId = "c"
  local params = {textDocument = {uri=uri,text=text,version=version,languageId=languageId}}
  safe_print(params)
  do_notify("textDocument/didOpen", params)
  a.nvim_buf_attach(bufnr, false, {on_lines=function(...) do_change(...) end})
end

if false then
uv.write(stdin, "\n")
do_init()
do_open(2)

do_req("blååååøg", {3}, function (r) safe_print(r.error.message) end)
--print(vim.inspect(uv))
--uv.flush
end

