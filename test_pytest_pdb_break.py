import attr
import pytest

from pathlib import Path
from _pytest.pytester import LineMatcher
from pytest_pdb_break import BreakLoc, get_targets, PdbBreak
# Most of these need pexpect


prompt_re = r"\(Pdb[+]*\)\s?"


def test_get_targets():
    # XXX this assumes parametrized variants, whether their names are
    # auto-assigned or not, always appear in the order they'll be called.
    items = [BreakLoc(file="file_a", lnum=1, name="test_notfoo"),
             BreakLoc(file="file_b", lnum=1, name="test_foo"),
             BreakLoc(file="file_b", lnum=10, name="test_bar[one-1]"),
             BreakLoc(file="file_b", lnum=10, name="test_bar[two-2]"),
             BreakLoc(file="file_b", lnum=10, name="test_bar[three-3]"),
             BreakLoc(file="file_b", lnum=99, name="test_baz"),
             BreakLoc(file="file_c", lnum=1, name="test_notbaz")]
    assert get_targets("file_b", 30, items).popleft() == items[2]
    assert items[2].name == "test_bar[one-1]"
    items.reverse()
    assert get_targets("file_b", 30, items).popleft() == items[2]
    assert items[2].name == "test_bar[three-3]"


# TODO delete this after committing once; add note and SHA to _resolve_wanted
def test_cwd_lemma(testdir):
    """Current directory persists between ``pytest_configure`` visits.
    (Which is when ``._resolve_wanted`` runs.)
    """
    testdir.makeconftest("""
        pytest_plugins = ['pytest_one', 'pytest_two']
    """)
    common = """
        def pytest_configure(config):
            cwd = type(config.invocation_dir)()
            print('in', %%r)
            print('invocation_dir:', config.invocation_dir)
            print('cwd:', cwd)
            if config.invocation_dir == cwd:
                import os
                os.chdir(%r)
    """ % str(testdir.test_tmproot)
    testdir.makepyfile(pytest_one=common % "one")
    testdir.makepyfile(pytest_two=common % "two")
    testdir.makepyfile("""
        def test_foo(request):
            cwd = type(request.config.invocation_dir)()
            assert request.config.invocation_dir.samefile(%r)
            assert cwd.samefile(%r)
    """ % (str(testdir.tmpdir), str(testdir.test_tmproot)))
    result = testdir.runpytest("--capture=no")
    result.assert_outcomes(passed=1)
    testdir.maketxtfile(log="\n".join(result.outlines))


def test_resolve_wanted(tmp_path, request):
    # tmp_path is a pathlib.Path object, which has no .chdir()
    import os

    # For rootdir determination, see:
    # - _pytest.config.findpaths
    # - _pytest.config.Config._initini
    # - testing/test_config.py (pytest project)
    import py
    invocation_dir = py.path.local()
    assert Path(invocation_dir).is_absolute()
    assert invocation_dir == Path().cwd() == request.config.invocation_dir
    assert invocation_dir.strpath == str(invocation_dir)

    # PdbBreak stub with mocked .config dirs
    Config = attr.make_class("Config", ["rootdir", "invocation_dir"])
    PdbClass = attr.make_class("PdbClass", ["config"])
    PdbClass._resolve_wanted = PdbBreak._resolve_wanted
    rootdir = tmp_path / "rootdir"
    inst = PdbClass(Config(py.path.local(rootdir), invocation_dir))

    rootdir.mkdir()
    os.chdir(rootdir)
    assert Path().cwd() == rootdir

    # Relative, top-level
    file = Path(rootdir / "test_top.py")
    path = Path(file.name)
    assert not path.is_absolute()
    wanted = BreakLoc(path, 1, None)
    with pytest.raises(FileNotFoundError):
        inst._resolve_wanted(wanted)
    file.write_text("pass")
    result = inst._resolve_wanted(wanted)
    assert result.file.exists()
    assert result.file.is_absolute()

    # Relative, subdir
    subdir = rootdir / "subdir"
    subdir.mkdir()
    file = subdir / "test_sub.py"
    path = file.relative_to(rootdir)
    assert not path.is_absolute()
    wanted = BreakLoc(path, 1, None)
    #
    file.write_text("pass")
    result = inst._resolve_wanted(wanted)
    assert result.file.exists()
    assert result.file.is_absolute()
    #
    os.chdir(subdir)
    result = inst._resolve_wanted(wanted)
    assert result.file.exists()
    assert result.file.is_absolute()


def unansi(byte_string, as_list=True):
    import re
    out = re.sub("\x1b\\[[\\d;]+m", "", byte_string.decode().strip())
    if as_list:
        return out.split("\r\n")
    out


@pytest.fixture
def testdir_setup(testdir):
    """Require main file."""
    testdir.makeconftest("""
        import sys
        sys.path.insert(0, %r)
        pytest_plugins = %r
    """ % (str(Path(__file__).parent), PdbBreak.__module__))
    return testdir


def test_invalid_arg(testdir_setup):
    td = testdir_setup
    td.makepyfile("""
        def test_foo():
            assert True
    """)

    # No line number (argparse error)
    result = td.runpytest("--break=test_invalid_arg.py")
    assert result.ret == 4
    lines = LineMatcher(result.stderr.lines)
    lines.fnmatch_lines(["usage:*", "*--break*invalid BreakLoc value*"])

    # Non-existent file
    result = td.runpytest("--break=foo:99")
    assert result.ret == 3
    lines = LineMatcher(result.stderr.lines)
    lines.fnmatch_lines("INTERNALERROR>*FileNotFoundError*")

    # Ambiguous case: no file named, but multiple given
    td.makepyfile(test_otherfile="""
        def test_bar():
            assert True
    """)
    result = td.runpytest("--break=1")
    assert result.ret == 3
    lines = LineMatcher(result.stdout.lines[-5:])
    lines.fnmatch_lines("INTERNALERROR>*RuntimeError: "
                        "breakpoint file couldn't be determined")

    # No file named, but pytest arg names one
    pe = td.spawn_pytest("--break=1 test_otherfile.py")  # <- Two sep args
    # XXX API call sig is different for these spawning funcs (string)
    pe.expect(prompt_re)
    befs = LineMatcher(unansi(pe.before))
    befs.fnmatch_lines([
        "*>*/test_otherfile.py(2)test_bar()",
        "->*assert True"
    ])
    pe.sendline("c")  # requested line is adjusted to something breakable


@pytest.fixture
def testdir_two_funcs(testdir_setup):
    # Note: unlike breakpoints, location line numbers are 0 indexed
    testdir_setup.makepyfile("""
        def test_true_int():
            # some comment
            somevar = True
            assert isinstance(True, int)   # <- line 4

        def test_false_int():              # <- line 6
            assert isinstance(False, int)
    """)
    return testdir_setup


def test_two_funcs_simple(testdir_two_funcs):
    pe = testdir_two_funcs.spawn_pytest("--break=test_two_funcs_simple.py:4")
    pe.expect(prompt_re)
    befs = LineMatcher(unansi(pe.before))
    befs.fnmatch_lines([
        "*>*/test_two_funcs_simple.py(4)test_true_int()",
        "->*# <- line 4",
    ])
    pe.sendline("c")


def test_two_funcs_comment(testdir_two_funcs):
    pe = testdir_two_funcs.spawn_pytest("--break=test_two_funcs_comment.py:2")
    pe.expect(prompt_re)
    befs = LineMatcher(unansi(pe.before))
    befs.fnmatch_lines([
        "*>*/test_two_funcs_comment.py(3)test_true_int()",
        "->*somevar = True"
    ])
    pe.sendline("c")


def test_two_funcs_gap(testdir_two_funcs):
    pe = testdir_two_funcs.spawn_pytest("--break=test_two_funcs_gap.py:5")
    pe.expect(prompt_re)
    befs = LineMatcher(unansi(pe.before))
    # Advances to first breakable line in next func
    befs.fnmatch_lines([
        "*>*/test_two_funcs_gap.py(7)test_false_int()",
        "->*isinstance(False, int)"
    ])
    pe.sendline("c")


def test_one_arg(testdir_setup):
    testdir_setup.makepyfile("""
        import pytest

        @pytest.fixture
        def string():
            yield "string"

        def test_string(string):
            assert string                # line 8

    """)
    pe = testdir_setup.spawn_pytest("--break=test_one_arg.py:8")
    pe.expect(prompt_re)
    befs = LineMatcher(unansi(pe.before))
    befs.fnmatch_lines("*>*/test_one_arg.py(8)test_string()")
    pe.sendline("c")


def test_mark_param(testdir_setup):
    # Only break once: with the first set of args bound
    testdir_setup.makepyfile("""
        import pytest

        @pytest.mark.parametrize("name,value", [("one", 1), ("two", 2)])
        def test_number(name, value):
            print(name)
            assert len(name) > value     # line 6
    """)
    pe = testdir_setup.spawn_pytest("--break=test_mark_param.py:6 "
                                    "--capture=no")
    pe.expect(prompt_re)
    befs = unansi(pe.before)
    assert "one" in befs
    pe.sendline("c")  # If called again, would get timeout error


@pytest.mark.parametrize("cap_method", ["fd", "sys"])
def test_capsys(testdir_setup, cap_method):
    testdir_setup.makepyfile(r"""
        def test_print(capsys):
            print("foo")
            capped = capsys.readouterr()
            assert capped.out == "foo\n"
            assert True                  # line 5
            print("bar")
            capped = capsys.readouterr()
            assert capped.out == "bar\n"
    """)  # raw string \n
    pe = testdir_setup.spawn_pytest("--break=test_capsys.py:5 "
                                    "--capture=%s" % cap_method)
    pe.expect(prompt_re)
    befs = unansi(pe.before)
    assert "foo" not in befs
    lbefs = LineMatcher(befs)
    lbefs.fnmatch_lines(("*>*/test_capsys.py(5)test_print()", "->*# line 5"))
    pe.sendline("c")
    afts = unansi(pe.read(-1))
    lafts = LineMatcher(afts)
    assert "bar" not in afts
    lafts.fnmatch_lines((".*[[]100%[]]", "*= 1 passed in * seconds =*"))


def test_capsys_noglobal(testdir_setup):
    testdir_setup.makepyfile(r"""
        def test_print(capsys):
            print("foo")
            assert capsys.readouterr() == "foo\n"
    """)
    result = testdir_setup.runpytest("--break=test_capsys_noglobal.py:3",
                                     "--capture=no")
    lout = LineMatcher(result.stdout.lines)
    lout.fnmatch_lines("*RuntimeError*capsys*global*")
    result.assert_outcomes(failed=1)  # this runs as function node obj


@pytest.fixture
def testdir_class(testdir_setup):
    testdir_setup.makepyfile("""
    class TestClass:
        class_attr = 1

        def test_one(self):
            '''multi
            line docstring
            '''
            x = "this"                        # line 8
            assert "h" in x

        def test_two(self):
            x = "hello"                       # line 12
            assert hasattr(x, 'check')
    """)
    return testdir_setup


def test_class_simple(testdir_class):
    pe = testdir_class.spawn_pytest("--break=test_class_simple.py:8")
    pe.expect(prompt_re)
    befs = LineMatcher(unansi(pe.before))
    befs.fnmatch_lines([
        "*>*/test_class_simple.py(8)test_one()",
        "->*# line 8"
    ])
    pe.sendline("c")


def test_class_early(testdir_class):
    # Target docstring
    pe = testdir_class.spawn_pytest("--break=test_class_early.py:5")
    pe.expect(prompt_re)
    befs = LineMatcher(unansi(pe.before))
    befs.fnmatch_lines([
        "*>*/test_class_early.py(8)test_one()",
        "->*# line 8"
    ])
    pe.sendline("c")


def test_class_gap(testdir_class):
    pe = testdir_class.spawn_pytest("--break=test_class_gap.py:10")
    pe.expect(prompt_re)
    befs = LineMatcher(unansi(pe.before))
    befs.fnmatch_lines([
        "*>*/test_class_gap.py(12)test_two()",
        "->*# line 12"
    ])
    pe.sendline("c")


def test_class_gap_named(testdir_class):
    # XXX while it's nice that this passes, it might not be desirable: if a
    # requested line precedes the start of the first test item, an error is
    # raised; but this doesn't apply to intervals between items, as shown here
    pe = testdir_class.spawn_pytest(
        "--break=test_class_gap_named.py:10 "
        "test_class_gap_named.py::TestClass::test_two"
    )
    pe.expect(prompt_re)
    befs = LineMatcher(unansi(pe.before))
    befs.fnmatch_lines([
        "*>*/test_class_gap_named.py(12)test_two()",
        "->*# line 12"
    ])
    pe.sendline("c")