#property strict
#include <Trade\Trade.mqh>

// === PARAMETRI SL/TP FISSI (in punti) ===
input int StopLossPoints   = 200;   // distanza SL in punti
input int TakeProfitPoints = 400;   // distanza TP in punti
input int RetryCount       = 10;    // numero tentativi per applicare SL/TP
input int RetryDelayMs     = 200;   // delay tra tentativi (ms)

// === PARAMETRI AUTOTRADE ===
input bool   AutoTradeEnabled = false; // se true apre ordini random in automatico
input string AutoSymbol       = "XAUUSD"; 
input double AutoLots         = 0.10;  // lotti autotrade
input int    AutoIntervalSec  = 60;    // intervallo minimo tra trade auto (sec)

CTrade trade;
datetime lastAutoTrade = 0; // ultimo trade automatico

// 🔹 Mappa simboli MT5 -> MT4
string MapSymbolForSlave(string masterSymbol)
{
   if(masterSymbol == "XAUUSD") return "GOLD#";
   if(masterSymbol == "EURUSD") return "EURUSD.";
   return masterSymbol;
}

// 🔹 Aggiorna file account_status_master.json
void UpdateAccountStatus()
{
   string file = "account_status_master.json";
   int h = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   string json="{";
   json+="\"account\":"+IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN))+","; 
   json+="\"name\":\""+AccountInfoString(ACCOUNT_NAME)+"\","; 
   json+="\"broker\":\""+AccountInfoString(ACCOUNT_COMPANY)+"\","; 
   json+="\"balance\":"+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)+","; 
   json+="\"equity\":"+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2)+","; 
   json+="\"connected\":"+(TerminalInfoInteger(TERMINAL_CONNECTED)?"true":"false"); 
   json+="}";
   FileWrite(h,json);
   FileClose(h);
}

// 🔹 Aggiorna positions.json
void UpdatePositionsFile(string side, long ticket, long positionId,
                         string symbol, string type, string mirrorType,
                         double lots, double price, string action,
                         double sl=0, double tp=0)
{
   string file = "positions.json";
   string content = "[]";

   int h = FileOpen(file, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      content = FileReadString(h);
      FileClose(h);
   }
   if(content=="" || content=="{}") content="[]";

   string timeStr = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string newEntry = "{";
   newEntry+="\"side\":\""+side+"\","; 
   newEntry+="\"ticket\":"+IntegerToString((int)ticket)+","; 
   newEntry+="\"position_id\":"+IntegerToString((int)positionId)+","; 
   newEntry+="\"symbol\":\""+symbol+"\","; 
   newEntry+="\"type\":\""+type+"\","; 
   newEntry+="\"mirror_type\":\""+mirrorType+"\","; 
   newEntry+="\"lots\":"+DoubleToString(lots,2)+","; 
   newEntry+="\"price\":"+DoubleToString(price,_Digits)+","; 
   newEntry+="\"sl\":"+DoubleToString(sl,_Digits)+","; 
   newEntry+="\"tp\":"+DoubleToString(tp,_Digits)+","; 
   newEntry+="\"status\":\""+action+"\","; 
   newEntry+="\"time\":\""+timeStr+"\""; 
   newEntry+="}";

   if(content=="[]")
      content = "["+newEntry+"]";
   else
   {
      if(StringSubstr(content,StringLen(content)-1,1)=="]")
         content = StringSubstr(content,0,StringLen(content)-1);
      content += ","+newEntry+"]";
   }

   h = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileWrite(h,content);
      FileClose(h);
   }
}

int OnInit()
{
   EventSetTimer(10); 
   Print("✅ Master MT5 avviato con SL=",StopLossPoints," TP=",TakeProfitPoints,
         " | AutoTrade=", (AutoTradeEnabled?"ON":"OFF"));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   UpdateAccountStatus();

   // === AUTOTRADE RANDOM ===
   if(AutoTradeEnabled && (TimeCurrent() - lastAutoTrade >= AutoIntervalSec))
   {
      if(!PositionSelect(AutoSymbol)) // apri solo se non c’è già una posizione aperta
      {
         int dir = (MathRand() % 2 == 0) ? 1 : -1;  // random BUY/SELL
         double price = (dir==1) ? 
                        SymbolInfoDouble(AutoSymbol, SYMBOL_ASK) : 
                        SymbolInfoDouble(AutoSymbol, SYMBOL_BID);

         bool ok;
         if(dir==1)
            ok = trade.Buy(AutoLots, AutoSymbol, price, 0, 0);
         else
            ok = trade.Sell(AutoLots, AutoSymbol, price, 0, 0);

         if(ok)
         {
            Print("🤖 AutoTrade aperto: ", (dir==1?"BUY":"SELL"), " ", AutoLots, " ", AutoSymbol, " @ ", price);
            lastAutoTrade = TimeCurrent();
         }
         else
            Print("❌ Errore apertura AutoTrade | Err=", GetLastError());
      }
   }
}

// 🔹 intercetta trade dal Master
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   long   dealTicket   = (long)trans.deal;
   long   positionId   = (long)trans.position;
   string dealSymbol   = trans.symbol;
   double dealVolume   = trans.volume;
   double dealPrice    = trans.price;
   int    dealType     = trans.deal_type;

   if(dealSymbol == "" || dealVolume <= 0 || dealPrice <= 0) return;

   int entryType = -1;
   if(HistoryDealSelect(dealTicket))
      entryType = (int)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

   string mappedSymbol = MapSymbolForSlave(dealSymbol);
   string dealTypeStr  = (dealType == DEAL_TYPE_BUY ? "BUY" : "SELL");
   string mirrorType   = (dealTypeStr == "BUY" ? "SELL" : "BUY");

   string action, prefix;
   double sl=0, tp=0;

   if(entryType == DEAL_ENTRY_IN) {
      action = "open";
      prefix = "order_OPEN_";

      // Calcolo SL/TP fissi
      if(dealTypeStr=="BUY") {
         sl = dealPrice - StopLossPoints*_Point;
         tp = dealPrice + TakeProfitPoints*_Point;
      } else {
         sl = dealPrice + StopLossPoints*_Point;
         tp = dealPrice - TakeProfitPoints*_Point;
      }

      // 🔹 Tentativi per applicare SL/TP
      bool modified = false;
      for(int i=0;i<RetryCount;i++) {
         if(PositionSelect(dealSymbol)) {
            if(trade.PositionModify(dealSymbol, sl, tp)) {
               modified=true;
               break;
            }
         }
         Sleep(RetryDelayMs);
      }

      UpdatePositionsFile("master", dealTicket, positionId,
                          mappedSymbol, dealTypeStr, mirrorType,
                          dealVolume, dealPrice, action, sl, tp);
   }
   else if(entryType == DEAL_ENTRY_OUT || entryType == DEAL_ENTRY_INOUT) {
      action = "close";
      prefix = "order_CLOSE_";

      UpdatePositionsFile("master", dealTicket, positionId,
                          mappedSymbol, dealTypeStr, mirrorType,
                          dealVolume, dealPrice, action);
   }

   // Scrivi file ordine per Slave
   string file = prefix + IntegerToString((int)positionId) + ".json"; 
   int h = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      string json="{";
      json+="\"ticket\":"+IntegerToString((int)dealTicket)+","; 
      json+="\"position_id\":"+IntegerToString((int)positionId)+","; 
      json+="\"symbol\":\""+mappedSymbol+"\","; 
      json+="\"type\":\""+dealTypeStr+"\","; 
      json+="\"mirror_type\":\""+mirrorType+"\","; 
      json+="\"lots\":"+DoubleToString(dealVolume,2)+","; 
      json+="\"price\":"+DoubleToString(dealPrice,_Digits)+","; 
      json+="\"sl\":"+DoubleToString(sl,_Digits)+","; 
      json+="\"tp\":"+DoubleToString(tp,_Digits)+","; 
      json+="\"action\":\""+action+"\""; 
      json+="}";
      FileWrite(h,json);
      FileClose(h);
   }

   UpdateAccountStatus();
}
