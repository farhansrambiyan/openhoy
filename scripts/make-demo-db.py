#!/usr/bin/env python3
"""Builds a fake Messages database (same schema subset as ~/Library/Messages/chat.db)
so OpenHoy can be tried and screenshotted without Full Disk Access:

    python3 scripts/make-demo-db.py /tmp/openhoy-demo
    OPENHOY_CHAT_DB=/tmp/openhoy-demo/chat.db OPENHOY_DRY_RUN=1 build/OpenHoy.app/Contents/MacOS/OpenHoy
"""
import os, sqlite3, sys, time, uuid

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "/tmp/openhoy-demo")
att = os.path.join(root, "att")
db_path = os.path.join(root, "chat.db")
if os.path.exists(db_path):
    os.remove(db_path)

db = sqlite3.connect(db_path)
db.executescript("""
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, service TEXT NOT NULL);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, chat_identifier TEXT,
                   service_name TEXT, display_name TEXT);
CREATE TABLE chat_handle_join (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, chat_id INTEGER, handle_id INTEGER);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, text TEXT, attributedBody BLOB,
                      handle_id INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0, date INTEGER, is_read INTEGER DEFAULT 1,
                      item_type INTEGER DEFAULT 0, associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0,
                      associated_message_emoji TEXT, cache_has_attachments INTEGER DEFAULT 0, is_audio_message INTEGER DEFAULT 0,
                      date_retracted INTEGER DEFAULT 0, thread_originator_guid TEXT, date_edited INTEGER DEFAULT 0,
                      error INTEGER DEFAULT 0, is_delivered INTEGER DEFAULT 1, date_read INTEGER DEFAULT 0);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0, PRIMARY KEY (chat_id, message_id));
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, filename TEXT, uti TEXT,
                         mime_type TEXT, transfer_name TEXT);
CREATE TABLE message_attachment_join (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER, attachment_id INTEGER);
""")

APPLE_EPOCH = 978307200
def apple_now(offset):
    return int((time.time() - APPLE_EPOCH + offset) * 1_000_000_000)

people = [("tanya@example.com", "Tanya"), ("+15551230001", None), ("+15551230002", None), ("mark@example.com", None)]
chat_ids, handle_ids = [], []
for i, (h, _) in enumerate(people):
    cur = db.execute("INSERT INTO handle (id, service) VALUES (?, 'iMessage')", (h,))
    handle_ids.append(cur.lastrowid)
    cur = db.execute("INSERT INTO chat (guid, chat_identifier, service_name) VALUES (?, ?, 'iMessage')", (f"any;-;{h}", h))
    chat_ids.append(cur.lastrowid)
    db.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)", (cur.lastrowid, handle_ids[-1]))

def add(chat, text=None, me=False, offset=0, files=(), body=None, read=1, assoc=None, assoc_type=0, audio=0, reply_to=None):
    guid = str(uuid.uuid4()).upper()
    d = apple_now(offset)
    cur = db.execute("""INSERT INTO message (guid, text, attributedBody, handle_id, is_from_me, date, is_read,
                        associated_message_guid, associated_message_type, cache_has_attachments, is_audio_message)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                     (guid, text, body, 0 if me else handle_ids[chat], 1 if me else 0, d, read, assoc, assoc_type,
                      1 if files else 0, audio))
    mid = cur.lastrowid
    if reply_to:
        db.execute("UPDATE message SET thread_originator_guid = ? WHERE ROWID = ?", (reply_to, mid))
    db.execute("INSERT INTO chat_message_join VALUES (?,?,?)", (chat_ids[chat], mid, d))
    for f, mime in files:
        a = db.execute("INSERT INTO attachment (guid, filename, mime_type, transfer_name) VALUES (?,?,?,?)",
                       (str(uuid.uuid4()), os.path.join(att, f), mime, f))
        db.execute("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?,?)", (mid, a.lastrowid))
    return guid

body1 = open(os.path.join(root, "body1.bin"), "rb").read() if os.path.exists(os.path.join(root, "body1.bin")) else None
t = -600
add(0, "ok, OpenHoy for Mac is so much fun!", offset=t); t += 20
add(0, None if body1 else "i can just drop anything to anyone?\nno sign-up, no third-party?", body=body1, offset=t); t += 20
add(0, "exactly, just your iMessage.", me=True, offset=t); t += 20
add(0, "￼", me=True, offset=t, files=[("Voice Note.m4a", "audio/x-m4a")]); t += 1
add(0, "Half the time I don't even type I just talk", me=True, offset=t); t += 20
add(0, "￼￼￼", me=True, offset=t, files=[("img1.jpg", "image/jpeg"), ("img2.jpg", "image/jpeg"), ("img3.jpg", "image/jpeg")]); t += 1
g = add(0, "and you can throw anything right in my face too", me=True, offset=t); t += 20
add(0, "Loved “and you can throw anything right in my face too”", offset=t, assoc=f"p:0/{g}", assoc_type=2000); t += 5
edited = add(0, "cool, didn't expect this!", offset=t); t += 20
db.execute("UPDATE message SET date_edited = ? WHERE guid = ?", (apple_now(t), edited))
unsent = add(0, "", offset=t); t += 5
db.execute("UPDATE message SET date_retracted = ?, date_edited = ? WHERE guid = ?", (apple_now(t), apple_now(t), unsent))
check = add(0, "check this then...", me=True, offset=t); t += 5
add(0, "￼", me=True, offset=t, files=[("Screen Recording.mp4", "video/mp4")]); t += 20
add(0, "ok stop, i love it!!", offset=t, read=0, reply_to=check); t += 20
long_body = os.path.join(root, "body-long.bin")
if os.path.exists(long_body):
    add(0, None, offset=t, body=open(long_body, "rb").read()); t += 20
last_mine = add(0, "Sure!! Also, a really long message to make sure nothing gets cut off: " + " ".join(["word%d" % i for i in range(60)]) + " — the end.", me=True, offset=t); t += 20

db.execute("UPDATE message SET date_read = ? WHERE guid = ?", (apple_now(t), last_mine))

# A second, older chat row for Tanya (as Messages keeps for SMS/iMessage) — OpenHoy merges it.
cur = db.execute("INSERT INTO chat (guid, chat_identifier, service_name) VALUES (?, ?, 'iMessage')",
                 ("iMessage;-;tanya@example.com", "tanya@example.com"))
chat_ids.append(cur.lastrowid); handle_ids.append(handle_ids[0])
db.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)", (cur.lastrowid, handle_ids[0]))
add(4, "(older thread) hey! long time", offset=-86400)

add(1, "are we still on for friday?", offset=-3000)
add(1, "yes! 7pm", me=True, offset=-2900)
add(2, "sent you the deck", offset=-5000, read=0)
add(3, "🎉🎉", offset=-9000)
db.commit()
print(db_path)
