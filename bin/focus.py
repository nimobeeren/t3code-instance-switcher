#!/usr/bin/env python3
"""Focus one of the two T3 Code instances: decide which one, then bring it forward.

usage: focus.py [--fallback name] [--personal pid] [--work pid]
prints the name of the instance it activated and exits 0 when it did.

Every option that is passed names a running instance together with the pid of
its main process; an instance that is not passed is not running. The one to
focus is, in order: the only running instance; the other one when one of them is
the focused application; the other one when one of them owns the frontmost
window; the one used most recently; and finally --fallback. Window order comes
from the window server, so the most recently used instance stays correct after
clicks, Cmd-Tab and our own focusing — nothing to record along the way. A window
that is closed, minimized or on another Space is not in the list, which leaves
that instance out of the running.

Activation is by pid: helper and backend processes cannot be activated, which is
why the pid recorded at exec time is the reliable handle. When activation fails
the chosen name is still printed, with a non-zero exit status so the caller can
fall back to `open`.
"""
import ctypes
import sys

CGWINDOWLIST_OPTION_ON_SCREEN_ONLY = 1 << 0
CGWINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS = 1 << 4
KCFNUMBER_SINT64_TYPE = 4
KCFSTRING_ENCODING_UTF8 = 0x08000100
NSAPPLICATION_ACTIVATE_ALL_WINDOWS = 1 << 0
NSAPPLICATION_ACTIVATE_IGNORING_OTHER_APPS = 1 << 1

# Fixed framework paths: ctypes.util.find_library shells out to locate them.
cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
objc = ctypes.CDLL("/usr/lib/libobjc.dylib")
ctypes.CDLL("/System/Library/Frameworks/AppKit.framework/AppKit")  # registers NSWorkspace, NSRunningApplication

cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
cf.CFArrayGetCount.restype = ctypes.c_long
cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
cf.CFDictionaryGetValue.restype = ctypes.c_void_p
cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFNumberGetValue.restype = ctypes.c_bool
cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
cf.CFRelease.argtypes = [ctypes.c_void_p]
objc.objc_getClass.restype = ctypes.c_void_p
objc.objc_getClass.argtypes = [ctypes.c_char_p]
objc.sel_registerName.restype = ctypes.c_void_p
objc.sel_registerName.argtypes = [ctypes.c_char_p]


def send(obj, selector, *args, restype=ctypes.c_void_p, argtypes=()):
    fn = objc.objc_msgSend
    fn.restype = restype
    fn.argtypes = (ctypes.c_void_p, ctypes.c_void_p) + tuple(argtypes)
    return fn(obj, objc.sel_registerName(selector), *args)


def number_for(dictionary, key):
    ref = cf.CFDictionaryGetValue(dictionary, key)
    if not ref:
        return None
    out = ctypes.c_longlong()
    cf.CFNumberGetValue(ref, KCFNUMBER_SINT64_TYPE, ctypes.byref(out))
    return out.value


def window_owner_pids():
    """Layer-0 window owners, front to back."""
    key_owner = cf.CFStringCreateWithCString(None, b"kCGWindowOwnerPID", KCFSTRING_ENCODING_UTF8)
    key_layer = cf.CFStringCreateWithCString(None, b"kCGWindowLayer", KCFSTRING_ENCODING_UTF8)
    windows = cg.CGWindowListCopyWindowInfo(
        CGWINDOWLIST_OPTION_ON_SCREEN_ONLY | CGWINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS,
        0,
    )
    try:
        pids = []
        for index in range(cf.CFArrayGetCount(windows)):
            window = cf.CFArrayGetValueAtIndex(windows, index)
            if number_for(window, key_layer) != 0:
                continue
            pid = number_for(window, key_owner)
            if pid is not None:
                pids.append(pid)
        return pids
    finally:
        cf.CFRelease(windows)


def focused_pid():
    """The focused application's main process, or None."""
    workspace = send(objc.objc_getClass(b"NSWorkspace"), b"sharedWorkspace")
    app = send(workspace, b"frontmostApplication")
    return send(app, b"processIdentifier", restype=ctypes.c_int32) if app else None


def activate(pid):
    cls = objc.objc_getClass(b"NSRunningApplication")
    app = send(cls, b"runningApplicationWithProcessIdentifier:", pid, argtypes=(ctypes.c_int32,))
    if not app:
        return False
    options = NSAPPLICATION_ACTIVATE_ALL_WINDOWS | NSAPPLICATION_ACTIVATE_IGNORING_OTHER_APPS
    return bool(send(app, b"activateWithOptions:", options, restype=ctypes.c_bool, argtypes=(ctypes.c_uint64,)))


def main() -> int:
    fallback = "personal"
    candidates = {}
    args = iter(sys.argv[1:])
    for arg in args:
        if arg == "--fallback":
            fallback = next(args)
        elif arg == "--personal":
            candidates["personal"] = int(next(args))
        elif arg == "--work":
            candidates["work"] = int(next(args))
        else:
            print(f"focus.py: unknown argument {arg}", file=sys.stderr)
            return 2

    if not candidates:
        return 2
    if fallback not in candidates:
        fallback = next(iter(candidates))

    names = {pid: name for name, pid in candidates.items()}
    if len(candidates) == 1:
        target = next(iter(candidates))
    else:
        # Switch away from the instance the user is in: the focused application
        # when it is one of ours, else the owner of the frontmost window. The
        # rest of the window order ranks "most recently used".
        focused = focused_pid()
        pids = [focused] if focused in names else window_owner_pids()
        away = names.get(pids[0]) if pids else None
        if away is not None:
            target = next(name for name in candidates if name != away)
        else:
            target = next((names[pid] for pid in pids if pid in names), fallback)

    print(target)
    return 0 if activate(candidates[target]) else 1


if __name__ == "__main__":
    sys.exit(main())
