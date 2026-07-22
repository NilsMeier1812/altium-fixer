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
{       Export): ApplyFixes ausfuehren - es zeigt genau dasselbe Fenster und ist  }
{       SOFORT da, auch nach einem Altium-Neustart (kein Neu-Einlesen mehr).      }
{                                                                              }
{  "Im Altium finden": Waehlt man im Browser bei EINEM Fehler "Im Altium finden",}
{  wird beim naechsten "Uebernehmen" dorthin gezoomt und das Fenster bleibt ZU   }
{  (modal wuerde die Sicht blockieren). Menue zurueck: ApplyFixes.               }
{                                                                              }
{  In der normalen Benutzung braucht man nur diese zwei Skripte:                 }
{    RunVerbindungsCheck (Export + Menue)  und  ApplyFixes (Menue erneut).       }
{                                                                              }
{  Kein Timer/Polling noetig: ein Klick holt genau einmal. Liegt die Track-Liste}
{  noch im Speicher (aus dem Export), wird sie als schnelle Abkuerzung genutzt.  }
{  Ist sie weg (z.B. nach Altium-Neustart), findet DoApply die Tracks per        }
{  KLEINER raeumlicher Suche ueber die vom Server mitgelieferte Ursprungslage -  }
{  daher NIE mehr eine komplette Iteration ueber das (grosse) Board beim Anwenden.}
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
  MAX_ITER   = 1000000;   // Not-Bremse gegen ewige Iteration
  MAX_TRACKS = 500000;    // Kapazitaet der Track-Zuordnung (statisches Array)

var
  Board     : IPCB_Board;
  // STATISCHES Array statt TInterfaceList: dieses DelphiScript erkennt bei
  // TInterfaceList die Member nicht zuverlaessig (.Clear/.Free/.Count schlugen
  // als "Undeclared identifier" fehl) UND kennt keine dynamischen Arrays
  // ("array of" -> "[ expected"). Ein festes Array + Zaehler braucht nur
  // Index-Zugriff - da kann nichts scheitern. Grenze MAX_TRACKS grosszuegig.
  TrackArr   : array[0 .. MAX_TRACKS - 1] of IPCB_Track;  // TrackArr[id] = Track
  TrackCount : Integer;               // gueltige Eintraege 0 .. TrackCount-1
  BuiltForBoard : IPCB_Board;   // Board, fuer das TrackArr gebaut wurde
  WorkDir   : String;
  JsonPath  : String;
  CmdPath   : String;           // bridge_cmd.txt  (Server -> Altium)
  AckPath   : String;           // bridge_ack.txt  (Altium -> Server)
  JumpPath  : String;           // bridge_jump.txt (Server -> Altium: "x;y")
  ApplyRequested : Boolean;     // True = "Uebernehmen" (anwenden + Fenster neu)


{------------------------------------------------------------------------------}
{ HINWEIS zu den Dummy-Parametern (Dummy : Integer):                            }
{ Altiums "Run Script"-Dialog listet ALLE parameterlosen procedures UND         }
{ functions. Damit dort nur die zwei Einstiegspunkte RunVerbindungsCheck und    }
{ ApplyFixes erscheinen, bekommt jeder interne Helfer einen (ungenutzten)        }
{ Parameter - dann blendet Altium ihn aus. Aufruf also z.B. DecSep(0).          }
{------------------------------------------------------------------------------}

{------------------------------------------------------------------------------}
{ Locale-unabhaengige Zahl <-> String                                          }
{------------------------------------------------------------------------------}
function DecSep(Dummy : Integer) : String;
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
  sep := DecSep(0);
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

// TrackArr "leeren": nur den Zaehler zuruecksetzen. Alte Eintraege oberhalb
// des neuen Zaehlers werden nie gelesen (Zugriffe pruefen tid < TrackCount).
procedure TrackReset(Dummy : Integer);
begin
  TrackCount := 0;
end;

// Einen Track ans Ende haengen. TrackCount zaehlt immer mit (= Export-Index),
// gespeichert wird nur solange die feste Kapazitaet reicht (Ueberlauf-Schutz).
procedure TrackAppend(Trk : IPCB_Track);
begin
  if TrackCount < MAX_TRACKS then
    TrackArr[TrackCount] := Trk;
  TrackCount := TrackCount + 1;
end;


{------------------------------------------------------------------------------}
{ Fester Arbeitsordner (Funktion, nicht const -> sonst "OleStr into Double")    }
{------------------------------------------------------------------------------}
function VCWorkDir(Dummy : Integer) : String;
begin
  Result := 'C:\altium-track-fixer';
end;

function CheckWorkDir(Dummy : Integer) : Boolean;
var d : String;
begin
  d := VCWorkDir(0);
  Result := FileExists(d + '\check_server.py');
  if not Result then
    ShowMessage('check_server.py nicht gefunden unter:' + #13#10 +
                d + '\check_server.py' + #13#10#13#10 +
                'Bitte das Repo nach ' + d + ' legen (oder VCWorkDir anpassen).');
end;


{------------------------------------------------------------------------------}
{ Board defensiv holen                                                         }
{------------------------------------------------------------------------------}
function GetBoard(Dummy : Integer) : IPCB_Board;
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
{ Raeumliche Track-Suche (fuer den "kalten" Fall ohne Zuordnung im Speicher).    }
{                                                                              }
{ Der Server liefert in bridge_cmd.txt jetzt zusaetzlich die URSPRUNGSLAGE      }
{ (ox;oy) des zu bewegenden Endpunkts und den Layernamen mit. Damit findet der   }
{ folgende Helfer den Track ueber einen KLEINEN raeumlichen Iterator wieder -    }
{ ohne das ganze Board neu durchzugehen. So muss ApplyFixes nach einem Neustart  }
{ nicht mehr minutenlang alles neu einlesen (frueher: RebuildTrackList).         }
{                                                                              }
{ Sicher: gesucht wird nur ein Track, dessen Endpunkt endNo SEHR nah an (ox,oy)  }
{ liegt und dessen Layer passt. Fehlerstellen sind partnerlos (kein zweiter      }
{ Endpunkt an genau dieser Stelle), also ist der Treffer eindeutig. Bei 0 oder   }
{ >1 Treffern wird NICHTS bewegt (nil) - lieber einen Fix auslassen als den      }
{ falschen Track verschieben.                                                    }
{------------------------------------------------------------------------------}
function LocateEndpoint(oxmm, oymm : Double; endNo : Integer;
                        const layName : String) : IPCB_Track;
var
  SpIter : IPCB_SpatialIterator;
  Trk, hit : IPCB_Track;
  cx, cy, r : TCoord;
  tol, ex, ey : Double;
  nhits : Integer;
  okLayer : Boolean;
begin
  Result := nil;
  hit := nil;
  nhits := 0;
  if Board = nil then Exit;

  cx  := Board.XOrigin + MMsToCoord(oxmm);
  cy  := Board.YOrigin + MMsToCoord(oymm);
  r   := MMsToCoord(0.1);    // 100 um Suchfenster um die Ursprungslage
  tol := 0.003;              // mm: so nah muss der Endpunkt an (ox,oy) liegen

  SpIter := Board.SpatialIterator_Create;
  try
    SpIter.AddFilter_ObjectSet(MkSet(eTrackObject));
    SpIter.AddFilter_Area(cx - r, cy - r, cx + r, cy + r);
    Trk := SpIter.FirstPCBObject;
    while Trk <> nil do
    begin
      okLayer := (layName = '') or (Board.LayerName(Trk.Layer) = layName);
      if okLayer then
      begin
        if endNo = 2 then
        begin
          ex := CoordToMMs(Trk.X2 - Board.XOrigin);
          ey := CoordToMMs(Trk.Y2 - Board.YOrigin);
        end
        else
        begin
          ex := CoordToMMs(Trk.X1 - Board.XOrigin);
          ey := CoordToMMs(Trk.Y1 - Board.YOrigin);
        end;
        if (Abs(ex - oxmm) <= tol) and (Abs(ey - oymm) <= tol) then
        begin
          nhits := nhits + 1;
          hit := Trk;
        end;
      end;
      Trk := SpIter.NextPCBObject;
    end;
  finally
    Board.SpatialIterator_Destroy(SpIter);
  end;

  if nhits = 1 then Result := hit;   // eindeutig -> sicher; sonst nil (auslassen)
end;


{ Beliebigen (naechstgelegenen) Track nahe (xmm,ymm) finden - nur fuer den Layer }
{ beim "Im Altium finden"-Sprung, wenn die Zuordnung nicht im Speicher liegt.    }
function LocateAnyTrackNear(xmm, ymm, radmm : Double) : IPCB_Track;
var
  SpIter : IPCB_SpatialIterator;
  Trk, best : IPCB_Track;
  cx, cy, r : TCoord;
  bestD, d, ex, ey : Double;
begin
  Result := nil;
  best := nil;
  bestD := 1.0E30;
  if Board = nil then Exit;

  cx := Board.XOrigin + MMsToCoord(xmm);
  cy := Board.YOrigin + MMsToCoord(ymm);
  r  := MMsToCoord(radmm);

  SpIter := Board.SpatialIterator_Create;
  try
    SpIter.AddFilter_ObjectSet(MkSet(eTrackObject));
    SpIter.AddFilter_Area(cx - r, cy - r, cx + r, cy + r);
    Trk := SpIter.FirstPCBObject;
    while Trk <> nil do
    begin
      ex := CoordToMMs(Trk.X1 - Board.XOrigin) - xmm;
      ey := CoordToMMs(Trk.Y1 - Board.YOrigin) - ymm;
      d  := ex * ex + ey * ey;                       // quadr. Abstand Endpunkt 1
      ex := CoordToMMs(Trk.X2 - Board.XOrigin) - xmm;
      ey := CoordToMMs(Trk.Y2 - Board.YOrigin) - ymm;
      if (ex * ex + ey * ey) < d then d := ex * ex + ey * ey;  // ... vs Endpunkt 2
      if d < bestD then begin bestD := d; best := Trk; end;
      Trk := SpIter.NextPCBObject;
    end;
  finally
    Board.SpatialIterator_Destroy(SpIter);
  end;

  Result := best;
end;


{------------------------------------------------------------------------------}
{ Fixes aus bridge_cmd.txt auf die (im Speicher liegende) TrackList anwenden.   }
{ Der Server schreibt nur noch offene Fixes in bridge_cmd.txt, also werden hier  }
{ genau die neuen angewendet. Rueckgabe: Anzahl angepasster Endpunkte.          }
{------------------------------------------------------------------------------}
function DoApply(Dummy : Integer) : Integer;
var
  cmd, parts, results : TStringList;
  i, tid, endNo, applied : Integer;
  fid, layName : String;
  xmm, ymm, oxmm, oymm : Double;
  cx, cy : TCoord;
  Trk : IPCB_Track;
  okMove, warm : Boolean;
begin
  Result := 0;
  // Board muss da sein - die Track-Zuordnung im Speicher ist NICHT mehr noetig:
  // fehlt sie (kalt, z.B. nach Altium-Neustart), findet DoApply die Tracks per
  // raeumlicher Suche ueber die vom Server mitgelieferte Ursprungslage.
  if Board = nil then Exit;
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
      xmm   := DotStrToFloat(parts[3]);     // Zielkoordinaten
      ymm   := DotStrToFloat(parts[4]);
      // Neue Felder (rueckwaertskompatibel): Ursprungslage (ox;oy) + Layername.
      oxmm := 0.0; oymm := 0.0; layName := '';
      if parts.Count >= 7 then
      begin
        oxmm := DotStrToFloat(parts[5]);
        oymm := DotStrToFloat(parts[6]);
      end;
      if parts.Count >= 8 then layName := parts[7];

      // Track aufloesen: 1) schnelle Abkuerzung ueber die Zuordnung im Speicher
      // (nur wenn sie zum aktuellen Board gehoert), sonst 2) raeumliche Suche
      // ueber die Ursprungslage - dann ist KEIN Neu-Einlesen des Boards noetig.
      Trk := nil;
      warm := (BuiltForBoard = Board) and (tid >= 0) and
              (tid < TrackCount) and (tid < MAX_TRACKS);
      if warm then Trk := TrackArr[tid];
      if (Trk = nil) and (parts.Count >= 7) then
        Trk := LocateEndpoint(oxmm, oymm, endNo, layName);

      okMove := False;
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
{ Sprung-Wunsch aus bridge_jump.txt ("x_mm;y_mm;track_id") -> im PCB dorthin     }
{ zoomen UND den Layer des Tracks aktiv setzen (sonst springt man auf dem        }
{ gerade aktiven Layer). Rueckgabe: True, wenn gesprungen wurde.                 }
{------------------------------------------------------------------------------}
function DoJump(Dummy : Integer) : Boolean;
var
  jl, parts : TStringList;
  line : String;
  xmm, ymm : Double;
  cx, cy, r : TCoord;
  tid : Integer;
  NearTrk : IPCB_Track;
begin
  Result := False;
  if (Board = nil) or (JumpPath = '') then Exit;
  if not FileExists(JumpPath) then Exit;

  jl := TStringList.Create;
  try
    jl.LoadFromFile(JumpPath);
  except
    jl.Free;
    Exit;   // gerade im Schreibvorgang -> beim naechsten Mal
  end;

  line := Trim(jl.Text);
  jl.Free;
  if line = '' then begin DeleteFile(JumpPath); Exit; end;

  parts := TStringList.Create;
  SplitSemi(line, parts);
  if parts.Count >= 2 then
  begin
    xmm := DotStrToFloat(parts[0]);
    ymm := DotStrToFloat(parts[1]);
    cx  := Board.XOrigin + MMsToCoord(xmm);
    cy  := Board.YOrigin + MMsToCoord(ymm);
    r   := MMsToCoord(2.0);   // ~4x4 mm Ausschnitt um den Punkt
    try
      // Layer des zugehoerigen Tracks aktiv setzen. Erst die Zuordnung im
      // Speicher probieren (nur wenn sie zum aktuellen Board gehoert), sonst
      // raeumlich den naechsten Track am Punkt suchen - so klappt es auch
      // "kalt" (nach Neustart, ohne Zuordnung im Speicher).
      NearTrk := nil;
      if parts.Count >= 3 then
      begin
        tid := StrToIntDef(parts[2], -1);
        if (BuiltForBoard = Board) and (tid >= 0) and
           (tid < TrackCount) and (tid < MAX_TRACKS) then
          NearTrk := TrackArr[tid];
      end;
      if NearTrk = nil then
        NearTrk := LocateAnyTrackNear(xmm, ymm, 0.5);
      if NearTrk <> nil then
        Board.CurrentLayer := NearTrk.Layer;

      Board.GraphicalView_ZoomOnRect(cx - r, cy - r, cx + r, cy + r);
      Board.GraphicalView_ZoomRedraw;
      Result := True;
    except
      Result := False;
    end;
  end;
  parts.Free;

  DeleteFile(JumpPath);   // verbraucht -> beim naechsten Uebernehmen kein Re-Sprung
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
{ oeffnet es wieder. "Fertig" beendet. startMsg = erste Statuszeile.            }
{ (Parameter absichtlich: so listet Altium diese Hilfsprozedur NICHT im         }
{ "Run Script"-Dialog - dort sollen nur RunVerbindungsCheck und ApplyFixes      }
{ auftauchen.)                                                                  }
{                                                                              }
{ Sonderfall "Im Altium finden": Hat man im Browser einen Punkt zum Anzeigen    }
{ gewaehlt, liegt beim Uebernehmen bridge_jump.txt vor. Dann werden die Fixes    }
{ angewendet, es wird zum Punkt gezoomt und das Fenster bleibt ZU (sonst        }
{ blockiert das modale Fenster die Sicht). Menue holt man mit ApplyFixes zurueck.}
{------------------------------------------------------------------------------}
procedure RunApplyLoop(const startMsg : String);
var n : Integer;
begin
  VCForm.LabelStatus.Caption := startMsg;
  repeat
    ApplyRequested := False;
    VCForm.ShowModal;
    if ApplyRequested then
    begin
      if (PCBServer <> nil) and (PCBServer.GetCurrentPCBBoard = Board) then
      begin
        n := DoApply(0);
        if DoJump(0) then
          // Sprung angefordert: Fixes sind drin, Ansicht ist am Punkt ->
          // Fenster NICHT wieder oeffnen. (Zurueck ins Menue: ApplyFixes.)
          ApplyRequested := False
        else
          VCForm.LabelStatus.Caption :=
            IntToStr(n) + ' Endpunkt(e) uebernommen.' + #13#10#13#10 +
            'Im Browser weiter anklicken und wieder "Aenderungen uebernehmen", ' +
            'oder "Fertig". (Strg+Z macht die letzte Runde rueckgaengig.)';
      end
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
  Board := GetBoard(0);
  if Board = nil then Exit;

  if not CheckWorkDir(0) then Exit;
  WorkDir  := VCWorkDir(0);
  JsonPath := WorkDir + '\tracks.json';
  CmdPath  := WorkDir + '\bridge_cmd.txt';
  AckPath  := WorkDir + '\bridge_ack.txt';
  JumpPath := WorkDir + '\bridge_jump.txt';

  if FileExists(CmdPath)  then DeleteFile(CmdPath);
  if FileExists(AckPath)  then DeleteFile(AckPath);
  if FileExists(JumpPath) then DeleteFile(JumpPath);

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

  sep := DecSep(0);
  ox  := Board.XOrigin;
  oy  := Board.YOrigin;

  TrackReset(0);   // TrackArr leeren

  sl := TStringList.Create;
  sl.Add('{');
  sl.Add('  "document": "' + JsonEscape(Board.FileName) + '",');
  sl.Add('  "tracks": [');

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  // TOP/BOTTOM schon HIER ausschliessen (nicht erst je Track pruefen): der
  // Iterator liefert diese Layer dann gar nicht mehr - spart bei mehrlagigen
  // Boards die meiste Arbeit. AllLayers ist eine Menge, minus die zwei
  // Aussenlagen. Der Check unten in der Schleife bleibt als Sicherheitsnetz,
  // falls die Mengendifferenz auf einer Altium-Version nicht greifen sollte.
  Iter.AddFilter_LayerSet(AllLayers - MkSet(eTopLayer, eBottomLayer));
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
        'Lese Innenlagen-Tracks ... bitte warten.' + #13#10#13#10 +
        'Durchlaufen (TOP/BOTTOM schon am Iterator raus): ' + IntToStr(iterated) +
        #13#10 + 'Exportiert (mit Net): ' + IntToStr(id);
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
      TrackAppend(Trk);        // Index = id
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

  BuiltForBoard := Board;   // TrackArr gehoert zu diesem Board (fuer ApplyFixes)

  if id > MAX_TRACKS then
    ShowMessage('Achtung: ' + IntToStr(id) + ' Tracks - mehr als die Kapazitaet ' +
      IntToStr(MAX_TRACKS) + '. Fixes an Tracks mit Index >= ' + IntToStr(MAX_TRACKS) +
      ' koennen nicht angewendet werden. Bitte melden, dann wird die Grenze erhoeht.');

  RunApplyLoop(
    'Export fertig: ' + IntToStr(id) + ' Tracks (mit Net, ohne TOP/BOTTOM). ' +
    'TOP/BOTTOM schon am Iterator ausgeschlossen (Sicherheitsnetz fing ' +
    IntToStr(skippedLayer) + '), ohne Net ' + IntToStr(netless) + '.' +
    #13#10#13#10 +
    'Der Browser-Report sollte offen sein (sonst start_watcher.bat starten). ' +
    'Jetzt die Fehler im Browser anklicken, dann hier "Aenderungen uebernehmen".');
end;


{------------------------------------------------------------------------------}
{ OPTIONALER FALLBACK - wird im Normalbetrieb NICHT mehr aufgerufen.             }
{ ApplyFixes braucht die Zuordnung nicht mehr neu aufzubauen (DoApply findet     }
{ Tracks raeumlich ueber die Ursprungslage). Diese Funktion bleibt nur als       }
{ Notnagel: Sollte die raeumliche Suche auf einer Altium-Version einmal nicht    }
{ greifen, kann man sie hier wieder in ApplyFixes einhaengen. Sie iteriert das   }
{ GANZE Board mit demselben Filter/derselben Reihenfolge wie der Export.         }
{ Rueckgabe: True bei Erfolg.                                                   }
{------------------------------------------------------------------------------}
function RebuildTrackList(Dummy : Integer) : Boolean;
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

  TrackReset(0);
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  // TOP/BOTTOM schon HIER ausschliessen (nicht erst je Track pruefen): der
  // Iterator liefert diese Layer dann gar nicht mehr - spart bei mehrlagigen
  // Boards die meiste Arbeit. AllLayers ist eine Menge, minus die zwei
  // Aussenlagen. Der Check unten in der Schleife bleibt als Sicherheitsnetz,
  // falls die Mengendifferenz auf einer Altium-Version nicht greifen sollte.
  Iter.AddFilter_LayerSet(AllLayers - MkSet(eTopLayer, eBottomLayer));
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
        'Zugeordnet: ' + IntToStr(TrackCount);
      try Application.ProcessMessages; except end;
    end;

    // Gleicher Filter wie beim Export: TOP/BOTTOM raus, nur Tracks mit Net.
    if (Trk.Layer <> eTopLayer) and (Trk.Layer <> eBottomLayer) and
       (Trk.Net <> nil) then
      TrackAppend(Trk);

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
  Board := GetBoard(0);
  if Board = nil then Exit;
  if not CheckWorkDir(0) then Exit;
  WorkDir  := VCWorkDir(0);
  JsonPath := WorkDir + '\tracks.json';
  CmdPath  := WorkDir + '\bridge_cmd.txt';
  AckPath  := WorkDir + '\bridge_ack.txt';
  JumpPath := WorkDir + '\bridge_jump.txt';

  // KEIN Neu-Iterieren mehr: Liegt die Zuordnung noch im Speicher (gleiches
  // Board, z.B. nach "Fertig" in derselben Sitzung), nutzt DoApply sie als
  // schnelle Abkuerzung. Ist sie weg (z.B. nach Altium-Neustart), findet
  // DoApply die Tracks per raeumlicher Suche ueber die vom Server gelieferte
  // Ursprungslage. In BEIDEN Faellen ist das Menue SOFORT da - der frueher
  // noetige, minutenlange Neu-Aufbau (RebuildTrackList) entfaellt.
  RunApplyLoop(
    'Menue erneut geoeffnet (kein neuer Export, kein Neu-Einlesen). Im Browser ' +
    'die Fehler anklicken, dann "Aenderungen uebernehmen" - oder "Fertig".');
end;

end.
