{..............................................................................}
{  Verbindungs-Check - Altium-Integration (DelphiScript, Formular + Timer)     }
{                                                                              }
{  Exportiert alle Tracks des aktiven PCB-Dokuments, startet den Python-       }
{  Server (check_server.py) und wendet die im HTML angeklickten Fixes LIVE     }
{  auf das Board an.                                                           }
{                                                                              }
{  WICHTIG: Dieses Skript besteht aus ZWEI Dateien, die zusammengehoeren:      }
{     VerbindungsCheck.pas   (dieser Code)                                     }
{     VerbindungsCheck.dfm   (das Formular)                                    }
{  Am besten das Projekt VerbindungsCheck.PrjScr oeffnen und daraus starten.   }
{                                                                              }
{  Bedienung in Altium:                                                        }
{    Skript ausfuehren -> Prozedur "RunVerbindungsCheck"                       }
{    1. Drei kurze Eingaben (Python, Skript-Ordner, Port).                     }
{    2. Board wird exportiert, Python-Server startet, Browser oeffnet Report.  }
{    3. Ein kleines Fenster zeigt "laeuft". Im Browser "In Altium fixen"       }
{       klicken -> Endpunkt wandert sofort (jeder Fix = eigener Undo-Schritt). }
{    4. Fertig? -> Button "Stoppen/Schliessen" ODER Python-Fenster schliessen. }
{                                                                              }
{  Warum ein Formular mit Timer statt einer Schleife: Eine Endlosschleife auf  }
{  Altiums Haupt-Thread friert Altium ein. Der Timer im (modalen) Formular     }
{  wird ueber die Nachrichtenschleife bedient und blockiert nicht.             }
{                                                                              }
{  Zahlen: locale-unabhaengig, Ausgabe mit Punkt, Lesen akzeptiert Punkt+Komma.}
{..............................................................................}

interface

type
  TVCForm = class(TForm)
    LabelStatus : TLabel;
    ButtonStop  : TButton;
    TimerPoll   : TTimer;
    procedure ButtonStopClick(Sender : TObject);
    procedure TimerPollTimer(Sender : TObject);
  end;

var
  VCForm : TVCForm;


implementation

{$R *.dfm}

var
  Board      : IPCB_Board;
  TrackList  : TInterfaceList;   // Items[id] = IPCB_Track
  TrackCount : Integer;
  BaseUrl    : String;
  RepoDir    : String;           // Ordner mit check_server.py (+ tracks.json)
  JsonPath   : String;
  PortPath   : String;
  ServerMiss : Integer;          // wie oft /ping in Folge fehlschlug


{------------------------------------------------------------------------------}
{ Locale-unabhaengige Zahl <-> String Umwandlung                               }
{------------------------------------------------------------------------------}
function DecSep : String;
var probe : String;
begin
  probe := FloatToStr(1.5);      // "1,5" oder "1.5"
  Result := Copy(probe, 2, 1);
end;

// Double -> String, IMMER mit Punkt.
function DotFloat(x : Double) : String;
var s, sep, c, r : String; i : Integer;
begin
  s := FloatToStr(x);
  sep := DecSep;
  r := '';
  for i := 1 to Length(s) do
  begin
    c := Copy(s, i, 1);
    if c = sep then r := r + '.' else r := r + c;
  end;
  Result := r;
end;

// String -> Double, akzeptiert Punkt UND Komma als Dezimaltrenner.
function DotStrToFloat(const s : String) : Double;
var sep, c, t : String; i : Integer;
begin
  sep := DecSep;
  t := '';
  for i := 1 to Length(s) do
  begin
    c := Copy(s, i, 1);
    if (c = '.') or (c = ',') then t := t + sep else t := t + c;
  end;
  Result := StrToFloatDef(t, 0);
end;


{------------------------------------------------------------------------------}
{ Kleine Helfer                                                                }
{------------------------------------------------------------------------------}
// JSON-String escapen (manuell, ohne Set-Syntax).
function JsonEscape(const s : String) : String;
var i : Integer; c, r : String;
begin
  r := '';
  for i := 1 to Length(s) do
  begin
    c := Copy(s, i, 1);
    if c = '\' then r := r + '\\'
    else if c = '"' then r := r + '\"'
    else r := r + c;
  end;
  Result := r;
end;

// Zeile an ';' in eine Liste zerlegen (ohne StrictDelimiter/DelimitedText).
procedure SplitSemi(const s : String; list : TStringList);
var i : Integer; cur, c : String;
begin
  list.Clear;
  cur := '';
  for i := 1 to Length(s) do
  begin
    c := Copy(s, i, 1);
    if c = ';' then
    begin
      list.Add(cur);
      cur := '';
    end
    else
      cur := cur + c;
  end;
  list.Add(cur);
end;

// HTTP GET ueber MSXML. Liefert responseText, oder '' bei Fehler.
function HttpGet(const url : String) : String;
var http : Variant;
begin
  Result := '';
  try
    http := CreateOleObject('MSXML2.XMLHTTP.6.0');
    http.open('GET', url, False);
    http.send;
    if http.status = 200 then
      Result := http.responseText;
  except
    Result := '';
  end;
end;

// Einen Fix beim Server bestaetigen.
procedure SendAck(const fid : String; ok : Boolean);
begin
  if fid = '' then Exit;
  if ok then
    HttpGet(BaseUrl + '/ack?fix_id=' + fid + '&ok=1')
  else
    HttpGet(BaseUrl + '/ack?fix_id=' + fid + '&ok=0');
end;


{------------------------------------------------------------------------------}
{ Board -> tracks.json                                                         }
{------------------------------------------------------------------------------}
function ExportBoard : Boolean;
var
  Iter    : IPCB_BoardIterator;
  Trk     : IPCB_Track;
  sl      : TStringList;
  netName : String;
  layName : String;
  x1, y1, x2, y2, wd : Double;
  first   : Boolean;
  line    : String;
  id      : Integer;
begin
  Result := False;
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = nil then
  begin
    ShowMessage('Kein PCB-Dokument aktiv. Bitte ein .PcbDoc oeffnen.');
    Exit;
  end;

  TrackList.Clear;

  sl := TStringList.Create;
  sl.Add('{');
  sl.Add('  "document": "' + JsonEscape(Board.FileName) + '",');
  sl.Add('  "tracks": [');

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  first := True;
  Trk := Iter.FirstPCBObject;
  while Trk <> nil do
  begin
    id := TrackList.Count;      // ID = Index in der Liste
    TrackList.Add(Trk);

    if Trk.Net <> nil then netName := Trk.Net.Name else netName := '';
    layName := Board.LayerName(Trk.Layer);

    x1 := CoordToMMs(Trk.X1 - Board.XOrigin);
    y1 := CoordToMMs(Trk.Y1 - Board.YOrigin);
    x2 := CoordToMMs(Trk.X2 - Board.XOrigin);
    y2 := CoordToMMs(Trk.Y2 - Board.YOrigin);
    wd := CoordToMMs(Trk.Width);

    line := '    {"id": ' + IntToStr(id) +
            ', "layer": "' + JsonEscape(layName) + '"' +
            ', "net": "' + JsonEscape(netName) + '"' +
            ', "x1": ' + DotFloat(x1) +
            ', "y1": ' + DotFloat(y1) +
            ', "x2": ' + DotFloat(x2) +
            ', "y2": ' + DotFloat(y2) +
            ', "width": ' + DotFloat(wd) + '}';
    if not first then
      sl[sl.Count - 1] := sl[sl.Count - 1] + ',';
    sl.Add(line);
    first := False;

    Trk := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  sl.Add('  ]');
  sl.Add('}');

  TrackCount := TrackList.Count;
  JsonPath := RepoDir + '\tracks.json';
  PortPath := JsonPath + '.port';
  if FileExists(PortPath) then
    DeleteFile(PortPath);
  sl.SaveToFile(JsonPath);
  sl.Free;

  Result := TrackCount > 0;
  if not Result then
    ShowMessage('Keine Tracks gefunden. Ist das richtige PcbDoc aktiv?');
end;


{------------------------------------------------------------------------------}
{ Python-Server starten und auf Port-File warten                               }
{------------------------------------------------------------------------------}
function StartServer(py, wishPort : String) : Boolean;
var
  Wsh   : Variant;
  cmd   : String;
  srv   : String;
  sl    : TStringList;
  tries : Integer;
begin
  Result := False;
  py := Trim(py);
  wishPort := Trim(wishPort);
  if py = '' then py := 'python';
  if wishPort = '' then wishPort := '8765';
  srv := RepoDir + '\check_server.py';

  // Fenster sichtbar (1) -> Python-Ausgabe/Fehler bleiben sichtbar.
  cmd := 'cmd /k ""' + py + '" "' + srv + '" "' + JsonPath +
         '" --port ' + wishPort + '"';
  try
    Wsh := CreateOleObject('WScript.Shell');
    Wsh.Run(cmd, 1, False);
  except
    ShowMessage('Konnte Python nicht starten. Pfad pruefen.');
    Exit;
  end;

  // Auf das Port-File warten (Server schreibt den echten Port hinein).
  tries := 0;
  while (not FileExists(PortPath)) and (tries < 40) do
  begin
    Sleep(250);
    Inc(tries);
  end;
  if not FileExists(PortPath) then
  begin
    ShowMessage('Server-Port nicht gefunden. Laeuft Python? Ordner/Python pruefen.');
    Exit;
  end;

  sl := TStringList.Create;
  sl.LoadFromFile(PortPath);
  BaseUrl := 'http://127.0.0.1:' + Trim(sl.Text);
  sl.Free;

  tries := 0;
  while (HttpGet(BaseUrl + '/ping') <> 'pong') and (tries < 20) do
  begin
    Sleep(200);
    Inc(tries);
  end;

  Result := True;
end;


{------------------------------------------------------------------------------}
{ Einen Endpunkt eines Tracks verschieben                                      }
{------------------------------------------------------------------------------}
function ApplyMove(tid, endNo : Integer; xmm, ymm : Double) : Boolean;
var
  Trk : IPCB_Track;
  cx, cy : TCoord;
begin
  Result := False;
  if (tid < 0) or (tid >= TrackList.Count) then Exit;
  Trk := TrackList.Items[tid];
  if Trk = nil then Exit;

  cx := Board.XOrigin + MMsToCoord(xmm);
  cy := Board.YOrigin + MMsToCoord(ymm);

  try
    PCBServer.PreProcess;
    Trk.BeginModify;
    if endNo = 1 then
    begin
      Trk.X1 := cx;
      Trk.Y1 := cy;
    end
    else
    begin
      Trk.X2 := cx;
      Trk.Y2 := cy;
    end;
    Trk.EndModify;
    Trk.GraphicallyInvalidate;
    PCBServer.PostProcess;
    Result := True;
  except
    Result := False;
  end;
end;


{------------------------------------------------------------------------------}
{ Eine Runde: /pending abfragen, Fixes anwenden, /ack senden                   }
{------------------------------------------------------------------------------}
procedure PollOnce;
var
  resp   : String;
  lines  : TStringList;
  parts  : TStringList;
  i      : Integer;
  fid    : String;
  tid, endNo : Integer;
  xmm, ymm   : Double;
  curFid : String;
  curOk  : Boolean;
  anyApplied : Boolean;
begin
  if BaseUrl = '' then Exit;
  // Nur anwenden, wenn das urspruengliche Board aktiv ist. Sonst gar nicht erst
  // /pending holen (sonst blieben Fixes serverseitig als "pending" haengen).
  if PCBServer.GetCurrentPCBBoard <> Board then Exit;

  resp := HttpGet(BaseUrl + '/pending');
  if resp = '' then Exit;

  lines := TStringList.Create;
  lines.Text := resp;
  parts := TStringList.Create;

  curFid := '';
  curOk  := True;
  anyApplied := False;

  for i := 0 to lines.Count - 1 do
  begin
    if Trim(lines[i]) = '' then Continue;
    SplitSemi(lines[i], parts);
    if parts.Count < 5 then Continue;

    fid   := parts[0];
    tid   := StrToIntDef(parts[1], -1);
    endNo := StrToIntDef(parts[2], 0);
    xmm   := DotStrToFloat(parts[3]);
    ymm   := DotStrToFloat(parts[4]);

    if (curFid <> '') and (fid <> curFid) then
    begin
      SendAck(curFid, curOk);
      curOk := True;
    end;
    curFid := fid;

    if not ApplyMove(tid, endNo, xmm, ymm) then
      curOk := False
    else
      anyApplied := True;
  end;
  SendAck(curFid, curOk);

  parts.Free;
  lines.Free;

  if anyApplied then
    Board.ViewManager_FullUpdate;
end;


{------------------------------------------------------------------------------}
{ Formular-Ereignisse                                                          }
{------------------------------------------------------------------------------}
// Timer: laeuft nur, solange das (modale) Fenster offen ist -> blockiert nicht.
procedure TVCForm.TimerPollTimer(Sender : TObject);
begin
  if HttpGet(BaseUrl + '/ping') = 'pong' then
  begin
    ServerMiss := 0;
    PollOnce;
    LabelStatus.Caption :=
      'Laeuft. Im Browser "In Altium fixen" klicken - Endpunkte wandern sofort.' +
      #13#10 + 'Beenden: unten stoppen oder das Python-Fenster schliessen.';
  end
  else
  begin
    Inc(ServerMiss);
    if ServerMiss >= 6 then      // ~3 s ohne Server
    begin
      TimerPoll.Enabled := False;
      LabelStatus.Caption :=
        'Server beendet (Python-Fenster geschlossen). Dieses Fenster kann zu.';
    end;
  end;
end;

procedure TVCForm.ButtonStopClick(Sender : TObject);
begin
  TimerPoll.Enabled := False;
  Close;
end;


{------------------------------------------------------------------------------}
{ Einstieg                                                                     }
{------------------------------------------------------------------------------}
procedure RunVerbindungsCheck;
var
  py, repo, wishPort : String;
begin
  BaseUrl := '';
  ServerMiss := 0;
  TrackList := TInterfaceList.Create;
  try
    py := InputBox('Verbindungs-Check',
                   'Python-Programm (Exe oder "python"):', 'python');
    repo := InputBox('Verbindungs-Check',
                     'Skript-Ordner (enthaelt check_server.py):',
                     'C:\Pfad\zu\altium-fixer');
    wishPort := InputBox('Verbindungs-Check',
                         'Port (wird bei Belegung hochgezaehlt):', '8765');

    // Skript-Ordner pruefen (dort landet auch tracks.json).
    repo := Trim(repo);
    if repo = '' then
    begin
      ShowMessage('Kein Skript-Ordner angegeben. Abbruch.');
      Exit;
    end;
    if Copy(repo, Length(repo), 1) = '\' then
      repo := Copy(repo, 1, Length(repo) - 1);
    RepoDir := repo;
    if not FileExists(RepoDir + '\check_server.py') then
    begin
      ShowMessage('check_server.py nicht gefunden unter:'#13#10 +
                  RepoDir + '\check_server.py');
      Exit;
    end;

    if not ExportBoard then Exit;
    if not StartServer(py, wishPort) then Exit;

    // Modales Fenster mit Timer -> Live-Uebernahme ohne Altium einzufrieren.
    VCForm := TVCForm.Create(nil);
    VCForm.ShowModal;
    VCForm.Free;
  finally
    TrackList.Free;
  end;
end;

end.
