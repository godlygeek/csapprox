" CSApprox:    Make gvim-only colorschemes Just Work terminal vim
" Maintainer:  Matthew Wozniski (mjw@drexel.edu)
" Date:        Wed, 01 Apr 2009 22:10:19 -0400
" Version:     3.50
" History:     :help csapprox-changelog
"
" Long Description:
" It's hard to find colorschemes for terminal Vim.  Most colorschemes are
" written to only support GVim, and don't work at all in terminal Vim.
"
" This plugin makes GVim-only colorschemes Just Work in terminal Vim, as long
" as the terminal supports 88 or 256 colors - and most do these days.  This
" usually requires no user interaction (but see below for what to do if things
" don't Just Work).  After getting this plugin happily installed, any time you
" use :colorscheme it will do its magic and make the colorscheme Just Work.
"
" Whenever you change colorschemes using the :colorscheme command this script
" will be executed.  It will take the colors that the scheme specified for use
" in the GUI and use an approximation algorithm to try to gracefully degrade
" them to the closest color available in your terminal.  If you are running in
" a GUI or if your terminal doesn't support 88 or 256 colors, no changes are
" made.  Also, no changes will be made if the colorscheme seems to have been
" high color already.
"
" License:
" Copyright (c) 2009, Matthew J. Wozniski
" All rights reserved.
"
" Redistribution and use in source and binary forms, with or without
" modification, are permitted provided that the following conditions are met:
"     * Redistributions of source code must retain the above copyright notice,
"       this list of conditions and the following disclaimer.
"     * Redistributions in binary form must reproduce the above copyright
"       notice, this list of conditions and the following disclaimer in the
"       documentation and/or other materials provided with the distribution.
"     * The names of the contributors may not be used to endorse or promote
"       products derived from this software without specific prior written
"       permission.
"
" THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER ``AS IS'' AND ANY EXPRESS
" OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
" OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
" NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR ANY DIRECT, INDIRECT,
" INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
" LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
" OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
" LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
" NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
" EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

" {>1} Basic plugin setup

" {>2} Check preconditions
" Quit if the user doesn't want or need us or is missing the gui feature.  We
" need +gui to be able to check the gui color settings; vim doesn't bother to
" store them if it is not built with +gui.
if exists('g:CSApprox_loaded')
  finish
elseif !has('gui') && v:version < 703
  " Vim versions less than < 7.3.0 need +gui.
  " Warn unless the user set g:CSApprox_verbose_level to zero.
  if get(g:, 'CSApprox_verbose_level', 1)
    echomsg "CSApprox needs gui support - not loading."
    echomsg "  See :help |csapprox-+gui| for possible workarounds."
  endif

  finish
endif

" {1} Mark us as loaded, and disable all compatibility options for now.
let g:CSApprox_loaded = 1

let s:savecpo = &cpo
set cpo&vim

" {>1} Collect info for the set highlights

" {>2} Determine if synIDattr is usable
" synIDattr() couldn't support 'guisp' until 7.2.052.  This function returns
" true if :redir is needed to find the 'guisp' attribute, false if synIDattr()
" is functional.  This test can be overridden by setting the global variable
" g:CSApprox_redirfallback to 1 (to force use of :redir) or to 0 (to force use
" of synIDattr()).
function! s:NeedRedirFallback()
  if !exists("g:CSApprox_redirfallback")
    let g:CSApprox_redirfallback = (v:version == 702 && !has('patch52'))
                                 \  || v:version < 702
  endif
  return g:CSApprox_redirfallback
endfunction

" {>2} Collect and store the highlights Get a dictionary containing
" information for every highlight group.  Return value is a dictionary mapping
" highlight group names to dictionaries with five keys each:
" [name|id|links|term|cterm|gui].
"   "name" is the highlight-group's name. 
"   "id" is the numeric id, suitable for passing to the synID* functions.
"   "links" holds the list of group names which are to be linked to this one.
"   "term", "cterm" and "gui" contain the highlight attributes as dictionaries.
"     Their keys are [fg|bg|extra|sp].
"     "extra" is a list of the non-color highlight information, such as 'bold'.
"     "sp" will be unset except under 'gui'
function! s:Highlights(modes)
  let rv = {} "return value
  let id2name = {}
  let name2link = {}

  let id = 0
  while 1
    let id += 1

    " Only interested in groups that exist
    if synIDtrans(id) == 0
      break
    endif

    " Handle vim bug allowing groups to be created without a name
    if synIDattr(id, "name") == ""
      continue
    endif

    " Handle linked highlight groups
    let name = synIDattr(id, "name")
    if synIDtrans(id) != id
      "save it for later. links can be out-of-order. see zellner.
      let name2link[name] = synIDtrans(id)
      continue
    endif

    let highlight = {'name':name, 'id':id, 'links':[]}
    for mode in a:modes
      let highlight[mode] = {}

      let attrs = s:PossibleAttributes()
      call filter(attrs, 'synIDattr(id, v:val, mode) == 1')
      let highlight[mode].extra = attrs

      for attr in [ "fg", "bg" ]
        let color = synIDattr(id, attr.'#', mode)
        if color == -1
          let highlight[mode][attr] = ''
        else
          let highlight[mode][attr] = color
        endif
      endfor

      if mode == "gui"
        let color = s:SynGuiSp(id, name)
        if color == -1
          let highlight[mode]["sp"] = ''
        else
          let highlight[mode]["sp"] = color
        endif
      endif

      " Link everything up!
      let rv[name] = highlight
      let id2name[id] = name
    endfor

  endwhile

  "record all the links we've seen
  for [name, link] in items(name2link)
    call add(rv[id2name[link]].links, name)
  endfor

  return rv
endfunction

" {>2} Retrieve guisp

" Get guisp using whichever method is specified by _redir_fallback
function! s:SynGuiSp(idx, name)
  if !s:NeedRedirFallback()
    return s:SynGuiSpAttr(a:idx)
  else
    return s:SynGuiSpRedir(a:name)
  endif
endfunction

" {>3} Implementation for retrieving guisp with redir hack
function! s:SynGuiSpRedir(name)
  redir => temp
  exe 'sil hi' a:name
  redir END
  let temp = matchstr(temp, 'guisp=\zs.*')
  if len(temp) == 0 || temp[0] =~ '\s'
    let temp = ""
  else
    " Make sure we can handle guisp='dark red'
    let temp = substitute(temp, '[\x00].*', '', '')
    let temp = substitute(temp, '\s*\(c\=term\|gui\).*', '', '')
    let temp = substitute(temp, '\s*$', '', '')
  endif
  return temp
endfunction

" {>3} Implementation for retrieving guisp with synIDattr()
function! s:SynGuiSpAttr(idx)
  return synIDattr(a:idx, 'sp#', 'gui')
endfunction

" {>1} Handle color names

" Place to store rgb.txt name to color mappings - lazy loaded if needed
let s:rgb = {}

" {>2} Builtin gui color names
" gui_x11.c and gui_gtk_x11.c have some default colors names that are searched
" if the x server doesn't know about a color.  If 'showrgb' is available,
" we'll default to using these color names and values, and overwrite them with
" other values if 'showrgb' tells us about those colors.
let s:rgb_defaults = { "lightred"     : "#FFBBBB",
                     \ "lightgreen"   : "#88FF88",
                     \ "lightmagenta" : "#FFBBFF",
                     \ "darkcyan"     : "#008888",
                     \ "darkblue"     : "#0000BB",
                     \ "darkred"      : "#BB0000",
                     \ "darkmagenta"  : "#BB00BB",
                     \ "darkgrey"     : "#BBBBBB",
                     \ "darkyellow"   : "#BBBB00",
                     \ "gray10"       : "#1A1A1A",
                     \ "grey10"       : "#1A1A1A",
                     \ "gray20"       : "#333333",
                     \ "grey20"       : "#333333",
                     \ "gray30"       : "#4D4D4D",
                     \ "grey30"       : "#4D4D4D",
                     \ "gray40"       : "#666666",
                     \ "grey40"       : "#666666",
                     \ "gray50"       : "#7F7F7F",
                     \ "grey50"       : "#7F7F7F",
                     \ "gray60"       : "#999999",
                     \ "grey60"       : "#999999",
                     \ "gray70"       : "#B3B3B3",
                     \ "grey70"       : "#B3B3B3",
                     \ "gray80"       : "#CCCCCC",
                     \ "grey80"       : "#CCCCCC",
                     \ "gray90"       : "#E5E5E5",
                     \ "grey90"       : "#E5E5E5" }

" {>2} Colors that vim will use by name in one of the default schemes, either
" for bg=light or for bg=dark.  This lets us avoid loading the entire rgb.txt
" database when the scheme itself doesn't ask for colors by name.
let s:rgb_presets = { "black"         : "#000000",
                     \ "blue"         : "#0000ff",
                     \ "brown"        : "#a52a2a",
                     \ "cyan"         : "#00ffff",
                     \ "darkblue"     : "#00008b",
                     \ "darkcyan"     : "#008b8b",
                     \ "darkgrey"     : "#a9a9a9",
                     \ "darkmagenta"  : "#8b008b",
                     \ "green"        : "#00ff00",
                     \ "grey"         : "#bebebe",
                     \ "grey40"       : "#666666",
                     \ "grey90"       : "#e5e5e5",
                     \ "lightblue"    : "#add8e6",
                     \ "lightcyan"    : "#e0ffff",
                     \ "lightgrey"    : "#d3d3d3",
                     \ "lightmagenta" : "#ffbbff",
                     \ "magenta"      : "#ff00ff",
                     \ "red"          : "#ff0000",
                     \ "seagreen"     : "#2e8b57",
                     \ "white"        : "#ffffff",
                     \ "yellow"       : "#ffff00" }

" {>2} Find available color names
" Find the valid named colors.  By default, use our own rgb list, but try to
" retrieve the system's list if g:CSApprox_use_showrgb is set to true.  Store
" the color names and color values to the dictionary s:rgb - the keys are
" color names (in lowercase), the values are strings representing color values
" (as '#rrggbb').
function! s:UpdateRgbHash()
  try
    if !exists("g:CSApprox_use_showrgb") || !g:CSApprox_use_showrgb
      throw "Not using showrgb"
    endif

    " We want to use the 'showrgb' program, if it's around
    let lines = split(system('showrgb'), '\n')

    if v:shell_error || !exists('lines') || empty(lines)
      throw "'showrgb' didn't give us an rgb.txt"
    endif

    let s:rgb = copy(s:rgb_defaults)

    " fmt is (blanks?)(red)(blanks)(green)(blanks)(blue)(blanks)(name)
    let parsepat  = '^\s*\(\d\+\)\s\+\(\d\+\)\s\+\(\d\+\)\s\+\(.*\)$'

    for line in lines
      let v = matchlist(line, parsepat)
      if len(v) < 0
        throw "CSApprox: Bad RGB line: " . string(line)
      endif
      let s:rgb[tolower(v[4])] = printf("#%02x%02x%02x", v[1], v[2], v[3])
    endfor
  catch
    try
      let s:rgb = csapprox#rgb()
    catch
      echohl ErrorMsg
      echomsg "Can't call rgb() from autoload/csapprox.vim"
      echomsg "Named colors will not be available!"
      echohl None
    endtry
  endtry

  return 0
endfunction

" {>1} Derive and set cterm attributes

" {>2} List of all possible attributes
function! s:PossibleAttributes()
  " inverse is exactly equivalent to reverse: they'll both be set or unset
  " the rest of these are distinct
  return [ "bold", "italic", "reverse", "standout", "underline", "undercurl" ]
endfunction

" {>2} Attribute overrides
" Allow the user to override a specified attribute with another attribute.
" For example, the default is to map 'italic' to 'underline' (since many
" terminals cannot display italic text, and gvim itself will replace italics
" with underlines where italicizing is impossible), and to replace 'sp' with
" 'fg' (since terminals can't use one color for the underline and another for
" the foreground, we color the entire word).  This default can of course be
" overridden by the user, by setting g:CSApprox_attr_map.  This map must be
" a dictionary of string keys, representing the same attributes that synIDattr
" can look up, to string values, representing the attribute mapped to or an
" empty string to disable the given attribute entirely.
function! s:attr_map(attr)
  return get(g:CSApprox_attr_map, a:attr, a:attr)
endfunction

function! s:NormalizeAttrMap(map)
  let old = copy(a:map)
  let new = filter(a:map, '0')

  let valid_attrs = [ 'bg', 'fg', 'sp' ] + s:PossibleAttributes()

  let colorattrs = [ 'fg', 'bg', 'sp' ]

  for olhs in keys(old)
    if olhs ==? 'inverse'
      let nlhs = 'reverse'
    endif

    let orhs = old[olhs]

    if orhs ==? 'inverse'
      let nrhs = 'reverse'
    endif

    let nlhs = tolower(olhs)
    let nrhs = tolower(orhs)

    try
      if index(valid_attrs, nlhs) == -1
        echomsg "CSApprox: Bad attr map (removing unrecognized attribute " . olhs . ")"
      elseif nrhs != '' && index(valid_attrs, nrhs) == -1
        echomsg "CSApprox: Bad attr map (removing unrecognized attribute " . orhs . ")"
      elseif nrhs != '' && !!(index(colorattrs, nlhs)+1) != !!(index(colorattrs, nrhs)+1)
        echomsg "CSApprox: Bad attr map (removing " . olhs . "; type mismatch with " . orhs . ")"
      elseif nrhs == 'sp'
        echomsg "CSApprox: Bad attr map (removing " . olhs . "; can't map to 'sp')"
      else
        let new[nlhs] = nrhs
      endif
    catch
      echo v:exception
    endtry
  endfor
endfunction

" {>2} Normalize the GUI settings of a highlight group
" If the Normal group is cleared, set it to gvim's default, black on white
" Although this is a really weird thing for a scheme to do, the 'default'
" colorscheme does this.
function! s:FixupGuiInfo(highlights)
  if a:highlights['Normal'].gui.bg == ''
    let a:highlights['Normal'].gui.bg = 'white'
  endif

  if a:highlights['Normal'].gui.fg == ''
    let a:highlights['Normal'].gui.fg = 'black'
  endif
endfunction

" {>2} Map gui settings to cterm settings
" Given information about a highlight group, replace the cterm settings with
" the mapped gui settings, applying any attribute overrides along the way.  In
" particular, this gives special treatment to the 'guisp' attribute.  In
" particular, we ensure that the 'sp' attribute is never set for cterm, since
" no terminal can handle that particular highlight.  If the user wants to
" display the guisp color, he should map it to either 'fg' or 'bg' using
" g:CSApprox_attr_map.
function! s:FixupCtermInfo(highlights)
  for hl in values(a:highlights)
    let hl.cterm = {}

    " Find attributes to be set in the terminal
    let hl.cterm.extra = copy(hl.gui.extra)
    call map(hl.cterm.extra, 's:attr_map(v:val)')

    for mode in [ "bg", "fg" ]
      let hl.cterm[s:attr_map(mode)] = hl.gui[mode]
    endfor

    if strlen(hl.gui.sp) && s:attr_map('sp') != 'sp'
      let hl.cterm[s:attr_map('sp')] = hl.gui.sp
    endif

    if exists("g:CSApprox_fake_reverse") 
        \&& g:CSApprox_fake_reverse 
        \&& index(hl.cterm.extra, 'reverse') != -1
      "manually swap the colors
      call filter(hl.cterm.extra, 'v:val != "reverse"')

      if hl.cterm.bg == ''
        let hl.cterm.bg = 'bg'
      endif

      if hl.cterm.fg == ''
        let hl.cterm.fg = 'fg'
      endif

      let [hl.cterm.fg, hl.cterm.bg] = [hl.cterm.bg, hl.cterm.fg]
    endif

  endfor
endfunction

" {>2} Kludge around inability to reference autoload functions
function! s:DefaultApproximator(...)
  return call('csapprox#per_component#Approximate', a:000)
endfunction

" {>2} Set cterm colors for a highlight group
" Given the information for a single highlight group (ie, the value of
" one of the items in s:Highlights() already normalized with s:FixupCtermInfo
" and s:FixupGuiInfo), handle matching the gvim colors to the closest cterm
" colors by calling the appropriate approximator as specified with the
" g:CSApprox_approximator_function variable and set the colors and attributes
" appropriately to match the gui.
function! s:SetCtermFromGui(hl)
  let hl = a:hl

  " Set up the default approximator function, if needed
  if !exists("g:CSApprox_approximator_function")
    let g:CSApprox_approximator_function = function("s:DefaultApproximator")
  endif

  " Clear existing highlights
  exe 'hi' hl.name 'cterm=NONE ctermbg=NONE ctermfg=NONE'

  for mode in [ 'bg', 'fg' ]
    let val = hl.cterm[mode]

    " Skip unset colors
    if val == -1 || val == ""
      continue
    endif

    " Try translating anything but 'fg', 'bg', #rrggbb, and rrggbb from an
    " rgb.txt color to a #rrggbb color
    if val !~? '^[fb]g$' && val !~ '^#\?\x\{6}$'
      try
        " First see if it is in our preset-by-vim rgb list
        let val = s:rgb_presets[tolower(val)]
      catch
        " Then try loading and checking our real rgb list
        if empty(s:rgb)
          call s:UpdateRgbHash()
        endif
        try
          let val = s:rgb[tolower(val)]
        catch
          " And then barf if we still haven't found it
          if &verbose
            echomsg "CSApprox: Colorscheme uses unknown color \"" . val . "\""
          endif
          continue
        endtry
      endtry
    endif

    if val =~? '^[fb]g$'
      exe 'hi' hl.name 'cterm' . mode . '=' . val
      let hl.cterm[mode] = val
    elseif val =~ '^#\?\x\{6}$'
      let val = substitute(val, '^#', '', '')
      let r = str2nr(val[0:1], 16)
      let g = str2nr(val[2:3], 16)
      let b = str2nr(val[4:5], 16)
      let hl.cterm[mode] = g:CSApprox_approximator_function(r, g, b)
      exe 'hi' hl.name 'cterm' . mode . '=' . hl.cterm[mode]
    elseif val == ''
      " do nothing
    else
      throw "Internal error handling color: " . val
    endif
  endfor

  " Link the links
  for link in hl.links
    exe 'hi! link' link hl.name
  endfor

  " Finally, set the attributes
  if !empty(hl.cterm.extra)
    exe 'hi' hl.name 'cterm=' . join(hl.cterm.extra, ',')
  endif
endfunction


" {>1} Top-level control

" {>2} Builtin cterm color names above 15
" Vim defines some color name to high color mappings internally (see
" syntax.c:do_highlight).  Since we don't want to overwrite a colorscheme that
" was actually written for a high color terminal with our choices, but have no
" way to tell if a colorscheme was written for a high color terminal, we fall
" back on guessing.  If any highlight group has a cterm color set to 16 or
" higher, we assume that the user has used a high color colorscheme - unless
" that color is one of the below, which vim can set internally when a color is
" requested by name.
let s:presets_88  = []
let s:presets_88 += [32] " Brown
let s:presets_88 += [72] " DarkYellow
let s:presets_88 += [84] " Gray
let s:presets_88 += [84] " Grey
let s:presets_88 += [82] " DarkGray
let s:presets_88 += [82] " DarkGrey
let s:presets_88 += [43] " LightBlue
let s:presets_88 += [61] " LightGreen
let s:presets_88 += [63] " LightCyan
let s:presets_88 += [74] " LightRed
let s:presets_88 += [75] " LightMagenta
let s:presets_88 += [78] " LightYellow

let s:presets_256  = []
let s:presets_256 += [130] " Brown
let s:presets_256 += [130] " DarkYellow
let s:presets_256 += [248] " Gray
let s:presets_256 += [248] " Grey
let s:presets_256 += [242] " DarkGray
let s:presets_256 += [242] " DarkGrey
let s:presets_256 += [ 81] " LightBlue
let s:presets_256 += [121] " LightGreen
let s:presets_256 += [159] " LightCyan
let s:presets_256 += [224] " LightRed
let s:presets_256 += [225] " LightMagenta
let s:presets_256 += [229] " LightYellow

" {>2} Wrapper around :exe to allow :executing multiple commands.
" "cmd" is the command to be :executed.
" If the variable is a String, it is :executed.
" If the variable is a List, each element is :executed.
function! s:exe(cmd)
  if type(a:cmd) == type('')
    exe a:cmd
  else
    for cmd in a:cmd
      call s:exe(cmd)
    endfor
  endif
endfunction

" {>2} Function to handle hooks
" Prototype: HandleHooks(type [, scheme])
" "type" is the type of hook to be executed, ie. "pre" or "post"
" "scheme" is the name of the colorscheme that is currently active, if known
"
" If the variables g:CSApprox_hook_{type} and g:CSApprox_hook_{scheme}_{type}
" exist, this will :execute them in that order.  If one does not exist, it
" will silently be ignored.
"
" If the scheme name contains characters that are invalid in a variable name,
" they will simply be removed.  Ie, g:colors_name = "123 foo_bar-baz456"
" becomes "foo_barbaz456"
"
" NOTE: Exceptions will be printed out, rather than end processing early.  The
" rationale is that it is worse for the user to fix the hook in an editor with
" broken colors.  :)
function! s:HandleHooks(type, ...)
  let type = a:type
  let scheme = (a:0 == 1 ? a:1 : "")
  let scheme = substitute(scheme, '[^[:alnum:]_]', '', 'g')
  let scheme = substitute(scheme, '^\d\+', '', '')

  for cmd in [ 'g:CSApprox_hook_' . type,
             \ 'g:CSApprox_' . scheme . '_hook_' . type,
             \ 'g:CSApprox_hook_' . scheme . '_' . type ]
    if exists(cmd)
      try
        call s:exe(eval(cmd))
      catch
        echomsg "Error processing " . cmd . ":"
        echomsg v:exception
      endtry
    endif
  endfor
endfunction

" {>2} Main function
" Wrapper around the actual implementation to make it easier to ensure that
" all temporary settings are restored by the time we return, whether or not
" something was thrown.  Additionally, sets the 'verbose' option to the max of
" g:CSApprox_verbose_level (default 1) and &verbose for the duration of the
" main function.  This allows us to default to a message whenever any error,
" even a recoverable one, occurs, meaning the user quickly finds out when
" something's wrong, but makes it very easy for the user to make us silent.
function! s:CSApprox(...)
  try
    if a:0 == 1 && a:1
      if !exists('s:inhibit_hicolor_test')
        let s:inhibit_hicolor_test = 0
      endif
      let s:inhibit_hicolor_test += 1
    endif

    let savelz  = &lz

    set lz

    if exists("g:CSApprox_attr_map") && type(g:CSApprox_attr_map) == type({})
      call s:NormalizeAttrMap(g:CSApprox_attr_map)
    else
      let g:CSApprox_attr_map = { 'italic' : 'underline', 'sp' : 'fg' }
    endif

    " colors_name must be unset and reset, or vim will helpfully reload the
    " colorscheme when we set the background for the Normal group.
    " See the help entries ':hi-normal-cterm' and 'g:colors_name'
    if exists("g:colors_name")
      let colors_name = g:colors_name
      unlet g:colors_name
    endif

    " Similarly, the global variable "syntax_cmd" must be set to something vim
    " doesn't recognize, lest vim helpfully switch all colors back to the
    " default whenever the Normal group is changed (in syncolor.vim)...
    if exists("g:syntax_cmd")
      let syntax_cmd = g:syntax_cmd
    endif
    let g:syntax_cmd = "PLEASE DON'T CHANGE ANY COLORS!!!"

    " Set up our verbosity level, if needed.
    " Default to 1, so the user can know if something's wrong.
    if !exists("g:CSApprox_verbose_level")
      let g:CSApprox_verbose_level = 1
    endif

    call s:HandleHooks("pre", (exists("colors_name") ? colors_name : ""))

    let old_bg = &bg

    " Set 'verbose' set to the maximum of &verbose and CSApprox_verbose_level
    exe max([&vbs, g:CSApprox_verbose_level]) 'verbose call s:CSApproxImpl()'

    let &bg = old_bg

    call s:HandleHooks("post", (exists("colors_name") ? colors_name : ""))
  finally
    if exists("colors_name")
      let g:colors_name = colors_name
    endif

    unlet g:syntax_cmd
    if exists("syntax_cmd")
      let g:syntax_cmd = syntax_cmd
    endif

    let &lz   = savelz

    if a:0 == 1 && a:1
      let s:inhibit_hicolor_test -= 1
      if s:inhibit_hicolor_test == 0
        unlet s:inhibit_hicolor_test
      endif
    endif
  endtry
endfunction

" {>2} CSApprox implementation
" Verifies that the user has not started the gui, and that vim recognizes his
" terminal as having enough colors for us to go on, then gathers the existing
" highlights and sets the cterm colors to match the gui colors for all those
" highlights (unless the colorscheme was already high-color).
function! s:CSApproxImpl()
  " Return if not running in an 88/256 color terminal
  if &t_Co != 256 && &t_Co != 88
    if &verbose && &t_Co != ''
      echomsg "CSApprox skipped; terminal only has" &t_Co "colors, not 88/256"
      echomsg "Try checking :help csapprox-terminal for workarounds"
    endif

    return
  endif

  " Get the current highlight colors
  let highlights = s:Highlights(["gui"])

  let names = keys(highlights)

  " Make sure that the script is not already 256 color by checking to make
  " sure that no groups are set to a value above 256, unless the color they're
  " set to can be set internally by vim (gotten by scraping
  " color_numbers_{88,256} in syntax.c:do_highlight)
  "
  " XXX: s:inhibit_hicolor_test allows this test to be skipped for snapshots
  if !exists("s:inhibit_hicolor_test") || !s:inhibit_hicolor_test
    for name in names
      for type in [ 'bg', 'fg' ]
        let color = synIDattr(highlights[name].id, type, 'cterm')

        if color > 15 && index(s:presets_{&t_Co}, str2nr(color)) < 0
          " The value is set above 15, and wasn't set by vim.
          if &verbose >= 2
            echomsg 'CSApprox: Exiting - high' type 'color found for' name
          endif
          return
        endif
      endfor
    endfor
  endif

  call s:FixupGuiInfo(highlights)
  call s:FixupCtermInfo(highlights)

  " We need to set the Normal group first so 'bg' and 'fg' work as colors
  call insert(names, remove(names, index(names, 'Normal')))

  " then set each color's cterm attributes to match gui
  for name in names
    call s:SetCtermFromGui(highlights[name])
  endfor
endfunction

" {>2} Write out the current colors to an 88/256 color colorscheme file.
" "file" - destination filename
" "overwrite" - overwrite an existing file
function! s:CSApproxSnapshot(file, overwrite)
  let force = a:overwrite
  let file = fnamemodify(a:file, ":p")

  if empty(file)
    throw "Bad file name: \"" . file . "\""
  elseif (filewritable(fnamemodify(file, ':h')) != 2)
    throw "Cannot write to directory \"" . fnamemodify(file, ':h') . "\""
  elseif (glob(file) || filereadable(file)) && !force
    " TODO - respect 'confirm' here and prompt if it's set.
    echohl ErrorMsg
    echomsg "E13: File exists (add ! to override)"
    echohl None
    return
  endif

  " Sigh... This is basically a bug, but one that I have no chance of fixing.
  " Vim decides that Pmenu should be highlighted in 'LightMagenta' in terminal
  " vim and as 'Magenta' in gvim...  And I can't ask it what color it actually
  " *wants*.  As far as I can see, there's no way for me to learn that
  " I should output 'Magenta' when 'LightMagenta' is provided by vim for the
  " terminal.
  if !has('gui_running')
    echohl WarningMsg
    echomsg "Warning: The written colorscheme may have incorrect colors"
    echomsg "         when CSApproxSnapshot is used in terminal vim!"
    echohl None
  endif

  let save_t_Co = &t_Co
  let s:inhibit_hicolor_test = 1
  if exists("g:CSApprox_konsole")
    let save_CSApprox_konsole = g:CSApprox_konsole
  endif
  if exists("g:CSApprox_eterm")
    let save_CSApprox_eterm = g:CSApprox_eterm
  endif

  " TODO: it seems like we don't really need this, since we re-use CSApprox
  " Needed just like in CSApprox()
  if exists("g:colors_name")
    let colors_name = g:colors_name
    unlet g:colors_name
  endif

  " Needed just like in CSApprox()
  if exists("g:syntax_cmd")
    let syntax_cmd = g:syntax_cmd
  endif
  let g:syntax_cmd = "PLEASE DON'T CHANGE ANY COLORS!!!"

  try
    let lines = []
    let lines += [ '" This scheme was created by CSApproxSnapshot' ]
    let lines += [ '" on ' . strftime("%a, %d %b %Y") ]
    let lines += [ '' ]
    let lines += [ 'syntax on' ]
    let lines += [ 'let syntax_cmd="skip"' ]
    let lines += [ 'highlight clear' ]
    let lines += [ '' ]
    let lines += [ 'let g:colors_name = expand("<sfile>:t:r")' ]
    let lines += [ 'function! s:CSAhi(group, ...)' ]
    let lines += [ '    exe "hi clear" a:group' ]
    let lines += [ '    let hi = join(a:000, " ")' ]
    let lines += [ '    if v:version < 700' ]
    let lines += [ '        let hi = substitute(substitute(hi, "undercurl", "underline", "g"), "guisp=\\S\\+", "", "g")' ]
    let lines += [ '    endif' ]
    let lines += [ '    exe "hi" a:group hi' ]
    let lines += [ 'endfunction' ]
    let lines += [ 'command! -nargs=+ CSAhi call s:CSAhi(<f-args>)' ]
    let lines += [ '' ]
    let lines += [ 'function! s:CSAlink(from, to)' ]
    let lines += [ '    exe "hi clear" a:from' ]
    let lines += [ '    exe "hi! link" a:from a:to' ]
    let lines += [ 'endfunction' ]
    let lines += [ 'command! -nargs=+ CSAlink call s:CSAlink(<f-args>)' ]
    let lines += [ '' ]
    let lines += [ 'function! s:old_kde()' ]
    let lines += [ '  " Konsole only used its own palette up til KDE 4.2.0' ]
    let lines += [ "  if executable('kde4-config') && system('kde4-config --kde-version') =~ '^4\.[10]\.'" ]
    let lines += [ '    return 1' ]
    let lines += [ "  elseif executable('kde-config') && system('kde-config --version') =~# 'KDE: 3\.'" ]
    let lines += [ '    return 1' ]
    let lines += [ '  else' ]
    let lines += [ '    return 0' ]
    let lines += [ '  endif' ]
    let lines += [ 'endfunction' ]
    let lines += [ '' ]


    let xterm_colors = {}
    for round in [ 'xterm', 'konsole', 'eterm', 'urxvt' ]
      sil! unlet g:CSApprox_eterm
      sil! unlet g:CSApprox_konsole

      if round == 'konsole'
        let g:CSApprox_konsole = 1
      elseif round == 'eterm'
        let g:CSApprox_eterm = 1
      endif

      if round == 'urxvt'
        set t_Co=88
      else
        set t_Co=256
      endif

      if round == 'xterm'
        let lines += [ 'if has("gui_running") || &t_Co == ' . &t_Co ]
      elseif round == 'konsole'
        let lines += [ '' ]
        let lines += [ '    if &term =~# "^xterm" || &term =~# "^screen"' ]
        let lines += [ '        " that''s an ambiguous terminal setting' ]
        let lines += [ '        if (exists("g:CSApprox_konsole") && g:CSApprox_konsole) || (&term =~? "^konsole" && s:old_kde())' ]
      elseif round == 'eterm'
        let lines += [ '        elseif (exists("g:CSApprox_eterm") && g:CSApprox_eterm) || &term =~? "^eterm"']
      elseif round == 'urxvt'
        let lines += [ '        endif' ]
        let lines += [ '    endif' ]
        let lines += [ '' ]
        let lines += [ 'elseif &t_Co == ' . &t_Co ]
      endif

      call s:CSApprox()

      let highlights = s:Highlights(["term", "cterm", "gui"])
      call s:FixupGuiInfo(highlights)

      " Sort the color groups, for readability
      let names = sort(keys(highlights))
      " We need to set the Normal group first so 'bg' and 'fg' work as colors
      call insert(names, remove(names, index(names, 'Normal')))

      for name in names
        let hl = highlights[name]
        let line = ''
        for mode in [ 'term', 'cterm', 'gui' ]
          if !empty(hl[mode].extra)
            let line .= ' ' . mode . '=' . join(hl[mode].extra, ',')
          endif
          if mode != 'term'
            if hl[mode].bg != ''
              let line .= ' ' . mode . 'bg=' . hl[mode].bg
            endif
            if hl[mode].fg != ''
              let line .= ' ' . mode . 'fg=' . hl[mode].fg
            endif
            if mode == 'gui' && hl.gui.sp !~ '^\s*$'
              let line .= ' ' . mode . 'sp=' . hl[mode].sp
            endif
          endif
        endfor
        if line == ''
          continue
        else
          let line = '    CSAhi ' . name . line
        endif
        if round == 'xterm'
          " Record what we set in the xterm round
          let xterm_colors[line] = 1
        endif
        if round == 'xterm' || round == 'urxvt'
          let lines += [ line ]
          " Write out links for accuracy, in sorted order for readability
          " Some color schemes set links (see zenburn, ir_black)
          for link in sort(hl.links)
            let lines += [ '      CSAlink ' . link . ' ' . hl.name ]
          endfor
        elseif round == 'konsole' || round == 'eterm'
          " only need to output this if it wasn't set in the xterm round
          if !has_key(xterm_colors, line)
            let lines += [ '    ' . line ]
          endif
        else
          throw "Internal error snapshotting: " . round
        endif
      endfor
    endfor
    let lines += [ 'endif' ]
    let lines += [ '' ]
    let lines += [ 'delcommand CSAlink' ]
    let lines += [ 'delfunction s:CSAlink' ]
    let lines += [ 'delcommand CSAhi' ]
    let lines += [ 'delfunction s:CSAhi' ]
    let lines += [ 'let syntax_cmd="on"' ]
    call writefile(lines, file)
  finally
    let &t_Co = save_t_Co

    if exists("save_CSApprox_konsole")
      let g:CSApprox_konsole = save_CSApprox_konsole
    endif
    if exists("save_CSApprox_eterm")
      let g:CSApprox_eterm = save_CSApprox_eterm
    endif

    if exists("colors_name")
      let g:colors_name = colors_name
    endif

    unlet g:syntax_cmd
    if exists("syntax_cmd")
      let g:syntax_cmd = syntax_cmd
    endif

    call s:CSApprox()

    unlet s:inhibit_hicolor_test
  endtry
endfunction

" {>2} Snapshot user command
command! -bang -nargs=1 -complete=file -bar CSApproxSnapshot
        \ call s:CSApproxSnapshot(<f-args>, strlen("<bang>"))

" {>2} Manual updates
command -bang -bar CSApprox call s:CSApprox(strlen("<bang>"))

" {>1} Autocmds
" Set up an autogroup to hook us on the completion of any :colorscheme command
augroup CSApprox
  au!
  au ColorScheme * call s:CSApprox()
  "au User CSApproxPost highlight Normal ctermbg=none | highlight NonText ctermbg=None
augroup END

" {>1} Restore compatibility options
let &cpo = s:savecpo
unlet s:savecpo


" {0} vim:sw=2:sts=2:et:fdm=expr:fde=substitute(matchstr(getline(v\:lnum),'^\\s*"\\s*{\\zs.\\{-}\\ze}'),'^$','=','')
