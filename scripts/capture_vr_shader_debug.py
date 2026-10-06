"""Read SteamVR debug messages without attaching a debugger or changing processes."""
import ctypes as c
from ctypes import wintypes as w
import datetime
import json
from pathlib import Path
import sys
import time

k = c.WinDLL("kernel32", use_last_error=True)
def api(name, result, *args):
    f = getattr(k, name)
    f.restype, f.argtypes = result, args
    return f

create_event = api("CreateEventW", w.HANDLE, c.c_void_p, w.BOOL, w.BOOL, w.LPCWSTR)
create_mapping = api("CreateFileMappingW", w.HANDLE, w.HANDLE, c.c_void_p, w.DWORD, w.DWORD, w.DWORD, w.LPCWSTR)
map_view = api("MapViewOfFile", c.c_void_p, w.HANDLE, w.DWORD, w.DWORD, w.DWORD, c.c_size_t)
unmap = api("UnmapViewOfFile", w.BOOL, c.c_void_p)
close = api("CloseHandle", w.BOOL, w.HANDLE)
set_event = api("SetEvent", w.BOOL, w.HANDLE)
wait = api("WaitForSingleObject", w.DWORD, w.HANDLE, w.DWORD)
open_process = api("OpenProcess", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
query_name = api("QueryFullProcessImageNameW", w.BOOL, w.HANDLE, w.DWORD, w.LPWSTR, c.POINTER(w.DWORD))
handles, view, names = [], None, {}

def process_name(pid):
    if pid not in names:
        handle = open_process(0x1000, False, pid)
        if not handle:
            return ""
        try:
            buf, size = c.create_unicode_buffer(32768), w.DWORD(32768)
            names[pid] = Path(buf.value).name.lower() if query_name(handle, 0, buf, c.byref(size)) else ""
        finally:
            close(handle)
    return names[pid]

try:
    for name in ("DBWIN_BUFFER_READY", "DBWIN_DATA_READY"):
        c.set_last_error(0)
        handle = create_event(None, False, False, name)
        error = c.get_last_error()
        if handle:
            handles.append(handle)
        if not handle or error == 183:
            raise RuntimeError(f"Debug listener unavailable: {name}, error {error}")
    ready, data = handles
    mapping = create_mapping(w.HANDLE(-1), None, 4, 0, 4096, "DBWIN_BUFFER")
    if not mapping:
        raise c.WinError(c.get_last_error())
    handles.append(mapping)
    view = map_view(mapping, 4, 0, 0, 4096)
    if not view:
        raise c.WinError(c.get_last_error())
    deadline = time.monotonic() + float(sys.argv[1] if len(sys.argv) > 1 else 90)
    output = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / "artifacts" / "runtime" / "vr-shader-debug.jsonl"
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("a", encoding="utf-8") as log:
        print("SteamVR debug listener ready", flush=True)
        set_event(ready)
        while time.monotonic() < deadline:
            status = wait(data, 500)
            if status == 258:
                continue
            if status != 0:
                raise c.WinError(c.get_last_error())
            raw = c.string_at(view, 4096)
            set_event(ready)
            pid = int.from_bytes(raw[:4], "little")
            name = process_name(pid)
            if name not in ("vrcompositor.exe", "vrserver.exe"):
                continue
            message = raw[4:].split(b"\0", 1)[0].decode("utf-8", errors="replace").strip()
            if message:
                entry = dict(time=datetime.datetime.now().isoformat(), pid=pid, process=name, message=message)
                log.write(json.dumps(entry, ensure_ascii=False) + "\n")
                log.flush()
        print("SteamVR debug capture complete", flush=True)
finally:
    if view:
        unmap(view)
    for handle in reversed(handles):
        close(handle)
