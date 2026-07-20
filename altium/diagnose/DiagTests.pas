{..............................................................................}
{  Verbindungs-Check - DIAGNOSE-Testskripte                                    }
{                                                                              }
{  Zweck: den Freeze eingrenzen. Jede Prozedur testet GENAU EINEN Abschnitt    }
{  des Workflows und zeigt am Ende eine ShowMessage. Friert eine Prozedur ein, }
{  liegt das Problem in genau diesem Abschnitt.                                 }
{                                                                              }
{  Bedienung:                                                                   }
{    DXP -> Run Script... -> diese Datei -> Prozedur aus der Liste waehlen.     }
{    Der Reihe nach ausfuehren: VC_T1_Hello, VC_T2_Board, VC_T3_Input,          }
{    VC_T4_CountTracks, VC_T5_FirstTrackProps, VC_T6_WriteFile,                 }
{    VC_T7_ExportCapped.                                                        }
{                                                                              }
{  Bitte melden: bei WELCHER Prozedur es einfriert bzw. welche Meldung kommt.   }
{  Alle Iterationen haben eine Sicherheitsgrenze (SAFELIMIT) - friert selbst    }
{  VC_T4 ein, ist der Iterator die Ursache; kommt "... (Grenze erreicht)",      }
{  liefert der Iterator kein Ende (Endlosschleife).                            }
{..............................................................................}

const
  SAFELIMIT = 200000;                   // Not-Aus fuer Schleifen

// Fester Arbeitsordner - bewusst als Funktion, nicht als String-const: eine
// String-Konstante ist in DelphiScript ein OleStr, und '+' mit einem Literal
// wirft dann "OleStr into Double". Eine Funktion liefert einen sauberen String.
function VCWorkDir : String;
begin
  Result := 'C:\altium-track-fixer';
end;


{ --- T1: Laeuft ueberhaupt ein Skript? ------------------------------------- }
procedure VC_T1_Hello;
begin
  ShowMessage('T1 ok - Skripte laufen in dieser Altium-Version.');
end;


{ --- T2: PCB-Board erreichbar? --------------------------------------------- }
procedure VC_T2_Board;
var
  Board : IPCB_Board;
begin
  if PCBServer = nil then
  begin
    ShowMessage('T2: PCBServer = nil (kein PCB-Editor aktiv).');
    Exit;
  end;
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = nil then
  begin
    ShowMessage('T2: Board = nil (kein PcbDoc im Vordergrund).');
    Exit;
  end;
  ShowMessage('T2 ok - Board: ' + Board.FileName);
end;


{ --- T3: InputBox + Rueckgabe ---------------------------------------------- }
procedure VC_T3_Input;
var
  s : String;
begin
  s := InputBox('T3', 'Irgendetwas eingeben und OK druecken:', 'test');
  ShowMessage('T3 ok - eingegeben: "' + s + '"');
end;


{ --- T4: Tracks NUR zaehlen (testet, ob die Iteration terminiert) ---------- }
procedure VC_T4_CountTracks;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Trk   : IPCB_Track;
  n     : Integer;
  hitLimit : Boolean;
begin
  if PCBServer = nil then begin ShowMessage('T4: PCBServer = nil'); Exit; end;
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = nil then begin ShowMessage('T4: Board = nil'); Exit; end;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  n := 0;
  hitLimit := False;
  Trk := Iter.FirstPCBObject;
  while Trk <> nil do
  begin
    n := n + 1;
    if n >= SAFELIMIT then begin hitLimit := True; Break; end;
    Trk := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  if hitLimit then
    ShowMessage('T4: Iterator liefert KEIN Ende - Endlosschleife! ' +
                '(Grenze ' + IntToStr(SAFELIMIT) + ' erreicht)')
  else
    ShowMessage('T4 ok - Tracks gezaehlt: ' + IntToStr(n));
end;


{ --- T5: Eigenschaften des ERSTEN Tracks lesen (Layer/Net/Koordinaten) ----- }
procedure VC_T5_FirstTrackProps;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Trk   : IPCB_Track;
  s     : String;
begin
  if PCBServer = nil then begin ShowMessage('T5: PCBServer = nil'); Exit; end;
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = nil then begin ShowMessage('T5: Board = nil'); Exit; end;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);
  Trk := Iter.FirstPCBObject;

  if Trk = nil then
  begin
    Board.BoardIterator_Destroy(Iter);
    ShowMessage('T5: keine Tracks auf dem Board.');
    Exit;
  end;

  s := 'Layer = ' + Board.LayerName(Trk.Layer);
  if Trk.Net <> nil then s := s + #13#10 + 'Net = ' + Trk.Net.Name
  else                   s := s + #13#10 + 'Net = (keins)';
  s := s + #13#10 + 'X1(mm) = ' + FloatToStr(CoordToMMs(Trk.X1 - Board.XOrigin));
  s := s + #13#10 + 'Y1(mm) = ' + FloatToStr(CoordToMMs(Trk.Y1 - Board.YOrigin));
  s := s + #13#10 + 'Width(mm) = ' + FloatToStr(CoordToMMs(Trk.Width));

  Board.BoardIterator_Destroy(Iter);
  ShowMessage('T5 ok - erster Track:' + #13#10 + s);
end;


{ --- T6: Datei in den Ordner schreiben (inkl. RenameFile wie im Export) ---- }
procedure VC_T6_WriteFile;
var
  dir : String;
  sl  : TStringList;
  target : String;
begin
  dir := VCWorkDir;
  target := dir + '\vc_test.txt';
  sl := TStringList.Create;
  sl.Add('Verbindungs-Check Test');
  sl.Add('Zeile 2');
  // gleicher atomarer Weg wie im echten Export:
  sl.SaveToFile(target + '.tmp');
  sl.Free;
  if FileExists(target) then DeleteFile(target);
  RenameFile(target + '.tmp', target);

  if FileExists(target) then
    ShowMessage('T6 ok - geschrieben: ' + target)
  else
    ShowMessage('T6: Datei wurde NICHT angelegt: ' + target);
end;


{ --- T7: Echter Export, aber gedeckelt auf die ersten 25 Tracks ------------ }
{ Baut denselben JSON-String wie RunVerbindungsCheck, nur begrenzt, und        }
{ schreibt ihn als tracks_test.json. Testet den kompletten Export-Pfad.        }
procedure VC_T7_ExportCapped;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Trk   : IPCB_Track;
  sl    : TStringList;
  dir, target, netName, layName, line : String;
  x1, y1, x2, y2, wd : Double;
  first : Boolean;
  id, cap : Integer;
begin
  if PCBServer = nil then begin ShowMessage('T7: PCBServer = nil'); Exit; end;
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = nil then begin ShowMessage('T7: Board = nil'); Exit; end;

  dir := VCWorkDir;
  target := dir + '\tracks_test.json';

  sl := TStringList.Create;
  sl.Add('{');
  sl.Add('  "document": "test",');
  sl.Add('  "tracks": [');

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  first := True;
  id := 0;
  cap := 25;
  Trk := Iter.FirstPCBObject;
  while (Trk <> nil) and (id < cap) do
  begin
    if Trk.Net <> nil then netName := Trk.Net.Name else netName := '';
    layName := Board.LayerName(Trk.Layer);

    x1 := CoordToMMs(Trk.X1 - Board.XOrigin);
    y1 := CoordToMMs(Trk.Y1 - Board.YOrigin);
    x2 := CoordToMMs(Trk.X2 - Board.XOrigin);
    y2 := CoordToMMs(Trk.Y2 - Board.YOrigin);
    wd := CoordToMMs(Trk.Width);

    line := '    {"id": ' + IntToStr(id) +
            ', "layer": "' + layName + '"' +
            ', "net": "' + netName + '"' +
            ', "x1": ' + FloatToStr(x1) +
            ', "y1": ' + FloatToStr(y1) +
            ', "x2": ' + FloatToStr(x2) +
            ', "y2": ' + FloatToStr(y2) +
            ', "width": ' + FloatToStr(wd) + '}';
    if not first then
      sl[sl.Count - 1] := sl[sl.Count - 1] + ',';
    sl.Add(line);
    first := False;

    id := id + 1;
    Trk := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  sl.Add('  ]');
  sl.Add('}');
  sl.SaveToFile(target);
  sl.Free;

  ShowMessage('T7 ok - ' + IntToStr(id) + ' Tracks nach tracks_test.json ' +
              'geschrieben (max. ' + IntToStr(cap) + ').');
end;


{ --- T8: Net-Situation pruefen (warum sind die Nets leer?) ------------------ }
{ Zaehlt in den ersten 20000 Tracks, wie viele ein Net / einen Net-Namen haben, }
{ und zeigt ein paar Beispiele. So sehen wir, ob die Fuellprimitive-Theorie     }
{ stimmt (viele ohne Net) oder ob der Net-Zugriff generell nicht liefert.       }
procedure VC_T8_NetCheck;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Trk   : IPCB_Track;
  n, withNet, withName, shown : Integer;
  samples : String;
begin
  if PCBServer = nil then begin ShowMessage('T8: PCBServer = nil'); Exit; end;
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = nil then begin ShowMessage('T8: Board = nil'); Exit; end;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  n := 0; withNet := 0; withName := 0; shown := 0; samples := '';
  Trk := Iter.FirstPCBObject;
  while (Trk <> nil) and (n < 20000) do
  begin
    n := n + 1;
    if Trk.Net <> nil then
    begin
      withNet := withNet + 1;
      if Trk.Net.Name <> '' then withName := withName + 1;
      if shown < 8 then
      begin
        samples := samples + #13#10 + '  Layer=' + Board.LayerName(Trk.Layer) +
                   '  Net="' + Trk.Net.Name + '"';
        shown := shown + 1;
      end;
    end;
    Trk := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  ShowMessage('T8 - von ' + IntToStr(n) + ' Tracks:' + #13#10 +
    '  mit Net-Objekt: ' + IntToStr(withNet) + #13#10 +
    '  mit Net-Namen:  ' + IntToStr(withName) + #13#10#13#10 +
    'Beispiele (mit Net):' + samples);
end;
