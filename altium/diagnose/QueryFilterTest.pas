{..............................................................................}
{  Verbindungs-Check - DIAGNOSE: Query-Vorfilter testen                        }
{                                                                              }
{  Frage: Kann man Tracks OHNE Net direkt "vorfiltern" (wie im PCB-Filter-Panel }
{  mit  (ObjectKind = 'Track') And Not (Net = 'No Net') ), statt sie einzeln in }
{  der Schleife per  Trk.Net = nil  auszusortieren?                             }
{                                                                              }
{  Der Board-Iterator selbst KANN das nicht (er kennt nur Objekt-/Layer-Filter, }
{  kein Net-Filter). Aber die native Query-Engine laesst sich evtl. ueber einen  }
{  Prozess anstossen. Dieses Skript testet genau das und vergleicht die Zahlen   }
{  mit der bisherigen Voll-Iteration.                                           }
{                                                                              }
{  NICHT Teil des Normalbetriebs. Nur zum Testen/Benchmarken auf dem Branch.     }
{                                                                              }
{  Bedienung:                                                                   }
{    DXP -> Run Script... -> Browse -> diese Datei -> TestQueryFilter -> OK.     }
{                                                                              }
{  ACHTUNG: hebt deine aktuelle Auswahl im PCB auf (waehlt per Query neu und     }
{  deselektiert am Ende alles). Sonst wird nichts am Board veraendert.           }
{                                                                              }
{  Moegliche Ergebnisse:                                                        }
{   - "Undeclared identifier: RunProcess" (oder ResetParameters/Now) beim        }
{     Start  -> diese DelphiScript-Umgebung kennt den Query-Aufruf nicht.        }
{     Damit ist die Antwort: geht hier NICHT, bleibt beim Pruefen pro Primitive. }
{   - RunProcess laeuft, aber Selected-Zahl = 0  -> Prozess/Parameter greifen    }
{     anders (bitte Zahlen melden, dann passe ich die Parameter an).            }
{   - Selected-Zahl == "mit Net"  -> funktioniert! Dann lohnt der Umbau.         }
{..............................................................................}

const
  SAFELIMIT = 2000000;   // Not-Aus gegen eine nicht endende Iteration

{ Sekunden zwischen zwei Now-Zeitstempeln (TDateTime ist in Tagen). }
function SecsBetween(a, b : TDateTime) : Double;
begin
  Result := (b - a) * 86400.0;
end;


procedure TestQueryFilter;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Trk   : IPCB_Track;
  tTotal, tNet, tNetInner, iterated : Integer;
  selCount, selTracks : Integer;
  t0, t1, t2, t3 : TDateTime;
  refSecs, qrySecs : Double;
  queryOk : Boolean;
  msg : String;
begin
  if PCBServer = nil then begin ShowMessage('PCBServer = nil (kein PCB-Editor aktiv).'); Exit; end;
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = nil then begin ShowMessage('Board = nil (kein PcbDoc im Vordergrund).'); Exit; end;

  { ------------------------------------------------------------------ }
  { 1) Referenz: Voll-Iteration (so wie der Export es heute macht).      }
  { ------------------------------------------------------------------ }
  tTotal := 0; tNet := 0; tNetInner := 0; iterated := 0;
  t0 := Now;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);
  Trk := Iter.FirstPCBObject;
  while Trk <> nil do
  begin
    iterated := iterated + 1;
    if iterated >= SAFELIMIT then Break;
    tTotal := tTotal + 1;
    if Trk.Net <> nil then
    begin
      tNet := tNet + 1;
      if (Trk.Layer <> eTopLayer) and (Trk.Layer <> eBottomLayer) then
        tNetInner := tNetInner + 1;
    end;
    Trk := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
  t1 := Now;
  refSecs := SecsBetween(t0, t1);

  { ------------------------------------------------------------------ }
  { 2) Query-Vorfilter: native Engine selektiert Tracks MIT Net.        }
  {    Parameter einzeln setzen (nicht "A=x|B=y"), weil der Ausdruck     }
  {    selbst '=' enthaelt und eine Pipe-Liste daran zerbrechen wuerde.  }
  { ------------------------------------------------------------------ }
  queryOk := False;
  selCount := -1;
  selTracks := -1;
  qrySecs := 0.0;
  t2 := Now;
  try
    ResetParameters;
    AddStringParameter('Apply', 'True');
    AddStringParameter('Expr', '(ObjectKind = ''Track'') And Not (Net = ''No Net'')');
    AddStringParameter('Index', '1');
    AddStringParameter('Zoom', 'False');
    AddStringParameter('Select', 'True');
    AddStringParameter('Mask', 'False');
    AddStringParameter('ClearExisting', 'True');
    RunProcess('PCB:RunQuery');
    queryOk := True;
  except
    queryOk := False;
  end;
  t3 := Now;
  qrySecs := SecsBetween(t2, t3);

  if queryOk then
  begin
    { a) direkte Anzahl der selektierten Objekte (API-Name mit Tippfehler!) }
    try selCount := Board.SelectecObjectCount; except selCount := -1; end;

    { b) Kreuzcheck: nochmal ueber ALLE Tracks, Selected zaehlen.           }
    selTracks := 0;
    iterated := 0;
    Iter := Board.BoardIterator_Create;
    Iter.AddFilter_ObjectSet(MkSet(eTrackObject));
    Iter.AddFilter_LayerSet(AllLayers);
    Iter.AddFilter_Method(eProcessAll);
    Trk := Iter.FirstPCBObject;
    while Trk <> nil do
    begin
      iterated := iterated + 1;
      if iterated >= SAFELIMIT then Break;
      if Trk.Selected then selTracks := selTracks + 1;
      Trk := Iter.NextPCBObject;
    end;
    Board.BoardIterator_Destroy(Iter);
  end;

  { Auswahl wieder aufheben, damit wir den Board-Zustand nicht veraendern. }
  try
    ResetParameters;
    AddStringParameter('Scope', 'All');
    RunProcess('PCB:DeSelect');
  except
    { egal - nur Aufraeumen }
  end;

  { ------------------------------------------------------------------ }
  { 3) Ergebnis anzeigen.                                               }
  { ------------------------------------------------------------------ }
  msg :=
    'REFERENZ (Voll-Iteration, wie heute):' + #13#10 +
    '  Tracks gesamt:              ' + IntToStr(tTotal) + #13#10 +
    '  davon MIT Net:              ' + IntToStr(tNet) + #13#10 +
    '  MIT Net & ohne TOP/BOTTOM:  ' + IntToStr(tNetInner) + #13#10 +
    '  Dauer: ' + FloatToStr(refSecs) + ' s' + #13#10 + #13#10;

  if queryOk then
    msg := msg +
      'QUERY-VORFILTER  (ObjectKind=Track) And Not (Net=No Net):' + #13#10 +
      '  RunProcess: OK' + #13#10 +
      '  SelectecObjectCount:        ' + IntToStr(selCount) + #13#10 +
      '  Selected-Tracks (Kreuzchk): ' + IntToStr(selTracks) + #13#10 +
      '  Dauer Query-Aufruf: ' + FloatToStr(qrySecs) + ' s' + #13#10 + #13#10 +
      'VERGLEICH: "MIT Net" (' + IntToStr(tNet) + ') sollte zu ' +
      'SelectecObjectCount und Selected-Tracks passen.' + #13#10 +
      'Passt es -> Vorfilter funktioniert. Ist Selected 0 -> Parameter melden.'
  else
    msg := msg +
      'QUERY-VORFILTER: RunProcess(''PCB:RunQuery'') hat eine Ausnahme ' +
      'geworfen. Der Query-Aufruf ist in dieser DelphiScript-Umgebung ' +
      'wohl nicht verfuegbar - dann bleibt es beim Pruefen pro Primitive ' +
      '(Trk.Net = nil in der Schleife).';

  ShowMessage(msg);
end;


{..............................................................................}
{  V2: WELCHER Aufruf legt Objekte wirklich in Board.SelectecObject?            }
{                                                                              }
{  Der erste Test zeigte: RunProcess laeuft, aber PCB:RunQuery mit Select=True  }
{  selektiert 0 (maskiert vermutlich nur). Diese Prozedur probiert in EINEM     }
{  Lauf mehrere Selektier-Varianten durch und zeigt je Variante die            }
{  SelectecObjectCount. Keine 66-s-Voll-Iteration - laeuft schnell.            }
{                                                                              }
{  Baseline (PCB:Select Scope=All) MUSS eine grosse Zahl (~alle Objekte)        }
{  liefern. Tut sie das nicht, zaehlt SelectecObjectCount generell nicht - dann }
{  ist Selektion der falsche Weg. Liefert die Baseline viel, eine Query-Variante }
{  aber die ~132820 (Tracks mit Net) -> DAS ist der richtige Aufruf.            }
{                                                                              }
{  Bitte die Zahlen aller Zeilen melden.                                        }
{..............................................................................}

function SelCntOf(B : IPCB_Board) : Integer;
begin
  Result := -1;
  try Result := B.SelectecObjectCount; except Result := -1; end;
end;

procedure DeselAll(Dummy : Integer);
begin
  try
    ResetParameters;
    AddStringParameter('Scope', 'All');
    RunProcess('PCB:DeSelect');
  except
  end;
end;

procedure TestQuerySelectVariants;
var
  Board : IPCB_Board;
  cAll, c1, c2, c3, c4 : Integer;
  q : String;
  msg : String;
begin
  if PCBServer = nil then begin ShowMessage('PCBServer = nil'); Exit; end;
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = nil then begin ShowMessage('Board = nil'); Exit; end;

  q := '(ObjectKind = ''Track'') And Not (Net = ''No Net'')';

  { --- Baseline: alles selektieren (zeigt, ob SelectecObjectCount zaehlt) --- }
  DeselAll(0);
  try
    ResetParameters;
    AddStringParameter('Scope', 'All');
    RunProcess('PCB:Select');
  except end;
  cAll := SelCntOf(Board);

  { --- V1: RunQuery mit Select=True UND Mask=True --- }
  DeselAll(0);
  try
    ResetParameters;
    AddStringParameter('Apply', 'True');
    AddStringParameter('Expr', q);
    AddStringParameter('Mask', 'True');
    AddStringParameter('Select', 'True');
    AddStringParameter('ClearExisting', 'True');
    RunProcess('PCB:RunQuery');
  except end;
  c1 := SelCntOf(Board);

  { --- V2: erst RunQuery-Maske, dann PCB:Select ueber die Maske --- }
  DeselAll(0);
  try
    ResetParameters;
    AddStringParameter('Apply', 'True');
    AddStringParameter('Expr', q);
    AddStringParameter('Mask', 'True');
    AddStringParameter('ClearExisting', 'True');
    RunProcess('PCB:RunQuery');
    ResetParameters;
    AddStringParameter('Scope', 'Filter');   // ggf. gefilterte/maskierte waehlen
    RunProcess('PCB:Select');
  except end;
  c2 := SelCntOf(Board);

  { --- V3: Prozess PCB:Filter statt PCB:RunQuery --- }
  DeselAll(0);
  try
    ResetParameters;
    AddStringParameter('Apply', 'True');
    AddStringParameter('Expr', q);
    AddStringParameter('Mask', 'True');
    AddStringParameter('Select', 'True');
    RunProcess('PCB:Filter');
  except end;
  c3 := SelCntOf(Board);

  { --- V4: RunQuery, Objekt-Highlight-Methode -> Select --- }
  DeselAll(0);
  try
    ResetParameters;
    AddStringParameter('Apply', 'True');
    AddStringParameter('Expr', q);
    AddStringParameter('Select', 'True');
    AddStringParameter('Mask', 'False');
    AddStringParameter('Zoom', 'False');
    AddStringParameter('Index', '1');
    AddStringParameter('ClearExisting', 'True');
    AddStringParameter('Highlight', 'True');
    RunProcess('PCB:RunQuery');
  except end;
  c4 := SelCntOf(Board);

  DeselAll(0);   { Aufraeumen }

  msg :=
    'Ziel: eine Variante soll ~132820 (Tracks mit Net) liefern.' + #13#10 +
    '(Baseline soll ~alle Objekte, also gross, liefern.)' + #13#10 + #13#10 +
    'Baseline PCB:Select Scope=All:            ' + IntToStr(cAll) + #13#10 +
    'V1 RunQuery Select+Mask:                  ' + IntToStr(c1) + #13#10 +
    'V2 RunQuery Maske + PCB:Select Scope=Filter: ' + IntToStr(c2) + #13#10 +
    'V3 PCB:Filter Select+Mask:                ' + IntToStr(c3) + #13#10 +
    'V4 RunQuery Select+Highlight:             ' + IntToStr(c4) + #13#10 + #13#10 +
    'Bitte alle Zahlen melden. -1 = SelectecObjectCount hat geworfen.';
  ShowMessage(msg);
end;
