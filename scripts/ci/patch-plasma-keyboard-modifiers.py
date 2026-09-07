#!/usr/bin/env python3
"""Patch plasma-keyboard so on-screen Ctrl/Alt/Meta stay latched and Ctrl+C works."""

from __future__ import annotations

import argparse
import pathlib
import sys

BEGIN = "// Y700_STICKY_MODIFIERS_BEGIN"

HELPER = r'''
// Y700_STICKY_MODIFIERS_BEGIN
namespace {

uint32_t y700StickyMods = 0;

uint32_t y700ModBit(int qtKey)
{
    switch (qtKey) {
    case Qt::Key_Control:
        return 1u;
    case Qt::Key_Alt:
        return 2u;
    case Qt::Key_Meta:
    case Qt::Key_Super_L:
    case Qt::Key_Super_R:
        return 4u;
    default:
        return 0;
    }
}

bool y700ToggleStickyModifier(InputPlugin &input, QKeyEvent *event)
{
    const uint32_t bit = y700ModBit(event->key());
    if (!bit) {
        return false;
    }

    const QList<xkb_keysym_t> keys = QXkbCommon::toKeysym(event);
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const bool latch = (y700StickyMods & bit) == 0;
    if (latch) {
        y700StickyMods |= bit;
    } else {
        y700StickyMods &= ~bit;
    }

    for (auto key : keys) {
        input.keysym(now, key, latch ? InputPlugin::Pressed : InputPlugin::Released, 0);
    }
    return true;
}

void y700SendKeysyms(InputPlugin &input, QKeyEvent *event, InputPlugin::KeyState state)
{
    const QList<xkb_keysym_t> keys = QXkbCommon::toKeysym(event);
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    for (auto key : keys) {
        input.keysym(now, key, state, 0);
    }
}

void y700CommitAsKeysyms(InputPlugin &input, const QString &commit)
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    for (const QChar ch : commit) {
        const xkb_keysym_t sym = xkb_utf32_to_keysym(uint32_t(ch.unicode()));
        if (sym == XKB_KEY_NoSymbol) {
            continue;
        }
        input.keysym(now, sym, InputPlugin::Pressed, 0);
        input.keysym(now, sym, InputPlugin::Released, 0);
    }
}

bool y700PreferKeysym(const QKeyEvent *event)
{
    if (y700StickyMods) {
        return true;
    }
    switch (event->key()) {
    case Qt::Key_Return:
    case Qt::Key_Enter:
    case Qt::Key_Tab:
    case Qt::Key_Backtab:
    case Qt::Key_Escape:
    case Qt::Key_Left:
    case Qt::Key_Right:
    case Qt::Key_Up:
    case Qt::Key_Down:
    case Qt::Key_Home:
    case Qt::Key_End:
    case Qt::Key_PageUp:
    case Qt::Key_PageDown:
    case Qt::Key_Insert:
    case Qt::Key_Delete:
        return true;
    default:
        return event->text().isEmpty();
    }
}

}

// Y700_STICKY_MODIFIERS_END
'''

PRESS_HOOK = """
    if (y700ToggleStickyModifier(m_input, event)) {
        event->accept();
        return;
    }
    if (y700PreferKeysym(event)) {
        y700SendKeysyms(m_input, event, InputPlugin::Pressed);
        event->accept();
        return;
    }
"""

RELEASE_HOOK = """
    if (y700ModBit(event->key())) {
        event->accept();
        return;
    }
    if (y700PreferKeysym(event)) {
        y700SendKeysyms(m_input, event, InputPlugin::Released);
        event->accept();
        return;
    }
"""

COMMIT_HOOK = """
    if (y700StickyMods && !commit.isEmpty()) {
        y700CommitAsKeysyms(m_input, commit);
        commit.clear();
        needsReplacement = false;
    }
"""


def normalize_newlines(text: str) -> str:
    return text.replace("\r\n", "\n")


def insert_after(src: str, needle: str, insert: str, label: str) -> str:
    idx = src.find(needle)
    if idx < 0:
        raise SystemExit(f"could not find {label}: {needle!r}")
    idx += len(needle)
    return src[:idx] + insert + src[idx:]


def patch_text(src: str) -> str:
    src = normalize_newlines(src)
    if BEGIN in src:
        return src

    if "#include <xkbcommon/xkbcommon.h>" not in src:
        include_needle = "#include "
        idx = src.find(include_needle)
        if idx < 0:
            src = "#include <xkbcommon/xkbcommon.h>\n" + src
        else:
            src = src[:idx] + "#include <xkbcommon/xkbcommon.h>\n" + src[idx:]

    marker = "InputListenerItem::InputListenerItem()"
    idx = src.find(marker)
    if idx < 0:
        raise SystemExit("could not find InputListenerItem constructor")
    src = src[:idx] + HELPER + "\n" + src[idx:]

    src = insert_after(
        src,
        "void InputListenerItem::keyPressEvent(QKeyEvent *event)\n{",
        PRESS_HOOK,
        "keyPressEvent",
    )
    src = insert_after(
        src,
        "void InputListenerItem::keyReleaseEvent(QKeyEvent *event)\n{",
        RELEASE_HOOK,
        "keyReleaseEvent",
    )

    im_idx = src.find("void InputListenerItem::inputMethodEvent")
    if im_idx < 0:
        raise SystemExit("could not find inputMethodEvent")

    needs_needle = "bool needsReplacement = event->replacementStart() != 0 || event->replacementLength() != 0;"
    pos = src.find(needs_needle, im_idx)
    if pos < 0:
        commit_needle = "QString commit = event->commitString();"
        pos = src.find(commit_needle, im_idx)
        if pos < 0:
            raise SystemExit("could not find commitString in inputMethodEvent")
        pos += len(commit_needle)
        src = (
            src[:pos]
            + "\n    bool needsReplacement = event->replacementStart() != 0 || event->replacementLength() != 0;"
            + COMMIT_HOOK
            + src[pos:]
        )
    else:
        src = src[: pos + len(needs_needle)] + COMMIT_HOOK + src[pos + len(needs_needle) :]

    return src


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=pathlib.Path)
    args = parser.parse_args()
    original = args.path.read_text(encoding="utf-8")
    patched = patch_text(original)
    if patched == normalize_newlines(original) and BEGIN in original:
        print(f"already patched: {args.path}")
        return 0
    args.path.write_text(patched, encoding="utf-8")
    print(f"patched: {args.path}")
    checks = [
        "y700StickyMods",
        "y700ToggleStickyModifier",
        "y700CommitAsKeysyms",
        "y700PreferKeysym",
    ]
    missing = [name for name in checks if name not in patched]
    if missing:
        print(f"patch missing symbols: {missing}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
