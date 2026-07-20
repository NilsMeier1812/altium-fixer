{..............................................................................}
{  Verbindungs-Check - Altium-Integration (DelphiScript, Formular)             }
{                                                                              }
{  Ablauf:                                                                      }
{    1. PcbDoc oeffnen und AKTIV in den Vordergrund holen.                      }
{    2. Skript -> RunVerbindungsCheck.                                          }
{       - liest alle Tracks MIT Net, schreibt tracks.json (Watcher oeffnet den  }
{         Browser-Report) und haelt die Track-Referenzen im Speicher.          }
{       - danach geht ein Fenster auf. Altium ist ab hier blockiert - das ist   }
{         ok, weil man jetzt im Browser arbeitet.                              }
{    3. Im Browser die Fehler anklicken (beliebig viele).                       }
{    4. Zurueck in Altium: Button "Aenderungen aus dem Browser holen" -> alle   }
{       angeklickten Fixes werden EINMALIG angewendet. Das Fenster bleibt offen,}
{       man kann im Browser weiter anklicken und erneut holen.                 }
{    5. "Fertig" beendet. Will man das Menue spaeter wieder oeffnen (ohne neuen  }
{       Export): ApplyFixes ausfuehren - es zeigt genau dasselbe Fenster.        }
{                                                                              }
{  In der normalen Benutzung braucht man nur diese zwei Skripte:                 }
{    RunVerbindungsCheck (Export + Menue)  und  ApplyFixes (Menue erneut).       }
{                                                                              }
{  Kein Timer/Polling noetig: ein Klick holt genau einmal. Die Track-Liste liegt}
{  im Speicher (aus dem Export), daher ist das Holen sofort da - ohne erneute   }
{  Iteration ueber das (grosse) Board.                                          }
{                                                                              }
{  Nur Tracks MIT Net und OHNE TOP/BOTTOM werden exportiert/behandelt           }
{  (ohne Net = Flaechenfuellung; TOP/BOTTOM sollen nie gezeigt werden).         }
{  Zahlen locale-unabhaengig. Board <-> Bridge laeuft ueber Dateien (kein OLE). }
{..............................................................................}

interface

type
  TVCForm = class(TForm)
    LabelStatus : TLabel;
    ButtonPull  : TButton;
    ButtonClose : TButton;
    procedure ButtonPullClick(Sender : TObject);
    procedure ButtonCloseClick(Sender : TObject);
  end;

var
  VCForm : TVCForm;


implementation

const
  MAX_ITER = 1000000;     // Not-Bremse gegen ewige Iteration

var
  Board     : IPCB_Board;
  TrackList : TInterfaceList;   // Items[id] = IPCB_Track (id = Export-Index)
  BuiltForBoard : IPCB_Board;   // Board, fuer das TrackList gebaut wurde
  WorkDir   : String;
  JsonPath  : String;
  CmdPath   : String;           // bridge_cmd.txt  (Server -> Altium)
  AckPath   : String;           // bridge_ack.txt  (Altium -> Server)
  ApplyRequested : Boolean;     // True = "Uebernehmen" (anwenden + Fenster neu)


{------------------------------------------------------------------------------}
{ Locale-unabhaengige Zahl <-> String                                          }
{------------------------------------------------------------------------------}
function DecSep : String;
var probe : String;
begin
  probe := FloatToStr(1.5);
  Result := Copy(probe, 2, 1);
end;

function DotFloatS(x : Double; const sep : String) : String;
var s, c, r : String; i : Integer;
begin
  s := FloatToStr(x);
  r := '';
  for i := 1 to Length(s) do
  begin
    c := Copy(s, i, 1);
    if c = sep then r := r + '.' else r := r + c;
  end;
  Result := r;
end;

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

procedure SplitSemi(const s : String; list : TStringList);
var i : Integer; cur, c : String;
begin
  list.Clear;
  cur := '';
  for i := 1 to Length(s) do
  begin
    c := Copy(s, i, 1);
    if c = ';' then begin list.Add(cur); cur := ''; end
    else cur := cur + c;
  end;
  list.Add(cur);
end;


{------------------------------------------------------------------------------}
{ Fester Arbeitsordner (Funktion, nicht const -> sonst "OleStr into Double")    }
{------------------------------------------------------------------------------}
function VCWorkDir : String;
begin
  Result := 'C:\altium-track-fixer';
end;

function CheckWorkDir : Boolean;
var d : String;
begin
  d := VCWorkDir;
  Result := FileExists(d + '\check_server.py');
  if not Result then
    ShowMessage('check_server.py nicht gefunden unter:' + #13#10 +
                d + '\check_server.py' + #13#10#13#10 +
                'Bitte das Repo nach ' + d + ' legen (oder VCWorkDir anpassen).');
end;


{------------------------------------------------------------------------------}
{ Board defensiv holen                                                         }
{------------------------------------------------------------------------------}
function GetBoard : IPCB_Board;
begin
  Result := nil;
  if PCBServer = nil then
  begin
    ShowMessage('PCB-Server nicht verfuegbar. Bitte ein .PcbDoc oeffnen und ' +
                'das PCB-Fenster in den Vordergrund holen.');
    Exit;
  end;
  try
    Result := PCBServer.GetCurrentPCBBoard;
  except
    Result := nil;
  end;
  if Result = nil then
    ShowMessage('Kein PCB-Dokument aktiv. Bitte ein .PcbDoc in den Vordergrund ' +
                'holen und das Skript erneut starten.');
end;


{------------------------------------------------------------------------------}
{ Fixes aus bridge_cmd.txt auf die (im Speicher liegende) TrackList anwenden.   }
{ Der Server schreibt nur noch offene Fixes in bridge_cmd.txt, also werden hier  }
{ genau die neuen angewendet. Rueckgabe: Anzahl angepasster Endpunkte.          }
{------------------------------------------------------------------------------}
function DoApply : Integer;
var
  cmd, parts, results : TStringList;
  i, tid, endNo, applied : Integer;
  fid : String;
  xmm, ymm : Double;
  cx, cy : TCoord;
  Trk : IPCB_Track;
  okMove : Boolean;
begin
  Result := 0;
  if (Board = nil) or (TrackList = nil) then Exit;
  if not FileExists(CmdPath) then Exit;

  cmd := TStringList.Create;
  try
    cmd.LoadFromFile(CmdPath);
  except
    cmd.Free;
    Exit;   // gerade im Schreibvorgang -> spaeter erneut
  end;
  if Trim(cmd.Text) = '' then begin cmd.Free; Exit; end;

  parts   := TStringList.Create;
  results := TStringList.Create;   // Values[fid] = '1'/'0'
  applied := 0;

  PCBServer.PreProcess;
  try
    for i := 0 to cmd.Count - 1 do
    begin
      if Trim(cmd[i]) = '' then Continue;
      SplitSemi(cmd[i], parts);
      if parts.Count < 5 then Continue;

      fid   := parts[0];
      tid   := StrToIntDef(parts[1], -1);
      endNo := StrToIntDef(parts[2], 0);
      xmm   := DotStrToFloat(parts[3]);
      ymm   := DotStrToFloat(parts[4]);

      okMove := False;
      if (tid >= 0) and (tid < TrackList.Count) then
      begin
        Trk := TrackList.Items[tid];
        if Trk <> nil then
        begin
          cx := Board.XOrigin + MMsToCoord(xmm);
          cy := Board.YOrigin + MMsToCoord(ymm);
          try
            Trk.BeginModify;
            if endNo = 1 then begin Trk.X1 := cx; Trk.Y1 := cy; end
            else               begin Trk.X2 := cx; Trk.Y2 := cy; end;
            Trk.EndModify;
            Trk.GraphicallyInvalidate;
            okMove := True;
            applied := applied + 1;
          except
            okMove := False;
          end;
        end;
      end;

      if okMove then
      begin
        if results.Values[fid] = '' then results.Values[fid] := '1';
      end
      else
        results.Values[fid] := '0';
    end;
  finally
    PCBServer.PostProcess;
  end;

  Board.ViewManager_FullUpdate;

  // Bestaetigungen schreiben (fix_id;1 / fix_id;0). Der Server dedupt per fix_id.
  cmd.Clear;
  for i := 0 to results.Count - 1 do
    cmd.Add(results.Names[i] + ';' + results.ValueFromIndex[i]);
  try
    cmd.SaveToFile(AckPath);
  except
    // Server liest evtl. gerade -> egal
  end;

  parts.Free;
  results.Free;
  cmd.Free;
  Result := applied;
end;


{------------------------------------------------------------------------------}
{ Formular-Ereignisse                                                          }
{------------------------------------------------------------------------------}
procedure TVCForm.ButtonPullClick(Sender : TObject);
begin
  // Fenster ZU. Das Anwenden passiert danach in der Schleife in
  // RunVerbindungsCheck (Fenster ist dann kurz zu -> Board zeichnet neu),
  // anschliessend geht das Fenster automatisch wieder auf.
  ApplyRequested := True;
  Close;
end;

procedure TVCForm.ButtonCloseClick(Sender : TObject);
begin
  ApplyRequested := False;   // Fertig -> nicht wieder oeffnen
  Close;
end;


{------------------------------------------------------------------------------}
{ Gemeinsame Menue-Schleife: "Uebernehmen" schliesst das Fenster, wendet die    }
{ offenen Fixes an (Fenster kurz zu -> Board wird sichtbar aktualisiert) und     }
{ oeffnet es wieder. "Fertig" beendet. Die Startmeldung setzt der Aufrufer.      }
{------------------------------------------------------------------------------}
procedure RunApplyLoop;
begin
  repeat
    ApplyRequested := False;
    VCForm.ShowModal;
    if ApplyRequested then
    begin
      if (PCBServer <> nil) and (PCBServer.GetCurrentPCBBoard = Board) then
        VCForm.LabelStatus.Caption :=
          IntToStr(DoApply) + ' Endpunkt(e) uebernommen.' + #13#10#13#10 +
          'Im Browser weiter anklicken und wieder "Aenderungen uebernehmen", ' +
          'oder "Fertig". (Strg+Z macht die letzte Runde rueckgaengig.)'
      else
        VCForm.LabelStatus.Caption :=
          'Anderes Dokument aktiv - bitte das urspruengliche PcbDoc in den ' +
          'Vordergrund holen, dann erneut "Aenderungen uebernehmen".';
    end;
  until not ApplyRequested;
end;


{------------------------------------------------------------------------------}
{ 1) Export: Board -> tracks.json (+ TrackList im Speicher) -> Fenster          }
{------------------------------------------------------------------------------}
procedure RunVerbindungsCheck;
var
  Iter : IPCB_BoardIterator;
  Trk  : IPCB_Track;
  sl   : TStringList;
  netName, layName, line, sep : String;
  x1, y1, x2, y2, wd : Double;
  ox, oy : TCoord;
  first, runaway : Boolean;
  id, netless, skippedLayer, iterated : Integer;
begin
  Board := GetBoard;
  if Board = nil then Exit;

  if not CheckWorkDir then Exit;
  WorkDir  := VCWorkDir;
  JsonPath := WorkDir + '\tracks.json';
  CmdPath  := WorkDir + '\bridge_cmd.txt';
  AckPath  := WorkDir + '\bridge_ack.txt';

  if FileExists(CmdPath) then DeleteFile(CmdPath);
  if FileExists(AckPath) then DeleteFile(AckPath);

  // Fortschrittsfenster MODELESS zeigen (Buttons aus), damit man waehrend des
  // langen Exports sieht, dass es laeuft. Application.ProcessMessages haelt das
  // Fenster am Leben. Vor der Apply-Schleife wird es kurz versteckt und dann
  // modal wieder gezeigt.
  VCForm.ButtonPull.Enabled  := False;
  VCForm.ButtonClose.Enabled := False;
  VCForm.LabelStatus.Caption :=
    'Lese Tracks ... (TOP/BOTTOM werden uebersprungen, nur Tracks mit Net).' +
    #13#10#13#10 + 'Das kann bei grossen Boards einige Minuten dauern. ' +
    'Bitte NICHT abbrechen - der Zaehler unten laeuft weiter.';
  try VCForm.Show; Application.ProcessMessages; except end;

  sep := DecSep;
  ox  := Board.XOrigin;
  oy  := Board.YOrigin;

  // Dieses DelphiScript erkennt bei TInterfaceList weder .Clear noch .Free.
  // Also NICHT aufraeumen, sondern einfach eine neue Liste anlegen - die alte
  // Referenz faellt weg (harmlos: ein paar Objekte pro Altium-Sitzung).
  TrackList := TInterfaceList.Create;

  sl := TStringList.Create;
  sl.Add('{');
  sl.Add('  "document": "' + JsonEscape(Board.FileName) + '",');
  sl.Add('  "tracks": [');

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  first        := True;
  id           := 0;
  netless      := 0;
  skippedLayer := 0;
  iterated     := 0;
  runaway      := False;
  Trk := Iter.FirstPCBObject;
  while Trk <> nil do
  begin
    iterated := iterated + 1;
    if iterated > MAX_ITER then begin runaway := True; Break; end;

    // Statusanzeige gelegentlich aktualisieren (nicht jeden Durchlauf).
    if (iterated mod 5000) = 0 then
    begin
      VCForm.LabelStatus.Caption :=
        'Lese Tracks ... bitte warten.' + #13#10#13#10 +
        'Geprueft: ' + IntToStr(iterated) + #13#10 +
        'Exportiert (mit Net, ohne TOP/BOTTOM): ' + IntToStr(id) + #13#10 +
        'TOP/BOTTOM uebersprungen: ' + IntToStr(skippedLayer);
      try Application.ProcessMessages; except end;
    end;

    // TOP und BOTTOM werden nie gezeigt -> frueh ueberspringen, spart die
    // teure Net-/String-/Add-Arbeit fuer den Grossteil der Tracks.
    if (Trk.Layer = eTopLayer) or (Trk.Layer = eBottomLayer) then
    begin
      skippedLayer := skippedLayer + 1;
    end
    else if Trk.Net = nil then
    begin
      netless := netless + 1;
    end
    else
    begin
      TrackList.Add(Trk);      // Index = id
      netName := Trk.Net.Name;
      layName := Board.LayerName(Trk.Layer);

      x1 := CoordToMMs(Trk.X1 - ox);
      y1 := CoordToMMs(Trk.Y1 - oy);
      x2 := CoordToMMs(Trk.X2 - ox);
      y2 := CoordToMMs(Trk.Y2 - oy);
      wd := CoordToMMs(Trk.Width);

      line := '    {"id": ' + IntToStr(id) +
              ', "layer": "' + JsonEscape(layName) + '"' +
              ', "net": "' + JsonEscape(netName) + '"' +
              ', "x1": ' + DotFloatS(x1, sep) +
              ', "y1": ' + DotFloatS(y1, sep) +
              ', "x2": ' + DotFloatS(x2, sep) +
              ', "y2": ' + DotFloatS(y2, sep) +
              ', "width": ' + DotFloatS(wd, sep) + '}';
      if not first then
        sl[sl.Count - 1] := sl[sl.Count - 1] + ',';
      sl.Add(line);
      first := False;

      id := id + 1;
    end;

    Trk := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  if runaway then
  begin
    sl.Free;
    try VCForm.Hide; except end;
    ShowMessage('Abgebrochen: mehr als ' + IntToStr(MAX_ITER) + ' Objekte ' +
      'durchlaufen, ohne ein Ende zu erreichen. Bitte melden.');
    Exit;
  end;

  sl.Add('  ]');
  sl.Add('}');
  sl.SaveToFile(JsonPath + '.tmp');
  sl.Free;
  if FileExists(JsonPath) then DeleteFile(JsonPath);
  RenameFile(JsonPath + '.tmp', JsonPath);

  // Fortschrittsfenster verstecken und Buttons wieder aktivieren, damit es
  // gleich sauber modal (mit klickbaren Buttons) geoeffnet werden kann.
  VCForm.ButtonPull.Enabled  := True;
  VCForm.ButtonClose.Enabled := True;
  try VCForm.Hide; except end;

  if id <= 0 then
  begin
    ShowMessage('Keine Tracks mit Net exportiert (ohne Net: ' + IntToStr(netless) +
      ', TOP/BOTTOM uebersprungen: ' + IntToStr(skippedLayer) +
      '). Fehlt dem Board die Konnektivitaet? Bitte VC_T8_NetCheck ausfuehren.');
    Exit;
  end;

  BuiltForBoard := Board;   // TrackList gehoert zu diesem Board (fuer ApplyFixes)

  VCForm.LabelStatus.Caption :=
    'Export fertig: ' + IntToStr(id) + ' Tracks (mit Net, ohne TOP/BOTTOM). ' +
    'Uebersprungen: TOP/BOTTOM ' + IntToStr(skippedLayer) +
    ', ohne Net ' + IntToStr(netless) + '.' + #13#10#13#10 +
    'Der Browser-Report sollte offen sein (sonst start_watcher.bat starten). ' +
    'Jetzt die Fehler im Browser anklicken, dann hier "Aenderungen uebernehmen".';

  RunApplyLoop;
end;


{------------------------------------------------------------------------------}
{ TrackList ohne erneuten Export neu aufbauen (nur Board-Iteration, kein JSON).  }
{ MUSS exakt denselben Filter/dieselbe Reihenfolge wie der Export nutzen, damit  }
{ die IDs zu den im Browser gewaehlten Fixes passen. Iteriert das GANZE Board,   }
{ nicht nur bis zur hoechsten ID - man kann im Browser ja neue Fehler anklicken. }
{ Rueckgabe: True bei Erfolg.                                                   }
{------------------------------------------------------------------------------}
function RebuildTrackList : Boolean;
var
  Iter : IPCB_BoardIterator;
  Trk  : IPCB_Track;
  iterated : Integer;
  runaway : Boolean;
begin
  Result := False;

  VCForm.ButtonPull.Enabled  := False;
  VCForm.ButtonClose.Enabled := False;
  VCForm.LabelStatus.Caption :=
    'Baue die Track-Zuordnung neu auf (kein neuer Export) ...' + #13#10#13#10 +
    'Das kann bei grossen Boards einige Minuten dauern. Bitte NICHT abbrechen.';
  try VCForm.Show; Application.ProcessMessages; except end;

  TrackList := TInterfaceList.Create;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);
  iterated := 0;
  runaway  := False;
  Trk := Iter.FirstPCBObject;
  while Trk <> nil do
  begin
    iterated := iterated + 1;
    if iterated > MAX_ITER then begin runaway := True; Break; end;

    if (iterated mod 5000) = 0 then
    begin
      VCForm.LabelStatus.Caption :=
        'Baue die Track-Zuordnung neu auf ... bitte warten.' + #13#10#13#10 +
        'Geprueft: ' + IntToStr(iterated) + #13#10 +
        'Zugeordnet: ' + IntToStr(TrackList.Count);
      try Application.ProcessMessages; except end;
    end;

    // Gleicher Filter wie beim Export: TOP/BOTTOM raus, nur Tracks mit Net.
    if (Trk.Layer <> eTopLayer) and (Trk.Layer <> eBottomLayer) and
       (Trk.Net <> nil) then
      TrackList.Add(Trk);

    Trk := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  VCForm.ButtonPull.Enabled  := True;
  VCForm.ButtonClose.Enabled := True;
  try VCForm.Hide; except end;

  if runaway then
  begin
    ShowMessage('Abgebrochen: Board zu gross beim Aufbau der Zuordnung.');
    Exit;
  end;

  BuiltForBoard := Board;
  Result := True;
end;


{------------------------------------------------------------------------------}
{ 2) Menue erneut oeffnen (ohne Export). Fuer den Fall, dass man das Fenster     }
{    geschlossen hat und weiter fixen moechte. Verwendet die Zuordnung aus dem   }
{    letzten Export wieder, wenn sie noch im Speicher liegt und zum aktuellen    }
{    Board gehoert - sonst wird sie einmal neu aufgebaut.                        }
{------------------------------------------------------------------------------}
procedure ApplyFixes;
begin
  Board := GetBoard;
  if Board = nil then Exit;
  if not CheckWorkDir then Exit;
  WorkDir  := VCWorkDir;
  JsonPath := WorkDir + '\tracks.json';
  CmdPath  := WorkDir + '\bridge_cmd.txt';
  AckPath  := WorkDir + '\bridge_ack.txt';

  if (TrackList = nil) or (TrackList.Count = 0) or (BuiltForBoard <> Board) then
    if not RebuildTrackList then Exit;

  VCForm.LabelStatus.Caption :=
    'Menue erneut geoeffnet (kein neuer Export). Im Browser die Fehler ' +
    'anklicken, dann "Aenderungen uebernehmen" - oder "Fertig".';

  RunApplyLoop;
end;

end.
