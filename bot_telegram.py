import os, json, time, telebot, threading
from telebot import types

# === CONFIG ===
CONFIG = json.load(open("config.json"))
bot = telebot.TeleBot(CONFIG["telegram_token"])
CHAT_ID = CONFIG["telegram_chat_id"]

# Cartella comune MetaTrader
SIGNALS_PATH = os.path.expanduser(
    "~/AppData/Roaming/MetaQuotes/Terminal/Common/Files/"
)
MASTER_FILE = os.path.join(SIGNALS_PATH, "account_status_master.json")
SLAVE_FILE = os.path.join(SIGNALS_PATH, "account_status_slave.json")
POSITIONS_FILE = os.path.join(SIGNALS_PATH, "positions.json")

# Stato precedente
last_status = {"master": None, "slave": None}
last_positions = []

# === UTILS ===
def load_json(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as fp:
            return json.load(fp)
    except:
        return {}

def is_recent(path, max_age=60):
    if not os.path.exists(path):
        return False
    mtime = os.path.getmtime(path)
    return (time.time() - mtime) < max_age

def get_status(path):
    acc = load_json(path)
    if not acc:
        return None, None
    connected = acc.get("connected", False)
    if not is_recent(path, 60):
        connected = False
    return acc, connected

def auto_delete(chat_id, msg_id, delay=15):
    """Cancella un messaggio dopo delay secondi"""
    def _delete():
        time.sleep(delay)
        try:
            bot.delete_message(chat_id, msg_id)
        except:
            pass
    threading.Thread(target=_delete, daemon=True).start()

# === FORMAT ACCOUNT ===
def format_account(acc, titolo, connected):
    if not acc:
        return f"⚠️ Nessun dato per {titolo}\n"
    return (
        f"📊 *{titolo}*\n"
        f"📡 : {'✅ Connesso' if connected else '❌ Disconnesso'}\n"
        f"👤 : {acc.get('account', '?')} ({acc.get('name', '?')})\n"
        f"🏦 : {acc.get('broker', '?')}\n"
        f"💰 : {acc.get('balance', 0)}\n"
    )

# === FORMAT SALDO ===
def format_saldo(master, m_conn, slave, s_conn):
    # Questi dati puoi spostarli in config.json se vuoi parametrizzarli
    user_name = "Federico Carmine"
    challenge = "50k"

    text = "💰 *Saldo Account*\n\n"
    text += f"👤 *Utente*: {user_name}\n"
    text += f"🎯 *Challenge*: {challenge}\n\n"

    text += "*PROP ACCOUNT*\n"
    text += f"▫️ Stato: {'✅ Connesso' if m_conn else '❌ Disconnesso'}\n"
    text += f"▫️ Bilancio: ${master.get('balance','?')}\n\n"

    text += "*BROKER ACCOUNT*\n"
    text += f"▫️ Stato: {'✅ Connesso' if s_conn else '❌ Disconnesso'}\n"
    text += f"▫️ Bilancio: €{slave.get('balance','?')}\n"

    return text

# === POSIZIONI ===
def format_current_positions(positions, master_acc=None, slave_acc=None):
    if not positions:
        return "✅ Nessuna posizione aperta"

    if isinstance(positions, dict):
        positions = [{"symbol": sym, **info} for sym, info in positions.items()]

    # Prendi solo l’ultima azione per posId+side
    latest_by_posid = {}
    for p in positions:
        posid = str(p.get("position_id", p.get("ticket")))
        key = posid + "_" + p.get("side", "?")
        latest_by_posid[key] = p

    current = [p for p in latest_by_posid.values() if p.get("status") == "open"]

    def side_label(side, acc):
        if side.lower() == "master":
            return f"MT5 Prop Master {acc.get('broker', '')}" if acc else "MT5 Master"
        elif side.lower() == "slave":
            return f"MT4 Broker Slave {acc.get('broker', '')}" if acc else "MT4 Slave"
        return side

    text = "📌 *Posizioni Correnti*\n\n"
    if not current:
        text += "— Nessuna posizione aperta\n"
    else:
        for p in current:
            mirror = p.get("mirror_type", "")
            mirror_str = f" (Mirror: {mirror})" if mirror else ""
            broker_label = side_label(p.get("side","?"), master_acc if p.get("side","").lower()=="master" else slave_acc)

            text += (
                f"🟢{broker_label}\n"
                f"    {p.get('symbol')} {p.get('type')} {p.get('lots')} @ {p.get('price')}{mirror_str}\n"
                f"    SL: {p.get('sl','-')} | TP: {p.get('tp','-')} |\n"
                f"    Ticket: {p.get('ticket')} | PosID: {p.get('position_id','?')}\n\n"
            )
    return text

def format_history_positions(positions, master_acc=None, slave_acc=None):
    if not positions:
        return "✅ Nessuna posizione chiusa di recente"

    if isinstance(positions, dict):
        positions = [{"symbol": sym, **info} for sym, info in positions.items()]

    # Prendi solo le chiusure più recenti (max 5)
    history = [p for p in positions if p.get("status") == "close"]
    history.sort(key=lambda x: x.get("time", ""), reverse=True)
    history = history[:5]

    def side_label(side):
        if side.lower() == "master":
            broker = master_acc.get("broker", "MT5") if master_acc else "MT5"
            return f"Master Prop MT5 {broker}"
        elif side.lower() == "slave":
            broker = slave_acc.get("broker", "MT4") if slave_acc else "MT4"
            return f"Slave MT4 {broker}"
        return side

    text = "📜 *Storico Recente*\n\n"
    if not history:
        text += "— Nessuna posizione chiusa di recente\n"
    else:
        for p in history:
            mirror = p.get("mirror_type", "")
            mirror_str = f" (Mirror: {mirror})" if mirror else ""
            text += (
                f"🔴 [{side_label(p.get('side','?'))}] {p.get('symbol')} "
                f"{p.get('type')} {p.get('lots')} @ {p.get('price')}{mirror_str} → CHIUSA\n"
            )
    return text

# === MENU ===
def main_menu():
    markup = types.InlineKeyboardMarkup()
    markup.add(types.InlineKeyboardButton("📊 Stato Account", callback_data="status"))
    markup.add(types.InlineKeyboardButton("📌 Posizioni", callback_data="positions_menu"))
    markup.add(types.InlineKeyboardButton("💰 Saldo", callback_data="saldo"))
    markup.add(types.InlineKeyboardButton("❓ Supporto", callback_data="supporto"))
    return markup

def positions_menu():
    markup = types.InlineKeyboardMarkup()
    markup.add(types.InlineKeyboardButton("📌 Posizioni Correnti", callback_data="positions_current"))
    markup.add(types.InlineKeyboardButton("📜 Storico Recente", callback_data="positions_history"))
    markup.add(types.InlineKeyboardButton("⬅️ Indietro al Menu", callback_data="menu"))
    return markup

def back_menu():
    markup = types.InlineKeyboardMarkup()
    markup.add(types.InlineKeyboardButton("⬅️ Indietro al Menu", callback_data="menu"))
    return markup

# === MONITOR ===
def monitor():
    global last_status, last_positions
    while True:
        master, m_conn = get_status(MASTER_FILE)
        if m_conn != last_status["master"]:
            msg = bot.send_message(CHAT_ID, "✅ Master (MT5) CONNESSO" if m_conn else "❌ Master (MT5) DISCONNESSO")
            auto_delete(CHAT_ID, msg.message_id)
            last_status["master"] = m_conn

        slave, s_conn = get_status(SLAVE_FILE)
        if s_conn != last_status["slave"]:
            msg = bot.send_message(CHAT_ID, "✅ Slave (MT4) CONNESSO" if s_conn else "❌ Slave (MT4) DISCONNESSO")
            auto_delete(CHAT_ID, msg.message_id)
            last_status["slave"] = s_conn

        positions = load_json(POSITIONS_FILE)
        if isinstance(positions, dict):
            positions = [{"symbol": sym, **info} for sym, info in positions.items()]

        # Usa chiave unica posId+side
        current = {str(p.get("position_id", p.get("ticket"))) + "_" + p.get("side","?"): p for p in positions}
        previous = {str(p.get("position_id", p.get("ticket"))) + "_" + p.get("side","?"): p for p in last_positions}

        for key, trade in current.items():
            if key not in previous and trade.get("status") == "open":
                mirror = trade.get("mirror_type", "")
                mirror_str = f" (Mirror: {mirror})" if mirror else ""
                msg = bot.send_message(
                    CHAT_ID,
                    f"🟢 Nuova posizione [{trade.get('side','?')}]\n"
                    f"{trade['symbol']} {trade['type']} {trade['lots']} lots @ {trade['price']}{mirror_str}"
                )
                auto_delete(CHAT_ID, msg.message_id)

            elif key in previous:
                old = previous[key]
                if trade.get("status") != old.get("status") and trade.get("status") == "close":
                    mirror = trade.get("mirror_type", "")
                    mirror_str = f" (Mirror: {mirror})" if mirror else ""
                    msg = bot.send_message(
                        CHAT_ID,
                        f"🔴 Posizione chiusa [{trade.get('side','?')}]\n"
                        f"{trade['symbol']} Ticket={trade['ticket']} PosID={trade.get('position_id','?')}{mirror_str}"
                    )
                    auto_delete(CHAT_ID, msg.message_id)

        last_positions = positions
        time.sleep(5)

threading.Thread(target=monitor, daemon=True).start()

# === COMANDI ===
@bot.message_handler(commands=['start'])
def start(message):
    bot.send_message(
        message.chat.id,
        "🏠 *Menu Principale*\n\nSeleziona un'operazione:",
        reply_markup=main_menu(),
        parse_mode="Markdown"
    )

# === CALLBACK ===
@bot.callback_query_handler(func=lambda call: True)
def callback_query(call):
    if call.data == "status":
        master, m_conn = get_status(MASTER_FILE)
        slave, s_conn = get_status(SLAVE_FILE)
        text = format_account(master, "Account Master (MT5)", m_conn)
        text += "\n" + format_account(slave, "Account Slave (MT4)", s_conn)
        bot.edit_message_text(text, call.message.chat.id, call.message.message_id,
                              parse_mode="Markdown", reply_markup=back_menu())

    elif call.data == "positions_menu":
        bot.edit_message_text("📌 *Seleziona una vista posizioni:*",
                              call.message.chat.id,
                              call.message.message_id,
                              parse_mode="Markdown",
                              reply_markup=positions_menu())

    elif call.data == "positions_current":
        positions = load_json(POSITIONS_FILE)
        master, _ = get_status(MASTER_FILE)
        slave, _ = get_status(SLAVE_FILE)
        text = format_current_positions(positions, master, slave)
        bot.edit_message_text(text, call.message.chat.id, call.message.message_id,
                              parse_mode="Markdown", reply_markup=positions_menu())

    elif call.data == "positions_history":
        positions = load_json(POSITIONS_FILE)
        master, _ = get_status(MASTER_FILE)
        slave, _ = get_status(SLAVE_FILE)
        text = format_history_positions(positions, master, slave)
        bot.edit_message_text(text, call.message.chat.id, call.message.message_id,
                              parse_mode="Markdown", reply_markup=positions_menu())

    elif call.data == "saldo":
        master, m_conn = get_status(MASTER_FILE)
        slave, s_conn = get_status(SLAVE_FILE)
        text = format_saldo(master, m_conn, slave, s_conn)
        bot.edit_message_text(text, call.message.chat.id, call.message.message_id,
                              parse_mode="Markdown", reply_markup=back_menu())

    elif call.data == "supporto":
        bot.edit_message_text("📩 Contatta il supporto qui.",
                              call.message.chat.id, call.message.message_id,
                              reply_markup=back_menu())

    elif call.data == "menu":
        bot.edit_message_text("🏠 *Menu Principale*\n\nSeleziona un'operazione:",
                              call.message.chat.id,
                              call.message.message_id,
                              parse_mode="Markdown",
                              reply_markup=main_menu())

print("🤖 Bot Telegram avviato...")
bot.polling()
