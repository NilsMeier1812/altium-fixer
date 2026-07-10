{..............................................................................}
{  Verbindungs-Check - Altium-Integration (DelphiScript)                       }
{                                                                              }
{  Exportiert alle Tracks des aktiven PCB-Dokuments, startet den Python-       }
{  Server (check_server.py) und wendet die im HTML angeklickten Fixes LIVE     }
{  auf das Board an.                                                           }
{                                                                              }
{  Bedienung in Altium:                                                        }
{    DXP -> Run Script ... -> dieses Skript -> Prozedur "RunVerbindungsCheck"  }
{  (oder das Skript in ein Skript-Projekt einbinden und ausfuehren)            }
{                                                                              }
{  Voraussetzung: Python installiert, dieses Repo-Verzeichnis bekannt          }
{  (enthaelt check_server.py + Ordner verbindungs_check).                      }
{..............................................................................}

var
  Board      : IPCB_Board;
  TrackArr   : array of IPCB_Track;   // Index = exportierte Track-ID
  TrackCount : Integer;
  PollTimer  : TTimer;
  MainForm   : TForm;
  StatusLbl  : TLabel;
  PyEdit     : TEdit;
  RepoEdit   : TEdit;
  PortEdit   : TEdit;
  StartBtn   : TButton;
  StopBtn    : TButton;
  BaseUrl    : String;
  JsonPath   : String;
  PortPath   : String;
  Polling    : Boolean;


{------------------------------------------------------------------------------}
{ Kleine Helfer                                                                }
{------------------------------------------------------------------------------}
function TempFolder : String;
var
  t : String;
begin
  t := GetEnvironmentVariable('TEMP');
  if t = '' then t := GetEnvironmentVariable('TMP');
  if t = '' then t := 'C:\Temp';
  Result := t + '\verbindungs_check';
  if not DirectoryExists(Result) then
    CreateDir(Result);
end;

function JsonEscape(const s : String) : String;
begin
  Result := StringReplace(s, '\', '\\', MkSet(rfReplaceAll));
  Result := StringReplace(Result, '"', '\"', MkSet(rfReplaceAll));
end;

// HTTP GET ueber MSXML. Liefert responseText, oder '' bei Fehler.
function HttpGet(const url : String) : String;
var
  http : OleVariant;
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

procedure SetStatus(const s : String);
begin
  if StatusLbl <> nil then
    StatusLbl.Caption := s;
  Application.ProcessMessages;
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
begin
  Result := False;
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = nil then
  begin
    ShowMessage('Kein PCB-Dokument aktiv. Bitte ein .PcbDoc oeffnen.');
    Exit;
  end;

  SetLength(TrackArr, 0);
  TrackCount := 0;

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
    // Track-Referenz merken; Index = ID
    SetLength(TrackArr, TrackCount + 1);
    TrackArr[TrackCount] := Trk;

    if Trk.Net <> nil then netName := Trk.Net.Name else netName := '';
    layName := Board.LayerName(Trk.Layer);

    // Koordinaten in mm relativ zum Board-Origin (wie im Excel-Export)
    x1 := CoordToMMs(Trk.X1 - Board.XOrigin);
    y1 := CoordToMMs(Trk.Y1 - Board.YOrigin);
    x2 := CoordToMMs(Trk.X2 - Board.XOrigin);
    y2 := CoordToMMs(Trk.Y2 - Board.YOrigin);
    wd := CoordToMMs(Trk.Width);

    line := '    {"id": ' + IntToStr(TrackCount) +
            ', "layer": "' + JsonEscape(layName) + '"' +
            ', "net": "' + JsonEscape(netName) + '"' +
            ', "x1": ' + FloatToStr(x1) +
            ', "y1": ' + FloatToStr(y1) +
            ', "x2": ' + FloatToStr(x2) +
            ', "y2": ' + FloatToStr(y2) +
            ', "width": ' + FloatToStr(wd) + '}';
    if not first then
      sl[sl.Count - 1] := sl[sl.Count - 1] + ',';
    sl.Add(line);
    first := False;

    Inc(TrackCount);
    Trk := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  sl.Add('  ]');
  sl.Add('}');

  JsonPath := TempFolder + '\tracks.json';
  PortPath := JsonPath + '.port';
  // altes Port-File entfernen, damit wir auf das neue warten koennen
  if FileExists(PortPath) then
    DeleteFile(PortPath);
  sl.SaveToFile(JsonPath);
  sl.Free;

  SetStatus('Export: ' + IntToStr(TrackCount) + ' Tracks -> ' + JsonPath);
  Result := TrackCount > 0;
end;


{------------------------------------------------------------------------------}
{ Python-Server starten und auf Port-File warten                               }
{------------------------------------------------------------------------------}
function StartServer : Boolean;
var
  Wsh     : OleVariant;
  cmd     : String;
  py, repo, srv : String;
  wishPort : String;
  sl      : TStringList;
  tries   : Integer;
begin
  Result := False;
  py   := Trim(PyEdit.Text);
  repo := Trim(RepoEdit.Text);
  if py = '' then py := 'python';
  if repo = '' then
  begin
    ShowMessage('Bitte den Skript-Ordner angeben (enthaelt check_server.py).');
    Exit;
  end;
  // abschliessenden Backslash entfernen
  if Copy(repo, Length(repo), 1) = '\' then
    repo := Copy(repo, 1, Length(repo) - 1);
  srv := repo + '\check_server.py';
  if not FileExists(srv) then
  begin
    ShowMessage('check_server.py nicht gefunden unter:'#13#10 + srv);
    Exit;
  end;

  wishPort := Trim(PortEdit.Text);
  if wishPort = '' then wishPort := '8765';

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
  SetStatus('Starte Server, warte auf Bereitschaft ...');
  tries := 0;
  while (not FileExists(PortPath)) and (tries < 40) do
  begin
    Sleep(250);
    Application.ProcessMessages;
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

  // kurz auf /ping warten
  tries := 0;
  while (HttpGet(BaseUrl + '/ping') <> 'pong') and (tries < 20) do
  begin
    Sleep(200);
    Application.ProcessMessages;
    Inc(tries);
  end;

  SetStatus('Server bereit: ' + BaseUrl + '  (Polling laeuft)');
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
  if (tid < 0) or (tid >= TrackCount) then Exit;
  Trk := TrackArr[tid];
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
{ Timer: /pending abfragen, Fixes anwenden, /ack senden                        }
{------------------------------------------------------------------------------}
procedure OnPoll(Sender : TObject);
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

  procedure FlushAck;
  begin
    if curFid <> '' then
    begin
      if curOk then
        HttpGet(BaseUrl + '/ack?fix_id=' + curFid + '&ok=1')
      else
        HttpGet(BaseUrl + '/ack?fix_id=' + curFid + '&ok=0');
    end;
  end;

begin
  if not Polling then Exit;
  if BaseUrl = '' then Exit;

  resp := HttpGet(BaseUrl + '/pending');
  if resp = '' then Exit;   // nichts zu tun oder Server kurz nicht erreichbar

  // Aktuelles Board pruefen: Fixes nur anwenden, wenn dasselbe Dokument aktiv.
  if PCBServer.GetCurrentPCBBoard <> Board then
  begin
    SetStatus('Anderes Dokument aktiv - Fixes pausiert. Urspruengliches ' +
              'PcbDoc wieder aktivieren.');
    Exit;
  end;

  lines := TStringList.Create;
  lines.Text := resp;
  parts := TStringList.Create;
  parts.Delimiter := ';';
  parts.StrictDelimiter := True;

  curFid := '';
  curOk  := True;
  anyApplied := False;

  for i := 0 to lines.Count - 1 do
  begin
    if Trim(lines[i]) = '' then Continue;
    parts.DelimitedText := lines[i];
    if parts.Count < 5 then Continue;

    fid   := parts[0];
    tid   := StrToIntDef(parts[1], -1);
    endNo := StrToIntDef(parts[2], 0);
    xmm   := StrToFloatDef(parts[3], 0);
    ymm   := StrToFloatDef(parts[4], 0);

    // Fix-Wechsel -> vorherigen bestaetigen
    if (curFid <> '') and (fid <> curFid) then
    begin
      FlushAck;
      curOk := True;
    end;
    curFid := fid;

    if not ApplyMove(tid, endNo, xmm, ymm) then
      curOk := False
    else
      anyApplied := True;
  end;
  FlushAck;

  parts.Free;
  lines.Free;

  if anyApplied then
  begin
    Board.ViewManager_FullUpdate;
    SetStatus('Fix angewendet. ' + FormatDateTime('hh:nn:ss', Now));
  end;
end;


{------------------------------------------------------------------------------}
{ Buttons                                                                      }
{------------------------------------------------------------------------------}
procedure OnStartClick(Sender : TObject);
begin
  Polling := False;
  if not ExportBoard then Exit;
  if not StartServer then Exit;
  Polling := True;
  PollTimer.Enabled := True;
  StopBtn.Enabled := True;
end;

procedure OnStopClick(Sender : TObject);
begin
  Polling := False;
  PollTimer.Enabled := False;
  StopBtn.Enabled := False;
  SetStatus('Polling gestoppt. Server-Fenster kann geschlossen werden.');
end;


{------------------------------------------------------------------------------}
{ Form aufbauen (kein .dfm noetig)                                             }
{------------------------------------------------------------------------------}
procedure RunVerbindungsCheck;
var
  y : Integer;
  l : TLabel;
begin
  Polling := False;
  BaseUrl := '';

  MainForm := TForm.Create(nil);
  MainForm.Caption := 'Verbindungs-Check (Altium-Live)';
  MainForm.Width := 560;
  MainForm.Height := 300;
  MainForm.Position := poScreenCenter;
  MainForm.BorderStyle := bsDialog;

  y := 16;

  l := TLabel.Create(MainForm); l.Parent := MainForm;
  l.Left := 16; l.Top := y; l.Caption := 'Python-Programm (Exe oder "python"):';
  PyEdit := TEdit.Create(MainForm); PyEdit.Parent := MainForm;
  PyEdit.Left := 260; PyEdit.Top := y - 3; PyEdit.Width := 270;
  PyEdit.Text := 'python';
  y := y + 32;

  l := TLabel.Create(MainForm); l.Parent := MainForm;
  l.Left := 16; l.Top := y; l.Caption := 'Skript-Ordner (mit check_server.py):';
  RepoEdit := TEdit.Create(MainForm); RepoEdit.Parent := MainForm;
  RepoEdit.Left := 260; RepoEdit.Top := y - 3; RepoEdit.Width := 270;
  RepoEdit.Text := 'C:\Pfad\zu\altium-fixer';
  y := y + 32;

  l := TLabel.Create(MainForm); l.Parent := MainForm;
  l.Left := 16; l.Top := y; l.Caption := 'Port (Wunsch, wird ggf. hochgezaehlt):';
  PortEdit := TEdit.Create(MainForm); PortEdit.Parent := MainForm;
  PortEdit.Left := 260; PortEdit.Top := y - 3; PortEdit.Width := 80;
  PortEdit.Text := '8765';
  y := y + 40;

  StartBtn := TButton.Create(MainForm); StartBtn.Parent := MainForm;
  StartBtn.Left := 16; StartBtn.Top := y; StartBtn.Width := 250; StartBtn.Height := 30;
  StartBtn.Caption := 'Board exportieren + Server starten';
  StartBtn.OnClick := OnStartClick;

  StopBtn := TButton.Create(MainForm); StopBtn.Parent := MainForm;
  StopBtn.Left := 280; StopBtn.Top := y; StopBtn.Width := 250; StopBtn.Height := 30;
  StopBtn.Caption := 'Polling stoppen';
  StopBtn.OnClick := OnStopClick;
  StopBtn.Enabled := False;
  y := y + 44;

  StatusLbl := TLabel.Create(MainForm); StatusLbl.Parent := MainForm;
  StatusLbl.Left := 16; StatusLbl.Top := y; StatusLbl.Width := 520;
  StatusLbl.AutoSize := False; StatusLbl.WordWrap := True; StatusLbl.Height := 60;
  StatusLbl.Caption := 'Bereit. Pfade pruefen, dann "Board exportieren + Server ' +
                       'starten". Danach im Browser Fixe anklicken - sie werden ' +
                       'live ins Board uebernommen.';

  PollTimer := TTimer.Create(MainForm);
  PollTimer.Interval := 500;
  PollTimer.Enabled := False;
  PollTimer.OnTimer := OnPoll;

  MainForm.ShowModal;

  PollTimer.Enabled := False;
  MainForm.Free;
end;
