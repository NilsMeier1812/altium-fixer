{..............................................................................}
{  Form-Test - Vorpruefung fuer den Live-Modus                                 }
{                                                                              }
{  ZWECK: klaeren, ob ein Skript-FORMULAR mit TTimer in dieser Altium-         }
{  Installation ueberhaupt laeuft, ohne einzufrieren. Nur wenn das geht, ist   }
{  ein "Altium lauscht alle 2 s"-Live-Modus moeglich.                          }
{                                                                              }
{  BEWUSST ein EIGENES, isoliertes Projekt (FormTest.PrjScr) - es hat nichts   }
{  mit dem funktionierenden VerbindungsCheck zu tun. Friert es ein, ist nur    }
{  dieses Testfenster betroffen; das Haupt-Skript bleibt unberuehrt.           }
{                                                                              }
{  BEDIENUNG:                                                                   }
{    FormTest.PrjScr oeffnen -> Run Script -> Prozedur RunFormTest.            }
{                                                                              }
{  ERWARTUNG bei Erfolg: Ein Fenster geht auf, der Zaehler zaehlt alle 2 s     }
{  hoch, und Altium bleibt daneben BEDIENBAR. Dann bitte melden: "Form-Test    }
{  ok" - dann baue ich den echten Live-Listener.                              }
{  Bei Misserfolg (kein Fenster / Einfrieren): auch melden - dann ist der      }
{  Live-Modus in diesem Altium nicht machbar und wir bleiben bei ApplyFixes.   }
{..............................................................................}

interface

type
  TFormTestForm = class(TForm)
    LabelInfo   : TLabel;
    ButtonClose : TButton;
    TimerTest   : TTimer;
    procedure ButtonCloseClick(Sender : TObject);
    procedure TimerTestTimer(Sender : TObject);
  end;

var
  FormTestForm : TFormTestForm;
  TickCount    : Integer;

implementation

procedure TFormTestForm.TimerTestTimer(Sender : TObject);
begin
  TickCount := TickCount + 1;
  LabelInfo.Caption :=
    'Timer laeuft. Ticks (alle 2 s): ' + IntToStr(TickCount) + #13#10#13#10 +
    'Bleibt Altium daneben bedienbar? Dann funktionieren Formulare -> ' +
    'Live-Modus ist moeglich. Zum Beenden auf Schliessen.';
end;

procedure TFormTestForm.ButtonCloseClick(Sender : TObject);
begin
  TimerTest.Enabled := False;
  Close;
end;

procedure RunFormTest;
begin
  // In Altium-Formular-Skripten wird die Form aus der .dfm AUTOMATISCH erzeugt.
  // Also NICHT selbst mit .Create anlegen (der Klassenname ist kein nutzbarer
  // Bezeichner) - einfach die vorhandene Instanz FormTestForm anzeigen.
  TickCount := 0;
  FormTestForm.ShowModal;
end;

end.
