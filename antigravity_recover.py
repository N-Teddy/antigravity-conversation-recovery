#!/usr/bin/env python3
"""
Antigravity IDE Cross-Platform Conversation Recovery & Workspace Indexer
Supports Linux, macOS, and Windows.
"""
import glob
import os
import sys
import sqlite3
import json
import base64
import re
import shutil
import platform
from datetime import datetime

CURRENT_OS = platform.system() # 'Linux', 'Darwin' (macOS), 'Windows'
HOME_DIR = os.path.expanduser("~")

def get_state_db_path():
    if CURRENT_OS == "Darwin":
        return os.path.join(HOME_DIR, "Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb")
    elif CURRENT_OS == "Windows":
        app_data = os.environ.get("APPDATA") or os.path.join(HOME_DIR, "AppData/Roaming")
        return os.path.join(app_data, "Antigravity IDE/User/globalStorage/state.vscdb")
    else: # Linux / FreeBSD
        return os.path.join(HOME_DIR, ".config/Antigravity IDE/User/globalStorage/state.vscdb")

STATE_DB_PATH = get_state_db_path()
CONVERSATIONS_DIR = os.path.join(HOME_DIR, ".gemini/antigravity-ide/conversations")
BRAIN_DIR = os.path.join(HOME_DIR, ".gemini/antigravity-ide/brain")

def encode_varint(val):
    out = bytearray()
    while val > 0x7F:
        out.append((val & 0x7F) | 0x80)
        val >>= 7
    out.append(val & 0x7F)
    return bytes(out)

def encode_tag(field_num, wire_type):
    return encode_varint((field_num << 3) | wire_type)

def encode_string(field_num, s):
    b = s.encode("utf-8")
    return encode_tag(field_num, 2) + encode_varint(len(b)) + b

def encode_bytes(field_num, b):
    return encode_tag(field_num, 2) + encode_varint(len(b)) + b

def encode_int(field_num, val):
    return encode_tag(field_num, 0) + encode_varint(val)

def encode_timestamp(field_num, seconds, nanos=0):
    ts = encode_int(1, seconds)
    if nanos:
        ts += encode_int(2, nanos)
    return encode_bytes(field_num, ts)

def parse_fields(b):
    i = 0
    fields = []
    while i < len(b):
        tag = 0
        shift = 0
        while True:
            byte = b[i]
            i += 1
            tag |= (byte & 0x7f) << shift
            if not (byte & 0x80):
                break
            shift += 7
        fnum = tag >> 3
        wtype = tag & 7
        if wtype == 0:
            val = 0
            shift = 0
            while True:
                byte = b[i]
                i += 1
                val |= (byte & 0x7f) << shift
                if not (byte & 0x80):
                    break
                shift += 7
            fields.append((fnum, "varint", val))
        elif wtype == 2:
            length = 0
            shift = 0
            while True:
                byte = b[i]
                i += 1
                length |= (byte & 0x7f) << shift
                if not (byte & 0x80):
                    break
                shift += 7
            val = b[i:i+length]
            i += length
            fields.append((fnum, "bytes", val))
        elif wtype == 1:
            val = b[i:i+8]
            i += 8
            fields.append((fnum, "64bit", val))
        elif wtype == 5:
            val = b[i:i+4]
            i += 4
            fields.append((fnum, "32bit", val))
        else:
            break
    return fields

def make_workspace_metadata(uri):
    return encode_string(1, uri) + encode_string(2, uri)

def find_project_root(path):
    curr = os.path.abspath(path)
    while curr and curr != "/" and curr != HOME_DIR:
        if os.path.exists(os.path.join(curr, ".git")):
            return curr
        curr = os.path.dirname(curr)
    return os.path.abspath(path)

def get_strict_workspace(cid, meta_blob):
    if meta_blob:
        fields = parse_fields(meta_blob)
        for f, w, v in fields:
            if f == 7:
                try:
                    u = v.decode("utf-8")
                    if u.startswith("file://"):
                        return u
                except:
                    pass
        for f, w, v in fields:
            if f == 1:
                for sf, sw, sv in parse_fields(v):
                    if sf == 1:
                        try:
                            u = sv.decode("utf-8")
                            if u.startswith("file://"):
                                return u
                        except:
                            pass

    tpath = os.path.join(BRAIN_DIR, cid, ".system_generated", "logs", "transcript.jsonl")
    if os.path.exists(tpath):
        try:
            with open(tpath, "r", encoding="utf-8", errors="replace") as tf:
                for line in tf:
                    m = re.search(r'file://(/[^",\s]+)', line)
                    if m:
                        p = m.group(1)
                        if os.path.exists(p):
                            root = find_project_root(p if os.path.isdir(p) else os.path.dirname(p))
                            return f"file://{root}"
                    for candidate in re.findall(re.escape(HOME_DIR) + r"/[^,\s;]+", line):
                        if os.path.exists(candidate):
                            root = find_project_root(candidate if os.path.isdir(candidate) else os.path.dirname(candidate))
                            return f"file://{root}"
        except:
            pass

    return f"file://{HOME_DIR}"

def build_summary_pb(cid, title, step_count, ctime, mtime, last_user_time, last_user_step_idx, meta_blob, strict_ws_uri):
    inner_pb = bytearray()
    inner_pb += encode_string(1, title)
    inner_pb += encode_int(2, step_count)
    inner_pb += encode_timestamp(3, mtime)
    inner_pb += encode_string(4, cid)
    inner_pb += encode_int(5, 1)
    inner_pb += encode_timestamp(7, ctime)

    ws_msg = make_workspace_metadata(strict_ws_uri)
    inner_pb += encode_bytes(9, ws_msg)

    inner_pb += encode_timestamp(10, last_user_time)
    inner_pb += encode_int(16, last_user_step_idx)
    if meta_blob:
        inner_pb += encode_bytes(17, meta_blob)
    inner_pb += encode_int(22, 4)
    return inner_pb

def recover_all(dry_run=False):
    if not os.path.exists(STATE_DB_PATH):
        print(f"Error: Database not found at {STATE_DB_PATH}")
        return

    conn = sqlite3.connect(STATE_DB_PATH)
    c = conn.cursor()
    c.execute("SELECT value FROM ItemTable WHERE key='antigravityUnifiedStateSync.trajectorySummaries'")
    row = c.fetchone()
    if not row:
        print("Key antigravityUnifiedStateSync.trajectorySummaries not found in state.vscdb!")
        conn.close()
        return

    val = row[0]
    raw = base64.b64decode(val)

    existing_summaries = {}
    for fnum, wtype, entry_bytes in parse_fields(raw):
        if fnum == 1:
            efields = parse_fields(entry_bytes)
            cid = None
            row_bytes = None
            for f, w, v in efields:
                if f == 1:
                    cid = v.decode("utf-8", errors="replace")
                elif f == 2:
                    row_bytes = v

            if cid and row_bytes:
                rfields = parse_fields(row_bytes)
                b64_val = [v.decode("utf-8", errors="replace") for f, w, v in rfields if f == 1]
                if b64_val:
                    try:
                        inner = base64.b64decode(b64_val[0])
                        existing_summaries[cid] = inner
                    except:
                        pass

    db_files = glob.glob(os.path.join(CONVERSATIONS_DIR, "*.db"))
    rebuilt_entries = []
    map_entries_bytes = bytearray()

    for db_path in sorted(db_files, key=os.path.getmtime, reverse=True):
        cid = os.path.basename(db_path).replace(".db", "")

        try:
            c_conn = sqlite3.connect(db_path)
            c_cur = c_conn.cursor()
            c_cur.execute("SELECT count(*) FROM steps")
            step_count = c_cur.fetchone()[0]

            c_cur.execute("SELECT data FROM trajectory_metadata_blob WHERE id='main'")
            blob_row = c_cur.fetchone()
            meta_blob = blob_row[0] if blob_row else None
            c_conn.close()
        except Exception:
            continue

        mtime = int(os.path.getmtime(db_path))
        ctime = mtime
        last_user_time = mtime
        last_user_step_idx = 0
        title = f"Conversation {cid[:8]}"

        transcript_path = os.path.join(BRAIN_DIR, cid, ".system_generated", "logs", "transcript.jsonl")
        if os.path.exists(transcript_path):
            try:
                first_req = None
                with open(transcript_path, "r", encoding="utf-8", errors="replace") as tf:
                    for line in tf:
                        try:
                            obj = json.loads(line)
                        except:
                            continue
                        if obj.get("type") == "USER_INPUT":
                            step_idx = obj.get("step_index", 0)
                            last_user_step_idx = step_idx
                            content = obj.get("content", "")
                            created_at = obj.get("created_at")
                            if created_at:
                                try:
                                    dt = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
                                    t_sec = int(dt.timestamp())
                                    if first_req is None:
                                        ctime = t_sec
                                    last_user_time = t_sec
                                except:
                                    pass
                            if first_req is None:
                                m = re.search(r"<USER_REQUEST>(.*?)</USER_REQUEST>", content, re.DOTALL)
                                if m:
                                    raw_title = m.group(1).strip()
                                else:
                                    raw_title = content.strip()
                                lines = [l.strip() for l in raw_title.splitlines() if l.strip()]
                                if lines:
                                    first_req = lines[0][:100]
                                else:
                                    first_req = raw_title[:100]
                if first_req:
                    title = first_req
            except Exception:
                pass

        if cid in existing_summaries:
            in_fields = parse_fields(existing_summaries[cid])
            old_title = next((v.decode("utf-8", errors="replace") for f, w, v in in_fields if f == 1), None)
            if old_title and not old_title.startswith("Conversation "):
                title = old_title

        strict_ws = get_strict_workspace(cid, meta_blob)

        inner_pb = build_summary_pb(
            cid, title, step_count, ctime, mtime, last_user_time, last_user_step_idx, meta_blob, strict_ws
        )

        b64_inner = base64.b64encode(inner_pb)
        row_pb = encode_bytes(1, b64_inner)
        entry_pb = encode_string(1, cid) + encode_bytes(2, row_pb)
        map_entry = encode_bytes(1, entry_pb)

        map_entries_bytes += map_entry
        dt_str = datetime.fromtimestamp(ctime).strftime("%Y-%m-%d %H:%M")
        rebuilt_entries.append((dt_str, cid, title, step_count, strict_ws))

    if dry_run:
        conn.close()
        print(f"\n[DRY RUN] Found {len(rebuilt_entries)} conversations on disk ready for indexing.")
        return

    bak_path = STATE_DB_PATH + ".bak"
    try:
        shutil.copy2(STATE_DB_PATH, bak_path)
    except:
        pass

    new_val = base64.b64encode(map_entries_bytes).decode("ascii")
    c.execute("UPDATE ItemTable SET value=? WHERE key='antigravityUnifiedStateSync.trajectorySummaries'", (new_val,))
    conn.commit()
    conn.close()

    print(f"\n[+] Successfully rebuilt index for all {len(rebuilt_entries)} conversations with STRICT workspace isolation!\n")
    print("-" * 135)
    print(f"{'#':<4} | {'Date':<16} | {'Workspace':<26} | {'Conversation ID':<36} | Title")
    print("-" * 135)
    for i, (dt_str, cid, title, steps, ws) in enumerate(rebuilt_entries[:25], 1):
        ws_short = ws.replace(f"file://{HOME_DIR}/", "").replace("file://", "")
        print(f"{i:<4} | {dt_str:<16} | {ws_short[:26]:<26} | {cid:<36} | {title[:40]}")
    if len(rebuilt_entries) > 25:
        print(f"... and {len(rebuilt_entries) - 25} more conversations")
    print("-" * 135)

def list_existing_conversations(keyword_filter=None):
    if not os.path.exists(STATE_DB_PATH):
        print(f"Error: {STATE_DB_PATH} does not exist.")
        return

    conn = sqlite3.connect(STATE_DB_PATH)
    c = conn.cursor()
    c.execute("SELECT value FROM ItemTable WHERE key='antigravityUnifiedStateSync.trajectorySummaries'")
    row = c.fetchone()
    conn.close()

    if not row:
        print("No conversations index found in state.vscdb.")
        return

    raw = base64.b64decode(row[0])
    entries = []
    for fnum, wtype, entry_bytes in parse_fields(raw):
        if fnum == 1:
            efields = parse_fields(entry_bytes)
            cid = None
            row_bytes = None
            for f, w, v in efields:
                if f == 1:
                    cid = v.decode("utf-8", errors="replace")
                elif f == 2:
                    row_bytes = v

            if cid and row_bytes:
                rfields = parse_fields(row_bytes)
                b64_val = [v.decode("utf-8", errors="replace") for f, w, v in rfields if f == 1]
                if b64_val:
                    try:
                        inner = base64.b64decode(b64_val[0])
                        in_fields = parse_fields(inner)
                        title = next((v.decode("utf-8", errors="replace") for f, w, v in in_fields if f == 1), f"Conversation {cid[:8]}")
                        mtime_ts = next((v for f, w, v in in_fields if f in [3, 7]), None)
                        dt_str = ""
                        if isinstance(mtime_ts, bytes):
                            ts_fields = parse_fields(mtime_ts)
                            sec = next((v for f, w, v in ts_fields if f == 1), None)
                            if sec:
                                dt_str = datetime.fromtimestamp(sec).strftime("%Y-%m-%d %H:%M")
                        ws_uri = ""
                        for f, w, v in in_fields:
                            if f == 9:
                                for sf, sw, sv in parse_fields(v):
                                    if sf == 1:
                                        ws_uri = sv.decode("utf-8", errors="replace")
                        entries.append((dt_str, ws_uri, cid, title))
                    except:
                        entries.append(("", "", cid, f"Conversation {cid[:8]}"))

    if keyword_filter:
        kw = keyword_filter.lower()
        entries = [e for e in entries if kw in e[1].lower() or kw in e[3].lower() or kw in e[2].lower()]

    print(f"\nTotal Indexed Conversations: {len(entries)}")
    print("-" * 130)
    print(f"{'Date':<18} | {'Workspace':<26} | {'Conversation ID':<36} | Title")
    print("-" * 130)
    for dt_str, ws_uri, cid, title in sorted(entries, key=lambda x: x[0], reverse=True):
        ws_short = ws_uri.replace(f"file://{HOME_DIR}/", "").replace("file://", "")
        print(f"{dt_str:<18} | {ws_short[:26]:<26} | {cid:<36} | {title[:40]}")
    print("-" * 130)

def check_status():
    print("=== Antigravity IDE Persistence Status ===")
    print(f"Detected OS: {CURRENT_OS}")
    print(f"User Home: {HOME_DIR}")
    print(f"State Database ({STATE_DB_PATH}): {'Found' if os.path.exists(STATE_DB_PATH) else 'NOT FOUND'}")

    main_js_candidates = [
        "/opt/antigravity-ide/resources/app/out/main.js",
        "/usr/lib/antigravity-ide/resources/app/out/main.js",
        "/usr/share/antigravity-ide/resources/app/out/main.js",
        "/Applications/Antigravity IDE.app/Contents/Resources/app/out/main.js",
        os.path.expanduser("~/Applications/Antigravity IDE.app/Contents/Resources/app/out/main.js"),
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\Antigravity IDE\resources\app\out\main.js"),
        r"C:\Program Files\Antigravity IDE\resources\app\out\main.js"
    ]
    main_js = next((p for p in main_js_candidates if os.path.exists(p)), None)
    if main_js:
        with open(main_js, "r", encoding="utf-8") as f:
            content = f.read()
        p1 = "await this._persistTopic(" in content
        p2 = "delete this.lazilyInitializedTopicObservables[" in content
        print(f"Engine Core ({main_js}):")
        print(f"  - Immediate disk persistence patch: {'ACTIVE [OK]' if p1 else 'MISSING [!] (re-run installer)'}")
        print(f"  - Dynamic window reload patch:     {'ACTIVE [OK]' if p2 else 'MISSING [!] (re-run installer)'}")
    else:
        print("Engine Core: main.js not located at standard paths.")

    dbs = glob.glob(os.path.join(CONVERSATIONS_DIR, "*.db"))
    print(f"Conversation Databases on disk: {len(dbs)}")

    if os.path.exists(STATE_DB_PATH):
        conn = sqlite3.connect(STATE_DB_PATH)
        c = conn.cursor()
        c.execute("SELECT value FROM ItemTable WHERE key='antigravityUnifiedStateSync.trajectorySummaries'")
        row = c.fetchone()
        conn.close()
        if row:
            raw = base64.b64decode(row[0])
            count = sum(1 for fnum, _, _ in parse_fields(raw) if fnum == 1)
            print(f"Indexed in state.vscdb:         {count}")
        else:
            print("Indexed in state.vscdb:         0")

    if CURRENT_OS == "Linux":
        timer_active = os.system("systemctl --user is-active --quiet antigravity-recover.timer 2>/dev/null") == 0
        print(f"Background Recovery Timer:       {'ACTIVE [OK]' if timer_active else 'INACTIVE / NOT INSTALLED'}")

if __name__ == "__main__":
    args = sys.argv[1:]
    if "--status" in args or "-s" in args:
        check_status()
    elif "--dry-run" in args:
        recover_all(dry_run=True)
    elif "--list" in args or "-l" in args or "list" in args:
        kw = None
        for i, a in enumerate(args):
            if a in ["--filter", "-f"] and i + 1 < len(args):
                kw = args[i+1]
        list_existing_conversations(keyword_filter=kw)
    else:
        recover_all()
