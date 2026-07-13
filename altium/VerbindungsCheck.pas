{..............................................................................}
{  Verbindungs-Check - Altium-Integration (DelphiScript, FORMLOS)              }
{                                                                              }
{  Bewusst OHNE Formular, ohne TTimer, ohne .dfm, ohne OLE - das sind genau    }
{  die Dinge, die in dieser Altium-Installation Freezes/Fehler ausgeloest      }
{  haben. Statt einer dauerlaufenden Form gibt es zwei einfache Prozeduren:    }
{                                                                              }
{    RunVerbindungsCheck  -> exportiert alle Tracks nach tracks.json.          }
{                            Der Python-Watcher oeffnet daraufhin den Report.  }
{    ApplyFixes           -> liest die im Browser angeklickten Fixes aus       }
{                            bridge_cmd.txt und wendet sie aufs Board an.      }
{                                                                              }
{  Ablauf:                                                                      }
{    1. PcbDoc oeffnen und AKTIV in den Vordergrund holen.                      }
{    2. Skript -> RunVerbindungsCheck, Arbeitsordner bestaetigen.              }
{       -> tracks.json wird geschrieben, der Browser-Report geht auf.          }
{    3. Im Browser Fehler mit "In Altium fixen" anklicken (beliebig viele).    }
{    4. In Altium ApplyFixes ausfuehren (am besten auf einen Shortcut legen).  }
{       -> alle offenen Fixes werden angewendet, das Board aktualisiert sich.  }
{    5. Bei Bedarf 2-4 wiederholen (RunVerbindungsCheck fuer aktuellen Stand). }
{                                                                              }
{  Zahlen locale-unabhaengig (Punkt raus beim Schreiben, Punkt+Komma rein).    }
{..............................................................................}

const
  MAX_ITER = 1000000;     // Not-Bremse: bricht ab, falls der Iterator nicht endet
                          // (bei ~10k Tracks/s entspricht das ca. 100 s Obergrenze)
  WORKDIR  = 'C:\altium-track-fixer';   // fest verdrahteter Arbeitsordner


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

// Wie DotFloat, aber mit vorgegebenem Separator (spart je Zahl ein FloatToStr
// zur Separator-Erkennung - bei zehntausenden Tracks spuerbar schneller).
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
{ Board defensiv holen (PCBServer koennte nil sein -> sonst Access Violation)   }
{------------------------------------------------------------------------------}
function GetBoard : IPCB_Board;
begin
  Result := nil;
  if PCBServer = nil then
  begin
    ShowMessage('PCB-Server ist nicht verfuegbar.' + #13#10#13#10 +
      'Bitte ein .PcbDoc oeffnen und das PCB-Fenster in den Vordergrund holen ' +
      '(aktives Dokument), dann das Skript erneut starten.');
    Exit;
  end;
  try
    Result := PCBServer.GetCurrentPCBBoard;
  except
    Result := nil;
  end;
  if Result = nil then
    ShowMessage('Kein PCB-Dokument aktiv.' + #13#10#13#10 +
      'Bitte ein .PcbDoc oeffnen und das PCB-Fenster in den Vordergrund holen.');
end;


{------------------------------------------------------------------------------}
{ Arbeitsordner pruefen (fest verdrahtet auf WORKDIR)                           }
{------------------------------------------------------------------------------}
function CheckWorkDir : Boolean;
begin
  Result := FileExists(WORKDIR + '\check_server.py');
  if not Result then
    ShowMessage('check_server.py nicht gefunden unter:' + #13#10 +
                WORKDIR + '\check_server.py' + #13#10#13#10 +
                'Bitte das Repo nach ' + WORKDIR + ' legen (oder die Konstante ' +
                'WORKDIR oben im Skript anpassen).');
end;


{------------------------------------------------------------------------------}
{ 1) Export: Board -> tracks.json                                              }
{------------------------------------------------------------------------------}
procedure RunVerbindungsCheck;
var
  Board   : IPCB_Board;
  WorkDir : String;
  JsonPath, CmdPath, AckPath : String;
  Iter    : IPCB_BoardIterator;
  Trk     : IPCB_Track;
  sl      : TStringList;
  netName, layName, line, sep : String;
  x1, y1, x2, y2, wd : Double;
  ox, oy  : TCoord;
  first, runaway : Boolean;
  id, skipped, netless, iterated : Integer;
begin
  Board := GetBoard;
  if Board = nil then Exit;

  if not CheckWorkDir then Exit;
  WorkDir := WORKDIR;

  JsonPath := WorkDir + '\tracks.json';
  CmdPath  := WorkDir + '\bridge_cmd.txt';
  AckPath  := WorkDir + '\bridge_ack.txt';

  // frische Sitzung: alte Bridge-Dateien entfernen
  if FileExists(CmdPath) then DeleteFile(CmdPath);
  if FileExists(AckPath) then DeleteFile(AckPath);

  ShowMessage('Lese jetzt die Tracks (ohne Top/Bottom, nur mit Net).' +
    #13#10#13#10 + 'Bei grossen Boards kann das einige Minuten dauern - ' +
    'Altium reagiert solange NICHT. Das ist normal, bitte NICHT abbrechen ' +
    'und nicht ueber den Task-Manager schliessen.');

  // Einmalig cachen (nicht pro Track neu lesen -> deutlich schneller).
  sep := DecSep;
  ox  := Board.XOrigin;
  oy  := Board.YOrigin;

  sl := TStringList.Create;
  sl.Add('{');
  sl.Add('  "document": "' + JsonEscape(Board.FileName) + '",');
  sl.Add('  "tracks": [');

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  first    := True;
  id       := 0;
  skipped  := 0;
  netless  := 0;
  iterated := 0;
  runaway  := False;
  Trk := Iter.FirstPCBObject;
  while Trk <> nil do
  begin
    iterated := iterated + 1;
    if iterated > MAX_ITER then begin runaway := True; Break; end;

    // Layer 1 (Top) und letztes Layer (Bottom) auslassen - die grossen.
    // Weitere Layer hier ergaenzen, z.B.  or (Trk.Layer = eMidLayer1)
    if (Trk.Layer = eTopLayer) or (Trk.Layer = eBottomLayer) then
    begin
      skipped := skipped + 1;
    end
    // Tracks OHNE Net auslassen: das sind v.a. Polygon-/Flaechen-Fuellstuecke.
    // Die Analyse braucht das Net ohnehin - ohne Net kein sinnvoller Check.
    else if Trk.Net = nil then
    begin
      netless := netless + 1;
    end
    else
    begin
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
    ShowMessage('Abgebrochen: mehr als ' + IntToStr(MAX_ITER) + ' Objekte ' +
      'durchlaufen, ohne ein Ende zu erreichen.' + #13#10#13#10 +
      'Entweder ist das Board extrem gross oder der Iterator terminiert nicht. ' +
      'Bitte melden - dann schliessen wir weitere Layer aus bzw. wechseln die ' +
      'Iterationsmethode.');
    Exit;
  end;

  sl.Add('  ]');
  sl.Add('}');

  // atomar schreiben: erst .tmp, dann umbenennen
  sl.SaveToFile(JsonPath + '.tmp');
  sl.Free;
  if FileExists(JsonPath) then DeleteFile(JsonPath);
  RenameFile(JsonPath + '.tmp', JsonPath);

  if id <= 0 then
  begin
    ShowMessage('Keine verwertbaren Tracks exportiert.' + #13#10#13#10 +
      'Top/Bottom uebersprungen: ' + IntToStr(skipped) + #13#10 +
      'ohne Net uebersprungen: ' + IntToStr(netless) + #13#10#13#10 +
      'Sind ' + IntToStr(netless) + ' ohne Net: dann fehlt dem Board die ' +
      'Konnektivitaet (Nets), oder es sind nur Flaechen. Bitte VC_T8_NetCheck ' +
      'ausfuehren.');
    Exit;
  end;

  ShowMessage('tracks.json geschrieben: ' + IntToStr(id) + ' Tracks mit Net.' +
    #13#10 + '(Top/Bottom uebersprungen: ' + IntToStr(skipped) +
    ', ohne Net: ' + IntToStr(netless) + ')' +
    #13#10#13#10 +
    'Laeuft der Hintergrund-Watcher (start_watcher.bat, am besten im ' +
    'Windows-Autostart), oeffnet sich der Browser-Report jetzt von selbst.' +
    #13#10 + 'Falls nicht: einmalig start_watcher.bat im Ordner doppelklicken.' +
    #13#10#13#10 +
    'Danach im Browser die Fehler anklicken und in Altium "ApplyFixes" ' +
    'ausfuehren, um sie ins Board zu uebernehmen.');
end;


{------------------------------------------------------------------------------}
{ 2) Apply: bridge_cmd.txt -> Fixes ins Board, bridge_ack.txt zurueck          }
{------------------------------------------------------------------------------}
procedure ApplyFixes;
var
  Board   : IPCB_Board;
  WorkDir : String;
  CmdPath, AckPath : String;
  Iter    : IPCB_BoardIterator;
  Trk     : IPCB_Track;
  TrackList : TInterfaceList;
  cmd, parts, results : TStringList;
  i, tid, endNo, applied, maxTid, iterated : Integer;
  fid : String;
  xmm, ymm : Double;
  cx, cy : TCoord;
  okMove, runaway : Boolean;
begin
  Board := GetBoard;
  if Board = nil then Exit;

  if not CheckWorkDir then Exit;
  WorkDir := WORKDIR;

  CmdPath := WorkDir + '\bridge_cmd.txt';
  AckPath := WorkDir + '\bridge_ack.txt';

  if not FileExists(CmdPath) then
  begin
    ShowMessage('Keine offenen Fixes gefunden (bridge_cmd.txt fehlt).' +
      #13#10#13#10 + 'Erst im Browser Fehler mit "In Altium fixen" anklicken, ' +
      'dann ApplyFixes ausfuehren.');
    Exit;
  end;

  cmd := TStringList.Create;
  try
    cmd.LoadFromFile(CmdPath);
  except
    cmd.Free;
    ShowMessage('bridge_cmd.txt konnte nicht gelesen werden. Kurz warten und ' +
      'ApplyFixes erneut ausfuehren.');
    Exit;
  end;

  if Trim(cmd.Text) = '' then
  begin
    cmd.Free;
    ShowMessage('Keine offenen Fixes. Im Browser zuerst "In Altium fixen" ' +
      'anklicken.');
    Exit;
  end;

  // id -> IPCB_Track rekonstruieren. WICHTIG: exakt dieselbe Auswahl wie beim
  // Export (Top/Bottom UND netlose Tracks ueberspringen), sonst passen die IDs
  // nicht mehr zusammen.
  parts := TStringList.Create;

  // hoechste benoetigte Track-ID ermitteln -> nur bis dahin iterieren.
  maxTid := -1;
  for i := 0 to cmd.Count - 1 do
  begin
    if Trim(cmd[i]) = '' then Continue;
    SplitSemi(cmd[i], parts);
    if parts.Count < 5 then Continue;
    tid := StrToIntDef(parts[1], -1);
    if tid > maxTid then maxTid := tid;
  end;

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
    if (Trk.Layer <> eTopLayer) and (Trk.Layer <> eBottomLayer)
       and (Trk.Net <> nil) then
      TrackList.Add(Trk);
    if TrackList.Count > maxTid then Break;   // genug gesammelt
    Trk := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  if runaway then
  begin
    parts.Free; cmd.Free; TrackList.Free;
    ShowMessage('Abgebrochen: Board zu gross beim Aufbau der ID-Zuordnung ' +
      '(ueber ' + IntToStr(MAX_ITER) + ' Objekte). Bitte melden.');
    Exit;
  end;

  results := TStringList.Create;   // Values[fid] = '1' (ok) / '0' (Fehler)
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
            okMove := True;
            applied := applied + 1;
          except
            okMove := False;
          end;
        end;
      end;

      // Ergebnis je fix_id festhalten (ein Fehler -> '0')
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

  // Bestaetigungen schreiben: Zeilen "fix_id;1" bzw. "fix_id;0"
  cmd.Clear;
  for i := 0 to results.Count - 1 do
    cmd.Add(results.Names[i] + ';' + results.ValueFromIndex[i]);
  try
    cmd.SaveToFile(AckPath);
  except
    // Server liest evtl. gerade -> egal, naechste Runde
  end;

  parts.Free;
  results.Free;
  cmd.Free;
  TrackList.Free;

  ShowMessage(IntToStr(applied) + ' Endpunkt(e) angepasst.' + #13#10#13#10 +
    'Im Browser wechseln die erledigten Fehler auf "Behoben in Altium".' +
    #13#10 + 'Rueckgaengig: ein Strg+Z macht die ganze Runde rueckgaengig.');
end;
