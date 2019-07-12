hi default LspWarning guifg=#aaaa00
hi default LspError guifg=#ee2222
hi default LspOtherMsg guifg=#888888
hi default LspLocation gui=underline

function! LuvLsp()
  lua require'luvlsp'.start()
  lua require'luvlsp.feat'
endfunction
command! LuvLsp call LuvLsp()
