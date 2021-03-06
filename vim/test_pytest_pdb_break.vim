scriptencoding utf-8

" See 041ced4 for query_helper (get_config_info) stuff
" TODO if overhauling, use vader: https://github.com/junegunn/vader.vim

if !has('unix')
  cquit!
endif

if exists('$VIRTUAL_ENV')
  cquit!
endif

let s:tempdir = $PYTEST_PDB_BREAK_TEST_TEMPDIR
if empty(s:tempdir) || s:tempdir !~# '^\%(/[^/]\+\)\{2,}'
  cquit!
endif
let s:venvdir = $PYTEST_PDB_BREAK_TEST_VENVDIR
if empty(s:venvdir) || s:venvdir !~# '^\%(/[^/]\+\)\{3,}'
  cquit!
endif
let s:temphome = s:tempdir .'/vim'
call mkdir(s:temphome, 'p')

let g:pytest_pdb_break_testing = {}
let s:g = g:pytest_pdb_break_overrides
call pytest_pdb_break#new({'session': 'fake'})
let s:this_buffer = bufname('%')
let s:s = g:pytest_pdb_break_testing.s
let s:o = g:pytest_pdb_break_testing.o
let s:pfx = s:s.prefix()
let s:i = {}
let s:playlist = []
let s:tests = {}
let s:errors = []

if expand('%:p:h') . '/autoload/pytest_pdb_break.vim' != s:s.get('file')
  cquit! " bad &rtp or cwd or s:pfx
endif
execute 'cd '. s:temphome


function s:_fmterrors(k, v)
  let pat = '\(^.*\)\(line \d\+\): \(.*\)'
  let F = {m -> printf("[%d] %s(%s)\n\t%s\n", a:k,
        \ fnamemodify(m[1], ':t'), m[2], m[3])}
  return substitute(a:v, pat, F, '')
endfunction

function s:_report()
  let s:errors += map(copy(v:errors), funcref('s:_fmterrors'))
  if !empty($PYTEST_PDB_BREAK_TEST_VIM_TEST_OUTPUT)
    call writefile(s:errors, $PYTEST_PDB_BREAK_TEST_VIM_TEST_OUTPUT)
  else
    " https://github.com/junegunn/vader.vim ... vader#print_stderr
    for line in s:errors
      verbose echon line."\n"
    endfor
  endif
endfunction

function s:has_overrides()
  return len(filter(copy(s:g), 'v:key !~# "^_"'))
endfunction

function s:clear_overrides()
  call filter(s:g, '0')
endfunction

function s:runfail(test_func, ...)
  " ... => [exit hander][defer]
  let ec = 1000
  let Handler = a:0 ? a:1 : v:null
  let defer = a:0 == 2 ? a:2 : v:false
  let orig_defaults = copy(g:pytest_pdb_break_defaults)
  let orig_xtraopts = copy(g:pytest_pdb_break_extra_opts)
  try
    call a:test_func()
    let ec = 0
  catch /.*/
    let m = matchlist(v:exception, '^Vim\%((\a\+)\)\=:E\(\d\+\)')
    let ec = get(m, 1, 1001)
    call add(s:errors, s:_fmterrors(
          \ ec, printf('%s: %s', v:throwpoint, v:exception)
          \ ))
  finally
    if type(Handler) == 2
      try
        call Handler()
      catch /.*/
        call add(s:errors, v:exception)
        let ec = 1002
      endtry
    endif
    if !empty(s:errors) && !defer
      verbose echo join(s:errors, "\n") . "\n"
    endif
    if !empty(v:errors)
      let ec = len(v:errors)
      call s:_report()
    endif
    if ec && !defer
      cquit!
    endif
    call s:clear_overrides()
    let g:pytest_pdb_break_extra_opts = orig_xtraopts
    let g:pytest_pdb_break_defaults = orig_defaults
  endtry
  return ec
endfunction

function s:pybuf(name)
  let tempname = s:temphome . '/' . a:name
  if a:name =~# '^test_'
    call delete(tempname, 'rf')
    call mkdir(tempname)
  endif
  let Func = funcref('s:'. a:name)
  execute 'cd '. tempname
  let scratchbuf = tempname . '/source.py'
  execute 'edit '. scratchbuf
  call assert_true(exists('*s:'. a:name))
  call assert_equal('python', &filetype)
  call assert_false(exists('b:pytest_pdb_break_context'))
  call assert_false(exists('b:pytest_pdb_break_pytest_exe'))
  function! s:_pybuf_handler() closure
    execute 'bdelete!'. scratchbuf
    call assert_false(bufloaded(tempname))
    call assert_equal(s:this_buffer, bufname('%'))
  endfunction
  call s:runfail(Func, funcref('s:_pybuf_handler'))
endfunction

function s:pypath(name)
  let origpath = $PATH
  try
    let path = s:venvdir . '/base/bin'
    let $PATH = path .':'. $PATH
    return call('s:pybuf', [a:name])
  finally
    let $PATH = origpath
  endtry
endfunction

function s:capture(func, ...)
  " ... => [logfile name][mode]
  let rv = v:null
  let extra = []
  redir => output
  try
    silent exec 'let rv = a:func()'
  catch /.*/
    let extra += [v:exception]
  finally
    redir END
    let outlines = ['<<< '. string(a:func)] + split(output, "\n") + extra
    let outname = a:0 && type(a:1) == 1 ?
          \ a:1 : bufname('%') =~# 'source\.py$' ?
          \ 'log' : fnamemodify(bufname('%'), ':r') . '.log'
    let mode = a:0 == 2 ? a:2 : 'a'
    call writefile(outlines, outname, mode)
  endtry
  return [rv, output] " exc not included but maybe should be
endfunction

function s:write_src(src)
  if bufname('%') !~# '^'. s:temphome
    throw 'Cannot write '. bufname('%')
  endif
  call cursor(1, 1)
  normal! dG
  call append(0, a:src)
  normal! dG
  call assert_equal(a:src[-1], getline('$'))
  silent write
endfunction

function s:wait_for(test, maxwait)
  let n = a:maxwait
  while !a:test() && n > 0
    sleep 1m
    let n -= 1
  endwhile
  call assert_true(n)
endfunction

function s:set_ifuncs(...)
  for f in a:000
    let s = s:pfx . f
    call assert_true(exists('*'. s))
    let s:i[f] = funcref(s)
  endfor
endfunction

function s:func_equal(one, two)
  return get(a:one, 'func') == get(a:two, 'func')
endfunction

function s:tee(name, callable)
  call add(s:playlist, a:name)
  let s:tests[a:name] = a:callable
endfunction


" Utils (above) ---------------------------------------------------------------

let s:g.runner = {-> 'fake'}
call assert_false(s:func_equal(s:g.runner, s:o.runner))
call assert_equal(1, s:has_overrides())
call s:clear_overrides()
call assert_false(s:has_overrides())
call s:runfail(function('assert_true', [v:true])) " No file-scope v:errors yet

function s:test_fail(ecode)
  throw 'Should be '. a:ecode
endfunction
call assert_equal(1001, s:runfail(
      \ funcref('s:test_fail', [1001]), v:null, v:true
      \ ))
let s:_soon = 1 == len(s:errors) && match(s:errors[0], 'Should be 1001') != -1
let s:errors = []
call s:runfail(function('assert_true', [s:_soon]))

call assert_equal(1002, s:runfail(
      \ function('acos', [-1]), funcref('s:test_fail', [1002]), v:true
      \ ))
let s:_soon = ['Should be 1002'] == s:errors
let s:errors = []
call s:runfail(function('assert_true', [s:_soon]))

function s:test_utils()
  call assert_true(v:false)
endfunction
" Exit code matches len(v:errors)
call assert_equal(1, s:capture(
      \ funcref('s:runfail', [funcref('s:test_utils'), v:null, v:true]),
      \ s:temphome . '/test_utils.log', ''
      \ )[0])
let s:_soon = len(s:errors) == 1 && s:errors[0] =~# 'test_utils.*line 1'
      \ && len(v:errors) == 1 && v:errors[0] =~# 'test_utils.*line 1'
let s:errors = []
let v:errors = []
call s:runfail(function('assert_true', [s:_soon]))
unlet s:_soon

let s:ifuncs = [
      \ '_init',
      \ '_get_pytest_exe',
      \ '_get_interpreter',
      \ '_get_node_id_parts',
      \ '_check_json',
      \ '_present_loclist'
      \ ]
call s:runfail(funcref('s:set_ifuncs', s:ifuncs))


" new -------------------------------------------------------------------------

function s:test_new()
  let overrideables = [
        \ 'extend_python_path', 'get_context', 'get_node_id',
        \ 'prompt_for_item', 'runner', 'split'
        \ ]
  call assert_equal(overrideables, sort(keys(s:o)))
  function s:g.get_context()
    return {'fake': 1}
  endfunction
  function s:g.get_node_id(...)
    return [self, a:000]
  endfunction
  let args = [1, 2, 3]
  let d = pytest_pdb_break#new()
  let [ifaced, rv] = call(d.get_node_id, args)
  call assert_equal(d, ifaced)
  call assert_true(s:func_equal(s:g.get_node_id, d.get_node_id))
  call assert_true(has_key(ifaced, 'session'))
  call assert_equal(1, ifaced.session.fake)
  call assert_equal(args, rv)
  " Explicitly passed dict wins
  let s:g.extend_python_path = {-> a:000}  " ignored
  let d = pytest_pdb_break#new(ifaced)
  try
    " XXX if this is supposed to propagate, must always use in tandem?
    call assert_fails(call(d.extend_python_path, args))
  catch /.*/
    call assert_exception('E118:') "Too many arguments
  endtry
  let d = pytest_pdb_break#new()  " not ignored
  call assert_equal(args, call(d.extend_python_path, args))
  "
  let oneoff = {}
  function oneoff.split(...)
    return call(self.get_node_id, a:000)
  endfunction
  let rv = call(pytest_pdb_break#new(oneoff).split, args)
  call assert_equal(args, rv[1])
  let ifaced = rv[0]
  call assert_true(s:func_equal(s:o.runner, ifaced.runner))
  call assert_false(s:func_equal(s:o.get_context, ifaced.get_context))
  call assert_equal(ifaced,
        \ call(pytest_pdb_break#new(ifaced).get_node_id, args)[0])
  "
  function! g:pytest_pdb_break_overrides.runner(...) closure
    call remove(self, 'session')
    call assert_equal(overrideables, sort(keys(self)))
    return args == a:000
  endfunction
  "
  call assert_true(call(pytest_pdb_break#new().runner, args))
endfunction

call s:tee('new', funcref('s:runfail', [funcref('s:test_new')]))


" _get_pytest_exe and _get_exe ------------------------------------------------

function s:test_get_executables()
  "
  let bin_path = fnamemodify('fake', ':p')
  let pyvbin_path = fnamemodify('pv_exec', ':p')
  let pytest_path = bin_path . '/pytest'
  let pyv_pt_path = pyvbin_path . '/pytest'
  let interp_path = bin_path . '/python'
  call mkdir(bin_path)
  call mkdir(pyvbin_path)
  call writefile(['#!' . interp_path], pytest_path)
  call writefile(['#!' . interp_path], pyv_pt_path)
  call writefile([], interp_path)
  call setfperm(pytest_path, 'rwx------')
  call setfperm(pyv_pt_path, 'rwx------')
  call setfperm(interp_path, 'rwx------')
  "
  " Explicit b: option
  let b:pytest_pdb_break_pytest_exe = pytest_path
  call assert_equal(pytest_path, s:i._get_pytest_exe())
  call assert_equal(interp_path, s:i._get_interpreter(pytest_path))
  unlet b:pytest_pdb_break_pytest_exe
  "
  " Fake PATH
  let origpath = $PATH
  try
    let $PATH = bin_path .':'. $PATH
    call assert_equal(pytest_path, exepath('pytest'))
    call assert_equal(interp_path, exepath('python'))
    call assert_equal(pytest_path, s:i._get_pytest_exe())
    call assert_equal(interp_path, s:i._get_interpreter(pytest_path))
    "
    " Pyenv
    let pyenv_path = bin_path . '/pyenv'
    let shimlines = ['#!/usr/bin/env bash', 'set -e', 'export PYENV_ROOT']
    call writefile(shimlines, pytest_path)
    call writefile(['#!/bin/sh', 'echo '. pyv_pt_path], pyenv_path)
    call setfperm(pyenv_path, 'rwx------')
    call assert_equal(interp_path, s:i._get_interpreter(pytest_path))
    "
    let $PATH = pyvbin_path .':'. origpath
    try
      call s:i._get_interpreter(pyv_pt_path)
    catch /.*/
      call assert_exception('Could not find a python executable')
    endtry
  finally
    let $PATH = origpath
  endtry
endfunction

call s:tee('get_executables', funcref('s:pybuf', ['test_get_executables']))


" init ------------------------------------------------------------------------

function s:test_init()
  function s:_assert_clean_slate()
    " Invalid alt lib
    call assert_false(s:s.get('initialized'))
    call assert_false(s:s.exists('plugin'))
    call assert_false(s:s.exists('home'))
    call assert_false(s:s.exists('helper'))
    call assert_false(s:s.exists('isolib'))
  endfunction
  "
  " Invalid alt lib
  call s:_assert_clean_slate()
  let fake_lib = fnamemodify('test_init_isolib', ':p')
  call mkdir(fake_lib)
  let g:pytest_pdb_break_alt_lib = fake_lib
  try
    call s:i._init({})
  catch /.*/
    call assert_exception('Invalid alt lib:')
  endtry
  call s:s.assign('initialized', 'v:false')
  call s:s.forget('plugin')
  call s:s.forget('home')
  call s:s.forget('helper')
  call assert_false(s:s.exists('isolib'))
  "
  " Fake alt lib
  call s:_assert_clean_slate()
  if isdirectory(fake_lib)  " os should throw permissions error anyway
    call mkdir(fake_lib . '/pytest_pdb_break-x.x.x.dist-info')
  endif
  call s:i._init({})
  call s:s.assign('initialized', 'v:false')
  call s:s.forget('plugin')
  call s:s.forget('home')
  call s:s.forget('helper')
  call s:s.forget('isolib')
  unlet g:pytest_pdb_break_alt_lib
  "
  " Normal run
  call s:_assert_clean_slate()
  call s:i._init({'pytest_exe': s:venvdir .'/base/bin/pytest'})
  "
  call assert_true(s:s.get('initialized'))
  call assert_true(s:s.exists('plugin'))
  call assert_true(s:s.exists('home'))
  call assert_true(s:s.exists('helper'))
  call assert_true(s:s.exists('isolib'))
  call assert_equal(fnamemodify(s:s.get('file'), ':h:h:h'), s:s.get('home'))
endfunction

call s:tee('init', funcref('s:pybuf', ['test_init']))


" get_context -----------------------------------------------------------------

function s:test_get_context()
  " FIXME run against uninitialized state
  call assert_false(exists('b:pytest_pdb_break_context'))
  call mkdir('fake')
  call writefile(['#!/fakebin/fakepython'], 'fake/pytest')
  call setfperm('fake/pytest', 'rwx------')
  " Script-local vars persist
  let before = map(['plugin', 'home', 'helper', 'isolib'], 's:s.get(v:val)')
  let full = fnamemodify('fake', ':p') . '/pytest'
  let b:pytest_pdb_break_pytest_exe = full
  call s:o.get_context()
  call assert_true(has_key(b:pytest_pdb_break_context, full))
  let after = map(['plugin', 'home', 'helper', 'isolib'], 's:s.get(v:val)')
  call assert_equal(before, after)
  unlet b:pytest_pdb_break_pytest_exe
  " Modify PATH (as done by $VIRTUAL_ENV/bin/activate)
  let origpath = $PATH
  try
    let vbin = s:venvdir .'/base/bin'
    let vers = fnamemodify(s:venvdir, ':t')
    let vpy = vbin .'/python'. vers
    let vpt = vbin .'/pytest'
    let $PATH = vbin .':'. $PATH
    call assert_equal(vpt, exepath('pytest'))
    call assert_equal(vpy, exepath('python'. vers))
    call s:o.get_context()
    call assert_true(has_key(b:pytest_pdb_break_context, vpt))
  finally
    let $PATH = origpath
  endtry
endfunction

call s:tee('get_context', funcref('s:pybuf', ['test_get_context']))


" get_node_id_parts -----------------------------------------------------------

let s:src_two_funcs = [
      \ 'def test_first():',
      \ '    varone = True',
      \ '    assert varone',
      \ '',
      \ 'def some_func():',
      \ '    # a comment',
      \ '    return 1',
      \ '',
      \ 'def test_last(request):',
      \ '    def inner():',
      \ '        foo = 1',
      \ '        return True',
      \ '    vartwo = True',
      \ '    assert vartwo',
      \ ]

let s:src_one_class = [
      \ 'class TestClass:',
      \ '    """',
      \ '    class Example:',
      \ '    """',
      \ '    def test_one(self):',
      \ '        varone = 1',
      \ '        assert varone',
      \ '',
      \ '    def test_two(self, request):',
      \ '        vartwo = 2',
      \ '        assert vartwo',
      \ ]

function s:test_get_node_id_two_funcs()
  " Setup
  let buf = bufname('%')
  call assert_true(buf =~# '^/')
  call s:write_src(s:src_two_funcs)
  " Baseline
  call cursor(1, 1)
  let pos = searchpos('varone')
  call assert_notequal([0, 0], pos)
  " vint: -ProhibitCommandRelyOnUser
  normal [m
  call assert_true(getline('.') =~# 'def test_first')
  " Returns list
  call cursor(pos)
  let rv = s:i._get_node_id_parts()
  call assert_equal([buf, 'test_first'], rv)
  " External
  let ext_pos = searchpos('# a comment')
  call assert_notequal([0, 0], ext_pos)
  let [line_num, column] = pos
  let Partial = funcref(s:i._get_node_id_parts, [0, line_num, column, 0])
  let [__, out] = s:capture(Partial)
  call assert_match('No test found', out, 'Got: '. string(__))
  call assert_equal(ext_pos, getpos('.')[1:2])
  " List
  call cursor(pos)
  let rv = s:i._get_node_id_parts()
  call assert_equal([buf, 'test_first'], rv)
  call assert_equal(pos, getpos('.')[1:2])
  " In def line
  call cursor(1, 1)
  call assert_true(search('test_first') > 0)
  let [__, out] = s:capture(funcref(s:i._get_node_id_parts, []))
  call assert_match('No test found', out, 'Got: '. string(__))
  " Last line
  call cursor(line('$'), 1)
  normal! $
  let rv = s:i._get_node_id_parts()
  call assert_equal([buf, 'test_last'], rv)
  " Inner
  call searchpos('foo = 1')
  let rv = s:i._get_node_id_parts()
  call assert_equal([buf, 'test_last'], rv)
  " No match
  call cursor(ext_pos)
  let [__, out] = s:capture(funcref(s:i._get_node_id_parts, []))
  call assert_match('No test found', out, 'Got: '. string(__))
  call assert_equal(ext_pos, getpos('.')[1:2])
endfunction

function s:test_get_node_id_one_class()
  let buf = bufname('%')
  call assert_true(buf =~# '^/')
  call s:write_src(s:src_one_class)
  " Baseline
  call cursor(1, 1)
  let pos = searchpos('varone')
  call assert_notequal([0, 0], pos)
  " vint: -ProhibitCommandRelyOnUser
  normal [m
  call assert_true(getline('.') =~# 'def test_one')
  " Returns list
  call cursor(pos)
  let rv = s:i._get_node_id_parts()
  call assert_equal([buf, 'TestClass', 'test_one'], rv)
  " With signature
  call setline(1, 'class TestClass(object):')
  call assert_equal(pos, getpos('.')[1:2])
  let rv = s:i._get_node_id_parts()
  call assert_equal([buf, 'TestClass', 'test_one'], rv)
  " Between
  call cursor(1, 1)
  let pos = searchpos('^$')
  call assert_notequal([0, 0], pos)
  let [__, out] = s:capture(funcref(s:i._get_node_id_parts, []))
  call assert_match('No test found', out)
  " Last line
  call cursor(line('$'), 1)
  let rv = s:i._get_node_id_parts()
  call assert_equal([buf, 'TestClass', 'test_two'], rv)
  " Indentation level
  " FIXME bad example (implies there's some fixture named 'self')
  let unlikely = ['', 'def test_arg(self):', '    return self']
  call s:write_src(s:src_one_class + unlikely)
  call cursor(line('$'), 1)
  let rv = s:i._get_node_id_parts()
  call assert_equal([buf, 'test_arg'], rv)
endfunction

call s:tee('get_node_id_two_funcs',
      \ funcref('s:pybuf', ['test_get_node_id_two_funcs']))
call s:tee('get_node_id_one_class',
      \ funcref('s:pybuf', ['test_get_node_id_one_class']))


" check_json ------------------------------------------------------------------

function s:test_check_json()
  " XXX depends on test_init
  let vbin = s:venvdir .'/base/bin'
  let vers = fnamemodify(s:venvdir, ':t')
  let vpy = vbin .'/python'. vers
  let context = {'interpreter': vpy}
  call writefile(s:src_two_funcs, 'test_two_funcs.py')
  call writefile(s:src_one_class, 'test_one_class.py')
  " No such method
  let args = [context, 'fake', 'foo', 'bar']
  let [__, out] = s:capture(funcref(s:i._check_json, args))
  call assert_match('usage.*cmdline', out)
  " Subproc error
  let args = [context, 'get_collected', '--fakeopt']
  let [__, out] = s:capture(funcref(s:i._check_json, args))
  call assert_match('Traceback.*UsageError', out)
  " OK
  let args = [context, 'get_collected']
  let rv = call(s:i._check_json, args)
  call assert_equal(v:t_list, type(rv))
  for loc in rv
    call assert_true(has_key(loc, 'file'))
    call assert_true(has_key(loc, 'lnum'))
    call assert_true(has_key(loc, 'name'))
    call assert_true(has_key(loc, 'nodeid'))
  endfor
  call writefile([json_encode(rv)], 'rv.json')
endfunction

call s:tee('check_json', funcref('s:pybuf', ['test_check_json']))


" present_loclist -------------------------------------------------------------

function! s:test_present_loclist()
  " XXX depends on test_check_json, test_init
  let curwin = winnr()
  call assert_equal(0, getloclist(curwin, {'nr': '$'}).nr)
  let vbin = s:venvdir .'/base/bin'
  let fstr = 'grep -Hn if '. vbin .'/activate*'
  call setloclist(curwin, [], ' ', {'title': 'Foo', 'lines' : systemlist(fstr)})
  call assert_equal(1, getloclist(curwin, {'nr': '$'}).nr)
  let title = getloclist(curwin, {'title': 0, 'nr': '$'}).title
  call assert_equal('Foo', title)
  " Mock context, use output from previous test
  let lines = readfile(s:temphome .'/test_check_json/rv.json')
  call assert_true(len(lines))
  let locs = json_decode(join(lines, ''))
  let seen = []
  let ctx = {}
  let ctx.ll_callback = {ti -> add(seen, ti)}
  function s:_await_poploc() closure
    call call(s:i._present_loclist, [ctx, locs])
    let T = {-> (exists('ctx.ll_timer') && empty(timer_info(ctx.ll_timer)))}
    call s:wait_for(T, 1000)
  endfunction
  let [__, out] = s:capture(funcref('s:_await_poploc'))
  "
  call assert_match('selects', out)
  call assert_equal('quickfix', &buftype)
  call assert_equal(1, getloclist(curwin, {'nr': '$'}).nr)
  let title = getloclist(curwin, {'title': 1}).title
  call assert_match('Pytest', title)
  call assert_notequal(curwin, winnr())
  call assert_false(empty(maparg('<cr>', 'n')))
  execute "normal \<CR>"
  call s:wait_for({-> len(seen)}, 1000)
  call assert_equal(curwin, winnr())
  call assert_equal(locs[0], seen[0])
  call assert_equal('', &buftype)
  call assert_equal(1, getloclist(curwin, {'nr': '$'}).nr)
  let title = getloclist(curwin, {'title': 1}).title
  call assert_equal('Foo', title)
endfunction

call s:tee('present_loclist', funcref('s:pybuf', ['test_present_loclist']))


" extend_python_path ----------------------------------------------------------

function s:test_extend_python_path()
  " Depends on test_init
  try
    unlet $PYTHONPATH
  catch /^Vim\%((\a\+)\)\=:E488/
    let $PYTHONPATH = ''
  endtry
  call assert_true(empty($PYTHONPATH))
  "
  let ctx = {'PP': '/tmp/fake'}
  let calldict = {'session': ctx}
  "
  let rv = call(s:o.extend_python_path, [], calldict)
  call assert_equal(ctx.PP, rv)
  unlet ctx.PP
  let isolib = s:s.get('isolib')
  call assert_true(filereadable(isolib . '/pytest_pdb_break.py'))
  call assert_false(filereadable(isolib . '/tox.ini'))
  let rv = call(s:o.extend_python_path, [], calldict)
  call assert_equal(isolib, rv)
  call assert_equal(ctx.PP, isolib)
  unlet ctx.PP
  "
  let first = s:temphome . '/first'
  let $PYTHONPATH = first
  let rv = call(s:o.extend_python_path, [], calldict)
  call assert_equal(isolib .':'. first, rv)
  call assert_equal(isolib .':'. first, ctx.PP)
  call assert_equal($PYTHONPATH, first)
  " Returned path is filtered filtering
  let $PYTHONPATH = join([isolib, ctx.PP, isolib, isolib], ':')
  unlet ctx.PP
  let expected = join([isolib, first], ':')
  let rv = call(s:o.extend_python_path, [], calldict)
  call assert_equal(expected, rv)
  call assert_equal(expected, ctx.PP)
  try
    unlet $PYTHONPATH
  catch /^Vim\%((\a\+)\)\=:E488/
    let $PYTHONPATH = ''
  endtry
endfunction

call s:tee('extend_python_path',
      \ funcref('s:runfail', [funcref('s:test_extend_python_path')]))


" runner ----------------------------------------------------------------------

function s:test_runner()
  " Depends on test_init
  " Mocks split, get_node_id
  let thisbuf = bufname('%')
  let dirname = fnamemodify(bufname('%'), ':h')
  let isolib = s:s.get('isolib')
  let s:g.split = {-> a:000}
  let s:g.get_node_id = {-> join([thisbuf, 'test_first'], '::')}
  let b:pytest_pdb_break_pytest_exe = '/bin/true'
  let ctx = s:o.get_context()
  call assert_false(exists('ctx.PP'))
  "
  let [rvcl, rvjd] = pytest_pdb_break#new().runner('⁉')
  call assert_true(exists('ctx.PP'))
  call assert_equal(g:pytest_pdb_break_extra_opts, [])
  call assert_equal(['--complete'], g:pytest_pdb_break_defaults)
  call assert_false(exists('b:pytest_pdb_break_extra_opts'))
  call assert_equal([], ctx.opts)
  call assert_equal(ctx.session_opts, ['⁉'])
  let common = [
        \ '--complete', '--break='. thisbuf .':1', '⁉',
        \ thisbuf .'::test_first'
        \ ]
  if has('nvim')
    call assert_equal(
          \ ['env', 'PYTHONPATH='. isolib, '/bin/true'] + common,
          \ rvcl
          \ )
    call assert_equal({}, rvjd)
  else
    call assert_equal(['/bin/true'] + common, rvcl)
    call assert_equal({'env': {'PYTHONPATH': isolib}}, rvjd)
  endif
  let g:pytest_pdb_break_extra_opts = ['--foo']
  let b:pytest_pdb_break_extra_opts = ['--bar']
  let [rvcl, rvjd] = pytest_pdb_break#new().runner()
  call assert_equal(['--foo', '--bar'], ctx.opts)
  call assert_equal([], ctx.session_opts)
  let common = [
        \ '--foo', '--bar', '--complete', '--break='. thisbuf .':1',
        \ thisbuf .'::test_first'
        \ ]
  call assert_equal(common, rvcl[-5:])
  unlet b:pytest_pdb_break_extra_opts
endfunction

call s:tee('runner', funcref('s:pybuf', ['test_runner']))


" split -----------------------------------------------------------------------

function s:on_stdout(id, data, event) dict
  let str = join(a:data, '')
  call add(self.output, str)
  let comms = self.commands
  if str =~# self.prompt
    if !empty(comms)
      call chansend(a:id, [comms[0], ''])
      call remove(comms, 0)
    else
      call chansend(a:id, ['', ''])
    endif
  endif
endfunction

function s:out_cb(chan, msg) dict
  call add(self.output, a:msg)
  if a:msg =~# self.prompt
    if !empty(self.commands)
      call ch_sendraw(a:chan, self.commands[0] . "\n")
      call remove(self.commands, 0)
    else
      call ch_sendraw(a:chan, "\x4")
    endif
  endif
endfunction

function s:await_split(jd)
  let jobd = a:jd
  if has('nvim')
    call assert_equal([0], jobwait([jobd.job], 5000))
    execute 'bdelete! term'
    let outlines = split(join(jobd.output, ''), "\r\\|\n")
  else
    let bn = ch_getbufnr(jobd.job, 'out')
    let waited = 0
    while (ch_status(jobd.job) !=? 'closed'
          \ || job_status(jobd.job) !=? 'dead')
          \ && waited < 2000
      call term_wait(bn)
      let waited += 10
    endwhile
    call ch_log('waited: '. waited .'ms')
    bdelete!
    let _jd = get(jobd.out_cb, 'dict')
    let outlines = split(join(_jd.output, ''), "\r\n")
  endif
  call writefile(outlines, 'term.log')
  return outlines
endfunction

function s:test_split()
  let exe = s:venvdir . '/base/bin/python'
  let buf = bufname('%')
  let jobd = {'commands': ['import sys', 'sys.path[1]'], 'output': []}
  let jobd.prompt = '>>> $'
  if has('nvim')
    let cmdl = ['env', 'PYTHONPATH=/tmp/fake', exe, '-i']
    let jobd.on_stdout = funcref('s:on_stdout')
  else
    let cmdl = [exe, '-i']
    let _jobd = jobd
    let jobd = {}
    let jobd.env = {'PYTHONPATH': '/tmp/fake'}
    let jobd.out_cb = funcref('s:out_cb', _jobd)
    call ch_logfile(expand('%:p:h') .'/vim8-channel.log', 'a')
  endif
  call s:o.split(cmdl, jobd)
  call assert_true(has_key(jobd, 'vertical'))
  call assert_true(has_key(jobd, 'job'))
  call assert_notequal(buf, bufname('%'))
  let outlines = s:await_split(jobd)
  call assert_match('/tmp/fake', join(outlines, ''))
endfunction

call s:tee('split', funcref('s:pybuf', ['test_split']))


" functional ------------------------------------------------------------------

function s:sub_split(cmdline, jd) dict
  call assert_equal(self.session.jobd, a:jd)
  let expectd = {}
  let expectd.commands = ['import sys', 'sys.path[1]', 'q']
  let expectd.output = []
  let expectd.prompt = '(Pdb) $'
  if has('nvim')
    let jobd = extend(a:jd, expectd)
    let jobd.on_stdout = funcref('s:on_stdout')
  else
    let jobd = a:jd
    let jobd.out_cb = funcref('s:out_cb', expectd)
    call ch_logfile(expand('%:p:h') .'/vim8-channel.log', 'a')
  endif
  return self.super.split(a:cmdline, jobd)
endfunction

function s:test_live()
  let buf = bufname('%')
  let s:g.split = funcref('s:sub_split')
  let inst = pytest_pdb_break#new()
  let inst.super = {}
  let inst.super.split = s:o.split
  let ctx = inst.session
  call s:write_src(s:src_one_class)
  call cursor(1, 1)
  let pos = searchpos('varone')
  "
  call inst.runner()
  call s:wait_for({-> has_key(ctx.jobd, 'job')}, 2000) " no closure w. exists()
  "
  let outlines = s:await_split(ctx.jobd)
  let joined = join(outlines, '')
  call assert_match('/base/bin', joined)
  call assert_match('passed', joined)
endfunction

call s:tee('live', funcref('s:pypath', ['test_live']))


" -----------------------------------------------------------------------------

if exists('$PYTEST_PDB_BREAK_TEST_SELECTION')
  let s:wanted = split($PYTEST_PDB_BREAK_TEST_SELECTION, ',')
else
  let s:wanted = s:playlist
endif

for wanted in s:wanted
  call call(s:tests[wanted], [])
endfor

quitall!
