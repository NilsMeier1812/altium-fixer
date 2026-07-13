{..............................................................................}
{  Verbindungs-Check - Altium-Integration (DelphiScript, Datei-Bridge)         }
{                                                                              }
{  Exportiert alle Tracks des aktiven PCB-Dokuments und wendet die im HTML     }
{  angeklickten Fixes LIVE auf das Board an - ueber DATEIEN, nicht ueber HTTP. }
{                                                                              }
{  Warum Datei-Bridge: Dieses Altium-DelphiScript kennt KEIN CreateOleObject   }
{  (kein MSXML/HTTP, kein WScript.Shell). Also kommuniziert Altium mit dem      }
{  Python-Server ueber zwei Textdateien im Arbeitsordner:                      }
{     bridge_cmd.txt   Server -> Altium  (offene Fixes: fix_id;track;end;x;y)   }
{     bridge_ack.txt   Altium -> Server  (erledigt:     fix_id;1)               }
{                                                                              }
{  Der Python-Server wird NICHT aus Altium gestartet (kein Prozess-Start ohne   }
{  OLE). Stattdessen doppelklickt man start_server.bat im Arbeitsordner.        }
{                                                                              }
{  Ablauf:                                                                      }
{    1. PcbDoc aktiv, Skript -> RunVerbindungsCheck, Arbeitsordner bestaetigen. }
{    2. tracks.json wird geschrieben. Ein kleines Fenster geht auf.             }
{    3. start_server.bat doppelklicken -> Browser oeffnet den Report.           }
{    4. Im Browser "In Altium fixen" -> der Timer uebernimmt es live.           }
{    5. Beenden: "Stoppen/Schliessen" + Python-Fenster schliessen.             }
{                                                                              }
{  Der Timer laeuft im modalen Formular (Nachrichtenschleife) und friert       }
{  Altium NICHT ein. Zahlen locale-unabhaengig (Punkt raus, Punkt+Komma rein). }
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

var
  Board      : IPCB_Board;
  TrackList  : TInterfaceList;   // Items[id] = IPCB_Track
  TrackCount : Integer;
  WorkDir    : String;           // Ordner mit check_server.py + Bridge-Dateien
  JsonPath   : String;
  CmdPath    : String;           // bridge_cmd.txt  (Server -> Altium)
  AckPath    : String;           // bridge_ack.txt  (Altium -> Server)
  AppliedFids : TStringList;     // schon angewendete fix_ids (Dedupe)
  AckLines    : TStringList;     // kumulativ "fix_id;1" fuer bridge_ack.txt


{------------------------------------------------------------------------------}
{ Locale-unabhaengige Zahl <-> String Umwandlung                               }
{------------------------------------------------------------------------------}
function DecSep : String;
var probe : String;
begin
  probe := FloatToStr(1.5);      // "1,5" oder "1.5"
  Result := Copy(probe, 2, 1);
end;

function DotFloat(x : Double) : String;   // Double -> String, IMMER mit Punkt
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

function DotStrToFloat(const s : String) : Double;  // akzeptiert Punkt UND Komma
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

// Zeile an ';' in eine Liste zerlegen.
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
  // Atomar schreiben: erst .tmp, dann umbenennen. So sieht der Watcher nie
  // eine halb geschriebene Datei.
  sl.SaveToFile(JsonPath + '.tmp');
  sl.Free;
  if FileExists(JsonPath) then DeleteFile(JsonPath);
  RenameFile(JsonPath + '.tmp', JsonPath);

  Result := TrackCount > 0;
  if not Result then
    ShowMessage('Keine Tracks gefunden. Ist das richtige PcbDoc aktiv?');
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
{ Eine Runde: bridge_cmd.txt lesen, Fixes anwenden, bridge_ack.txt schreiben   }
{------------------------------------------------------------------------------}
procedure PollOnce;
var
  cmd    : TStringList;
  lines  : TStringList;
  parts  : TStringList;
  i      : Integer;
  fid, curFid : String;
  tid, endNo  : Integer;
  xmm, ymm    : Double;
  curOk       : Boolean;
  changed     : Boolean;
  anyApplied  : Boolean;
begin
  if not FileExists(CmdPath) then
  begin
    LabelStatus.Caption :=
      'Warte auf Server ... bitte start_server.bat im Ordner starten.';
    Exit;
  end;
  // Nur anwenden, wenn das urspruengliche Board aktiv ist.
  if PCBServer.GetCurrentPCBBoard <> Board then
  begin
    LabelStatus.Caption := 'Anderes Dokument aktiv - urspruengliches PcbDoc waehlen.';
    Exit;
  end;

  cmd := TStringList.Create;
  try
    cmd.LoadFromFile(CmdPath);
  except
    cmd.Free;
    Exit;   // Datei gerade im Schreibvorgang -> naechste Runde
  end;

  lines := cmd;   // Alias
  parts := TStringList.Create;

  curFid  := '';
  curOk   := True;
  changed := False;
  anyApplied := False;

  for i := 0 to lines.Count - 1 do
  begin
    if Trim(lines[i]) = '' then Continue;
    SplitSemi(lines[i], parts);
    if parts.Count < 5 then Continue;

    fid := parts[0];

    // Fix-Wechsel -> vorherigen abschliessen (Ack schreiben, wenn neu)
    if (curFid <> '') and (fid <> curFid) then
    begin
      if AppliedFids.IndexOf(curFid) < 0 then
      begin
        AppliedFids.Add(curFid);
        if curOk then AckLines.Add(curFid + ';1')
        else          AckLines.Add(curFid + ';0');
        changed := True;
      end;
      curOk := True;
    end;
    curFid := fid;

    // schon angewendet? dann ueberspringen
    if AppliedFids.IndexOf(fid) >= 0 then
    begin
      curFid := fid;
      Continue;
    end;

    tid   := StrToIntDef(parts[1], -1);
    endNo := StrToIntDef(parts[2], 0);
    xmm   := DotStrToFloat(parts[3]);
    ymm   := DotStrToFloat(parts[4]);

    if not ApplyMove(tid, endNo, xmm, ymm) then
      curOk := False
    else
      anyApplied := True;
  end;

  // letzten Fix abschliessen
  if (curFid <> '') and (AppliedFids.IndexOf(curFid) < 0) then
  begin
    AppliedFids.Add(curFid);
    if curOk then AckLines.Add(curFid + ';1')
    else          AckLines.Add(curFid + ';0');
    changed := True;
  end;

  parts.Free;
  cmd.Free;

  if anyApplied then
    Board.ViewManager_FullUpdate;

  if changed then
  begin
    try
      AckLines.SaveToFile(AckPath);
    except
      // Server liest gerade -> naechste Runde erneut versuchen
    end;
  end;

  LabelStatus.Caption :=
    'Aktiv. Angewendete Fixes: ' + IntToStr(AppliedFids.Count) + '.' + #13#10 +
    'Im Browser weiter fixen. Beenden: unten stoppen + Python-Fenster zu.';
end;


{------------------------------------------------------------------------------}
{ Formular-Ereignisse                                                          }
{------------------------------------------------------------------------------}
procedure TVCForm.TimerPollTimer(Sender : TObject);
begin
  PollOnce;
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
  repo : String;
begin
  TrackList   := TInterfaceList.Create;
  AppliedFids := TStringList.Create;
  AckLines    := TStringList.Create;
  try
    repo := InputBox('Verbindungs-Check',
                     'Arbeitsordner (enthaelt check_server.py + start_server.bat):',
                     'C:\Pfad\zu\altium-fixer');
    repo := Trim(repo);
    if repo = '' then
    begin
      ShowMessage('Kein Ordner angegeben. Abbruch.');
      Exit;
    end;
    if Copy(repo, Length(repo), 1) = '\' then
      repo := Copy(repo, 1, Length(repo) - 1);
    WorkDir := repo;
    if not FileExists(WorkDir + '\check_server.py') then
    begin
      ShowMessage('check_server.py nicht gefunden unter:'#13#10 +
                  WorkDir + '\check_server.py');
      Exit;
    end;

    JsonPath := WorkDir + '\tracks.json';
    CmdPath  := WorkDir + '\bridge_cmd.txt';
    AckPath  := WorkDir + '\bridge_ack.txt';

    // eigene Ausgabedatei einer frueheren Sitzung entfernen
    if FileExists(AckPath) then DeleteFile(AckPath);

    if not ExportBoard then Exit;

    ShowMessage('tracks.json wurde geschrieben.' + #13#10#13#10 +
                'Laeuft der Hintergrund-Watcher (start_watcher.bat, am besten im ' +
                'Windows-Autostart), oeffnet sich der Browser jetzt von selbst.' +
                #13#10#13#10 +
                'Falls nicht: einmalig "start_watcher.bat" im Ordner ' +
                'doppelklicken.' + #13#10#13#10 +
                'Dann im Browser "In Altium fixen" klicken - dieses Fenster ' +
                'uebernimmt die Fixe live ins Board.');

    // Modales Fenster mit Timer -> Live-Uebernahme ohne Altium einzufrieren.
    VCForm := TVCForm.Create(nil);
    VCForm.ShowModal;
    VCForm.Free;
  finally
    AckLines.Free;
    AppliedFids.Free;
    TrackList.Free;
  end;
end;

end.
