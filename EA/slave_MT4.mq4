#property strict

// === Parametri configurabili ===
extern double lot_ratio  = 0.25;   // Rapporto lotti Master -> Slave
extern double SL_Points  = 300;    // StopLoss in punti
extern double TP_Points  = 600;    // TakeProfit in punti

datetime lastAccUpdate = 0;

// 🔹 Mapping simboli MT5 -> MT4
string MapSymbol(string masterSymbol)
{
   if(masterSymbol == "XAUUSD") return "GOLD#";
   if(masterSymbol == "EURUSD") return "EURUSD.";
   return masterSymbol;
}

// 🔹 Aggiorna stato account (file account_status_slave.json)
void UpdateAccountStatus()
{
   if(TimeCurrent() - lastAccUpdate < 30) return; // max ogni 30s
   lastAccUpdate = TimeCurrent();

   string file = "account_status_slave.json";
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      string json="{";
      json+="\"account\":"+IntegerToString(AccountNumber())+",";
      json+="\"name\":\""+AccountName()+"\",";
      json+="\"broker\":\""+AccountCompany()+"\",";
      json+="\"balance\":"+DoubleToString(AccountBalance(),2)+",";
      json+="\"equity\":"+DoubleToString(AccountEquity(),2)+",";
      json+="\"connected\":"+(IsConnected()?"true":"false");
      json+="}";
      FileWrite(h,json);
      FileClose(h);

      Print("📂 Stato account salvato in ", file, " -> ", json);
   }
}

// 🔹 Aggiorna positions.json aggiungendo trade lato Slave
void UpdatePositionsFile(long ticket, long posId, string symbol, string type, double lots, double price, string action)
{
   string file = "positions.json";
   string content = "[]";

   int h = FileOpen(file, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      content = FileReadString(h);
      FileClose(h);
   }
   if(content=="" || content=="{}") content="[]";

   string timeStr = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string newEntry = "{";
   newEntry+="\"side\":\"slave\",";
   newEntry+="\"ticket\":"+IntegerToString(ticket)+",";
   newEntry+="\"position_id\":"+IntegerToString(posId)+",";
   newEntry+="\"symbol\":\""+symbol+"\",";
   newEntry+="\"type\":\""+type+"\",";
   newEntry+="\"lots\":"+DoubleToString(lots,2)+",";
   newEntry+="\"price\":"+DoubleToString(price,Digits)+",";
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

   h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileWrite(h,content);
      FileClose(h);
      Print("📂 positions.json aggiornato (slave): ", newEntry);
   }
}

// === Utility ===
string ReadFile(string path)
{
   int h = FileOpen(path,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE) return "";
   string txt = FileReadString(h);
   FileClose(h);
   return txt;
}

string GetValue(string json,string key)
{
   string pattern="\""+key+"\":";
   int pos=StringFind(json,pattern);
   if(pos==-1) return "";
   pos+=StringLen(pattern);
   while(pos<StringLen(json) && (StringGetChar(json,pos)==' '||StringGetChar(json,pos)=='\"')) pos++;
   int end=pos;
   while(end<StringLen(json) && StringGetChar(json,end)!=',' && StringGetChar(json,end)!='}' && StringGetChar(json,end)!='\"') end++;
   return StringSubstr(json,pos,end-pos);
}

// === Ciclo EA ===
int OnInit()
{
   EventSetTimer(2);
   Print("✅ Slave MT4 avviato con SL=",SL_Points," TP=",TP_Points);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   string filename;
   int handle = FileFindFirst("order_*.json", filename, FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      do
      {
         if(StringFind(filename,"order_OPEN_")==0 || StringFind(filename,"order_CLOSE_")==0)
         {
            string content = ReadFile(filename);
            if(content!="")
            {
               string rawSymbol = GetValue(content,"symbol");
               string symbol    = MapSymbol(rawSymbol);
               string mirror    = GetValue(content,"mirror_type"); 
               string action    = GetValue(content,"action");
               string lotStr    = GetValue(content,"lots");
               string posStr    = GetValue(content,"position_id");
               long   posId     = StrToInteger(posStr);
               double lots      = StrToDouble(lotStr) * lot_ratio;

               // normalizza lotti
               double minLot   = MarketInfo(symbol, MODE_MINLOT);
               double lotStep  = MarketInfo(symbol, MODE_LOTSTEP);
               double maxLot   = MarketInfo(symbol, MODE_MAXLOT);
               lots = MathMax(minLot,lots);
               lots = MathMin(maxLot,lots);
               lots = MathFloor(lots/lotStep)*lotStep;
               lots = NormalizeDouble(lots,2);

               if(!SymbolSelect(symbol,true))
               {
                  Print("⚠️ Simbolo non disponibile su Slave: ", symbol);
                  FileDelete(filename, FILE_COMMON);
                  continue;
               }

               // === Apertura ===
               if(action=="open")
               {
                  int orderType = (mirror=="BUY") ? OP_BUY : OP_SELL;
                  double price  = (orderType==OP_BUY) ? MarketInfo(symbol,MODE_ASK) : MarketInfo(symbol,MODE_BID);

                  // Calcolo SL e TP
                  double sl=0, tp=0;
                  if(orderType==OP_BUY)
                  {
                     sl = price - SL_Points*Point;
                     tp = price + TP_Points*Point;
                  }
                  else
                  {
                     sl = price + SL_Points*Point;
                     tp = price - TP_Points*Point;
                  }

                  int ticket = OrderSend(symbol,orderType,lots,price,3,sl,tp,"Slave posId="+IntegerToString(posId));
                  if(ticket>0)
                  {
                     Print("✅ Trade aperto su Slave: posId=",posId," ",symbol," ",mirror," lots=",lots," SL=",sl," TP=",tp);
                     UpdatePositionsFile(ticket,posId,symbol,mirror,lots,price,"open");
                  }
                  else
                     Print("❌ Errore OrderSend su Slave: ", GetLastError());
               }

               // === Chiusura ===
               else if(action=="close")
               {
                  bool closed=false;
                  for(int i=OrdersTotal()-1;i>=0;i--)
                  {
                     if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES))
                     {
                        // 🔹 Cerca esattamente la posizione con lo stesso posId
                        if(OrderSymbol()==symbol && OrderComment()=="Slave posId="+IntegerToString(posId))
                        {
                           double price = (OrderType()==OP_BUY) ? MarketInfo(symbol,MODE_BID) : MarketInfo(symbol,MODE_ASK);
                           if(OrderClose(OrderTicket(),OrderLots(),price,3,clrYellow))
                           {
                              Print("✅ Posizione chiusa su Slave: posId=",posId," ticket=",OrderTicket());
                              string type = (OrderType()==OP_BUY) ? "BUY" : "SELL";
                              UpdatePositionsFile(OrderTicket(),posId,symbol,type,OrderLots(),price,"close");
                              closed=true;
                              break;
                           }
                           else
                              Print("❌ Errore chiusura Slave: ", GetLastError());
                        }
                     }
                  }
                  if(!closed)
                  {
                     Print("⚠️ Nessuna posizione trovata da chiudere su Slave per posId=",posId," ",symbol);
                     UpdatePositionsFile(0,posId,symbol,mirror,lots,0,"close");
                  }
               }
            }
            FileDelete(filename, FILE_COMMON); // ✅ cancella solo dopo aver processato
         }
      }
      while(FileFindNext(handle, filename));
      FileFindClose(handle);
   }

   UpdateAccountStatus();
}
