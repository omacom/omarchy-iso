"""A stand-in archinstall, so tests can import the orchestrator modules that use it.

archinstall exists only on the ISO, and archinstall_adapter and luks_tuning
import it at module level. Inside orchestrator_module() and adapter(),
`import archinstall.<anything>` succeeds and every name in it is a class that
accepts anything, unless the test supplies its own. Afterwards sys.modules is
as it was, so tests that stub the adapter or parts of archinstall themselves
are not affected by the order the test modules run in.
"""

import importlib
import importlib.abc
import importlib.machinery
import sys
import types
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

PACKAGE_ROOT = Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"


def _nothing(*_args, **_kwargs):
    return None


class _AnyClass(type):
    """A class whose missing attributes, and its instances', are functions
    that do nothing."""

    def __getattr__(cls, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return _nothing


def _instance_attribute(self, name):
    if name.startswith("__"):
        raise AttributeError(name)
    return _nothing


class _AnyModule(types.ModuleType):
    """A package whose every attribute is such a class, named as asked for."""

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        value = _AnyClass(name, (), {"__getattr__": _instance_attribute})
        setattr(self, name, value)
        return value


class _Finder(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    def find_spec(self, name, path=None, target=None):
        if name == "archinstall" or name.startswith("archinstall."):
            return importlib.machinery.ModuleSpec(name, self, is_package=True)
        return None

    def create_module(self, spec):
        return _AnyModule(spec.name)

    def exec_module(self, module):
        pass


@contextmanager
def archinstall(names=None):
    """Make archinstall importable. names maps a module to the attributes a
    test wants in it: {"archinstall.lib.installer": {"Installer": FakeInstaller}}."""
    before = dict(sys.modules)
    # Stand-ins another test module put in place are set aside, not edited.
    for name in [name for name in sys.modules if name == "archinstall" or name.startswith("archinstall.")]:
        del sys.modules[name]
    finder = _Finder()
    sys.meta_path.insert(0, finder)
    try:
        for module_name, attributes in (names or {}).items():
            module = importlib.import_module(module_name)
            for attribute, value in attributes.items():
                setattr(module, attribute, value)
        yield
    finally:
        sys.meta_path.remove(finder)
        for name in set(sys.modules) - set(before):
            del sys.modules[name]
        sys.modules.update(before)


@contextmanager
def orchestrator_module(name, names=None, version="4.4"):
    """orchestrator.<name>, imported against the stand-in archinstall, which
    stays importable for as long as the context is open: the orchestrator
    imports parts of archinstall when its functions run. version is what the
    adapter's startup check sees as the installed archinstall."""
    if str(PACKAGE_ROOT) not in sys.path:
        sys.path.insert(0, str(PACKAGE_ROOT))
    with archinstall(names), mock.patch("importlib.metadata.version", return_value=version):
        # Loaded afresh, with everything it imports from the orchestrator, so
        # it binds to this stand-in and not to one an earlier test left.
        for loaded in [loaded for loaded in sys.modules if loaded.startswith("orchestrator.")]:
            del sys.modules[loaded]
        yield importlib.import_module(f"orchestrator.{name}")


def adapter(names=None, version="4.4"):
    """The real archinstall_adapter; see orchestrator_module."""
    return orchestrator_module("archinstall_adapter", names, version)
