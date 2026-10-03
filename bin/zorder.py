#!/usr/bin/env python3
"""Which of two app instances is frontmost, and which was used most recently.

usage: zorder.py <pid-a> <pid-b>
prints two words: the frontmost pid (or -) and the most recently used pid (or -).

Window order comes from the window server, so this stays correct after clicks,
Cmd-Tab and our own focusing — nothing to record along the way. A window that
is closed, minimized or on another Space is not in the list, which leaves that
instance out of the running for "most recently used".
"""
import ctypes
import ctypes.util
import sys

CGWINDOWLIST_OPTION_ON_SCREEN_ONLY = 1 << 0
CGWINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS = 1 << 4
KCFNUMBER_SINT64_TYPE = 4
KCFSTRING_ENCODING_UTF8 = 0x08000100

cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics"))
cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))

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


def main() -> None:
    candidates = [int(arg) for arg in sys.argv[1:3]]
    pids = window_owner_pids()

    # The first layer-0 window belongs to the frontmost application.
    frontmost = pids[0] if pids and pids[0] in candidates else None
    most_recent = next((pid for pid in pids if pid in candidates), None)

    print(
        f"{frontmost if frontmost is not None else '-'} "
        f"{most_recent if most_recent is not None else '-'}"
    )


if __name__ == "__main__":
    main()
