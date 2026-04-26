" set common settings
set expandtab number tabstop=4 splitbelow splitright shiftwidth=2 softtabstop=2 ignorecase smartcase smartindent
" turn on syntax highlighting
syntax enable
" cursor highlighting
autocmd InsertEnter,InsertLeave * set cul!
" yaml config
autocmd FileType yaml setlocal ai et ts=2 sw=2 cuc!

" set gvim settings
if has("gui_running")
  set lines=43 columns=132
  set guifont=Cascadia\ Code\ PL\ 12
endif

" Install vim-plug if not found
if empty(glob('~/.vim/autoload/plug.vim'))
  silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
endif
" Run PlugInstall if there are missing plugins
autocmd VimEnter * if len(filter(values(g:plugs), '!isdirectory(v:val.dir)')) | PlugInstall --sync | q | endif
" vim-plug
call plug#begin()
  " vim-code-dark theme
  Plug 'tomasiser/vim-code-dark'
  " surround.vim
  Plug 'tpope/vim-surround'
  " NERD Commenter
  Plug 'preservim/nerdcommenter'
call plug#end()

" colorscheme
colorscheme codedark
" scheme customize
highlight Comment cterm=italic gui=italic

" keyboard shortcuts
let mapleader =" "
nnoremap <F8> Y<C-W>w<C-W>"0<C-W>w
xnoremap <F8> y<C-W>w<C-W>"0<C-W>w
inoremap kj <esc>

" abbreviations
abbr _bash #!/usr/bin/env bash<CR>
abbr _pwsh #!/usr/bin/env -S pwsh -nop<CR>
