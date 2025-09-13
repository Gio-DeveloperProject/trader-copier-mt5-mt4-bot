# 📖 Trader Copier MT5 ⇄ MT4 (Reverse)

Sistema di copia ordini tra **MT5 (Master)** e **MT4 (Slave)** con gestione **reverse trade**, SL/TP fissi e monitoraggio tramite **Bot Telegram**.


## 📂 Struttura del progetto

TraderCopier/
│
├── Master_MT5.mq5 # EA da installare su MT5 (prop / master)
├── Slave_MT4.mq4 # EA da installare su MT4 (broker / slave)
│
├── bot_telegram.py # Bot Telegram (monitoraggio e notifiche)
├── config.json # Configurazione bot Telegram (token, chat_id)
│
├── common_files/ # Cartella condivisa MetaTrader
│ ├── account_status_master.json # Stato account Master (MT5)
│ ├── account_status_slave.json # Stato account Slave (MT4)
│ ├── positions.json # Log posizioni (aperte/chiuse su entrambi)
│ ├── order_OPEN_xxx.json # File segnale apertura (dal Master allo Slave)
│ ├── order_CLOSE_xxx.json # File segnale chiusura (dal Master allo Slave)
│
└── README.md # Documentazione del progetto


## ⚙️ Flusso di funzionamento

1. **Master_MT5.mq5 (EA su MT5)**
   - Intercetta tutte le operazioni fatte sul Master.  
   - Salva i dettagli in `positions.json`.  
   - Scrive file di segnale (`order_OPEN_xxx.json` / `order_CLOSE_xxx.json`) in `common_files/`.  
   - Aggiorna periodicamente lo stato account in `account_status_master.json`.  
   - (Se consentito dal broker) imposta SL/TP fissi sulla posizione del Master.

2. **Slave_MT4.mq4 (EA su MT4)**
   - Monitora la cartella `common_files/` per file `order_*.json`.  
   - Quando trova un `order_OPEN`, apre una posizione **inversa** sullo Slave.  
   - Applica **SL e TP fissi da parametri EA**.  
   - Alla chiusura (`order_CLOSE`), cerca la posizione corrispondente e la chiude.  
   - Aggiorna `positions.json` e `account_status_slave.json`.

3. **Bot Telegram (Python)**
   - Legge ciclicamente i file JSON in `common_files/`.  
   - Monitora lo stato account Master/Slave e le posizioni correnti.  
   - Invia notifiche su:
     - Connessione/disconnessione account.  
     - Apertura nuova posizione.  
     - Chiusura posizione.  
   - Permette di interrogare via menu inline:
     - Stato account.  
     - Posizioni correnti.  
     - Storico chiusure.  
     - Saldi correnti.

---

## 🔑 File principali

- **`Master_MT5.mq5`**
  - Parametri: `StopLossPoints`, `TakeProfitPoints`.  
  - Usa `OnTradeTransaction` per intercettare ordini.  
  - Scrive segnali `order_*.json`.  

- **`Slave_MT4.mq4`**
  - Parametri: `lot_ratio`, `SL_Points`, `TP_Points`.  
  - Usa `OrderSend()` per aprire posizioni inverse con SL/TP.  
  - Elimina file `order_*.json` dopo l’elaborazione.  

- **`bot_telegram.py`**
  - Legge `positions.json` e file `account_status_*.json`.  
  - Tiene traccia delle variazioni per notificare solo nuovi eventi.  
  - Gestisce menu interattivo `/start`.

- **`positions.json`**
  - Log comune di tutte le operazioni (apertura/chiusura Master e Slave).  
  - Ogni voce contiene:  
    ```json
    {
      "side": "master",
      "ticket": 123456,
      "position_id": 78910,
      "symbol": "XAUUSD",
      "type": "BUY",
      "mirror_type": "SELL",
      "lots": 0.10,
      "price": 3625.50,
      "sl": 3620.00,
      "tp": 3635.00,
      "status": "open",
      "time": "2025.09.11 12:57:30"
    }
    ```

---

## 📡 Comunicazione Master ⇄ Slave

La comunicazione avviene tramite **file JSON condivisi** salvati nella cartella comune di MetaTrader:  

- `order_OPEN_xxx.json` → segnala apertura (dal Master allo Slave).  
- `order_CLOSE_xxx.json` → segnala chiusura (dal Master allo Slave).  
- Dopo la lettura, lo Slave elimina il file per evitare duplicazioni.

---

## 🚀 Avvio del sistema

1. Copiare `Master_MT5.mq5` in **MQL5/Experts/** del terminale MT5 (Prop firm).  
2. Copiare `Slave_MT4.mq4` in **MQL4/Experts/** del terminale MT4 (Broker).  
3. Assicurarsi che entrambi i terminali abbiano accesso alla stessa cartella `common_files/`.  
   - (default: `~/AppData/Roaming/MetaQuotes/Terminal/Common/Files/`).  
4. Avviare entrambi gli EA su grafico (simboli corrispondenti).  
5. Avviare `bot_telegram.py` per ricevere notifiche.

---

✍️ Autore: *Giovanni Lentini*  
📅 Ultimo aggiornamento: **11/09/2025**
