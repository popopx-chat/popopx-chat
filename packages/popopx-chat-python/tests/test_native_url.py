from unittest.mock import patch

import pytest

from simplex_chat._native import _libname, _libs_url, _platform_tag
from simplex_chat._version import LIBS_RELEASE


@patch("sys.platform", "linux")
@patch("platform.machine", return_value="x86_64")
def test_platform_linux_x64(_):
    assert _platform_tag() == "linux-x86_64"


@patch("sys.platform", "darwin")
@patch("platform.machine", return_value="arm64")
def test_platform_macos_arm64(_):
    assert _platform_tag() == "macos-aarch64"


@patch("sys.platform", "win32")
@patch("platform.machine", return_value="AMD64")
def test_platform_windows_x64(_):
    assert _platform_tag() == "windows-x86_64"


@patch("sys.platform", "freebsd")
@patch("platform.machine", return_value="x86_64")
def test_platform_unsupported(_):
    with pytest.raises(RuntimeError, match="Unsupported"):
        _platform_tag()


def test_libname_per_platform():
    # With no directory to inspect the loader answers with the name this fork builds.
    with patch("sys.platform", "linux"):
        assert _libname() == "libpopopx.so"
    with patch("sys.platform", "darwin"):
        assert _libname() == "libpopopx.dylib"
    with patch("sys.platform", "win32"):
        assert _libname() == "libpopopx.dll"


def test_libname_prefers_ours_and_falls_back(tmp_path):
    # The pinned upstream libs asset is still called libsimplex.*, so a directory that
    # only holds that file has to resolve to it rather than fail.
    with patch("sys.platform", "linux"):
        assert _libname(tmp_path) == "libpopopx.so"  # nothing there yet: the name we build
        (tmp_path / "libsimplex.so").touch()
        assert _libname(tmp_path) == "libsimplex.so"
        (tmp_path / "libpopopx.so").touch()
        assert _libname(tmp_path) == "libpopopx.so"


@patch("simplex_chat._native._platform_tag", return_value="linux-x86_64")
def test_url_sqlite(_):
    assert (
        _libs_url("sqlite")
        == "https://github.com/popopx-chat/popopx-chat-libs/releases/download/"
        f"{LIBS_RELEASE}/popopx-chat-libs-linux-x86_64.zip"
    )


@patch("simplex_chat._native._platform_tag", return_value="linux-x86_64")
def test_url_postgres(_):
    assert (
        _libs_url("postgres")
        == "https://github.com/popopx-chat/popopx-chat-libs/releases/download/"
        f"{LIBS_RELEASE}/popopx-chat-libs-linux-x86_64-postgres.zip"
    )
