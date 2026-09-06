void InputListenerItem::InputListenerItem()
{
}

void InputListenerItem::keyPressEvent(QKeyEvent *event)
{
    if (IGNORED_KEYS->find(event->key()) != IGNORED_KEYS->end()) {
        return;
    }

    const QList<xkb_keysym_t> keys = QXkbCommon::toKeysym(event);
    for (auto key : keys) {
        if (event->text().isEmpty() || key == XKB_KEY_Return) {
            m_input.keysym(QDateTime::currentMSecsSinceEpoch(), key, InputPlugin::Pressed, 0);
        }
    }
}

void InputListenerItem::keyReleaseEvent(QKeyEvent *event)
{
    if (IGNORED_KEYS->find(event->key()) != IGNORED_KEYS->end()) {
        return;
    }

    const QList<xkb_keysym_t> keys = QXkbCommon::toKeysym(event);
    for (auto key : keys) {
        if (event->text().isEmpty() || key == XKB_KEY_Return) {
            m_input.keysym(QDateTime::currentMSecsSinceEpoch(), key, InputPlugin::Released, 0);
        } else {
            m_input.commit(event->text());
        }
    }
}

void InputListenerItem::inputMethodEvent(QInputMethodEvent *event)
{
    if (!window()->isExposed()) {
        return;
    }

    QString commit = event->commitString();
    QString preedit = event->preeditString();
    bool needsReplacement = event->replacementStart() != 0 || event->replacementLength() != 0;

    if (needsReplacement) {
        m_input.deleteSurroundingText(0, 0);
    }
    if (needsReplacement || !commit.isEmpty()) {
        m_input.commit(commit);
    }
}
